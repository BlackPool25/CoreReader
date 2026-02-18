import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../services/local_store.dart';
import '../services/settings_store.dart';
import '../widgets/app_settings_scope.dart';
import '../widgets/downloads_scope.dart';
import '../widgets/library_scope.dart';
import 'add_novel_screen.dart';
import 'novel_detail_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _busy = false;
  bool _didPrefetchCovers = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPrefetchCovers) return;
    _didPrefetchCovers = true;

    // Best-effort: fill in missing cover images for existing novels.
    unawaited(_prefetchMissingCovers());
  }

  Future<void> _prefetchMissingCovers() async {
    final library = LibraryScope.of(context);
    final settings = AppSettingsScope.of(context);
    final base = settings.serverBaseUrl;
    for (final novel in library.novels) {
      if (!mounted) return;
      if (novel.coverUrl != null && novel.coverUrl!.trim().isNotEmpty) continue;
      try {
        final uri = SettingsStore.httpUri(base, '/novel_details').replace(
          queryParameters: {'url': novel.novelUrl},
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) continue;
        final decoded = jsonDecode(res.body);
        if (decoded is Map) {
          final cover = decoded['cover_url']?.toString();
          if (cover != null && cover.trim().isNotEmpty) {
            await library.setNovelCoverUrl(novel.id, cover);
          }
        }
      } catch (_) {
        // best-effort
      }
    }
  }

  int _gridCountForWidth(BuildContext context, double w) {
    final pref = AppSettingsScope.of(context).libraryGridColumns;
    if (w < 600) return pref;
    if (w >= 1100) return 6;
    if (w >= 900) return 5;
    if (w >= 700) return 4;
    if (w >= 520) return 3;
    return 2;
  }

  Future<void> _refreshAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    final library = LibraryScope.of(context);
    final settings = AppSettingsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    var ok = 0;
    try {
      for (final novel in library.novels) {
        try {
          final base = settings.serverBaseUrl;
          final uri = SettingsStore.httpUri(base, '/novel_index').replace(
            queryParameters: {'url': novel.novelUrl},
          );
          final res = await http.get(uri).timeout(const Duration(seconds: 30));
          if (res.statusCode != 200) continue;
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
                  final fallbackN = chapters.length + 1;
                  final n = (parsedN != null && parsedN > 0) ? parsedN : fallbackN;
                  chapters.add(StoredChapter(n: n, title: title, url: url));
                }
              }
            }
          }
          chapters.sort((a, b) => a.n.compareTo(b.n));
          if (chapters.isEmpty) continue;
          await library.setCache(
            novel.id,
            StoredNovelCache(
              fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
              chapters: chapters,
            ),
          );
          ok++;
        } catch (_) {
          // best-effort
        }
      }
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Refreshed chapters for $ok novels')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final novels = library.novels;

    if (novels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No novels yet.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                // The app bar already has the Add button; keep this as a shortcut.
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddNovelScreen()),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('Use the + button to add'),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final crossAxisCount = _gridCountForWidth(context, c.maxWidth);
        final settings = AppSettingsScope.of(context);
        final rows = settings.libraryGridRows;
        final availableH = (c.maxHeight - 32).clamp(0.0, double.infinity);
        final extent = (availableH - 12.0 * (rows - 1)) / rows;
        final mainAxisExtent = extent.clamp(96.0, 240.0);
        return Column(
          children: [
            Row(
              children: [
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh all novels',
                  onPressed: _busy ? null : _refreshAll,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: mainAxisExtent,
                ),
                itemCount: novels.length,
                itemBuilder: (context, i) {
                  final n = novels[i];
                  return _NovelCard(
                    novel: n,
                    busy: _busy,
                    onRefreshAll: _refreshAll,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NovelCard extends StatelessWidget {
  const _NovelCard({
    required this.novel,
    required this.busy,
    required this.onRefreshAll,
  });

  final StoredNovel novel;
  final bool busy;
  final VoidCallback onRefreshAll;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final library = LibraryScope.of(context);
    final progress = library.progressFor(novel.id);
    final subtitle = progress == null
        ? 'Not started'
        : 'Continue: Chapter ${progress.chapterN}';

    final hasCover = novel.coverUrl != null && novel.coverUrl!.trim().isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NovelDetailScreen(novel: novel),
            ),
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned.fill(
                child: hasCover
                    ? Image.network(
                        novel.coverUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => DecoratedBox(
                          decoration: BoxDecoration(color: cs.surfaceContainerHighest),
                        ),
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(color: cs.surfaceContainerHighest),
                      ),
              ),
              // Actions in the top-right.
              Positioned(
                top: 6,
                right: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
                  ),
                  child: PopupMenuButton<String>(
                    tooltip: 'Actions',
                    onSelected: (v) async {
                      final settings = AppSettingsScope.of(context);
                      final downloads = DownloadsScope.of(context);
                      final library = LibraryScope.of(context);
                      switch (v) {
                        case 'refresh_all':
                          onRefreshAll();
                          break;
                        case 'delete':
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                title: const Text('Delete novel?'),
                                content: const Text('This removes the novel from your library and deletes its local cache/progress.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                                ],
                              );
                            },
                          );
                          if (ok == true) {
                            if (!context.mounted) return;
                            final tree = settings.downloadsTreeUri;
                            if (tree != null && tree.trim().isNotEmpty) {
                              try {
                                await downloads.deleteAllDownloadedForNovel(
                                  treeUri: tree,
                                  novelId: novel.id,
                                );
                              } catch (_) {}
                            }
                            await library.removeNovel(novel.id);
                          }
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'refresh_all',
                        enabled: !busy,
                        child: const Text('Refresh all chapters'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete from library'),
                      ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.more_vert, size: 18),
                    ),
                  ),
                ),
              ),
              // Bottom label area for readability.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: 0.85),
                    border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35))),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          novel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
