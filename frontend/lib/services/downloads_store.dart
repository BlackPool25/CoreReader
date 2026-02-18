import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_models.dart';

class DownloadsStore {
  static const _indexKey = 'downloads_index_v1';

  static Future<Map<String, List<DownloadedChapter>>> loadIndex() async {
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
    final prefs = await SharedPreferences.getInstance();
    final obj = <String, dynamic>{};
    for (final e in index.entries) {
      obj[e.key] = e.value.map((c) => c.toJson()).toList(growable: false);
    }
    await prefs.setString(_indexKey, jsonEncode(obj));
  }
}
