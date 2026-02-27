import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/local_store.dart';
import '../services/android_saf.dart';
import '../services/settings_store.dart';
import '../widgets/app_settings_scope.dart';
import '../widgets/downloads_scope.dart';
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

  bool _selectMode = false;
  final Set<int> _selected = {};

  bool _didSyncDownloads = false;

  Future<String?> _ensureDownloadsFolder() async {
    final settings = AppSettingsScope.of(context);
    final existing = settings.downloadsTreeUri;
    if (existing != null && existing.trim().isNotEmpty) return existing;

    if (!AndroidSaf.isSupported) return null;
    final uri = await AndroidSaf.pickDownloadsFolderTreeUri();
    if (uri == null || uri.trim().isEmpty) return null;
    try {
      await AndroidSaf.persistTreePermission(uri);
    } catch (_) {}
    await settings.setDownloadsTreeUri(uri);
    return uri;
  }

  Future<List<String>> _loadBackendVoices() async {
    final settings = AppSettingsScope.of(context);
    final base = settings.serverBaseUrl;
    final uri = SettingsStore.httpUri(base, '/voices');
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const <String>[];
    final decoded = jsonDecode(res.body);
    final raw = decoded is Map ? decoded['voices'] : null;
    if (raw is! List) return const <String>[];
    return raw.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
  }

  Future<String?> _promptDownloadVoice({required List<String> voices}) async {
    if (!mounted) return null;
    final settings = AppSettingsScope.of(context);
    final defaultVoice = settings.defaultVoice ?? 'af_bella';

    var selected = '__default__';
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Download voice'),
          content: StatefulBuilder(
            builder: (context, setInner) {
              return DropdownButtonFormField<String>(
                initialValue: selected,
                items: [
                  DropdownMenuItem(value: '__default__', child: Text('Default ($defaultVoice)')),
                  ...voices.map((v) => DropdownMenuItem(value: v, child: Text(v))),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setInner(() => selected = v);
                },
                decoration: const InputDecoration(border: OutlineInputBorder()),
              );
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, selected), child: const Text('Use')),
          ],
        );
      },
    );
    if (result == null) return null;
    return result == '__default__' ? defaultVoice : result;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSyncDownloads) return;
    _didSyncDownloads = true;

    final settings = AppSettingsScope.of(context);
    final tree = settings.downloadsTreeUri;
    if (tree == null || tree.trim().isEmpty) return;
    final downloads = DownloadsScope.of(context);
    unawaited(
      downloads.reconcileWithDisk(treeUri: tree, novelId: widget.novel.id).catchError((_) {}),
    );
  }

  void _enterSelection(int chapterN) {
    setState(() {
      _selectMode = true;
      _selected.add(chapterN);
    });
  }

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

  Future<void> _refreshCover() async {
    final library = LibraryScope.of(context);
    final settings = AppSettingsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final base = settings.serverBaseUrl;
      final uri = SettingsStore.httpUri(base, '/novel_details').replace(
        queryParameters: {'url': widget.novel.novelUrl},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception('Backend /novel_details failed (${res.statusCode})');
      final decoded = jsonDecode(res.body);
      if (decoded is Map) {
        final cover = decoded['cover_url']?.toString();
        await library.setNovelCoverUrl(widget.novel.id, cover);
      }
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Cover refreshed')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Failed to refresh cover: $e')));
    }
  }

  Future<void> _downloadMany(List<StoredChapter> chapters) async {
    final treeUri = await _ensureDownloadsFolder();
    if (treeUri == null || treeUri.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a Downloads storage folder first')));
      return;
    }

    List<String> voices;
    try {
      voices = await _loadBackendVoices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load voices: $e')));
      return;
    }
    final voice = await _promptDownloadVoice(voices: voices);
    if (!mounted) return;
    if (voice == null || voice.trim().isEmpty) return;

    var chosenVoice = voice.trim();
    if (voices.isNotEmpty && !voices.contains(chosenVoice)) {
      chosenVoice = voices.first;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Selected voice not available on backend; using $chosenVoice')),
        );
      }
    }

    final settings = AppSettingsScope.of(context);
    final downloads = DownloadsScope.of(context);
    final speed = settings.defaultSpeed;

    var queued = 0;
    try {
      for (final c in chapters) {
        if (downloads.isDownloaded(widget.novel.id, c.n)) continue;
        unawaited(
          downloads.enqueueDownloadChapter(
            treeUri: treeUri,
            novelId: widget.novel.id,
            chapterN: c.n,
            chapterUrl: c.url,
            voice: chosenVoice,
            speed: speed,
            source: 'manual',
          ),
        );
        queued++;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Queued $queued downloads')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  Future<void> _deleteSelectedDownloads() async {
    final settings = AppSettingsScope.of(context);
    final treeUri = settings.downloadsTreeUri;
    if (treeUri == null || treeUri.trim().isEmpty) return;
    final downloads = DownloadsScope.of(context);

    final items = _selected.toList(growable: false);
    for (final n in items) {
      if (!downloads.isDownloaded(widget.novel.id, n)) continue;
      try {
        await downloads.deleteDownloadedChapter(treeUri: treeUri, novelId: widget.novel.id, chapterN: n);
      } catch (_) {}
    }
  }

  Future<void> _downloadNext(int count) async {
    final library = LibraryScope.of(context);
    final cache = library.cacheFor(widget.novel.id);
    final chapters = cache?.chapters ?? const <StoredChapter>[];
    if (chapters.isEmpty) return;

    final progress = library.progressFor(widget.novel.id);
    final curN = progress?.chapterN ?? 0;
    final next = chapters.where((c) => c.n > curN).toList(growable: false);
    if (next.isEmpty) return;

    await _downloadMany(next.take(count).toList(growable: false));
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final downloads = DownloadsScope.of(context);
    final cache = library.cacheFor(widget.novel.id);
    final progress = library.progressFor(widget.novel.id);
    final chapters = cache?.chapters ?? const <StoredChapter>[];
    final downloadedCount = downloads.chaptersForNovel(widget.novel.id).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.novel.name),
        actions: [
          IconButton(
            tooltip: _chaptersGrid ? 'Show list' : 'Show grid',
            onPressed: () => setState(() => _chaptersGrid = !_chaptersGrid),
            icon: Icon(_chaptersGrid ? Icons.view_list : Icons.grid_view),
          ),
          if (_selectMode) ...[
            IconButton(
              tooltip: 'Exit selection',
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
              icon: const Icon(Icons.close),
            ),
            PopupMenuButton<String>(
              tooltip: 'Selection actions',
              onSelected: (v) async {
                switch (v) {
                  case 'clear':
                    setState(() => _selected.clear());
                    break;
                  case 'download':
                    await _downloadMany(chapters.where((c) => _selected.contains(c.n)).toList(growable: false));
                    if (!mounted) return;
                    setState(() {
                      _selectMode = false;
                      _selected.clear();
                    });
                    break;
                  case 'delete':
                    await _deleteSelectedDownloads();
                    if (!mounted) return;
                    setState(() {
                      _selectMode = false;
                      _selected.clear();
                    });
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'clear',
                  enabled: _selected.isNotEmpty,
                  child: const Text('Clear selection'),
                ),
                PopupMenuItem(
                  value: 'download',
                  enabled: _selected.isNotEmpty && !_busy,
                  child: const Text('Download selected'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: _selected.isNotEmpty && !_busy,
                  child: const Text('Delete selected downloads'),
                ),
              ],
            ),
          ],
          IconButton(
            tooltip: 'Refresh Chapters',
            onPressed: _busy ? null : _refreshChapters,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: 'Actions',
            onSelected: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);
              final settings = AppSettingsScope.of(context);
              switch (v) {
                case 'download_all':
                  await _downloadMany(chapters);
                  break;
                case 'download_next_5':
                  await _downloadNext(5);
                  break;
                case 'download_next_10':
                  await _downloadNext(10);
                  break;
                case 'download_next_25':
                  await _downloadNext(25);
                  break;
                case 'delete_downloads':
                  final tree = settings.downloadsTreeUri;
                  if (tree == null || tree.trim().isEmpty) {
                    messenger.showSnackBar(const SnackBar(content: Text('Set Downloads storage folder in Settings first')));
                    return;
                  }
                  await downloads.deleteAllDownloadedForNovel(treeUri: tree, novelId: widget.novel.id);
                  if (!mounted) return;
                  messenger.showSnackBar(const SnackBar(content: Text('Deleted downloads')));
                  break;
                case 'refresh_cover':
                  await _refreshCover();
                  break;
                case 'remove_library':
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Remove from library?'),
                      content: const Text('This removes the novel from your library and deletes its local cache/progress.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    if (!mounted) return;
                    final tree = settings.downloadsTreeUri;
                    if (tree != null && tree.trim().isNotEmpty) {
                      try {
                        await downloads.deleteAllDownloadedForNovel(
                          treeUri: tree,
                          novelId: widget.novel.id,
                        );
                      } catch (_) {}
                    }
                    await library.removeNovel(widget.novel.id);
                    if (!mounted) return;
                    navigator.pop();
                  }
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'download_all',
                enabled: chapters.isNotEmpty && !_busy,
                child: const Text('Download all chapters'),
              ),
              PopupMenuItem(
                value: 'download_next_5',
                enabled: chapters.isNotEmpty && !_busy,
                child: const Text('Download next 5 chapters'),
              ),
              PopupMenuItem(
                value: 'download_next_10',
                enabled: chapters.isNotEmpty && !_busy,
                child: const Text('Download next 10 chapters'),
              ),
              PopupMenuItem(
                value: 'download_next_25',
                enabled: chapters.isNotEmpty && !_busy,
                child: const Text('Download next 25 chapters'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete_downloads',
                enabled: downloads.chaptersForNovel(widget.novel.id).isNotEmpty && !_busy,
                child: const Text('Delete downloads'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'refresh_cover',
                enabled: !_busy,
                child: const Text('Refresh cover image'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'remove_library',
                enabled: !_busy,
                child: const Text('Remove from library'),
              ),
            ],
          ),
        ],
      ),
      body: chapters.isEmpty && _busy
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
                    // Non-blocking progress indicator shown during refresh.
                    if (_busy)
                      const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Row(
                        children: [
                          Text(
                            'Downloaded: $downloadedCount',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const Spacer(),
                          Text(
                            _selectMode ? 'Long-press to add more' : 'Long-press to select',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
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
                                  downloaded: downloads.isDownloaded(widget.novel.id, c.n),
                                  selectMode: _selectMode,
                                  selected: _selected.contains(c.n),
                                  onToggleSelect: () => setState(() {
                                    if (_selected.contains(c.n)) {
                                      _selected.remove(c.n);
                                    } else {
                                      _selected.add(c.n);
                                    }
                                  }),
                                  onOpen: () => _selectMode
                                      ? setState(() {
                                          if (_selected.contains(c.n)) {
                                            _selected.remove(c.n);
                                          } else {
                                            _selected.add(c.n);
                                          }
                                        })
                                      : _openChapter(c),
                                  onLongPress: () => _enterSelection(c.n),
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
                                  downloaded: downloads.isDownloaded(widget.novel.id, c.n),
                                  selectMode: _selectMode,
                                  selected: _selected.contains(c.n),
                                  onToggleSelect: () => setState(() {
                                    if (_selected.contains(c.n)) {
                                      _selected.remove(c.n);
                                    } else {
                                      _selected.add(c.n);
                                    }
                                  }),
                                  onOpen: () => _selectMode
                                      ? setState(() {
                                          if (_selected.contains(c.n)) {
                                            _selected.remove(c.n);
                                          } else {
                                            _selected.add(c.n);
                                          }
                                        })
                                      : _openChapter(c),
                                  onLongPress: () => _enterSelection(c.n),
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
    required this.downloaded,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onOpen,
    required this.onLongPress,
  });

  final String novelId;
  final StoredChapter chapter;
  final bool downloaded;
  final bool selectMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final progress = library.progressFor(novelId);
    final read = progress?.completedChapters.contains(chapter.n) ?? false;

    final downloads = DownloadsScope.of(context);
    final downloading = downloads.isDownloading(novelId, chapter.n);
    final job = downloads.jobFor(novelId, chapter.n);
    final progressValue = job?.progress;

    Widget? downloadIndicator;
    if (downloaded) {
      downloadIndicator = const Icon(Icons.check_circle);
    } else if (downloading) {
      downloadIndicator = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          value: progressValue,
        ),
      );
    }

    return ListTile(
      title: Text('Chapter ${chapter.n}'),
      subtitle: chapter.title.isEmpty ? null : Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      leading: selectMode
          ? Checkbox(value: selected, onChanged: (_) => onToggleSelect())
          : Icon(read ? Icons.check_circle : Icons.radio_button_unchecked),
      onTap: onOpen,
      onLongPress: () {
        if (!selectMode) onLongPress();
      },
      trailing: selectMode
          ? (downloaded ? const Icon(Icons.download_done) : const SizedBox.shrink())
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (downloadIndicator != null) ...[
                  downloadIndicator,
                  const SizedBox(width: 8),
                ],
                PopupMenuButton<String>(
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
              ],
            ),
    );
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.novelId,
    required this.chapter,
    required this.downloaded,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onOpen,
    required this.onLongPress,
  });

  final String novelId;
  final StoredChapter chapter;
  final bool downloaded;
  final bool selectMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final library = LibraryScope.of(context);
    final progress = library.progressFor(novelId);
    final read = progress?.completedChapters.contains(chapter.n) ?? false;

    final downloads = DownloadsScope.of(context);
    final downloading = downloads.isDownloading(novelId, chapter.n);
    final job = downloads.jobFor(novelId, chapter.n);
    final progressValue = job?.progress;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onOpen,
      onLongPress: () {
        if (!selectMode) onLongPress();
      },
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
              if (selectMode)
                Checkbox(value: selected, onChanged: (_) => onToggleSelect())
              else
                Icon(read ? Icons.check_circle : Icons.circle_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Chapter ${chapter.n}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!selectMode && downloaded) const Icon(Icons.check_circle, size: 18),
              if (!selectMode && !downloaded && downloading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 3, value: progressValue),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
