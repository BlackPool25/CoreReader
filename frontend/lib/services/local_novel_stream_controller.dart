import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:kokoro_tts_flutter/kokoro_tts_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'local_kokoro_voice_bank.dart';
import 'reader_stream_controller.dart';

class _NovelCoolChapter {
  _NovelCoolChapter({
    required this.title,
    required this.url,
    required this.paragraphs,
    required this.nextUrl,
    required this.prevUrl,
  });

  final String title;
  final String url;
  final List<String> paragraphs;
  final String? nextUrl;
  final String? prevUrl;
}

class _NovelCoolScraper {
  const _NovelCoolScraper();

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36'
  };

  Future<_NovelCoolChapter> scrapeChapter(String url) async {
    final res = await http.get(Uri.parse(url), headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch page: ${res.statusCode}');
    }

    final doc = html_parser.parse(res.body);
    final h1 = doc.querySelector('h1');
    var title = h1?.text.trim();
    if (title == null || title.isEmpty) {
      final t = doc.querySelector('title')?.text.trim() ?? 'Unknown Chapter';
      title = t.split(' - Novel Cool').first.trim();
      if (title.isEmpty) title = t;
    }

    var content = doc.querySelector('div.site-content div.overflow-hidden');
    if (content == null) {
      // Fallback: pick the div with most <p>.
      var best = content;
      var bestCount = -1;
      for (final div in doc.querySelectorAll('div')) {
        final c = div.querySelectorAll('p').length;
        if (c > bestCount) {
          bestCount = c;
          best = div;
        }
      }
      content = best;
    }

    if (content == null) {
      throw Exception('Could not find chapter content container');
    }

    final paragraphs = <String>[];
    for (final p in content.querySelectorAll('p')) {
      final txt = p.text.trim();
      if (txt.isEmpty) continue;
      if (p.classes.contains('chapter-end-mark') || txt.toLowerCase() == 'chapter end') {
        break;
      }
      paragraphs.add(txt);
    }
    if (paragraphs.isEmpty) {
      final raw = content.text;
      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) paragraphs.add(t);
      }
    }

    String? nextUrl;
    String? prevUrl;
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null || !href.contains('/chapter/')) continue;
      final t = a.text.trim();
      if (nextUrl == null && t.contains('Next')) {
        nextUrl = Uri.parse(url).resolve(href).toString();
      }
      if (prevUrl == null && t.contains('Prev')) {
        prevUrl = Uri.parse(url).resolve(href).toString();
      }
      if (nextUrl != null && prevUrl != null) break;
    }

    return _NovelCoolChapter(
      title: title,
      url: url,
      paragraphs: paragraphs,
      nextUrl: nextUrl,
      prevUrl: prevUrl,
    );
  }
}

class _KokoroModelPaths {
  const _KokoroModelPaths({
    required this.modelPath,
  });

  final String modelPath;
}

class _KokoroModelManager {
  // Smaller (and usually faster) model for phones.
  static const _modelUrl =
      'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx';

  static Future<_KokoroModelPaths> ensure() async {
    final dir = await getApplicationSupportDirectory();
    final kokoroDir = Directory('${dir.path}/kokoro');
    if (!await kokoroDir.exists()) {
      await kokoroDir.create(recursive: true);
    }
    final modelFile = File('${kokoroDir.path}/kokoro-v1.0.int8.onnx');

    if (!await modelFile.exists()) {
      await _downloadToFile(_modelUrl, modelFile);
    }

    return _KokoroModelPaths(
      modelPath: modelFile.path,
    );
  }

  static Future<void> _downloadToFile(String url, File outFile) async {
    final req = http.Request('GET', Uri.parse(url));
    final client = http.Client();
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw Exception('Download failed (${res.statusCode}) for $url');
      }
      final sink = outFile.openWrite();
      try {
        await res.stream.pipe(sink);
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close();
    }
  }
}

