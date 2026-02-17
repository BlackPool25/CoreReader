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
    final novel = StoredNovel(
      id: _makeId(),
      name: name.trim(),
      novelUrl: novelUrl.trim(),
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
    _cacheByNovelId.remove(novelId);
    _progressByNovelId.remove(novelId);
    notifyListeners();
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
}
