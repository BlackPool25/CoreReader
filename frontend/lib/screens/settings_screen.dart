import 'package:flutter/material.dart';

import '../services/settings_store.dart';
import '../widgets/glass_container.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _loading = true;
  double _fontSize = 16.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final base = await SettingsStore.getServerBaseUrl();
    _controller.text = base;
    _fontSize = await SettingsStore.getReaderFontSize();
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    await SettingsStore.setServerBaseUrl(value);
    await SettingsStore.setReaderFontSize(_fontSize);
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
