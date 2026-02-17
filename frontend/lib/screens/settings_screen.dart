import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../services/settings_store.dart';
import '../widgets/glass_container.dart';
import '../widgets/app_settings_scope.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _loading = true;
  double _fontSize = 16.0;

  List<String> _voices = const [];
  String? _defaultVoice;
  double _defaultSpeed = 0.9;
  int _libraryGridColumns = 2;
  int _libraryGridRows = 2;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = AppSettingsScope.of(context);
    _controller.text = settings.serverBaseUrl;
    _fontSize = settings.fontSize;
    _defaultVoice = settings.defaultVoice;
    _defaultSpeed = settings.defaultSpeed;
    _libraryGridColumns = settings.libraryGridColumns;
    _libraryGridRows = settings.libraryGridRows;
    await _loadVoices();
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
    await settings.setFontSize(_fontSize);
    if (_defaultVoice != null && _defaultVoice!.isNotEmpty) {
      await settings.setDefaultVoice(_defaultVoice!);
    }
    await settings.setDefaultSpeed(_defaultSpeed);
    await settings.setLibraryGridColumns(_libraryGridColumns);
    await settings.setLibraryGridRows(_libraryGridRows);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved settings')),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: GlassContainer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Backend server',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        labelText: 'WebSocket base URL',
                        hintText: 'ws://192.168.1.45:8000',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        // If user edits server URL, try reloading voices for the selector.
                        // Keep it lightweight; no debounce for MVP.
                        _loadVoices();
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Library grid columns (phone)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                        ButtonSegment(value: 4, label: Text('4')),
                      ],
                      selected: {_libraryGridColumns},
                      onSelectionChanged: (s) {
                        final v = s.first;
                        setState(() => _libraryGridColumns = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Library grid rows (phone)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                        ButtonSegment(value: 4, label: Text('4')),
                      ],
                      selected: {_libraryGridRows},
                      onSelectionChanged: (s) {
                        final v = s.first;
                        setState(() => _libraryGridRows = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Default voice',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _defaultVoice,
                      items: _voices
                          .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                          .toList(growable: false),
                      onChanged: (v) => setState(() => _defaultVoice = v),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
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
                    const Text(
                      'Reader font size',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Slider(
                      value: _fontSize,
                      min: 12,
                      max: 24,
                      divisions: 12,
                      label: _fontSize.toStringAsFixed(0),
                      onChanged: (v) => setState(() => _fontSize = v),
                    ),
                    const SizedBox(height: 12),
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
