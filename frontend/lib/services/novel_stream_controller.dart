import 'dart:async';
import 'dart:convert';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  Timer? _noAudioTimer;
  bool _receivedAnyAudio = false;

  bool _connected = false;
  @override
  bool get connected => _connected;

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
      bufferingTimeNeeds: 1.0,
      maxBufferSizeDuration: const Duration(minutes: 30),
    );
    final handle = await _soloud.play(src);

    _audioSource = src;
    _handle = handle;
    _streamSampleRate = sampleRate;
  }

  @override
  Future<void> connectAndPlay({
    required String url,
    required String voice,
    required double speed,
    int prefetch = 3,
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
            _eventsController.add(obj);
            if (obj['type'] == 'chapter_info') {
              final audio = (obj['audio'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
              final sampleRate = (audio['sample_rate'] as num?)?.toInt() ?? 24000;
              try {
                await _ensureAudioStream(sampleRate);
              } catch (e) {
                _eventsController.add({'type': 'error', 'message': _formatAudioInitError(e)});
              }
            }
            if (obj['type'] == 'chapter_complete') {
              if (_audioSource != null) {
                try {
                  _soloud.setDataIsEnded(_audioSource!);
                } catch (_) {}
              }
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
            _soloud.addAudioDataStream(_audioSource!, bytes);
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
    };
    _channel!.sink.add(jsonEncode(payload));
  }

  @override
  Future<void> pause() async {
    if (!_connected || _channel == null) return;
    if (_paused) return;
    _paused = true;
    _channel!.sink.add(jsonEncode({'command': 'pause'}));
    if (_handle != null) {
      _soloud.setPause(_handle!, true);
    }
  }

  @override
  Future<void> resume() async {
    if (!_connected || _channel == null) return;
    if (!_paused) return;
    _paused = false;
    if (_handle != null) {
      _soloud.setPause(_handle!, false);
    }
    _channel!.sink.add(jsonEncode({'command': 'resume'}));
  }

  @override
  Future<void> stop() async {
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
  }
}
