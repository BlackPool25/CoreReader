import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'android_saf.dart';
import 'downloads_models.dart';
import 'downloads_store.dart';
import 'settings_store.dart';
import 'ws_binary_to_bytes.dart';

enum DownloadJobStatus {
  queued,
  downloading,
  completed,
  failed,
}

class DownloadJob {
  DownloadJob({
    required this.novelId,
    required this.chapterN,
    required this.chapterUrl,
    required this.voice,
    required this.speed,
    required this.source,
    required this.status,
    required this.progress,
    this.error,
  });

  final String novelId;
  final int chapterN;
  final String chapterUrl;
  final String voice;
  final double speed;
  final String source;

  DownloadJobStatus status;
  double? progress; // null => indeterminate
  String? error;
}

class DownloadsController extends ChangeNotifier {
  Map<String, List<DownloadedChapter>> _index = const {};
  bool _loaded = false;

  final Map<String, DownloadJob> _jobsByKey = {};

  Future<void> _downloadChain = Future<void>.value();
  bool _downloading = false;

  bool get downloading => _downloading;

  bool get loaded => _loaded;

  String _jobKey(String novelId, int chapterN) => '$novelId:$chapterN';

  DownloadJob? jobFor(String novelId, int chapterN) => _jobsByKey[_jobKey(novelId, chapterN)];

  bool isDownloading(String novelId, int chapterN) {
    final j = jobFor(novelId, chapterN);
    return j != null && (j.status == DownloadJobStatus.queued || j.status == DownloadJobStatus.downloading);
  }

  Future<void> load() async {
    _index = await DownloadsStore.loadIndex();
    _loaded = true;
    notifyListeners();
  }

  List<DownloadedChapter> chaptersForNovel(String novelId) => _index[novelId] ?? const <DownloadedChapter>[];

  DownloadedChapter? downloadedChapter(String novelId, int chapterN) {
    final list = _index[novelId];
    if (list == null) return null;
    for (final c in list) {
      if (c.chapterN == chapterN) return c;
    }
    return null;
  }

  bool isDownloaded(String novelId, int chapterN) => downloadedChapter(novelId, chapterN) != null;

  static List<String> _pcmPath(String novelId, int chapterN) => ['LN-TTS', novelId, 'chapters', '$chapterN', 'audio.pcm'];
  static List<String> _metaPath(String novelId, int chapterN) => ['LN-TTS', novelId, 'chapters', '$chapterN', 'meta.json'];
  static List<String> _chaptersDir(String novelId) => ['LN-TTS', novelId, 'chapters'];

  /// Reconcile the in-memory/indexed download list with what actually exists in
  /// the configured SAF downloads folder.
  ///
  /// This fixes "ghost files" (files that exist but aren’t tracked) and removes
  /// stale index entries (tracked but missing on disk). Incomplete chapter dirs
  /// (only meta or only audio) are cleaned up best-effort.
  Future<void> reconcileWithDisk({required String treeUri, required String novelId}) async {
    if (kIsWeb) return;
    if (!AndroidSaf.isSupported) return;
    final t = treeUri.trim();
    if (t.isEmpty) return;

    List<String> children;
    try {
      children = await AndroidSaf.listChildren(treeUri: t, pathSegments: _chaptersDir(novelId));
    } catch (_) {
      return;
    }

    final scanned = <int, DownloadedChapter>{};
    for (final name in children) {
      final n = int.tryParse(name);
      if (n == null || n <= 0) continue;
      final pcmPath = _pcmPath(novelId, n);
      final metaPath = _metaPath(novelId, n);
      bool hasPcm = false;
      bool hasMeta = false;
      try {
        hasPcm = await AndroidSaf.exists(treeUri: t, pathSegments: pcmPath);
        hasMeta = await AndroidSaf.exists(treeUri: t, pathSegments: metaPath);
      } catch (_) {
        continue;
      }

      if (hasPcm && hasMeta) {
        final meta = await _loadMetaAtPath(treeUri: t, metaPath: metaPath);
        // Ignore incomplete downloads (keep on disk; do not surface as downloaded).
        if (meta != null && meta.complete == false) {
          continue;
        }
        final title = meta?.title ?? 'Chapter $n';
        final sampleRate = meta?.sampleRate ?? 24000;
        final voice = meta?.voice ?? 'af_bella';
        final ttsSpeed = meta?.ttsSpeed ?? 1.0;
        final source = meta?.source ?? 'manual';
        scanned[n] = DownloadedChapter(
          novelId: novelId,
          chapterN: n,
          title: title,
          chapterUrl: meta?.url ?? '',
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          sampleRate: sampleRate,
          voice: voice,
          ttsSpeed: ttsSpeed,
          source: source,
          pcmPath: pcmPath,
          metaPath: metaPath,
        );
      } else {
        // Incomplete chapter on disk.
        // We intentionally do NOT delete here because downloads may be in-flight.
      }
    }

    final existing = chaptersForNovel(novelId);
    final out = <DownloadedChapter>[];
    final seen = <int>{};

    // Keep existing entries that still exist on disk, and refresh with scanned meta when available.
    for (final c in existing) {
      final n = c.chapterN;
      if (n <= 0) continue;
      if (seen.contains(n)) continue;
      if (scanned.containsKey(n)) {
        out.add(scanned[n]!);
        seen.add(n);
        continue;
      }
      try {
        final okPcm = await AndroidSaf.exists(treeUri: t, pathSegments: c.pcmPath);
        final okMeta = await AndroidSaf.exists(treeUri: t, pathSegments: c.metaPath);
        if (okPcm && okMeta) {
          out.add(c);
          seen.add(n);
        }
      } catch (_) {
        // ignore
      }
    }

    // Add any scanned-but-not-indexed chapters.
    for (final entry in scanned.entries) {
      if (seen.add(entry.key)) out.add(entry.value);
    }
    out.sort((a, b) => a.chapterN.compareTo(b.chapterN));

    _index = {
      ..._index,
      novelId: out,
    };
    await DownloadsStore.saveIndex(_index);
    notifyListeners();
  }

