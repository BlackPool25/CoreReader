import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'android_saf.dart';
import 'settings_store.dart';

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

  static const List<String> _safRoot = ['LN-TTS', 'app_state'];

  static List<String> _safLibraryPath() => [..._safRoot, 'library.json'];
  static List<String> _safCachePath(String novelId) => [..._safRoot, 'cache', '$novelId.json'];
  static List<String> _safProgressPath(String novelId) => [..._safRoot, 'progress', '$novelId.json'];

  static Future<String?> _treeUri() async {
    if (kIsWeb) return null;
    if (!AndroidSaf.isSupported) return null;
    return await SettingsStore.getDownloadsTreeUri();
  }

  static Future<String?> _readSafText({required String treeUri, required List<String> path}) async {
    final handle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: path);
    if (handle <= 0) return null;
    try {
      final chunks = <int>[];
      while (true) {
        final bytes = await AndroidSaf.read(handle, maxBytes: 64 * 1024);
        if (bytes == null || bytes.isEmpty) break;
        chunks.addAll(bytes);
      }
      if (chunks.isEmpty) return null;
      return utf8.decode(chunks);
    } finally {
      await AndroidSaf.closeRead(handle);
    }
  }

  static Future<void> _writeSafText({
    required String treeUri,
    required List<String> path,
    required String mimeType,
    required String text,
  }) async {
    final handle = await AndroidSaf.openWrite(
      treeUri: treeUri,
      pathSegments: path,
      mimeType: mimeType,
      append: false,
    );
    if (handle <= 0) throw Exception('Failed to open SAF file for write');
    try {
      await AndroidSaf.write(handle, Uint8List.fromList(utf8.encode(text)));
    } finally {
      await AndroidSaf.closeWrite(handle);
    }
  }

  static Future<void> deleteNovelCache(String novelId) async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      try {
        await AndroidSaf.delete(treeUri: tree, pathSegments: _safCachePath(novelId));
      } catch (_) {}
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_cachePrefix$novelId');
  }

  static Future<void> deleteProgress(String novelId) async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      try {
        await AndroidSaf.delete(treeUri: tree, pathSegments: _safProgressPath(novelId));
      } catch (_) {}
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_progressPrefix$novelId');
  }

  static Future<List<StoredNovel>> loadLibrary() async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      try {
        final raw = await _readSafText(treeUri: tree, path: _safLibraryPath());
        if (raw == null || raw.isEmpty) {
          // Migration path: seed SAF storage from existing prefs.
          final prefsNovels = await _loadLibraryFromPrefs();
          if (prefsNovels.isNotEmpty) {
            try {
              await saveLibrary(prefsNovels);
            } catch (_) {}
          }
          return prefsNovels;
        }
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

    return _loadLibraryFromPrefs();
  }

  static Future<List<StoredNovel>> _loadLibraryFromPrefs() async {
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
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      final raw = jsonEncode(novels.map((n) => n.toJson()).toList(growable: false));
      await _writeSafText(treeUri: tree, path: _safLibraryPath(), mimeType: 'application/json', text: raw);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(novels.map((n) => n.toJson()).toList(growable: false));
    await prefs.setString(_libraryKey, raw);
  }

  static Future<StoredNovelCache?> loadNovelCache(String novelId) async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      try {
        final raw = await _readSafText(treeUri: tree, path: _safCachePath(novelId));
        if (raw == null || raw.isEmpty) {
          final prefsCache = await _loadNovelCacheFromPrefs(novelId);
          if (prefsCache != null) {
            try {
              await saveNovelCache(novelId, prefsCache);
            } catch (_) {}
          }
          return prefsCache;
        }
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return StoredNovelCache.fromJson(decoded.cast<String, dynamic>());
        }
      } catch (_) {
        return null;
      }
      return null;
    }

    return _loadNovelCacheFromPrefs(novelId);
  }

  static Future<StoredNovelCache?> _loadNovelCacheFromPrefs(String novelId) async {
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
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      await _writeSafText(
        treeUri: tree,
        path: _safCachePath(novelId),
        mimeType: 'application/json',
        text: jsonEncode(cache.toJson()),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_cachePrefix$novelId', jsonEncode(cache.toJson()));
  }

  static Future<StoredReadingProgress?> loadProgress(String novelId) async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      try {
        final raw = await _readSafText(treeUri: tree, path: _safProgressPath(novelId));
        if (raw == null || raw.isEmpty) {
          final prefsProgress = await _loadProgressFromPrefs(novelId);
          if (prefsProgress != null) {
            try {
              await saveProgress(prefsProgress);
            } catch (_) {}
          }
          return prefsProgress;
        }
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return StoredReadingProgress.fromJson(decoded.cast<String, dynamic>());
        }
      } catch (_) {
        return null;
      }
      return null;
    }

    return _loadProgressFromPrefs(novelId);
  }

  static Future<StoredReadingProgress?> _loadProgressFromPrefs(String novelId) async {
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
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      await _writeSafText(
        treeUri: tree,
        path: _safProgressPath(progress.novelId),
        mimeType: 'application/json',
        text: jsonEncode(progress.toJson()),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_progressPrefix${progress.novelId}', jsonEncode(progress.toJson()));
  }
}
