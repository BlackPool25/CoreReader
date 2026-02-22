import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'android_saf.dart';
import 'settings_store.dart';
import 'ws_binary_to_bytes.dart';
import 'reader_stream_controller.dart';

class ChapterInfo {
  ChapterInfo({
    required this.title,
    required this.url,
    required this.nextUrl,
    required this.prevUrl,
    required this.sampleRate,
  });
  final String title;
  final String url;
  final String? nextUrl;
  final String? prevUrl;
  final int sampleRate;
}

class _LiveSentenceChunk {
  _LiveSentenceChunk({required this.pcm, required this.event});

  /// PCM16 mono bytes (must be 2-byte aligned).
  final Uint8List pcm;

  /// The sentence JSON event associated with this PCM chunk (may be null if the
  /// backend sent audio without a preceding sentence event).
  final Map<String, dynamic>? event;
}

class _ScheduledSentence {
  _ScheduledSentence({required this.startSample, required this.event});

  /// Absolute sample index from the start of the stream at which this sentence
  /// chunk begins.
  final int startSample;

  /// The event to emit on the public events stream.
  final Map<String, dynamic> event;
}

class NovelStreamController implements ReaderStreamController {
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final SoLoud _soloud = SoLoud.instance;
  bool _soloudReady = false;

  AudioSource? _audioSource;
  SoundHandle? _handle;
  int? _streamSampleRate;

  // Track how much PCM we have enqueued into the SoLoud buffer stream.
  // We clamp highlight time against this to avoid highlight drift when the
  // backend is slower than real-time (buffer underruns).
  int _enqueuedSamples = 0;

  Timer? _noAudioTimer;
  bool _receivedAnyAudio = false;

  int? _pcmCarryByte;

  // If the backend provides chunk sizing, we can assemble a full sentence chunk
  // even if the PCM arrives split across multiple binary messages.
  final BytesBuilder _partialSentencePcm = BytesBuilder(copy: false);

  // Live stream sentence-audio queue.
  final _pendingSentenceMeta = <Map<String, dynamic>>[];
  final _receivedSentenceAudio = <_LiveSentenceChunk>[];
  Timer? _chunkPumpTimer;
  bool _remoteChapterComplete = false;
  int _playedSentenceCount = 0;
  int _enqueuedSentenceCount = 0;
  static const int _targetSentenceLookahead = 3;

  // Highlight schedule for live streaming, keyed off exact enqueued sample boundaries.
  final _scheduledLiveSentences = <_ScheduledSentence>[];
  Timer? _liveTimelineTimer;

  // Offline playback state.
  Timer? _offlineTimelineTimer;
  int? _offlineReadHandle;
  bool _offlineActive = false;
  List<Map<String, dynamic>> _offlineTimeline = const [];
  int _offlineTimelineIdx = 0;
  int _offlineStartMs = 0;
  int _offlineEnqueuedSamples = 0;

  bool _connected = false;
  @override
  bool get connected => _connected;

  @override
  bool get active => _connected || _offlineActive;

  bool _paused = false;
  @override
  bool get paused => _paused;

  /// Initialize the audio engine in response to a user gesture.
  ///
  /// On Web, browsers may block audio initialization/playback unless triggered
  /// by an explicit user action.
  @override
  Future<void> primeAudio({int sampleRate = 24000}) async {
    try {
      await _ensureAudioStream(sampleRate);
    } catch (e) {
      _eventsController.add({'type': 'error', 'message': _formatAudioInitError(e)});
    }
  }

  String _formatAudioInitError(Object e) {
    final raw = e.toString();
    // Common Flutter Web failure from WASM worker/audio worklet initialization.
    if (raw.contains('createWorkerInWasm') || raw.contains('SharedArrayBuffer')) {
      return 'Audio init failed on Web. This usually requires cross-origin isolation headers (COOP/COEP) or a non-dev server. Raw: $raw';
    }
    return 'Audio init failed: $raw';
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _eventsController.close();
  }