  Future<void> deleteDownloadedChapter({required String treeUri, required String novelId, required int chapterN}) async {
    final existing = downloadedChapter(novelId, chapterN);
    if (existing != null) {
      await AndroidSaf.delete(treeUri: treeUri, pathSegments: existing.pcmPath);
      await AndroidSaf.delete(treeUri: treeUri, pathSegments: existing.metaPath);
    } else {
      await AndroidSaf.delete(treeUri: treeUri, pathSegments: _pcmPath(novelId, chapterN));
      await AndroidSaf.delete(treeUri: treeUri, pathSegments: _metaPath(novelId, chapterN));
    }

    final list = [...(_index[novelId] ?? const <DownloadedChapter>[])];
    list.removeWhere((c) => c.chapterN == chapterN);
    _index = {
      ..._index,
      novelId: list,
    };
    await DownloadsStore.saveIndex(_index);
    notifyListeners();
  }

  Future<void> deleteAllDownloadedForNovel({required String treeUri, required String novelId}) async {
    final list = chaptersForNovel(novelId);
    for (final c in list) {
      try {
        await AndroidSaf.delete(treeUri: treeUri, pathSegments: c.pcmPath);
      } catch (_) {}
      try {
        await AndroidSaf.delete(treeUri: treeUri, pathSegments: c.metaPath);
      } catch (_) {}
    }
    _index = {
      ..._index,
      novelId: const <DownloadedChapter>[],
    };
    await DownloadsStore.saveIndex(_index);
    notifyListeners();
  }

