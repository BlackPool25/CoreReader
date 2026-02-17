import 'package:shared_preferences/shared_preferences.dart';

import 'local_defaults.dart';

class SettingsStore {
  static const _serverBaseKey = 'server_base_url';
  static const _fontSizeKey = 'reader_font_size';
  static const _useLocalTtsKey = 'use_local_tts';

  /// Base URL including scheme and port, e.g. `ws://192.168.1.45:8000`.
  static Future<String> getServerBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverBaseKey) ?? 'ws://localhost:8000';
  }

  static Future<void> setServerBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverBaseKey, value);
  }

  static Future<double> getReaderFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_fontSizeKey) ?? 16.0;
  }

  static Future<void> setReaderFontSize(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, value);
  }

  static Future<bool> getUseLocalTts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_useLocalTtsKey) ?? defaultUseLocalTts();
  }

  static Future<void> setUseLocalTts(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useLocalTtsKey, value);
  }

  static Uri wsUri(String serverBaseUrl) {
    final base = Uri.parse(serverBaseUrl);
    return base.replace(path: '/ws');
  }

  static Uri httpUri(String serverBaseUrl, String path) {
    // Convert ws(s):// -> http(s)://
    final base = Uri.parse(serverBaseUrl);
    final scheme = base.scheme == 'wss' ? 'https' : 'http';
    return base.replace(scheme: scheme, path: path);
  }
}