  Future<void> _ensureAudioStream(int sampleRate) async {
    if (_audioSource != null && _streamSampleRate == sampleRate) return;

    if (!_soloudReady) {
      // Initialize the engine close to our PCM stream format.
      await _soloud.init(sampleRate: sampleRate, channels: Channels.mono);
      _soloudReady = true;
    }

    // Dispose any previous stream.
    if (_handle != null) {
      try {
        await _soloud.stop(_handle!);
      } catch (_) {}
    }
    if (_audioSource != null) {
      try {
        await _soloud.disposeSource(_audioSource!);
      } catch (_) {}
    }

    // Create a buffer stream that accepts PCM16 mono.
    final src = _soloud.setBufferStream(
      sampleRate: sampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
      bufferingType: BufferingType.released,
      // More headroom reduces audible gaps when synthesis/network jitter occurs.
      // Keep startup latency low; buffering pauses will happen at sentence boundaries
      // because the backend streams sentence-atomic chunks.
      bufferingTimeNeeds: 0.20,
      maxBufferSizeDuration: const Duration(minutes: 30),
    );
    final handle = await _soloud.play(src);

    _audioSource = src;
    _handle = handle;
    _streamSampleRate = sampleRate;

    _enqueuedSamples = 0;
    _offlineEnqueuedSamples = 0;

    // Reset live-queue state when we recreate the stream.
    _pendingSentenceMeta.clear();
    _receivedSentenceAudio.clear();
    _partialSentencePcm.clear();
    _remoteChapterComplete = false;
    _playedSentenceCount = 0;
    _enqueuedSentenceCount = 0;
    _chunkPumpTimer?.cancel();
    _chunkPumpTimer = null;
  }

