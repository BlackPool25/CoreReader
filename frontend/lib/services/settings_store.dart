import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  static const _serverBaseKey = 'server_base_url';
  static const _fontSizeKey = 'reader_font_size';
  static const _themeModeKey = 'theme_mode';
  static const _defaultVoiceKey = 'default_voice';
  static const _defaultSpeedKey = 'default_speed';
  static const _libraryGridColumnsKey = 'library_grid_columns';
  static const _libraryGridRowsKey = 'library_grid_rows';

  /// Base URL including scheme and port, e.g. `ws://192.168.1.45:8000`.
  static Future<String> getServerBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverBaseKey) ?? 'ws://localhost:8000';
  }

  static Future<void> setServerBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverBaseKey, normalizeServerBaseUrl(value));
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

  static Future<String?> getDefaultVoice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_defaultVoiceKey);
  }

  static Future<void> setDefaultVoice(String voice) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_defaultVoiceKey, voice);
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
