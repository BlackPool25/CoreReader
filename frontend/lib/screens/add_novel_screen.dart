import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../widgets/glass_container.dart';
import '../widgets/library_scope.dart';
import '../widgets/app_settings_scope.dart';
import '../services/settings_store.dart';

class AddNovelScreen extends StatefulWidget {
  const AddNovelScreen({super.key});

  @override
  State<AddNovelScreen> createState() => _AddNovelScreenState();
}

class _AddNovelScreenState extends State<AddNovelScreen> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) return;
    setState(() => _busy = true);
    try {
      final library = LibraryScope.of(context);
      final base = AppSettingsScope.of(context).serverBaseUrl;
      final novel = await library.addNovel(name: name, novelUrl: url);

      // Best-effort: fetch cover URL via backend and store it.
      try {
        final uri = SettingsStore.httpUri(base, '/novel_details').replace(
          queryParameters: {'url': novel.novelUrl},
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            final cover = decoded['cover_url']?.toString();
            if (cover != null && cover.trim().isNotEmpty) {
              await library.setNovelCoverUrl(novel.id, cover);
            }
          }
        }
      } catch (_) {
        // Ignore cover failures.
      }
      if (!mounted) return;
      _name.clear();
      _url.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added novel to library')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add novel: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add novel'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: GlassContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add novel',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Novel name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Novel URL',
                    hintText: 'https://www.novelcool.com/novel/...html',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add to library'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