  void _startLiveTimeline() {
    _liveTimelineTimer?.cancel();
    _liveTimelineTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (_audioSource == null || _scheduledLiveSentences.isEmpty) return;
      try {
        final src = _audioSource!;
        final sr = _streamSampleRate ?? 24000;

        // Prefer microseconds to reduce rounding drift.
        final consumedUs = _soloud.getStreamTimeConsumed(src).inMicroseconds;
        var consumedSamples = ((consumedUs * sr) / 1000000.0).floor();
        if (consumedSamples < 0) consumedSamples = 0;

        // Clamp to what we have actually enqueued.
        if (consumedSamples > _enqueuedSamples) consumedSamples = _enqueuedSamples;

        while (_scheduledLiveSentences.isNotEmpty) {
          final next = _scheduledLiveSentences.first;
          if (next.startSample > consumedSamples) break;
          _scheduledLiveSentences.removeAt(0);
          _eventsController.add(next.event);
          _playedSentenceCount++;
          _pumpSentenceAudio();
        }
      } catch (_) {
        // ignore
      }
    });
  }

  void _stopLiveTimeline() {
    _liveTimelineTimer?.cancel();
    _liveTimelineTimer = null;
    _scheduledLiveSentences.clear();

    _chunkPumpTimer?.cancel();
    _chunkPumpTimer = null;
    _pendingSentenceMeta.clear();
    _receivedSentenceAudio.clear();
    _remoteChapterComplete = false;
    _playedSentenceCount = 0;
    _enqueuedSentenceCount = 0;
  }

  void _pumpSentenceAudio() {
    if (_audioSource == null) return;

    // Enqueue enough audio to maintain a small sentence lookahead.
    while (_receivedSentenceAudio.isNotEmpty && (_enqueuedSentenceCount - _playedSentenceCount) < _targetSentenceLookahead) {
      final item = _receivedSentenceAudio.removeAt(0);
      try {
        final aligned = item.pcm;
        if (aligned.isNotEmpty) {
          final startSample = _enqueuedSamples;
          _soloud.addAudioDataStream(_audioSource!, aligned);
          _enqueuedSamples += aligned.length ~/ 2;

          // Schedule the sentence highlight exactly at the point this chunk
          // begins playing (sample-accurate with respect to what we actually
          // enqueued into SoLoud).
          final evt = item.event;
          if (evt != null) {
            _scheduledLiveSentences.add(_ScheduledSentence(startSample: startSample, event: evt));
          }
        }
      } catch (_) {
        // ignore
      }
      _enqueuedSentenceCount++;
    }

    // Finalize only when remote signaled completion AND we've drained our queue.
    if (_remoteChapterComplete && _receivedSentenceAudio.isEmpty) {
      // Flush any pending PCM carry byte to keep sample alignment.
      if (_pcmCarryByte != null) {
        try {
          final padded = Uint8List.fromList([_pcmCarryByte!, 0]);
          _pcmCarryByte = null;
          _soloud.addAudioDataStream(_audioSource!, padded);
        } catch (_) {
          // ignore
        }
      }
      try {
        _soloud.setDataIsEnded(_audioSource!);
      } catch (_) {
        // ignore
      }
    }
  }

  @override
  Future<void> connectAndPlay({
    required String url,
    required String voice,
    required double speed,
    int prefetch = 6,
    int startParagraph = 0,
  }) async {
    await stop();

    final base = await SettingsStore.getServerBaseUrl();
    final wsUri = SettingsStore.wsUri(base);
    _channel = WebSocketChannel.connect(wsUri);
    _connected = true;
    _paused = false;

    _receivedAnyAudio = false;
    _noAudioTimer?.cancel();
    _noAudioTimer = Timer(const Duration(seconds: 6), () {
      if (_connected && !_receivedAnyAudio) {
        _eventsController.add({
          'type': 'error',
          'message': 'No audio frames received from backend. Check Server URL and backend logs.',
        });
      }
    });

    _subscription = _channel!.stream.listen(
      (event) async {
        if (event is String) {
          final obj = jsonDecode(event);
          if (obj is Map<String, dynamic>) {
            if (obj['type'] == 'sentence') {
              // Queue sentence metadata so the next binary chunk can be paired
              // with it, ensuring highlights are driven by the actual PCM
              // chunk that gets enqueued.
              _pendingSentenceMeta.add(obj);
              return;
            }
            _eventsController.add(obj);
            if (obj['type'] == 'chapter_info') {
              final audio = (obj['audio'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
              final sampleRate = (audio['sample_rate'] as num?)?.toInt() ?? 24000;
              try {
                await _ensureAudioStream(sampleRate);
                _startLiveTimeline();
              } catch (e) {
                _eventsController.add({'type': 'error', 'message': _formatAudioInitError(e)});
              }
            }
            if (obj['type'] == 'chapter_complete') {
              // Mark completion; we finalize only after draining any locally
              // queued sentence audio.
              _remoteChapterComplete = true;
              _pumpSentenceAudio();
            }
          }
          return;
        }

        // Binary frames.
        final bytes = await wsBinaryToBytes(event);
        if (bytes == null) return;

        _receivedAnyAudio = true;

        // If we haven't received chapter_info yet, default to 24k.
        try {
          await _ensureAudioStream(_streamSampleRate ?? 24000);
        } catch (e) {
          _eventsController.add({'type': 'error', 'message': _formatAudioInitError(e)});
          return;
        }
        if (_audioSource != null) {
          try {
            // Pair PCM with sentence meta. Prefer assembling based on backend-provided
            // chunk_bytes/chunk_samples so we don't assume 1 WS binary message == 1 sentence.

            if (_pendingSentenceMeta.isNotEmpty) {
              final peek = _pendingSentenceMeta.first;
              final expectedBytes = (peek['chunk_bytes'] as num?)?.toInt() ?? 0;

              if (expectedBytes > 0) {
                _partialSentencePcm.add(bytes);
                if (_partialSentencePcm.length >= expectedBytes) {
                  final meta = _pendingSentenceMeta.removeAt(0);
                  final full = _partialSentencePcm.takeBytes();

                  // If we received more than expected, carry remainder forward.
                  if (full.length > expectedBytes) {
                    final used = full.sublist(0, expectedBytes);
                    final rem = full.sublist(expectedBytes);
                    if (rem.isNotEmpty) _partialSentencePcm.add(rem);
                    final aligned = _alignPcm16(Uint8List.fromList(used));
                    _receivedSentenceAudio.add(_LiveSentenceChunk(pcm: aligned, event: meta));
                  } else {
                    final aligned = _alignPcm16(Uint8List.fromList(full));
                    _receivedSentenceAudio.add(_LiveSentenceChunk(pcm: aligned, event: meta));
                  }
                }
              } else {
                // Legacy: assume each binary event is one sentence chunk.
                final meta = _pendingSentenceMeta.removeAt(0);
                final aligned = _alignPcm16(bytes);
                _receivedSentenceAudio.add(_LiveSentenceChunk(pcm: aligned, event: meta));
              }
            } else {
              // Audio without sentence meta (best-effort): still enqueue.
              final aligned = _alignPcm16(bytes);
              _receivedSentenceAudio.add(_LiveSentenceChunk(pcm: aligned, event: null));
            }

            // Start a small pump to keep lookahead filled, without dumping all
            // received data into the buffer at once.
            _chunkPumpTimer ??= Timer.periodic(const Duration(milliseconds: 40), (_) {
              if (!_connected || _audioSource == null) return;
              _pumpSentenceAudio();
              if (_remoteChapterComplete && _receivedSentenceAudio.isEmpty) {
                _chunkPumpTimer?.cancel();
                _chunkPumpTimer = null;
              }
            });

            _pumpSentenceAudio();
          } catch (e) {
            _eventsController.add({'type': 'error', 'message': e.toString()});
          }
        }
      },
      onDone: () {
        _connected = false;
        _eventsController.add({'type': 'disconnected'});
      },
      onError: (err) {
        _eventsController.add({'type': 'error', 'message': err.toString()});
      },
    );

    final payload = <String, dynamic>{
      'command': 'play',
      'url': url,
      'voice': voice,
      'speed': speed,
      'prefetch': prefetch,
      'frame_ms': 200,
      'start_paragraph': startParagraph,
      // Streaming should be paced; downloads explicitly set realtime=false.
      'realtime': true,
    };
    _channel!.sink.add(jsonEncode(payload));
  }

  @override
  Future<void> playDownloaded({
    required String treeUri,
    required List<String> pcmPath,
    required Map<String, dynamic> metaJson,
    required double playbackSpeed,
    int startParagraph = 0,
  }) async {
    await stop();

    final sampleRate = (metaJson['sampleRate'] as num?)?.toInt() ?? 24000;
    final title = (metaJson['title'] as String?) ?? 'Downloaded chapter';
    final url = (metaJson['url'] as String?) ?? '';
    final paragraphs = (metaJson['paragraphs'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    final rawTimeline = metaJson['timeline'];
    final timeline = <Map<String, dynamic>>[];
    if (rawTimeline is List) {
      for (final item in rawTimeline) {
        if (item is Map<String, dynamic>) {
          timeline.add(item);
        } else if (item is Map) {
          timeline.add(item.cast<String, dynamic>());
        }
      }
    }
    timeline.sort((a, b) => ((a['ms'] as num?)?.toInt() ?? 0).compareTo(((b['ms'] as num?)?.toInt() ?? 0)));

    // Compute a start offset based on requested paragraph.
    _offlineStartMs = 0;
    if (startParagraph > 0 && timeline.isNotEmpty) {
      for (final item in timeline) {
        final p = (item['p'] as num?)?.toInt() ?? 0;
        if (p >= startParagraph) {
          _offlineStartMs = (item['ms'] as num?)?.toInt() ?? 0;
          break;
        }
      }
    }

    _offlineTimeline = timeline;
    // Pre-advance past events that precede the start offset so the first timer
    // tick does not fire a catch-up burst of stale highlights.
    _offlineTimelineIdx = 0;
    if (_offlineStartMs > 0) {
      while (_offlineTimelineIdx < timeline.length) {
        final ms = (timeline[_offlineTimelineIdx]['ms'] as num?)?.toInt() ?? 0;
        if (ms >= _offlineStartMs) break;
        _offlineTimelineIdx++;
      }
    }
    _offlineActive = true;

    // Emit chapter_info (same shape as backend).
    _eventsController.add({
      'type': 'chapter_info',
      'title': title,
      'url': url,
      'next_url': null,
      'prev_url': null,
      'paragraphs': paragraphs,
      'start_paragraph': startParagraph,
      'audio': {
        'encoding': 'pcm_s16le',
        'sample_rate': sampleRate,
        'channels': 1,
        'frame_ms': 200,
      },
    });

    await _ensureAudioStream(sampleRate);
    // Do NOT call setRelativePlaySpeed here. The TTS speed is already baked
    // into the PCM at download time. Applying it again would double the effect
    // and engage SoLoud's linear interpolation resampler, causing crackling and
    // pitch distortion. Playback always runs at 1.0× (the natural sample rate).

    // Start a timer to emit sentence events based on stream time consumed.
    _offlineTimelineTimer?.cancel();
    _offlineTimelineTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!_offlineActive || _audioSource == null) return;
      try {
        final consumed = _soloud.getStreamTimeConsumed(_audioSource!).inMilliseconds;
        final sr = _streamSampleRate ?? sampleRate;
        final maxPlayableMs = _offlineStartMs + (((_offlineEnqueuedSamples * 1000) / sr).floor());
        final rawT = consumed + _offlineStartMs;
        final t = rawT <= maxPlayableMs ? rawT : maxPlayableMs;
        while (_offlineTimelineIdx < _offlineTimeline.length) {
          final item = _offlineTimeline[_offlineTimelineIdx];
          final ms = (item['ms'] as num?)?.toInt() ?? 0;
          if (ms > t) break;
          _offlineTimelineIdx++;
          _eventsController.add({
            'type': 'sentence',
            'text': (item['text'] as String?) ?? '',
            'paragraph_index': (item['p'] as num?)?.toInt() ?? 0,
            'sentence_index': (item['s'] as num?)?.toInt() ?? 0,
            if (item['cs'] != null) 'char_start': (item['cs'] as num?)?.toInt() ?? 0,
            if (item['ce'] != null) 'char_end': (item['ce'] as num?)?.toInt() ?? 0,
          });
        }
      } catch (_) {
        // ignore
      }
    });

    // Stream PCM from SAF into SoLoud buffer.
    final handle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: pcmPath);
    if (handle <= 0) {
      _eventsController.add({'type': 'error', 'message': 'Failed to open downloaded audio'});
      return;
    }
    _offlineReadHandle = handle;

    final skipBytes = ((_offlineStartMs / 1000.0) * sampleRate * 2).round();
    var skipped = 0;

    var chunkCount = 0;
    try {
      while (_offlineActive) {
        final chunk = await AndroidSaf.read(handle, maxBytes: 64 * 1024);
        if (chunk == null || chunk.isEmpty) break;
        if (skipped < skipBytes) {
          final remain = skipBytes - skipped;
          if (chunk.length <= remain) {
            skipped += chunk.length;
            continue;
          }
          final sliced = chunk.sublist(remain);
          skipped = skipBytes;
          if (sliced.isNotEmpty) {
            final aligned = _alignPcm16(sliced);
            if (aligned.isNotEmpty) {
              _soloud.addAudioDataStream(_audioSource!, aligned);
            }
          }
          continue;
        }

        final aligned = _alignPcm16(chunk);
        if (aligned.isNotEmpty) {
          _soloud.addAudioDataStream(_audioSource!, aligned);
          _offlineEnqueuedSamples += aligned.length ~/ 2;
        }

        // Light pacing: prevents some devices/drivers from glitching when
        // pushing large amounts of PCM immediately.
        chunkCount++;
        if ((chunkCount % 6) == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }

      // If we ended with a dangling byte, pad it to complete the last PCM16 sample.
      if (_pcmCarryByte != null && _audioSource != null) {
        try {
          final padded = Uint8List.fromList([_pcmCarryByte!, 0]);
          _pcmCarryByte = null;
          _soloud.addAudioDataStream(_audioSource!, padded);
        } catch (_) {
          // ignore
        }
      }

      if (_audioSource != null) {
        try {
          _soloud.setDataIsEnded(_audioSource!);
        } catch (_) {}
      }

      // Wait until playback finishes.
      while (_offlineActive && _handle != null && _soloud.getIsValidVoiceHandle(_handle!)) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      if (_offlineActive) {
        _eventsController.add({'type': 'chapter_complete', 'next_url': null, 'prev_url': null});
      }
    } catch (e) {
      _eventsController.add({'type': 'error', 'message': e.toString()});
    } finally {
      try {
        await AndroidSaf.closeRead(handle);
      } catch (_) {}
      _offlineReadHandle = null;
    }
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    if (_handle == null) return;
    try {
      _soloud.setRelativePlaySpeed(_handle!, speed);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    if (_connected && _channel != null) {
      _channel!.sink.add(jsonEncode({'command': 'pause'}));
    }
    if (_handle != null) {
      _soloud.setPause(_handle!, true);
    }
  }

  @override
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    if (_handle != null) {
      _soloud.setPause(_handle!, false);
    }
    if (_connected && _channel != null) {
      _channel!.sink.add(jsonEncode({'command': 'resume'}));
    }
  }

  @override
  Future<void> stop() async {
    _pcmCarryByte = null;
    _partialSentencePcm.clear();
    _pendingSentenceMeta.clear();
    _receivedSentenceAudio.clear();
    _scheduledLiveSentences.clear();
    _remoteChapterComplete = false;
    _playedSentenceCount = 0;
    _enqueuedSentenceCount = 0;
    _chunkPumpTimer?.cancel();
    _chunkPumpTimer = null;
    _stopLiveTimeline();
    _offlineActive = false;
    _offlineTimelineTimer?.cancel();
    _offlineTimelineTimer = null;
    if (_offlineReadHandle != null) {
      try {
        await AndroidSaf.closeRead(_offlineReadHandle!);
      } catch (_) {}
    }
    _offlineReadHandle = null;

    _noAudioTimer?.cancel();
    _noAudioTimer = null;
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode({'command': 'stop'}));
      } catch (_) {}
      try {
        await _channel!.sink.close();
      } catch (_) {}
    }

    await _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _connected = false;
    _paused = false;

    if (_handle != null) {
      try {
        await _soloud.stop(_handle!);
      } catch (_) {}
    }
    if (_audioSource != null) {
      try {
        _soloud.setDataIsEnded(_audioSource!);
      } catch (_) {}
      try {
        await _soloud.disposeSource(_audioSource!);
      } catch (_) {}
    }
    _handle = null;
    _audioSource = null;
    _streamSampleRate = null;
    _enqueuedSamples = 0;
    _offlineEnqueuedSamples = 0;
  }

  Uint8List _alignPcm16(Uint8List bytes) {
    if (bytes.isEmpty) return bytes;
    var chunk = bytes;
    if (_pcmCarryByte != null) {
      final merged = Uint8List(chunk.length + 1);
      merged[0] = _pcmCarryByte!;
      merged.setRange(1, merged.length, chunk);
      _pcmCarryByte = null;
      chunk = merged;
    }
    if (chunk.length.isOdd) {
      _pcmCarryByte = chunk.last;
      return chunk.sublist(0, chunk.length - 1);
    }
    return chunk;
  }
}
