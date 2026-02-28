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
  _ScheduledSentence({required this.startMs, required this.event});

  /// Millisecond offset from the start of the stream at which this sentence
  /// chunk begins. Compared directly against
  /// [SoLoud.getStreamTimeConsumed().inMilliseconds] — no sample-rate
  /// conversion needed, so it works regardless of the browser AudioContext
  /// native sample rate (44100/48000 Hz) vs our PCM rate (24000 Hz).
  final int startMs;

  /// The event to emit on the public events stream.
  final Map<String, dynamic> event;
}

/// A cached sentence PCM chunk with its metadata event.
class _CachedSentence {
  _CachedSentence({required this.pcm, required this.event});
  final Uint8List pcm;
  final Map<String, dynamic>? event;
}

/// In-memory audio cache for a single chapter, keyed by URL.
class _ChapterAudioCache {
  _ChapterAudioCache({required this.url, required this.chapterInfoEvent});
  final String url;
  final Map<String, dynamic> chapterInfoEvent;
  /// Ordered list of cached sentences — each contains PCM and metadata.
  final List<_CachedSentence> sentences = [];
  /// Paragraph index of the first cached sentence (always 0 for full chapters).
  int startParagraph = 0;
  bool chapterComplete = false;
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

  // Total samples enqueued into the SoLoud buffer so far.
  // Used to compute the ms offset for each sentence's highlight.
  int _enqueuedSamples = 0;
  // Total ms of audio enqueued so far (derived from _enqueuedSamples).
  int _enqueuedMs = 0;

  // ---------- Wall-clock playback timer ----------
  // We do NOT use SoLoud.getStreamTimeConsumed() because on Chrome Web it
  // advances at (nativeAudioContextRate / ourStreamRate) × real time — e.g.
  // 2× when the browser AudioContext is 48 kHz and our PCM is 24 kHz.
  // Instead we keep our own Stopwatch-based clock that accounts for
  // pause/resume and playback-speed changes.
  final Stopwatch _playbackClock = Stopwatch();
  double _playbackSpeedMultiplier = 1.0;
  int _accumulatedPlaybackMs = 0;
  bool _clockStarted = false;

  /// Effective playback position in ms, accounting for speed changes and pauses.
  int _playbackElapsedMs() =>
      _accumulatedPlaybackMs +
      (_playbackClock.elapsedMilliseconds * _playbackSpeedMultiplier).round();

  Timer? _noAudioTimer;
  bool _receivedAnyAudio = false;

  int? _pcmCarryByte;

  // Sentence metadata queue: each incoming binary PCM chunk is paired with the
  // most recent JSON sentence event that preceded it.
  final BytesBuilder _partialSentencePcm = BytesBuilder(copy: false);
  final _pendingSentenceMeta = <Map<String, dynamic>>[];
  // Assembled sentence chunks waiting to be enqueued into SoLoud.
  final _receivedSentenceAudio = <_LiveSentenceChunk>[];
  bool _remoteChapterComplete = false;

  // Highlight schedule for live streaming.
  // Sentences are enqueued into SoLoud as soon as they arrive, and their
  // start-ms is recorded here. The 40 ms timer fires each highlight when
  // _playbackElapsedMs() reaches that ms offset.
  final _scheduledLiveSentences = <_ScheduledSentence>[];
  Timer? _liveTimelineTimer;

  // Offline playback state.
  Timer? _offlineTimelineTimer;
  int? _offlineReadHandle;
  bool _offlineActive = false;
  bool _offlineFlacMode = false;
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

  int _lastHeardParagraphIndex = -1;
  @override
  int get lastHeardParagraphIndex => _lastHeardParagraphIndex;

  // ---------------------------------------------------------------------------
  // In-memory audio cache (sliding window of up to 3 chapters)
  // ---------------------------------------------------------------------------
  static const int _maxCachedChapters = 3;
  final List<_ChapterAudioCache> _audioCache = [];
  /// The URL of the chapter currently being streamed into cache.
  String? _currentlyCachingUrl;

  _ChapterAudioCache? _cacheForUrl(String url) {
    for (final c in _audioCache) {
      if (c.url == url) return c;
    }
    return null;
  }

