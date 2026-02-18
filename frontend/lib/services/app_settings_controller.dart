import 'package:flutter/material.dart';

import 'settings_store.dart';

ThemeMode _parseThemeMode(String s) {
  return switch (s) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

String _serializeThemeMode(ThemeMode m) {
  return switch (m) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}

class AppSettingsController extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  String _serverBaseUrl = 'ws://localhost:8000';
  List<String> _serverBaseUrls = const ['ws://localhost:8000'];
  double _fontSize = 16.0;
  String? _defaultVoice;
  double _defaultSpeed = 0.9;
  int _libraryGridColumns = 2;
  int _libraryGridRows = 2;

  bool _showNowReading = false;
  bool _readerAutoScroll = true;
  int _highlightDelayMs = 800;

  String? _downloadsTreeUri;
  int _downloadsPrefetchAhead = 2;
  int _downloadsKeepBehind = 1;

  ThemeMode get themeMode => _themeMode;
  String get serverBaseUrl => _serverBaseUrl;
  List<String> get serverBaseUrls => _serverBaseUrls;
  double get fontSize => _fontSize;
  String? get defaultVoice => _defaultVoice;
  double get defaultSpeed => _defaultSpeed;
  int get libraryGridColumns => _libraryGridColumns;
  int get libraryGridRows => _libraryGridRows;

  bool get showNowReading => _showNowReading;
  bool get readerAutoScroll => _readerAutoScroll;
  int get highlightDelayMs => _highlightDelayMs;

  String? get downloadsTreeUri => _downloadsTreeUri;
  int get downloadsPrefetchAhead => _downloadsPrefetchAhead;
  int get downloadsKeepBehind => _downloadsKeepBehind;

  Future<void> load() async {
    _themeMode = _parseThemeMode(await SettingsStore.getThemeMode());
    _serverBaseUrl = await SettingsStore.getServerBaseUrl();
    _serverBaseUrls = await SettingsStore.getServerBaseUrlList();
    _fontSize = await SettingsStore.getReaderFontSize();
    _defaultVoice = await SettingsStore.getDefaultVoice();
    _defaultSpeed = await SettingsStore.getDefaultSpeed();
    _libraryGridColumns = await SettingsStore.getLibraryGridColumns();
    _libraryGridRows = await SettingsStore.getLibraryGridRows();

    _showNowReading = await SettingsStore.getShowNowReading();
    _readerAutoScroll = await SettingsStore.getReaderAutoScroll();
    _highlightDelayMs = await SettingsStore.getHighlightDelayMs();

    _downloadsTreeUri = await SettingsStore.getDownloadsTreeUri();
    _downloadsPrefetchAhead = await SettingsStore.getDownloadsPrefetchAhead();
    _downloadsKeepBehind = await SettingsStore.getDownloadsKeepBehind();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await SettingsStore.setThemeMode(_serializeThemeMode(mode));
  }

  Future<void> toggleLightDark() async {
    // If system: default to dark on first toggle.
    final next = switch (_themeMode) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.system => ThemeMode.dark,
    };
    await setThemeMode(next);
  }

  Future<void> setServerBaseUrl(String value) async {
    final normalized = SettingsStore.normalizeServerBaseUrl(value);
    if (_serverBaseUrl == normalized) return;
    _serverBaseUrl = normalized;
    notifyListeners();
    await SettingsStore.setServerBaseUrl(normalized);
  }

  Future<void> setServerBaseUrls(List<String> urls) async {
    _serverBaseUrls = urls;
    notifyListeners();
    await SettingsStore.setServerBaseUrlList(urls);
  }

  Future<void> setFontSize(double value) async {
    if (_fontSize == value) return;
    _fontSize = value;
    notifyListeners();
    await SettingsStore.setReaderFontSize(value);
  }

  Future<void> setDefaultVoice(String voice) async {
    if (_defaultVoice == voice) return;
    _defaultVoice = voice;
    notifyListeners();
    await SettingsStore.setDefaultVoice(voice);
  }

  Future<void> setDefaultSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 2.0).toDouble();
    if ((_defaultSpeed - clamped).abs() < 0.0001) return;
    _defaultSpeed = clamped;
    notifyListeners();
    await SettingsStore.setDefaultSpeed(clamped);
  }

  Future<void> setLibraryGridColumns(int columns) async {
    final v = columns.clamp(2, 4);
    if (_libraryGridColumns == v) return;
    _libraryGridColumns = v;
    notifyListeners();
    await SettingsStore.setLibraryGridColumns(v);
  }

  Future<void> setLibraryGridRows(int rows) async {
    final v = rows.clamp(2, 4);
    if (_libraryGridRows == v) return;
    _libraryGridRows = v;
    notifyListeners();
    await SettingsStore.setLibraryGridRows(v);
  }

  Future<void> setShowNowReading(bool v) async {
    if (_showNowReading == v) return;
    _showNowReading = v;
    notifyListeners();
    await SettingsStore.setShowNowReading(v);
  }

  Future<void> setReaderAutoScroll(bool v) async {
    if (_readerAutoScroll == v) return;
    _readerAutoScroll = v;
    notifyListeners();
    await SettingsStore.setReaderAutoScroll(v);
  }

  Future<void> setHighlightDelayMs(int v) async {
    final clamped = v.clamp(0, 3000);
    if (_highlightDelayMs == clamped) return;
    _highlightDelayMs = clamped;
    notifyListeners();
    await SettingsStore.setHighlightDelayMs(clamped);
  }

  Future<void> setDownloadsTreeUri(String? uri) async {
    final normalized = (uri == null || uri.trim().isEmpty) ? null : uri.trim();
    if (_downloadsTreeUri == normalized) return;
    _downloadsTreeUri = normalized;
    notifyListeners();
    await SettingsStore.setDownloadsTreeUri(normalized);
  }

  Future<void> setDownloadsPrefetchAhead(int v) async {
    final clamped = v.clamp(0, 10);
    if (_downloadsPrefetchAhead == clamped) return;
    _downloadsPrefetchAhead = clamped;
    notifyListeners();
    await SettingsStore.setDownloadsPrefetchAhead(clamped);
  }

  Future<void> setDownloadsKeepBehind(int v) async {
    final clamped = v.clamp(0, 10);
    if (_downloadsKeepBehind == clamped) return;
    _downloadsKeepBehind = clamped;
    notifyListeners();
    await SettingsStore.setDownloadsKeepBehind(clamped);
  }
}