class LocalNovelStreamController implements ReaderStreamController {
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  final SoLoud _soloud = SoLoud.instance;
  bool _soloudReady = false;
  AudioSource? _audioSource;
  SoundHandle? _handle;
  int? _streamSampleRate;

  final _scraper = const _NovelCoolScraper();
  final LocalKokoroVoiceBank _voiceBank = LocalKokoroVoiceBank();
  Tokenizer? _tokenizer;
  _KokoroModelPaths? _modelPaths;

  final OnnxRuntime _ort = OnnxRuntime();
  OrtSession? _session;
  bool _sessionReady = false;

  bool _connected = false;
  @override
  bool get connected => _connected;

  bool _paused = false;
  @override
  bool get paused => _paused;

  bool _stopRequested = false;

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
      bufferingTimeNeeds: 0.25,
      maxBufferSizeDuration: const Duration(minutes: 30),
    );
    final handle = await _soloud.play(src);

    _audioSource = src;
    _handle = handle;
    _streamSampleRate = sampleRate;
  }

  Future<void> _ensureEngineReady() async {
    if (_tokenizer != null && _sessionReady && _session != null) return;

    _modelPaths ??= await _KokoroModelManager.ensure();
    final tokenizer = Tokenizer();
    await tokenizer.ensureInitialized();

    _session ??= await _ort.createSession(_modelPaths!.modelPath);
    _sessionReady = true;
    _tokenizer = tokenizer;
  }

  Future<Float32List> _runInference({
    required List<int> tokens,
    required Float32List styleVector,
    required double speed,
  }) async {
    if (_session == null || !_sessionReady) {
      throw Exception('Model session not initialized');
    }

    final paddedTokens = <int>[0, ...tokens, 0];
    final inputNames = _session!.inputNames;
    if (inputNames.length < 3) {
      throw Exception('Model requires at least 3 inputs');
    }

    final inputs = <String, OrtValue>{};
    final created = <OrtValue>[];
    try {
      final tokenTensor = await OrtValue.fromList(
        Int64List.fromList(paddedTokens),
        [1, paddedTokens.length],
      );
      created.add(tokenTensor);

      final styleTensor = await OrtValue.fromList(
        styleVector,
        [1, styleVector.length],
      );
      created.add(styleTensor);

      final speedTensor = await OrtValue.fromList(
        Float32List.fromList([speed.toDouble()]),
        [1],
      );
      created.add(speedTensor);

      if (inputNames.contains('input_ids')) {
        inputs['input_ids'] = tokenTensor;
        inputs['style'] = styleTensor;
        inputs['speed'] = speedTensor;
      } else {
        inputs[inputNames[0]] = tokenTensor;
        inputs[inputNames[1]] = styleTensor;
        inputs[inputNames[2]] = speedTensor;
      }

      final outputs = await _session!.run(inputs);
      final outputNames = _session!.outputNames;
      if (outputNames.isEmpty || outputs.isEmpty) {
        throw Exception('Model has no outputs');
      }
      final out = outputs[outputNames[0]];
      if (out == null) throw Exception('Output tensor is null');

      final raw = await out.asFlattenedList();
      final floats = Float32List(raw.length);
      for (var i = 0; i < raw.length; i++) {
        floats[i] = (raw[i] as num).toDouble();
      }
      return floats;
    } finally {
      for (final v in created) {
        try {
          await v.dispose();
        } catch (_) {}
      }
    }
  }

  Uint8List _floatToPcm16(Float32List samples) {
    if (samples.isEmpty) return Uint8List(0);
    double maxAbs = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > maxAbs) maxAbs = a;
    }
    final gain = maxAbs > 0 ? (0.98 / maxAbs) : 1.0;
    final pcm = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i] * gain).clamp(-1.0, 1.0);
      pcm[i] = (v * 32767.0).round();
    }
    return pcm.buffer.asUint8List();
  }

  List<String> _splitSentences(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return const [];
    final parts = cleaned.split(RegExp(r'(?<=[\.!?])\s+'));
    return parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toList(growable: false);
  }

  Future<void> _waitIfPaused() async {
    while (_paused && !_stopRequested) {
      await Future.delayed(const Duration(milliseconds: 60));
    }
  }

  @override
  Future<void> primeAudio({int sampleRate = 24000}) async {
    try {
      await _ensureAudioStream(sampleRate);
    } catch (_) {
      // ignore
    }
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
    _connected = true;
    _paused = false;
    _stopRequested = false;

    try {
      await _ensureEngineReady();
      final chapter = await _scraper.scrapeChapter(url);

      final paras = (startParagraph <= 0)
          ? chapter.paragraphs
          : chapter.paragraphs.sublist(
              startParagraph.clamp(0, chapter.paragraphs.length),
            );
      final text = paras.join('\n');
      final sentences = _splitSentences(text);

      final sr = sampleRate;
      await _ensureAudioStream(sr);

      _eventsController.add({
        'type': 'chapter_info',
        'title': chapter.title,
        'url': chapter.url,
        'next_url': chapter.nextUrl,
        'prev_url': chapter.prevUrl,
        // Keep full paragraphs for rendering/tap-to-play.
        'paragraphs': chapter.paragraphs,
        'start_paragraph': startParagraph,
        'audio': {
          'encoding': 'pcm_s16le',
          'sample_rate': sr,
          'channels': 1,
          'frame_ms': 200,
        },
      });

      for (final sentence in sentences) {
        if (_stopRequested) break;
        await _waitIfPaused();
        if (_stopRequested) break;

        _eventsController.add({'type': 'sentence', 'text': sentence});

        final phonemes = await _tokenizer!.phonemize(sentence, lang: 'en-us');

        final tokens = _tokenizer!.tokenize(phonemes);
        final style = await _voiceBank.styleVectorForTokens(
          voiceId: voice,
          tokenLength: tokens.length,
        );
        final audio = await _runInference(tokens: tokens, styleVector: style, speed: speed);
        final pcmBytes = _floatToPcm16(audio);

        // Stream PCM in ~200ms frames to keep UI highlight pacing stable.
        const frameMs = 200;
        final bytesPerSample = 2;
        final frameSamples = (sr * frameMs) ~/ 1000;
        final frameBytes = frameSamples * bytesPerSample;
        for (var off = 0; off < pcmBytes.length; off += frameBytes) {
          if (_stopRequested) break;
          await _waitIfPaused();
          if (_stopRequested) break;

          final end = (off + frameBytes < pcmBytes.length) ? off + frameBytes : pcmBytes.length;
          final chunk = pcmBytes.sublist(off, end);
          if (_audioSource != null) {
            _soloud.addAudioDataStream(_audioSource!, chunk);
          }
          final chunkSeconds = chunk.length / (bytesPerSample * sr);
          await Future.delayed(Duration(milliseconds: (chunkSeconds * 1000).round()));
        }
      }

      if (_audioSource != null) {
        try {
          _soloud.setDataIsEnded(_audioSource!);
        } catch (_) {}
      }

      _eventsController.add({
        'type': 'chapter_complete',
        'next_url': chapter.nextUrl,
        'prev_url': chapter.prevUrl,
      });
    } catch (e) {
      _eventsController.add({'type': 'error', 'message': e.toString()});
    } finally {
      _connected = false;
    }
  }

  @override
  Future<void> pause() async {
    if (!_connected) return;
    _paused = true;
    if (_handle != null) {
      _soloud.setPause(_handle!, true);
    }
  }

  @override
  Future<void> resume() async {
    if (!_connected) return;
    _paused = false;
    if (_handle != null) {
      _soloud.setPause(_handle!, false);
    }
  }

  @override
  Future<void> stop() async {
    _stopRequested = true;
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

  @override
  Future<void> dispose() async {
    await stop();
    await _eventsController.close();
    if (_session != null) {
      try {
        await _session!.close();
      } catch (_) {}
      _session = null;
      _sessionReady = false;
    }
  }
}
