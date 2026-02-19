import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_saf.dart';
import 'downloads_models.dart';
import 'settings_store.dart';

class DownloadsStore {
  static const _indexKey = 'downloads_index_v1';

  static const List<String> _safIndexPath = ['LN-TTS', 'app_state', 'downloads_index.json'];

  static Future<String?> _treeUri() async {
    if (kIsWeb) return null;
    if (!AndroidSaf.isSupported) return null;
    return await SettingsStore.getDownloadsTreeUri();
  }

  static Future<String?> _readSafText(String treeUri) async {
    final handle = await AndroidSaf.openRead(treeUri: treeUri, pathSegments: _safIndexPath);
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

  static Future<void> _writeSafText(String treeUri, String text) async {
    final handle = await AndroidSaf.openWrite(
      treeUri: treeUri,
      pathSegments: _safIndexPath,
      mimeType: 'application/json',
      append: false,
    );
    if (handle <= 0) throw Exception('Failed to open downloads index for write');
    try {
      await AndroidSaf.write(handle, Uint8List.fromList(utf8.encode(text)));
    } finally {
      await AndroidSaf.closeWrite(handle);
    }
  }

  static Future<Map<String, List<DownloadedChapter>>> loadIndex() async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      final raw = await _readSafText(tree);
      if (raw == null || raw.isEmpty) {
        final prefsIndex = await _loadIndexFromPrefs();
        if (prefsIndex.isNotEmpty) {
          try {
            await saveIndex(prefsIndex);
          } catch (_) {}
        }
        return prefsIndex;
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return const {};
        final out = <String, List<DownloadedChapter>>{};
        for (final entry in decoded.entries) {
          final novelId = entry.key.toString();
          final value = entry.value;
          if (value is! List) continue;
          final chapters = <DownloadedChapter>[];
          for (final item in value) {
            if (item is Map<String, dynamic>) {
              chapters.add(DownloadedChapter.fromJson(item));
            } else if (item is Map) {
              chapters.add(DownloadedChapter.fromJson(item.cast<String, dynamic>()));
            }
          }
          out[novelId] = chapters.where((c) => c.chapterN > 0 && c.pcmPath.isNotEmpty && c.metaPath.isNotEmpty).toList(growable: false);
        }
        return out;
      } catch (_) {
        return const {};
      }
    }

    return _loadIndexFromPrefs();
  }

  static Future<Map<String, List<DownloadedChapter>>> _loadIndexFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, List<DownloadedChapter>>{};
      for (final entry in decoded.entries) {
        final novelId = entry.key.toString();
        final value = entry.value;
        if (value is! List) continue;
        final chapters = <DownloadedChapter>[];
        for (final item in value) {
          if (item is Map<String, dynamic>) {
            chapters.add(DownloadedChapter.fromJson(item));
          } else if (item is Map) {
            chapters.add(DownloadedChapter.fromJson(item.cast<String, dynamic>()));
          }
        }
        out[novelId] = chapters.where((c) => c.chapterN > 0 && c.pcmPath.isNotEmpty && c.metaPath.isNotEmpty).toList(growable: false);
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  static Future<void> saveIndex(Map<String, List<DownloadedChapter>> index) async {
    final tree = await _treeUri();
    if (tree != null && tree.trim().isNotEmpty) {
      final obj = <String, dynamic>{};
      for (final e in index.entries) {
        obj[e.key] = e.value.map((c) => c.toJson()).toList(growable: false);
      }
      await _writeSafText(tree, jsonEncode(obj));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final obj = <String, dynamic>{};
    for (final e in index.entries) {
      obj[e.key] = e.value.map((c) => c.toJson()).toList(growable: false);
    }
    await prefs.setString(_indexKey, jsonEncode(obj));
  }
}