  void _evictOldCaches() {
    while (_audioCache.length > _maxCachedChapters) {
      _audioCache.removeAt(0);
    }
  }

  @override
  bool hasCachedAudio(String url, int startParagraph) {
    final cache = _cacheForUrl(url);
    if (cache == null || cache.sentences.isEmpty) return false;
    // Check if we have any sentence at or after the requested paragraph.
    return cache.sentences.any((s) {
      final pIdx = (s.event?['paragraph_index'] as num?)?.toInt() ?? -1;
      return pIdx >= startParagraph;
    });
  }

  @override
  Future<bool> replayFromCache({
    required String url,
    required int startParagraph,
  }) async {
    final cache = _cacheForUrl(url);
    if (cache == null || cache.sentences.isEmpty) return false;

    await stop();

    // Re-emit chapter_info so the reader rebuilds paragraphs.
    _eventsController.add(cache.chapterInfoEvent);

    final audio = (cache.chapterInfoEvent['audio'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final sampleRate = (audio['sample_rate'] as num?)?.toInt() ?? 24000;
    await _ensureAudioStream(sampleRate);

    // Find the first cached sentence at or after the requested paragraph.
    var startIdx = 0;
    for (var i = 0; i < cache.sentences.length; i++) {
      final pIdx = (cache.sentences[i].event?['paragraph_index'] as num?)?.toInt() ?? -1;
      if (pIdx >= startParagraph) {
        startIdx = i;
        break;
      }
    }

    _startLiveTimeline();

    // Enqueue cached PCM into SoLoud and schedule highlights.
    for (var i = startIdx; i < cache.sentences.length; i++) {
      final item = cache.sentences[i];
      if (item.pcm.isNotEmpty) {
        if (!_clockStarted) {
          _clockStarted = true;
          _playbackClock.reset();
          _playbackClock.start();
        }
        final startMs = (_enqueuedSamples * 1000) ~/ sampleRate;
        _soloud.addAudioDataStream(_audioSource!, item.pcm);
        _enqueuedSamples += item.pcm.length ~/ 2;
        _enqueuedMs = (_enqueuedSamples * 1000) ~/ sampleRate;

        if (item.event != null) {
          _scheduledLiveSentences.add(
            _ScheduledSentence(startMs: startMs, event: item.event!),
          );
        }
      }
      // Yield every few chunks to keep UI responsive.
      if ((i - startIdx) % 10 == 9) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (cache.chapterComplete) {
      try {
        _soloud.setDataIsEnded(_audioSource!);
      } catch (_) {}
      // Wait for audio to finish, then emit chapter_complete.
      unawaited(() async {
        while (_handle != null && _soloud.getIsValidVoiceHandle(_handle!)) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        _eventsController.add({'type': 'chapter_complete', 'next_url': null, 'prev_url': null});
      }());
    }

    _connected = false; // Not connected to WS, but audio is active via cache.
    return true;
  }

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
      await _soloud.init(sampleRate: sampleRate, channels: Channels.mono);
      _soloudReady = true;
    }

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

    final src = _soloud.setBufferStream(
      sampleRate: sampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 1.0,
      maxBufferSizeDuration: const Duration(minutes: 30),
    );
    final handle = await _soloud.play(src);

    _audioSource = src;
    _handle = handle;
    _streamSampleRate = sampleRate;

    _enqueuedSamples = 0;
    _enqueuedMs = 0;
    _offlineEnqueuedSamples = 0;
    _accumulatedPlaybackMs = 0;
    _playbackSpeedMultiplier = 1.0;
    _clockStarted = false;
    _playbackClock.stop();
    _playbackClock.reset();
    // Clock starts lazily in _pumpSentenceAudio when first data is enqueued.

    _pendingSentenceMeta.clear();
    _receivedSentenceAudio.clear();
    _partialSentencePcm.clear();
    _remoteChapterComplete = false;
  }

  // ---------------------------------------------------------------------------
  // Live-stream highlight timeline
  // ---------------------------------------------------------------------------

  void _startLiveTimeline() {
    _liveTimelineTimer?.cancel();
    _liveTimelineTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (_audioSource == null || _scheduledLiveSentences.isEmpty) return;
      try {
        var elapsedMs = _playbackElapsedMs();
        if (elapsedMs < 0) elapsedMs = 0;
        // Clamp to what we have actually enqueued.
        if (elapsedMs > _enqueuedMs) elapsedMs = _enqueuedMs;

        while (_scheduledLiveSentences.isNotEmpty) {
          final next = _scheduledLiveSentences.first;
          if (next.startMs > elapsedMs) break;
          _scheduledLiveSentences.removeAt(0);
          // Track the last actually-heard sentence for pause-resume accuracy.
          final pIdx = (next.event['paragraph_index'] as num?)?.toInt();
          if (pIdx != null) _lastHeardParagraphIndex = pIdx;
          _eventsController.add(next.event);
        }
      } catch (_) {
        // ignore timer errors; stream may have been disposed
      }
    });
  }

  void _stopLiveTimeline() {
    _liveTimelineTimer?.cancel();
    _liveTimelineTimer = null;
    _scheduledLiveSentences.clear();

    _pendingSentenceMeta.clear();
    _receivedSentenceAudio.clear();
    _remoteChapterComplete = false;
  }

  // ---------------------------------------------------------------------------
  // Audio pump — enqueue ALL assembled sentence chunks into SoLoud immediately.
  //
  // KEY DESIGN: the pump is NOT gated on how many highlights have fired.
  // Previously enqueueing was throttled by (_enqueuedCount - _playedCount) < N,
  // which created a feedback loop: early highlights → more audio enqueued →
  // highlights enqueued at a sample offset that fires even earlier → cascade.
  // Now we enqueue as fast as chunks arrive from the backend; the highlight
  // schedule is a read-only side-effect of enqueueing, never a governor of it.
  // ---------------------------------------------------------------------------

  void _pumpSentenceAudio() {
    if (_audioSource == null) return;
    // Don't enqueue new audio while paused — prevents buffer from growing
    // and keeps the pause position accurate.
    if (_paused) return;
    final sr = _streamSampleRate ?? 24000;

    // Drain all assembled chunks into SoLoud unconditionally.
    while (_receivedSentenceAudio.isNotEmpty) {
      final item = _receivedSentenceAudio.removeAt(0);
      try {
        final aligned = item.pcm;
        if (aligned.isNotEmpty) {
          // Start the playback clock on the FIRST audio chunk enqueued.
          // This eliminates the ~2s dead time between play() and when the
          // backend actually sends the first synthesised audio.
          if (!_clockStarted) {
            _clockStarted = true;
            _playbackClock.reset();
            _playbackClock.start();
          }
          // Compute the ms at which this chunk starts BEFORE adding it.
          final startMs = (_enqueuedSamples * 1000) ~/ sr;
          _soloud.addAudioDataStream(_audioSource!, aligned);
          _enqueuedSamples += aligned.length ~/ 2;
          _enqueuedMs = (_enqueuedSamples * 1000) ~/ sr;

          final evt = item.event;
          if (evt != null) {
            _scheduledLiveSentences.add(
              _ScheduledSentence(startMs: startMs, event: evt),
            );
          }

          // Store in in-memory cache for potential rewind.
          if (_currentlyCachingUrl != null) {
            _cacheForUrl(_currentlyCachingUrl!)?.sentences.add(
              _CachedSentence(pcm: Uint8List.fromList(aligned), event: item.event),
            );
          }
        }
      } catch (_) {
        // ignore individual chunk errors
      }
    }

    // Signal end-of-stream only after we've received the chapter_complete from
    // the backend AND have drained every received chunk.
    if (_remoteChapterComplete && _receivedSentenceAudio.isEmpty) {
      if (_pcmCarryByte != null) {
        try {
          final padded = Uint8List.fromList([_pcmCarryByte!, 0]);
          _pcmCarryByte = null;
          _soloud.addAudioDataStream(_audioSource!, padded);
        } catch (_) {}
      }
      try {
        _soloud.setDataIsEnded(_audioSource!);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Future<void> connectAndPlay({
    required String url,
    required String voice,
    required double speed,
    int prefetch = 6,
    int startParagraph = 0,
  }) async {
    await stop();

    _currentlyCachingUrl = url;

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
              // Initialise in-memory cache for this chapter.
              if (_currentlyCachingUrl != null) {
                _audioCache.removeWhere((c) => c.url == _currentlyCachingUrl);
                _audioCache.add(_ChapterAudioCache(
                  url: _currentlyCachingUrl!,
                  chapterInfoEvent: obj,
                ));
                _evictOldCaches();
              }
            }
            if (obj['type'] == 'chapter_complete') {
              _remoteChapterComplete = true;
              _pumpSentenceAudio();
              // Mark cache as complete.
              if (_currentlyCachingUrl != null) {
                _cacheForUrl(_currentlyCachingUrl!)?.chapterComplete = true;
              }
            }
          }
          return;
        }

        // Binary frames — assemble into sentence chunks and pump immediately.
        final bytes = await wsBinaryToBytes(event);
        if (bytes == null) return;

        _receivedAnyAudio = true;

        try {
          await _ensureAudioStream(_streamSampleRate ?? 24000);
        } catch (e) {
          _eventsController.add({'type': 'error', 'message': _formatAudioInitError(e)});
          return;
        }

        if (_audioSource != null) {
          try {
            if (_pendingSentenceMeta.isNotEmpty) {
              final peek = _pendingSentenceMeta.first;
              final expectedBytes = (peek['chunk_bytes'] as num?)?.toInt() ?? 0;

              if (expectedBytes > 0) {
                _partialSentencePcm.add(bytes);
                if (_partialSentencePcm.length >= expectedBytes) {
                  final meta = _pendingSentenceMeta.removeAt(0);
                  final full = _partialSentencePcm.takeBytes();

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

            // Pump immediately — no throttling against highlight count.
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
    _offlineTimelineIdx = 0;
    if (_offlineStartMs > 0) {
      while (_offlineTimelineIdx < timeline.length) {
        final ms = (timeline[_offlineTimelineIdx]['ms'] as num?)?.toInt() ?? 0;
        if (ms >= _offlineStartMs) break;
        _offlineTimelineIdx++;
      }
    }
    _offlineActive = true;

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

    final audioFormat = (metaJson['audioFormat'] as String?) ?? 'pcm';
    _offlineFlacMode = audioFormat == 'flac';

    if (_offlineFlacMode) {
      await _playDownloadedFlac(
        treeUri: treeUri,
        audioPath: pcmPath,
        sampleRate: sampleRate,
        playbackSpeed: playbackSpeed,
      );
      return;
    }

    // ---------- PCM buffer-stream path ----------
    _offlineFlacMode = false;
    await _ensureAudioStream(sampleRate);

    // Apply the playback speed multiplier for the offline chapter.
    if (_handle != null && (playbackSpeed - 1.0).abs() > 0.001) {
      try {
        _soloud.setRelativePlaySpeed(_handle!, playbackSpeed);
        // Sync our clock speed with SoLoud's speed.
        _accumulatedPlaybackMs = _playbackElapsedMs();
        _playbackClock.reset();
        _playbackClock.start();
        _playbackSpeedMultiplier = playbackSpeed;
      } catch (_) {}
    }

    // Drive highlights via our wall-clock playback timer.
    _startOfflineTimeline(sampleRate);

    // Stream PCM from SAF into SoLoud buffer.
    final handle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: pcmPath);
    if (handle <= 0) {
      _eventsController.add({'type': 'error', 'message': 'Failed to open downloaded audio'});
      return;
    }
    _offlineReadHandle = handle;

    final skipBytes = ((_offlineStartMs / 1000.0) * sampleRate * 2).round();
    var skipped = 0;

    // Pre-buffer ~2s of audio before starting the playback clock to avoid
    // glitches at the beginning of downloaded chapter playback.
    final preBufferBytes = sampleRate * 2 * 2; // 2 seconds of PCM16 mono
    var preBuffered = 0;
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
              _offlineEnqueuedSamples += aligned.length ~/ 2;
              preBuffered += aligned.length;
            }
          }
          continue;
        }

        final aligned = _alignPcm16(chunk);
        if (aligned.isNotEmpty) {
          _soloud.addAudioDataStream(_audioSource!, aligned);
          _offlineEnqueuedSamples += aligned.length ~/ 2;
          preBuffered += aligned.length;
          // Start the playback clock only after pre-buffering is complete.
          if (!_clockStarted && preBuffered >= preBufferBytes) {
            _clockStarted = true;
            _playbackClock.reset();
            _playbackClock.start();
          }
        }

        chunkCount++;
        // Yield every 4 chunks (~256KB) to keep the UI responsive and avoid
        // overwhelming the SoLoud buffer.
        if ((chunkCount % 4) == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
      }

      // Start the clock in case the file was shorter than the pre-buffer target.
      if (!_clockStarted && _offlineEnqueuedSamples > 0) {
        _clockStarted = true;
        _playbackClock.reset();
        _playbackClock.start();
      }

      if (_pcmCarryByte != null && _audioSource != null) {
        try {
          final padded = Uint8List.fromList([_pcmCarryByte!, 0]);
          _pcmCarryByte = null;
          _soloud.addAudioDataStream(_audioSource!, padded);
        } catch (_) {}
      }

      if (_audioSource != null) {
        try {
          _soloud.setDataIsEnded(_audioSource!);
        } catch (_) {}
      }

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

  /// Play a downloaded FLAC file using SoLoud's native decoding.
  Future<void> _playDownloadedFlac({
    required String treeUri,
    required List<String> audioPath,
    required int sampleRate,
    required double playbackSpeed,
  }) async {
    // Read the entire FLAC file from SAF into memory.
    final flacHandle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: audioPath);
    if (flacHandle <= 0) {
      _eventsController.add({'type': 'error', 'message': 'Failed to open downloaded FLAC audio'});
      return;
    }

    final builder = BytesBuilder(copy: false);
    try {
      while (true) {
        final chunk = await AndroidSaf.read(flacHandle, maxBytes: 256 * 1024);
        if (chunk == null || chunk.isEmpty) break;
        builder.add(chunk);
      }
    } finally {
      try { await AndroidSaf.closeRead(flacHandle); } catch (_) {}
    }

    final flacBytes = builder.toBytes();
    if (flacBytes.isEmpty) {
      _eventsController.add({'type': 'error', 'message': 'Downloaded FLAC file is empty'});
      return;
    }

    // Validate FLAC header: must start with 'fLaC' magic and be >100 bytes.
    if (flacBytes.length < 100 ||
        flacBytes[0] != 0x66 || // 'f'
        flacBytes[1] != 0x4C || // 'L'
        flacBytes[2] != 0x61 || // 'a'
        flacBytes[3] != 0x43) { // 'C'
      _eventsController.add({
        'type': 'error',
        'message': 'Downloaded FLAC file is corrupt '
            '(${flacBytes.length} bytes, header: ${flacBytes.length >= 4 ? flacBytes.sublist(0, 4) : flacBytes}). '
            'Try re-downloading the chapter.',
      });
      return;
    }

    // Ensure SoLoud is initialised.
    if (!_soloudReady) {
      await _soloud.init(sampleRate: sampleRate, channels: Channels.mono);
      _soloudReady = true;
    }

    // Dispose any previous source/handle.
    if (_handle != null) {
      try { await _soloud.stop(_handle!); } catch (_) {}
    }
    if (_audioSource != null) {
      try { await _soloud.disposeSource(_audioSource!); } catch (_) {}
    }

    // Load FLAC into SoLoud via loadMem (native dr_flac/libFLAC decoder).
    final AudioSource src;
    final SoundHandle handle;
    try {
      src = await _soloud.loadMem('offline_chapter.flac', flacBytes);
      handle = await _soloud.play(src);
    } catch (e) {
      _eventsController.add({
        'type': 'error',
        'message': 'Failed to decode FLAC audio: $e. Try re-downloading.',
      });
      return;
    }
    _audioSource = src;
    _handle = handle;
    _streamSampleRate = sampleRate;

    // Seek to the start paragraph offset.
    if (_offlineStartMs > 0) {
      _soloud.seek(handle, Duration(milliseconds: _offlineStartMs));
    }

    // Apply playback speed.
    if ((playbackSpeed - 1.0).abs() > 0.001) {
      try {
        _soloud.setRelativePlaySpeed(handle, playbackSpeed);
        _playbackSpeedMultiplier = playbackSpeed;
      } catch (_) {}
    }

    // The clock is not used for FLAC mode — getPosition() is authoritative.
    _clockStarted = true;

    // Drive highlights via SoLoud's getPosition.
    _startOfflineTimeline(sampleRate);

    // Wait for playback to finish.
    try {
      while (_offlineActive && _handle != null && _soloud.getIsValidVoiceHandle(_handle!)) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (_offlineActive) {
        _eventsController.add({'type': 'chapter_complete', 'next_url': null, 'prev_url': null});
      }
    } catch (e) {
      _eventsController.add({'type': 'error', 'message': e.toString()});
    }
  }

  /// Start (or restart) the periodic timer that drives offline highlight events.
  void _startOfflineTimeline(int sampleRate) {
    _offlineTimelineTimer?.cancel();
    _offlineTimelineTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!_offlineActive || _handle == null) return;
      try {
        int t;
        if (_offlineFlacMode) {
          // FLAC: SoLoud natively tracks position.
          t = _soloud.getPosition(_handle!).inMilliseconds;
        } else {
          // PCM buffer-stream: use wall-clock timer.
          final elapsedMs = _playbackElapsedMs();
          final sr = _streamSampleRate ?? sampleRate;
          final maxPlayableMs = _offlineStartMs + (((_offlineEnqueuedSamples * 1000) / sr).floor());
          final rawT = elapsedMs + _offlineStartMs;
          t = rawT <= maxPlayableMs ? rawT : maxPlayableMs;
        }
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
          final pIdxOff = (item['p'] as num?)?.toInt();
          if (pIdxOff != null) _lastHeardParagraphIndex = pIdxOff;
        }
      } catch (_) {
        // ignore
      }
    });
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    // Snapshot the effective elapsed time before changing the multiplier.
    _accumulatedPlaybackMs = _playbackElapsedMs();
    _playbackClock.reset();
    _playbackClock.start();
    _playbackSpeedMultiplier = speed;
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

    // 1. Stop audio output FIRST — this is the critical user-facing action.
    //    Must come before the WS send which can throw on flaky connections.
    if (_handle != null) {
      try {
        _soloud.setPause(_handle!, true);
      } catch (_) {}
    }

    // 2. Freeze the playback clock so highlights stop advancing.
    _accumulatedPlaybackMs = _playbackElapsedMs();
    _playbackClock.stop();
    _playbackClock.reset(); // Reset so _playbackElapsedMs() doesn't double-count.

    // 3. Cancel highlight timers — no events should fire while paused.
    _liveTimelineTimer?.cancel();
    _offlineTimelineTimer?.cancel();

    // 4. Tell the backend to stop sending new audio.
    if (_connected && _channel != null) {
      try {
        _channel!.sink.add(jsonEncode({'command': 'pause'}));
      } catch (_) {}
    }
  }

  @override
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;

    // Resume the playback clock from where we paused.
    _playbackClock.reset();
    _playbackClock.start();

    // Resume audio output.
    if (_handle != null) {
      try {
        _soloud.setPause(_handle!, false);
      } catch (_) {}
    }

    // Restart highlight timers.
    if (_scheduledLiveSentences.isNotEmpty) {
      _startLiveTimeline();
    }
    // Offline timeline timer is restarted only if offline playback is active.
    if (_offlineActive && _offlineTimeline.isNotEmpty) {
      _startOfflineTimeline(_streamSampleRate ?? 24000);
    }

    // Tell the backend to resume sending audio.
    if (_connected && _channel != null) {
      try {
        _channel!.sink.add(jsonEncode({'command': 'resume'}));
      } catch (_) {}
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
    _stopLiveTimeline();
    _offlineActive = false;
    _offlineFlacMode = false;
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
    _enqueuedMs = 0;
    _offlineEnqueuedSamples = 0;
    _accumulatedPlaybackMs = 0;
    _playbackSpeedMultiplier = 1.0;
    _clockStarted = false;
    _playbackClock.stop();
    _playbackClock.reset();
    _lastHeardParagraphIndex = -1;
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