  /// Download a chapter using backend WS play (realtime=false) and save PCM+meta.
  Future<DownloadedChapter> downloadChapter({
    required String treeUri,
    required String novelId,
    required int chapterN,
    required String chapterUrl,
    required String voice,
    required double speed,
    String source = 'manual',
    int prefetchSentences = 8,
  }) async {
    if (kIsWeb) throw Exception('Downloads are not supported on Web');
    if (!AndroidSaf.isSupported) throw Exception('Downloads are currently supported on Android only');
    if (treeUri.trim().isEmpty) throw Exception('Downloads folder not set');

    final pcmPath = _pcmPath(novelId, chapterN);
    final metaPath = _metaPath(novelId, chapterN);

    // Ensure we start from a clean slate (some SAF providers may not truncate
    // reliably on overwrite, which can sound like jitter/corruption).
    try {
      await AndroidSaf.delete(treeUri: treeUri, pathSegments: pcmPath);
    } catch (_) {}
    try {
      await AndroidSaf.delete(treeUri: treeUri, pathSegments: metaPath);
    } catch (_) {}

    // Write a placeholder meta immediately so reconcile doesn't treat the chapter
    // as incomplete and delete the audio while we're still downloading.
    try {
      final placeholder = DownloadedChapterMeta(
        title: 'Chapter $chapterN',
        url: chapterUrl,
        sampleRate: 24000,
        voice: voice,
        ttsSpeed: speed,
        complete: false,
        source: source,
        paragraphs: const <String>[],
        timeline: const <ChapterTimelineItem>[],
      );
      final bytes = utf8.encode(jsonEncode(placeholder.toJson()));
      final metaHandle = await AndroidSaf.openWrite(
        treeUri: treeUri,
        pathSegments: metaPath,
        mimeType: 'application/json',
        append: false,
      );
      if (metaHandle > 0) {
        await AndroidSaf.write(metaHandle, Uint8List.fromList(bytes));
        await AndroidSaf.closeWrite(metaHandle);
      }
    } catch (_) {
      // Best-effort.
    }

    final pcmHandle = await AndroidSaf.openWrite(
      treeUri: treeUri,
      pathSegments: pcmPath,
      mimeType: 'application/octet-stream',
      append: false,
    );
    if (pcmHandle <= 0) throw Exception('Failed to open audio output');

    WebSocketChannel? channel;
    var bytesWritten = 0;
    var writeChain = Future<void>.value();
    int? pendingByte;
    var title = 'Chapter $chapterN';
    var sampleRate = 24000;
    var effectiveVoice = voice;
    final paragraphs = <String>[];
    final timeline = <ChapterTimelineItem>[];

    var sentenceTotal = 0;
    var sentencesSeen = 0;

    try {
      final base = await SettingsStore.getServerBaseUrl();
      final wsUri = SettingsStore.wsUri(base);
      channel = WebSocketChannel.connect(wsUri);

      final payload = <String, dynamic>{
        'command': 'play',
        'url': chapterUrl,
        'voice': voice,
        'speed': speed,
        'prefetch': prefetchSentences,
        'frame_ms': 200,
        'start_paragraph': 0,
        'realtime': false,
      };
      channel.sink.add(jsonEncode(payload));

      final done = Completer<void>();
      final sub = channel.stream.listen(
        (event) {
          if (event is String) {
            final obj = jsonDecode(event);
            if (obj is Map) {
              final type = obj['type']?.toString();
              if (type == 'chapter_info') {
                title = (obj['title'] as String?) ?? title;
                final v = (obj['voice'] as String?)?.trim();
                if (v != null && v.isNotEmpty) {
                  effectiveVoice = v;
                }
                final audio = (obj['audio'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
                sampleRate = (audio['sample_rate'] as num?)?.toInt() ?? 24000;
                final st = (obj['sentence_total'] as num?)?.toInt();
                sentenceTotal = (st != null && st > 0) ? st : 0;
                final paras = (obj['paragraphs'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
                paragraphs
                  ..clear()
                  ..addAll(paras);
              } else if (type == 'sentence') {
                final text = (obj['text'] as String?) ?? '';
                final p = (obj['paragraph_index'] as num?)?.toInt() ?? 0;
                final s = (obj['sentence_index'] as num?)?.toInt() ?? 0;
                final ms = ((bytesWritten / 2) / sampleRate * 1000).round();
                timeline.add(ChapterTimelineItem(ms: ms, text: text, paragraphIndex: p, sentenceIndex: s));

                // Progress is based on sentence count, not bytes.
                sentencesSeen++;
                final key = _jobKey(novelId, chapterN);
                final job = _jobsByKey[key];
                if (job != null && job.status == DownloadJobStatus.downloading) {
                  if (sentenceTotal > 0) {
                    job.progress = (sentencesSeen / sentenceTotal).clamp(0.0, 1.0);
                  } else {
                    job.progress = null;
                  }
                  notifyListeners();
                }
              } else if (type == 'chapter_complete') {
                done.complete();
              } else if (type == 'error') {
                final msg = (obj['message'] as String?) ?? 'Unknown error';
                if (!done.isCompleted) {
                  done.completeError(Exception(msg));
                }
              }
            }
            return;
          }

          // Binary audio frame.
          writeChain = writeChain.then((_) async {
            final bytes = await wsBinaryToBytes(event);
            if (bytes == null || bytes.isEmpty) return;
            var chunk = bytes;

            // Ensure PCM16 alignment (2 bytes/sample). If a chunk boundary splits
            // a sample, stash 1 byte and prepend it to the next chunk.
            if (pendingByte != null) {
              final merged = Uint8List(chunk.length + 1);
              merged[0] = pendingByte!;
              merged.setRange(1, merged.length, chunk);
              pendingByte = null;
              chunk = merged;
            }

            if (chunk.length.isOdd) {
              pendingByte = chunk.last;
              chunk = chunk.sublist(0, chunk.length - 1);
            }
            if (chunk.isEmpty) return;

            bytesWritten += chunk.length;
            await AndroidSaf.write(pcmHandle, chunk);
          });
        },
        onError: (e) {
          if (!done.isCompleted) done.completeError(e);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );

      await done.future.timeout(const Duration(minutes: 60));
      await writeChain;
      await sub.cancel();

      // If we ended with a dangling PCM byte, pad it to avoid truncating a sample.
      if (pendingByte != null) {
        try {
          await AndroidSaf.write(pcmHandle, Uint8List.fromList([pendingByte!, 0]));
          bytesWritten += 2;
        } catch (_) {}
        pendingByte = null;
      }

      final meta = DownloadedChapterMeta(
        title: title,
        url: chapterUrl,
        sampleRate: sampleRate,
        voice: effectiveVoice,
        ttsSpeed: speed,
        complete: true,
        source: source,
        paragraphs: paragraphs,
        timeline: timeline,
      );
      final metaBytes = utf8.encode(jsonEncode(meta.toJson()));
      final metaHandle = await AndroidSaf.openWrite(
        treeUri: treeUri,
        pathSegments: metaPath,
        mimeType: 'application/json',
        append: false,
      );
      if (metaHandle <= 0) throw Exception('Failed to open meta output');
      await AndroidSaf.write(metaHandle, Uint8List.fromList(metaBytes));
      await AndroidSaf.closeWrite(metaHandle);

      final chapter = DownloadedChapter(
        novelId: novelId,
        chapterN: chapterN,
        title: title,
        chapterUrl: chapterUrl,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        sampleRate: sampleRate,
        voice: effectiveVoice,
        ttsSpeed: speed,
        source: source,
        pcmPath: pcmPath,
        metaPath: metaPath,
      );

      final list = [...(_index[novelId] ?? const <DownloadedChapter>[])];
      list.removeWhere((c) => c.chapterN == chapterN);
      list.add(chapter);
      list.sort((a, b) => a.chapterN.compareTo(b.chapterN));
      _index = {
        ..._index,
        novelId: list,
      };
      await DownloadsStore.saveIndex(_index);
      notifyListeners();
      return chapter;
    } finally {
      try {
        await AndroidSaf.closeWrite(pcmHandle);
      } catch (_) {}
      try {
        await channel?.sink.close();
      } catch (_) {}
    }
  }

  Future<DownloadedChapterMeta?> _loadMetaAtPath({required String treeUri, required List<String> metaPath}) async {
    final handle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: metaPath);
    if (handle <= 0) return null;
    try {
      final chunks = <int>[];
      while (true) {
        final bytes = await AndroidSaf.read(handle, maxBytes: 64 * 1024);
        if (bytes == null || bytes.isEmpty) break;
        chunks.addAll(bytes);
      }
      final s = utf8.decode(chunks);
      final decoded = jsonDecode(s);
      if (decoded is Map) {
        return DownloadedChapterMeta.fromJson(decoded.cast<String, dynamic>());
      }
      return null;
    } finally {
      await AndroidSaf.closeRead(handle);
    }
  }

  /// Queue a chapter download behind any in-flight downloads.
  Future<DownloadedChapter> enqueueDownloadChapter({
    required String treeUri,
    required String novelId,
    required int chapterN,
    required String chapterUrl,
    required String voice,
    required double speed,
    String source = 'manual',
  }) {
    final key = _jobKey(novelId, chapterN);
    _jobsByKey[key] = DownloadJob(
      novelId: novelId,
      chapterN: chapterN,
      chapterUrl: chapterUrl,
      voice: voice,
      speed: speed,
      source: source,
      status: DownloadJobStatus.queued,
      progress: null,
    );
    notifyListeners();

    final completer = Completer<DownloadedChapter>();
    _downloadChain = _downloadChain.then((_) async {
      _downloading = true;
      final job = _jobsByKey[key];
      if (job != null) {
        job.status = DownloadJobStatus.downloading;
        job.progress = 0.0;
      }
      notifyListeners();
      try {
        final c = await downloadChapter(
          treeUri: treeUri,
          novelId: novelId,
          chapterN: chapterN,
          chapterUrl: chapterUrl,
          voice: voice,
          speed: speed,
          source: source,
        );
        final job2 = _jobsByKey[key];
        if (job2 != null) {
          job2.status = DownloadJobStatus.completed;
          job2.progress = 1.0;
        }
        completer.complete(c);
      } catch (e, st) {
        final job2 = _jobsByKey[key];
        if (job2 != null) {
          job2.status = DownloadJobStatus.failed;
          job2.progress = null;
          job2.error = e.toString();
        }
        completer.completeError(e, st);
      } finally {
        _downloading = false;
        notifyListeners();
      }
    });
    return completer.future;
  }

  Future<DownloadedChapterMeta?> loadMeta({required String treeUri, required DownloadedChapter chapter}) async {
    final handle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: chapter.metaPath);
    if (handle <= 0) return null;
    try {
      final chunks = <int>[];
      while (true) {
        final bytes = await AndroidSaf.read(handle, maxBytes: 64 * 1024);
        if (bytes == null || bytes.isEmpty) break;
        chunks.addAll(bytes);
      }
      final s = utf8.decode(chunks);
      final decoded = jsonDecode(s);
      if (decoded is Map) {
        return DownloadedChapterMeta.fromJson(decoded.cast<String, dynamic>());
      }
      return null;
    } finally {
      await AndroidSaf.closeRead(handle);
    }
  }
}
