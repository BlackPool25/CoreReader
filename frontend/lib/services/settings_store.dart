import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  static const _serverBaseKey = 'server_base_url';
  static const _fontSizeKey = 'reader_font_size';

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

    final normalized = uri.replace(
      scheme: scheme,
      path: '',
      query: '',
      fragment: '',
    );
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
