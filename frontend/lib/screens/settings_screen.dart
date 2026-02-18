import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../services/settings_store.dart';
import '../services/android_saf.dart';
import '../widgets/glass_container.dart';
import '../widgets/app_settings_scope.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  final _newServerController = TextEditingController();
  bool _loading = true;
  bool _didInit = false;
  double _fontSize = 16.0;

  List<String> _voices = const [];
  String? _defaultVoice;
  double _defaultSpeed = 0.9;
  int _libraryGridColumns = 2;
  int _libraryGridRows = 2;

  List<String> _serverUrls = const ['ws://localhost:8000'];
  String _selectedServerUrl = 'ws://localhost:8000';

  bool _showNowReading = false;
  bool _autoScroll = true;
  int _highlightDelayMs = 800;

  String? _downloadsTreeUri;
  int _downloadsPrefetchAhead = 2;
  int _downloadsKeepBehind = 1;

  bool get _autoDownloadsEnabled => _downloadsPrefetchAhead > 0 || _downloadsKeepBehind > 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = AppSettingsScope.of(context);
    final base = SettingsStore.normalizeServerBaseUrl(settings.serverBaseUrl);
    _controller.text = base;
    _newServerController.text = '';
    _fontSize = settings.fontSize;
    _defaultVoice = settings.defaultVoice;
    _defaultSpeed = settings.defaultSpeed;
    _libraryGridColumns = settings.libraryGridColumns;
    _libraryGridRows = settings.libraryGridRows;

    final seen = <String>{};
    final urls = <String>[];
    for (final u in settings.serverBaseUrls) {
      final n = SettingsStore.normalizeServerBaseUrl(u);
      if (n.trim().isEmpty) continue;
      if (seen.add(n)) urls.add(n);
    }
    if (urls.isEmpty) urls.add('ws://localhost:8000');
    if (!urls.contains(base)) urls.add(base);
    _serverUrls = urls;
    _selectedServerUrl = urls.contains(base) ? base : urls.first;

    _showNowReading = settings.showNowReading;
    _autoScroll = settings.readerAutoScroll;
    _highlightDelayMs = settings.highlightDelayMs;

    _downloadsTreeUri = settings.downloadsTreeUri;
    _downloadsPrefetchAhead = settings.downloadsPrefetchAhead;
    _downloadsKeepBehind = settings.downloadsKeepBehind;
    await _loadVoices();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadVoices() async {
    try {
      final base = _controller.text.trim();
      final uri = SettingsStore.httpUri(base, '/voices');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['voices'] is List) {
        final voices = (decoded['voices'] as List).map((e) => e.toString()).toList();
        if (voices.isNotEmpty) {
          setState(() {
            _voices = voices;
            if (_defaultVoice == null || !_voices.contains(_defaultVoice)) {
              _defaultVoice = _voices.first;
            }
          });
        }
      }
    } catch (_) {
      // Ignore; we'll just keep the selector empty.
    }
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    final settings = AppSettingsScope.of(context);
    await settings.setServerBaseUrl(value);
    // Ensure current base is part of the saved list.
    final normalized = SettingsStore.normalizeServerBaseUrl(value);
    final urls = {..._serverUrls.map(SettingsStore.normalizeServerBaseUrl), normalized}
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
    await settings.setServerBaseUrls(urls);
    await settings.setFontSize(_fontSize);
    if (_defaultVoice != null && _defaultVoice!.isNotEmpty) {
      await settings.setDefaultVoice(_defaultVoice!);
    }
    await settings.setDefaultSpeed(_defaultSpeed);
    await settings.setLibraryGridColumns(_libraryGridColumns);
    await settings.setLibraryGridRows(_libraryGridRows);

    await settings.setShowNowReading(_showNowReading);
    await settings.setReaderAutoScroll(_autoScroll);
    await settings.setHighlightDelayMs(_highlightDelayMs);

    await settings.setDownloadsTreeUri(_downloadsTreeUri);
    await settings.setDownloadsPrefetchAhead(_downloadsPrefetchAhead);
    await settings.setDownloadsKeepBehind(_downloadsKeepBehind);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved settings')),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _newServerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(16),
      child: GlassContainer(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Backend server', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _serverUrls.contains(_selectedServerUrl) ? _selectedServerUrl : null,
                items: _serverUrls
                    .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                    .toList(growable: false),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _selectedServerUrl = v;
                    _controller.text = v;
                  });
                  _loadVoices();
                },
                decoration: const InputDecoration(
                  labelText: 'Saved servers',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'WebSocket base URL',
                  hintText: 'ws://192.168.1.45:8000',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _loadVoices(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      final n = SettingsStore.normalizeServerBaseUrl(_controller.text);
                      final urls = {..._serverUrls, n}.toList(growable: false);
                      setState(() {
                        _serverUrls = urls;
                        _selectedServerUrl = n;
                        _controller.text = n;
                      });
                      _loadVoices();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add server'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _serverUrls.length <= 1
                        ? null
                        : () {
                            final current = SettingsStore.normalizeServerBaseUrl(_controller.text);
                            final next = _serverUrls.where((u) => u != current).toList(growable: false);
                            setState(() {
                              _serverUrls = next.isEmpty ? const ['ws://localhost:8000'] : next;
                              _selectedServerUrl = _serverUrls.first;
                              _controller.text = _selectedServerUrl;
                            });
                            _loadVoices();
                          },
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Remove'),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              Text('Downloads storage (Android)', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                _downloadsTreeUri == null ? 'Not set' : _downloadsTreeUri!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: AndroidSaf.isSupported
                    ? () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final uri = await AndroidSaf.pickDownloadsFolderTreeUri();
                    if (uri == null || uri.trim().isEmpty) return;
                    if (!mounted) return;
                    setState(() => _downloadsTreeUri = uri);
                  } catch (e) {
                    if (!mounted) return;
                    messenger.showSnackBar(SnackBar(content: Text('Failed to pick folder: $e')));
                  }
                }
                    : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose folder'),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoDownloadsEnabled,
                title: const Text('Auto-download chapters'),
                onChanged: (v) {
                  setState(() {
                    if (!v) {
                      _downloadsPrefetchAhead = 0;
                      _downloadsKeepBehind = 0;
                    } else {
                      // sensible defaults
                      _downloadsPrefetchAhead = _downloadsPrefetchAhead.clamp(1, 5);
                      _downloadsKeepBehind = _downloadsKeepBehind.clamp(0, 5);
                      if (_downloadsPrefetchAhead == 0) _downloadsPrefetchAhead = 2;
                    }
                  });
                },
              ),
              Text(
                _downloadsPrefetchAhead == 0
                    ? 'Auto-download ahead: Off'
                    : 'Auto-download ahead: $_downloadsPrefetchAhead chapters',
              ),
              Slider(
                value: _downloadsPrefetchAhead.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                label: '$_downloadsPrefetchAhead',
                onChanged: _autoDownloadsEnabled
                    ? (v) => setState(() => _downloadsPrefetchAhead = v.round())
                    : null,
              ),
              Text(
                _downloadsKeepBehind == 0
                    ? 'Auto-keep behind: Off'
                    : 'Auto-keep behind: $_downloadsKeepBehind chapters',
              ),
              Slider(
                value: _downloadsKeepBehind.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                label: '$_downloadsKeepBehind',
                onChanged: _autoDownloadsEnabled
                    ? (v) => setState(() => _downloadsKeepBehind = v.round())
                    : null,
              ),
              const SizedBox(height: 18),

              Text('Library grid', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('Columns'),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 4, label: Text('4')),
                ],
                selected: {_libraryGridColumns},
                onSelectionChanged: (s) => setState(() => _libraryGridColumns = s.first),
              ),
              const SizedBox(height: 12),
              const Text('Rows'),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 4, label: Text('4')),
                ],
                selected: {_libraryGridRows},
                onSelectionChanged: (s) => setState(() => _libraryGridRows = s.first),
              ),
              const SizedBox(height: 18),

              Text('Reader', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoScroll,
                title: const Text('Auto-scroll to current paragraph'),
                onChanged: (v) => setState(() => _autoScroll = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _showNowReading,
                title: const Text('Show “Now reading” text box'),
                onChanged: (v) => setState(() => _showNowReading = v),
              ),
              const SizedBox(height: 8),
              Text('Highlight delay: ${_highlightDelayMs}ms'),
              Slider(
                value: _highlightDelayMs.toDouble(),
                min: 0,
                max: 2000,
                divisions: 40,
                label: '${_highlightDelayMs}ms',
                onChanged: (v) => setState(() => _highlightDelayMs = v.round()),
              ),
              const SizedBox(height: 18),

              Text('Default voice', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _defaultVoice,
                items: _voices
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(growable: false),
                onChanged: (v) => setState(() => _defaultVoice = v),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Text('Default speed: ${_defaultSpeed.toStringAsFixed(2)}x'),
              Slider(
                value: _defaultSpeed,
                min: 0.7,
                max: 1.4,
                divisions: 28,
                label: '${_defaultSpeed.toStringAsFixed(2)}x',
                onChanged: (v) => setState(() => _defaultSpeed = v),
              ),
              const SizedBox(height: 12),
              Text('Reader font size: ${_fontSize.toStringAsFixed(0)}'),
              Slider(
                value: _fontSize,
                min: 12,
                max: 24,
                divisions: 12,
                label: _fontSize.toStringAsFixed(0),
                onChanged: (v) => setState(() => _fontSize = v),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tip: Use your PC LAN IP when connecting from your phone. Make sure port 8000 is allowed through the firewall.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
