import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  static const _serverBaseKey = 'server_base_url';
  static const _serverBaseListKey = 'server_base_url_list_v1';
  static const _fontSizeKey = 'reader_font_size';
  static const _themeModeKey = 'theme_mode';
  static const _defaultVoiceKey = 'default_voice';
  static const _defaultSpeedKey = 'default_speed';
  static const _libraryGridColumnsKey = 'library_grid_columns';
  static const _libraryGridRowsKey = 'library_grid_rows';

  static const _showNowReadingKey = 'reader_show_now_reading_v1';
  static const _autoScrollKey = 'reader_auto_scroll_v1';
  static const _highlightDelayMsKey = 'reader_highlight_delay_ms_v1';

  static const _downloadTreeUriKey = 'downloads_tree_uri_v1';
  static const _downloadPrefetchAheadKey = 'downloads_prefetch_ahead_v1';
  static const _downloadKeepBehindKey = 'downloads_keep_behind_v1';

  /// Base URL including scheme and port, e.g. `ws://192.168.1.45:8000`.
  static Future<String> getServerBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverBaseKey) ?? 'ws://localhost:8000';
  }

  static Future<void> setServerBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverBaseKey, normalizeServerBaseUrl(value));
  }

  static Future<List<String>> getServerBaseUrlList() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_serverBaseListKey);
    if (raw == null || raw.isEmpty) {
      return const ['ws://localhost:8000'];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const ['ws://localhost:8000'];
      final urls = decoded.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
      if (urls.isEmpty) return const ['ws://localhost:8000'];
      // Normalize and dedupe.
      final seen = <String>{};
      final out = <String>[];
      for (final u in urls) {
        final n = normalizeServerBaseUrl(u);
        if (seen.add(n)) out.add(n);
      }
      return out.isEmpty ? const ['ws://localhost:8000'] : out;
    } catch (_) {
      return const ['ws://localhost:8000'];
    }
  }

  static Future<void> setServerBaseUrlList(List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = <String>{};
    final normalized = <String>[];
    for (final u in urls) {
      final n = normalizeServerBaseUrl(u);
      if (n.trim().isEmpty) continue;
      if (seen.add(n)) normalized.add(n);
    }
    if (normalized.isEmpty) normalized.add('ws://localhost:8000');
    await prefs.setString(_serverBaseListKey, jsonEncode(normalized));
  }

  static String normalizeServerBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'ws://localhost:8000';

    // Allow "host:port" without scheme.
    final withScheme = trimmed.contains('://') ? trimmed : 'ws://$trimmed';
    final uri = Uri.parse(withScheme);

    // Convert http(s) -> ws(s) for our stored base.
    final scheme = switch (uri.scheme) {
      'http' => 'ws',
      'https' => 'wss',
      '' => 'ws',
      _ => uri.scheme,
    };

    // IMPORTANT (Flutter Web): a non-null empty fragment serializes as a trailing '#',
    // and WebSocket URLs must not contain fragments.
    final normalized = uri.replace(
      scheme: scheme,
      path: '',
      query: null,
      fragment: null,
    );
    // Strip trailing slash if present.
    return normalized.toString().replaceAll(RegExp(r'/$'), '');
  }

  static Uri _normalizeBaseUri(String serverBaseUrl) {
    final s = normalizeServerBaseUrl(serverBaseUrl);
    return Uri.parse(s);
  }

  static Future<double> getReaderFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_fontSizeKey) ?? 16.0;
  }

  static Future<void> setReaderFontSize(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, value);
  }

  /// Persisted as: 'system' | 'light' | 'dark'
  static Future<String> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_themeModeKey) ?? 'system';
  }

  static Future<void> setThemeMode(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final v = switch (value) {
      'light' => 'light',
      'dark' => 'dark',
      _ => 'system',
    };
    await prefs.setString(_themeModeKey, v);
  }

  static Future<String> getDefaultVoice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_defaultVoiceKey) ?? 'af_bella';
  }

  static Future<void> setDefaultVoice(String voice) async {
    final prefs = await SharedPreferences.getInstance();
    final v = voice.trim();
    if (v.isEmpty) return;
    await prefs.setString(_defaultVoiceKey, v);
  }

  static Future<double> getDefaultSpeed() async {
    final prefs = await SharedPreferences.getInstance();
    // Default: slightly slower than 1.0
    return prefs.getDouble(_defaultSpeedKey) ?? 0.9;
  }

  static Future<void> setDefaultSpeed(double speed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_defaultSpeedKey, speed);
  }

  /// Number of columns for the Library novels grid on phone-sized layouts.
  /// Expected values: 2 or 3.
  static Future<int> getLibraryGridColumns() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_libraryGridColumnsKey) ?? 2;
    // Allow 2..4, default 2.
    if (v < 2) return 2;
    if (v > 4) return 4;
    return v;
  }

  static Future<void> setLibraryGridColumns(int columns) async {
    final prefs = await SharedPreferences.getInstance();
    final v = columns.clamp(2, 4);
    await prefs.setInt(_libraryGridColumnsKey, v);
  }

  static Future<int> getLibraryGridRows() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_libraryGridRowsKey) ?? 2;
    if (v < 2) return 2;
    if (v > 4) return 4;
    return v;
  }

  static Future<void> setLibraryGridRows(int rows) async {
    final prefs = await SharedPreferences.getInstance();
    final v = rows.clamp(2, 4);
    await prefs.setInt(_libraryGridRowsKey, v);
  }

  static Future<bool> getShowNowReading() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showNowReadingKey) ?? false;
  }

  static Future<void> setShowNowReading(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showNowReadingKey, v);
  }

  static Future<bool> getReaderAutoScroll() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoScrollKey) ?? true;
  }

  static Future<void> setReaderAutoScroll(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoScrollKey, v);
  }

  static Future<int> getHighlightDelayMs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_highlightDelayMsKey) ?? 800;
    return v.clamp(0, 3000);
  }

  static Future<void> setHighlightDelayMs(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_highlightDelayMsKey, v.clamp(0, 3000));
  }

  static Future<String?> getDownloadsTreeUri() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_downloadTreeUriKey);
    return (s == null || s.trim().isEmpty) ? null : s;
  }

  static Future<void> setDownloadsTreeUri(String? uri) async {
    final prefs = await SharedPreferences.getInstance();
    if (uri == null || uri.trim().isEmpty) {
      await prefs.remove(_downloadTreeUriKey);
      return;
    }
    await prefs.setString(_downloadTreeUriKey, uri.trim());
  }

  static Future<int> getDownloadsPrefetchAhead() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_downloadPrefetchAheadKey) ?? 0;
    return v.clamp(0, 10);
  }

  static Future<void> setDownloadsPrefetchAhead(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_downloadPrefetchAheadKey, v.clamp(0, 10));
  }

  static Future<int> getDownloadsKeepBehind() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_downloadKeepBehindKey) ?? 0;
    return v.clamp(0, 10);
  }

  static Future<void> setDownloadsKeepBehind(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_downloadKeepBehindKey, v.clamp(0, 10));
  }

  static Uri wsUri(String serverBaseUrl) {
    final base = _normalizeBaseUri(serverBaseUrl);
    return base.replace(path: '/ws');
  }

  static Uri httpUri(String serverBaseUrl, String path) {
    // Convert ws(s):// -> http(s)://
    final base = _normalizeBaseUri(serverBaseUrl);
    final scheme = base.scheme == 'wss' ? 'https' : 'http';
    return base.replace(scheme: scheme, path: path);
  }
}
