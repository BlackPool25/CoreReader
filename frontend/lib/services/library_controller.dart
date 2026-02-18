import 'dart:math';

import 'package:flutter/foundation.dart';

import 'local_store.dart';

String _makeId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final r = Random().nextInt(1 << 20);
  return '${now}_$r';
}

class LibraryController extends ChangeNotifier {
  List<StoredNovel> _novels = const [];
  final Map<String, StoredNovelCache> _cacheByNovelId = {};
  final Map<String, StoredReadingProgress> _progressByNovelId = {};

  List<StoredNovel> get novels => _novels;

  StoredNovelCache? cacheFor(String novelId) => _cacheByNovelId[novelId];
  StoredReadingProgress? progressFor(String novelId) => _progressByNovelId[novelId];

  Future<void> load() async {
    _novels = await LocalStore.loadLibrary();
    for (final n in _novels) {
      final cache = await LocalStore.loadNovelCache(n.id);
      if (cache != null) _cacheByNovelId[n.id] = cache;
      final progress = await LocalStore.loadProgress(n.id);
      if (progress != null) _progressByNovelId[n.id] = progress;
    }
    notifyListeners();
  }

  Future<StoredNovel> addNovel({required String name, required String novelUrl}) async {
    final normalizedUrl = _normalizeNovelUrl(novelUrl);
    if (_novels.any((n) => _normalizeNovelUrl(n.novelUrl) == normalizedUrl)) {
      throw Exception('A novel with the same URL is already in your library');
    }
    final novel = StoredNovel(
      id: _makeId(),
      name: name.trim(),
      novelUrl: normalizedUrl,
      addedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _novels = [..._novels, novel];
    await LocalStore.saveLibrary(_novels);
    notifyListeners();
    return novel;
  }

  Future<void> removeNovel(String novelId) async {
    _novels = _novels.where((n) => n.id != novelId).toList(growable: false);
    await LocalStore.saveLibrary(_novels);
    await LocalStore.deleteNovelCache(novelId);
    await LocalStore.deleteProgress(novelId);
    _cacheByNovelId.remove(novelId);
    _progressByNovelId.remove(novelId);
    notifyListeners();
  }

  Future<void> setNovelCoverUrl(String novelId, String? coverUrl) async {
    final idx = _novels.indexWhere((n) => n.id == novelId);
    if (idx < 0) return;
    final current = _novels[idx];
    final next = StoredNovel(
      id: current.id,
      name: current.name,
      novelUrl: current.novelUrl,
      coverUrl: (coverUrl != null && coverUrl.trim().isNotEmpty) ? coverUrl.trim() : null,
      addedAtMs: current.addedAtMs,
    );
    final list = [..._novels];
    list[idx] = next;
    _novels = list;
    await LocalStore.saveLibrary(_novels);
    notifyListeners();
  }


String _normalizeNovelUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  try {
    final uri = Uri.parse(trimmed);
    // Drop fragment/query (NovelCool pages shouldn't need them).
    final normalized = uri.replace(query: null, fragment: null);
    // Also remove trailing slash for stable comparisons.
    return normalized.toString().replaceAll(RegExp(r'/$'), '');
  } catch (_) {
    return trimmed.replaceAll(RegExp(r'/$'), '');
  }
}
  Future<void> setCache(String novelId, StoredNovelCache cache) async {
    _cacheByNovelId[novelId] = cache;
    await LocalStore.saveNovelCache(novelId, cache);
    notifyListeners();
  }

  Future<void> setProgress(StoredReadingProgress progress) async {
    _progressByNovelId[progress.novelId] = progress;
    await LocalStore.saveProgress(progress);
    notifyListeners();
  }

  Future<void> markRead(String novelId, int chapterN, {required bool read}) async {
    final current = _progressByNovelId[novelId] ?? StoredReadingProgress(
      novelId: novelId,
      chapterN: max(1, chapterN),
      paragraphIndex: 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      completedChapters: <int>{},
    );
    final set = {...current.completedChapters};
    if (read) {
      set.add(chapterN);
    } else {
      set.remove(chapterN);
    }
    await setProgress(StoredReadingProgress(
      novelId: novelId,
      chapterN: current.chapterN,
      paragraphIndex: current.paragraphIndex,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      completedChapters: set,
    ));
  }

  Future<void> markPrevAll(String novelId, int chapterN, {required bool read}) async {
    final current = _progressByNovelId[novelId] ?? StoredReadingProgress(
      novelId: novelId,
      chapterN: max(1, chapterN),
      paragraphIndex: 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      completedChapters: <int>{},
    );
    final set = {...current.completedChapters};
    // "Previous" explicitly excludes the current chapter.
    for (var n = 1; n < chapterN; n++) {
      if (read) {
        set.add(n);
      } else {
        set.remove(n);
      }
    }
    await setProgress(StoredReadingProgress(
      novelId: novelId,
      chapterN: current.chapterN,
      paragraphIndex: current.paragraphIndex,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      completedChapters: set,
    ));
  }

  Future<void> completeChapterAndAdvance({
    required String novelId,
    required int completedChapterN,
    required int? nextChapterN,
  }) async {
    final current = _progressByNovelId[novelId] ?? StoredReadingProgress(
      novelId: novelId,
      chapterN: max(1, completedChapterN),
      paragraphIndex: 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      completedChapters: <int>{},
    );

    final completed = {...current.completedChapters}..add(completedChapterN);
    final nextN = (nextChapterN != null && nextChapterN > 0) ? nextChapterN : current.chapterN;

    await setProgress(
      StoredReadingProgress(
        novelId: novelId,
        chapterN: nextN,
        paragraphIndex: 0,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        completedChapters: completed,
      ),
    );
  }
}
