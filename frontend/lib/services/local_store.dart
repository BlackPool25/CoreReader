import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class StoredNovel {
  StoredNovel({
    required this.id,
    required this.name,
    required this.novelUrl,
    this.coverUrl,
    required this.addedAtMs,
  });

  final String id;
  final String name;
  final String novelUrl;
  final String? coverUrl;
  final int addedAtMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'novelUrl': novelUrl,
      'coverUrl': coverUrl,
        'addedAtMs': addedAtMs,
      };

  static StoredNovel fromJson(Map<String, dynamic> json) {
    return StoredNovel(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      novelUrl: (json['novelUrl'] as String?) ?? '',
      coverUrl: (json['coverUrl'] as String?),
      addedAtMs: (json['addedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class StoredChapter {
  StoredChapter({
    required this.n,
    required this.title,
    required this.url,
  });

  final int n;
  final String title;
  final String url;

  Map<String, dynamic> toJson() => {
        'n': n,
        'title': title,
        'url': url,
      };

  static StoredChapter fromJson(Map<String, dynamic> json) {
    return StoredChapter(
      n: (json['n'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
    );
  }
}

class StoredNovelCache {
  StoredNovelCache({
    required this.fetchedAtMs,
    required this.chapters,
  });

  final int fetchedAtMs;
  final List<StoredChapter> chapters;

  Map<String, dynamic> toJson() => {
        'fetchedAtMs': fetchedAtMs,
        'chapters': chapters.map((c) => c.toJson()).toList(growable: false),
      };

  static StoredNovelCache fromJson(Map<String, dynamic> json) {
    final raw = json['chapters'];
    final chapters = <StoredChapter>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          chapters.add(StoredChapter.fromJson(item));
        } else if (item is Map) {
          chapters.add(StoredChapter.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    return StoredNovelCache(
      fetchedAtMs: (json['fetchedAtMs'] as num?)?.toInt() ?? 0,
      chapters: chapters,
    );
  }
}

class StoredReadingProgress {
  StoredReadingProgress({
    required this.novelId,
    required this.chapterN,
    required this.paragraphIndex,
    required this.updatedAtMs,
    required this.completedChapters,
  });

  final String novelId;
  final int chapterN;
  final int paragraphIndex;
  final int updatedAtMs;
  final Set<int> completedChapters;

  Map<String, dynamic> toJson() => {
        'novelId': novelId,
        'chapterN': chapterN,
        'paragraphIndex': paragraphIndex,
        'updatedAtMs': updatedAtMs,
        'completedChapters': completedChapters.toList(growable: false),
      };

  static StoredReadingProgress fromJson(Map<String, dynamic> json) {
    final rawCompleted = json['completedChapters'];
    final completed = <int>{};
    if (rawCompleted is List) {
      for (final x in rawCompleted) {
        final n = (x as num?)?.toInt();
        if (n != null) completed.add(n);
      }
    }
    return StoredReadingProgress(
      novelId: (json['novelId'] as String?) ?? '',
      chapterN: (json['chapterN'] as num?)?.toInt() ?? 1,
      paragraphIndex: (json['paragraphIndex'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      completedChapters: completed,
    );
  }
}

class LocalStore {
  static const _libraryKey = 'library_v1';
  static const _cachePrefix = 'novel_cache_v1:'; // + novelId
  static const _progressPrefix = 'reading_progress_v1:'; // + novelId

  static Future<void> deleteNovelCache(String novelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_cachePrefix$novelId');
  }

  static Future<void> deleteProgress(String novelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_progressPrefix$novelId');
  }

  static Future<List<StoredNovel>> loadLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_libraryKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => StoredNovel.fromJson(m.cast<String, dynamic>()))
          .where((n) => n.id.isNotEmpty && n.novelUrl.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveLibrary(List<StoredNovel> novels) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(novels.map((n) => n.toJson()).toList(growable: false));
    await prefs.setString(_libraryKey, raw);
  }

  static Future<StoredNovelCache?> loadNovelCache(String novelId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_cachePrefix$novelId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return StoredNovelCache.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  static Future<void> saveNovelCache(String novelId, StoredNovelCache cache) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_cachePrefix$novelId', jsonEncode(cache.toJson()));
  }

  static Future<StoredReadingProgress?> loadProgress(String novelId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_progressPrefix$novelId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return StoredReadingProgress.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  static Future<void> saveProgress(StoredReadingProgress progress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_progressPrefix${progress.novelId}', jsonEncode(progress.toJson()));
  }
}
