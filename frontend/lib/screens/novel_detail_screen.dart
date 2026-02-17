import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/local_store.dart';
import '../services/settings_store.dart';
import '../widgets/app_settings_scope.dart';
import '../widgets/library_scope.dart';
import 'reader_screen.dart';

class NovelDetailScreen extends StatefulWidget {
  const NovelDetailScreen({super.key, required this.novel});

  final StoredNovel novel;

  @override
  State<NovelDetailScreen> createState() => _NovelDetailScreenState();
}

class _NovelDetailScreenState extends State<NovelDetailScreen> {
  bool _busy = false;
  bool _chaptersGrid = false; // default list

  Future<void> _refreshChapters() async {
    setState(() => _busy = true);
    final library = LibraryScope.of(context);
    final settings = AppSettingsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final base = settings.serverBaseUrl;
      final uri = SettingsStore.httpUri(base, '/novel_index').replace(
        queryParameters: {'url': widget.novel.novelUrl},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw Exception('Backend /novel_index failed (${res.statusCode})');
      }
      final decoded = jsonDecode(res.body);
      final raw = decoded is Map ? decoded['chapters'] : null;
      final chapters = <StoredChapter>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final m = item.cast<String, dynamic>();
            final parsedN = (m['n'] as num?)?.toInt();
            final title = (m['title'] as String?) ?? '';
            final url = (m['url'] as String?) ?? '';
            if (url.isNotEmpty) {
              // Some NovelCool indexes fail to parse chapter numbers for some entries.
              // To keep the UX stable (and ensure Chapter 1 exists), fall back to
              // sequential numbering based on the chapter list order.
              final fallbackN = chapters.length + 1;
              final n = (parsedN != null && parsedN > 0) ? parsedN : fallbackN;
              chapters.add(StoredChapter(n: n, title: title, url: url));
            }
          }
        }
      }
      chapters.sort((a, b) => a.n.compareTo(b.n));
      if (chapters.isEmpty) throw Exception('No chapters found');

      final cache = StoredNovelCache(
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
        chapters: chapters,
      );
      await library.setCache(widget.novel.id, cache);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Chapters refreshed')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to refresh chapters: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openChapter(StoredChapter c, {int startParagraph = 0}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          novel: widget.novel,
          chapter: c,
          startParagraph: startParagraph,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final cache = library.cacheFor(widget.novel.id);
    final progress = library.progressFor(widget.novel.id);
    final chapters = cache?.chapters ?? const <StoredChapter>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.novel.name),
        actions: [
          IconButton(
            tooltip: _chaptersGrid ? 'Show list' : 'Show grid',
            onPressed: () => setState(() => _chaptersGrid = !_chaptersGrid),
            icon: Icon(_chaptersGrid ? Icons.view_list : Icons.grid_view),
          ),
          IconButton(
            tooltip: 'Refresh Chapters',
            onPressed: _busy ? null : _refreshChapters,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : chapters.isEmpty
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _refreshChapters,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Chapters'),
                  ),
                )
              : Column(
                  children: [
                    if (progress != null) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('Continue: Chapter ${progress.chapterN}'),
                            ),
                            FilledButton(
                              onPressed: () {
                                final idx = chapters.indexWhere((c) => c.n == progress.chapterN);
                                if (idx >= 0) {
                                  _openChapter(chapters[idx], startParagraph: progress.paragraphIndex);
                                }
                              },
                              child: const Text('Continue'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Expanded(
                      child: _chaptersGrid
                          ? GridView.builder(
                              padding: const EdgeInsets.all(16),
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 1.8,
                              ),
                              itemCount: chapters.length,
                              itemBuilder: (context, i) {
                                final c = chapters[i];
                                return _ChapterTile(
                                  novelId: widget.novel.id,
                                  chapter: c,
                                  onOpen: () => _openChapter(c),
                                );
                              },
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(8),
                              itemCount: chapters.length,
                              itemBuilder: (context, i) {
                                final c = chapters[i];
                                return _ChapterRow(
                                  novelId: widget.novel.id,
                                  chapter: c,
                                  onOpen: () => _openChapter(c),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.novelId,
    required this.chapter,
    required this.onOpen,
  });

  final String novelId;
  final StoredChapter chapter;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final progress = library.progressFor(novelId);
    final read = progress?.completedChapters.contains(chapter.n) ?? false;

    return ListTile(
      title: Text('Chapter ${chapter.n}'),
      subtitle: chapter.title.isEmpty ? null : Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      leading: Icon(read ? Icons.check_circle : Icons.radio_button_unchecked),
      onTap: onOpen,
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'read':
              library.markRead(novelId, chapter.n, read: true);
              break;
            case 'unread':
              library.markRead(novelId, chapter.n, read: false);
              break;
            case 'read_prev':
              library.markPrevAll(novelId, chapter.n, read: true);
              break;
            case 'unread_prev':
              library.markPrevAll(novelId, chapter.n, read: false);
              break;
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'read', child: Text('Mark as read')),
          PopupMenuItem(value: 'read_prev', child: Text('Mark previous all as read')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'unread', child: Text('Mark as unread')),
          PopupMenuItem(value: 'unread_prev', child: Text('Mark previous all as unread')),
        ],
      ),
    );
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.novelId,
    required this.chapter,
    required this.onOpen,
  });

  final String novelId;
  final StoredChapter chapter;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final library = LibraryScope.of(context);
    final progress = library.progressFor(novelId);
    final read = progress?.completedChapters.contains(chapter.n) ?? false;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onOpen,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Icon(read ? Icons.check_circle : Icons.circle_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Chapter ${chapter.n}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
