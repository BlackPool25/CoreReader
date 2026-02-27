import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/downloads_controller.dart';
import '../services/local_store.dart';
import '../services/android_saf.dart';
import '../services/settings_store.dart';
import '../widgets/app_settings_scope.dart';
import '../widgets/downloads_scope.dart';
import '../widgets/library_scope.dart';
import 'reader_screen.dart';

// ---------------------------------------------------------------------------
// Tri-state filter: off → include → exclude → off
// ---------------------------------------------------------------------------
enum _TriState { off, include, exclude }

_TriState _nextTriState(_TriState s) {
  switch (s) {
    case _TriState.off:
      return _TriState.include;
    case _TriState.include:
      return _TriState.exclude;
    case _TriState.exclude:
      return _TriState.off;
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class NovelDetailScreen extends StatefulWidget {
  const NovelDetailScreen({super.key, required this.novel});

  final StoredNovel novel;

  @override
  State<NovelDetailScreen> createState() => _NovelDetailScreenState();
}

class _NovelDetailScreenState extends State<NovelDetailScreen> {
  bool _busy = false;

  // Display options
  bool _chaptersGrid = false;
  int _gridColumns = 3;

  // Filter state
  _TriState _downloadedFilter = _TriState.off;
  _TriState _unreadFilter = _TriState.off;

  // Sort state
  bool _sortAscending = true;

  // Selection
  bool _selectMode = false;
  final Set<int> _selected = {};

  bool _didSyncDownloads = false;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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

  void _exitSelection() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

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
      messenger.showSnackBar(const SnackBar(content: Text('Chapters refreshed')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Failed to refresh chapters: $e')));
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

  // ---------------------------------------------------------------------------
  // Selection bottom-bar actions
  // ---------------------------------------------------------------------------

  void _markSelectedRead(bool read) {
    final library = LibraryScope.of(context);
    for (final n in _selected) {
      library.markRead(widget.novel.id, n, read: read);
    }
    _exitSelection();
  }

  void _markPreviousAsRead() {
    if (_selected.isEmpty) return;
    final library = LibraryScope.of(context);
    // Find the lowest selected chapter number and mark everything before it as read
    final minN = _selected.reduce((a, b) => a < b ? a : b);
    library.markPrevAll(widget.novel.id, minN, read: true);
    _exitSelection();
  }

  void _selectAllVisible(List<StoredChapter> visible) {
    setState(() {
      _selectMode = true;
      _selected.addAll(visible.map((c) => c.n));
    });
  }

  Future<void> _downloadSelected(List<StoredChapter> allChapters) async {
    final toDownload = allChapters.where((c) => _selected.contains(c.n)).toList(growable: false);
    await _downloadMany(toDownload);
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _deleteSelectedAndExit() async {
    await _deleteSelectedDownloads();
    if (!mounted) return;
    _exitSelection();
  }

  // ---------------------------------------------------------------------------
  // Filtering & sorting
  // ---------------------------------------------------------------------------

  List<StoredChapter> _applyFiltersAndSort(
    List<StoredChapter> chapters,
    StoredReadingProgress? progress,
    DownloadsController downloads,
  ) {
    var result = chapters.toList();

    // Downloaded filter
    if (_downloadedFilter == _TriState.include) {
      result = result.where((c) => downloads.isDownloaded(widget.novel.id, c.n)).toList();
    } else if (_downloadedFilter == _TriState.exclude) {
      result = result.where((c) => !downloads.isDownloaded(widget.novel.id, c.n)).toList();
    }

    // Unread filter
    final completed = progress?.completedChapters ?? const <int>{};
    if (_unreadFilter == _TriState.include) {
      result = result.where((c) => !completed.contains(c.n)).toList();
    } else if (_unreadFilter == _TriState.exclude) {
      result = result.where((c) => completed.contains(c.n)).toList();
    }

    // Sort
    if (_sortAscending) {
      result.sort((a, b) => a.n.compareTo(b.n));
    } else {
      result.sort((a, b) => b.n.compareTo(a.n));
    }

    return result;
  }

  bool get _hasActiveFilters =>
      _downloadedFilter != _TriState.off || _unreadFilter != _TriState.off;

  // ---------------------------------------------------------------------------
  // Bottom sheet: Filter / Sort / Display
  // ---------------------------------------------------------------------------

  void _showFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return _FilterSortDisplaySheet(
          downloadedFilter: _downloadedFilter,
          unreadFilter: _unreadFilter,
          sortAscending: _sortAscending,
          chaptersGrid: _chaptersGrid,
          gridColumns: _gridColumns,
          onChanged: ({
            _TriState? downloadedFilter,
            _TriState? unreadFilter,
            bool? sortAscending,
            bool? chaptersGrid,
            int? gridColumns,
          }) {
            setState(() {
              if (downloadedFilter != null) _downloadedFilter = downloadedFilter;
              if (unreadFilter != null) _unreadFilter = unreadFilter;
              if (sortAscending != null) _sortAscending = sortAscending;
              if (chaptersGrid != null) _chaptersGrid = chaptersGrid;
              if (gridColumns != null) _gridColumns = gridColumns;
            });
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final downloads = DownloadsScope.of(context);
    final cache = library.cacheFor(widget.novel.id);
    final progress = library.progressFor(widget.novel.id);
    final allChapters = cache?.chapters ?? const <StoredChapter>[];
    final downloadedCount = downloads.chaptersForNovel(widget.novel.id).length;

    final filteredChapters = _applyFiltersAndSort(allChapters, progress, downloads);

    return Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                tooltip: 'Exit selection',
                onPressed: _exitSelection,
                icon: const Icon(Icons.close),
              ),
              title: Text('${_selected.length}'),
            )
          : AppBar(
              title: Text(widget.novel.name),
              actions: [
                IconButton(
                  tooltip: 'Filter / Sort / Display',
                  onPressed: _showFilterSheet,
                  icon: Icon(
                    _hasActiveFilters ? Icons.filter_list_off : Icons.filter_list,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh chapters',
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
                        await _downloadMany(allChapters);
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
                      enabled: allChapters.isNotEmpty && !_busy,
                      child: const Text('Download all chapters'),
                    ),
                    PopupMenuItem(
                      value: 'download_next_5',
                      enabled: allChapters.isNotEmpty && !_busy,
                      child: const Text('Download next 5'),
                    ),
                    PopupMenuItem(
                      value: 'download_next_10',
                      enabled: allChapters.isNotEmpty && !_busy,
                      child: const Text('Download next 10'),
                    ),
                    PopupMenuItem(
                      value: 'download_next_25',
                      enabled: allChapters.isNotEmpty && !_busy,
                      child: const Text('Download next 25'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete_downloads',
                      enabled: downloads.chaptersForNovel(widget.novel.id).isNotEmpty && !_busy,
                      child: const Text('Delete all downloads'),
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
      bottomNavigationBar: _selectMode
          ? _SelectionBottomBar(
              selectedCount: _selected.length,
              onMarkRead: () => _markSelectedRead(true),
              onMarkUnread: () => _markSelectedRead(false),
              onMarkPrevRead: _markPreviousAsRead,
              onSelectAll: () => _selectAllVisible(filteredChapters),
              onDownload: () => _downloadSelected(allChapters),
              onDelete: _deleteSelectedAndExit,
            )
          : null,
      body: allChapters.isEmpty && _busy
          ? const Center(child: CircularProgressIndicator())
          : allChapters.isEmpty
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _refreshChapters,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Chapters'),
                  ),
                )
              : Column(
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    // Mihon-style cover header
                    if (!_selectMode)
                      _NovelCoverHeader(
                        novel: widget.novel,
                        chapterCount: allChapters.length,
                        downloadedCount: downloadedCount,
                        readCount: progress?.completedChapters.length ?? 0,
                        progress: progress,
                        onResume: progress != null
                            ? () {
                                final idx = allChapters.indexWhere((c) => c.n == progress.chapterN);
                                if (idx >= 0) {
                                  _openChapter(allChapters[idx], startParagraph: progress.paragraphIndex);
                                }
                              }
                            : null,
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Row(
                        children: [
                          Text(
                            '${filteredChapters.length} chapters',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (downloadedCount > 0) ...[
                            const SizedBox(width: 8),
                            Text(
                              '\u00b7 $downloadedCount downloaded',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const Spacer(),
                          Text(
                            _selectMode ? 'Long-press to add more' : 'Long-press to select',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: filteredChapters.isEmpty
                          ? Center(
                              child: Text(
                                'No chapters match filters',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            )
                          : _chaptersGrid
                              ? GridView.builder(
                                  padding: const EdgeInsets.all(16),
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: _gridColumns,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 1.8,
                                  ),
                                  itemCount: filteredChapters.length,
                                  itemBuilder: (context, i) {
                                    final c = filteredChapters[i];
                                    return _ChapterTile(
                                      novelId: widget.novel.id,
                                      chapter: c,
                                      downloaded: downloads.isDownloaded(widget.novel.id, c.n),
                                      selectMode: _selectMode,
                                      selected: _selected.contains(c.n),
                                      gridColumns: _gridColumns,
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
                                  itemCount: filteredChapters.length,
                                  itemBuilder: (context, i) {
                                    final c = filteredChapters[i];
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

// =============================================================================
// Selection bottom action bar
// =============================================================================
class _SelectionBottomBar extends StatelessWidget {
  const _SelectionBottomBar({
    required this.selectedCount,
    required this.onMarkRead,
    required this.onMarkUnread,
    required this.onMarkPrevRead,
    required this.onSelectAll,
    required this.onDownload,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onMarkRead;
  final VoidCallback onMarkUnread;
  final VoidCallback onMarkPrevRead;
  final VoidCallback onSelectAll;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final enabled = selectedCount > 0;
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _BarAction(
            icon: Icons.done_all,
            label: 'Select all',
            onTap: onSelectAll,
          ),
          _BarAction(
            icon: Icons.check,
            label: 'Read',
            onTap: enabled ? onMarkRead : null,
          ),
          _BarAction(
            icon: Icons.remove_done,
            label: 'Unread',
            onTap: enabled ? onMarkUnread : null,
          ),
          _BarAction(
            icon: Icons.arrow_upward,
            label: 'Prev read',
            onTap: enabled ? onMarkPrevRead : null,
          ),
          _BarAction(
            icon: Icons.download,
            label: 'Download',
            onTap: enabled ? onDownload : null,
          ),
          _BarAction(
            icon: Icons.delete_outline,
            label: 'Delete',
            onTap: enabled ? onDelete : null,
          ),
        ],
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = onTap == null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: disabled ? cs.onSurface.withValues(alpha: 0.38) : cs.onSurface),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: disabled ? cs.onSurface.withValues(alpha: 0.38) : cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Mihon-style cover header
// =============================================================================
class _NovelCoverHeader extends StatelessWidget {
  const _NovelCoverHeader({
    required this.novel,
    required this.chapterCount,
    required this.downloadedCount,
    required this.readCount,
    required this.progress,
    required this.onResume,
  });

  final StoredNovel novel;
  final int chapterCount;
  final int downloadedCount;
  final int readCount;
  final StoredReadingProgress? progress;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasCover = novel.coverUrl != null && novel.coverUrl!.isNotEmpty;

    return Stack(
      children: [
        // Blurred background cover
        if (hasCover)
          Positioned.fill(
            child: ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.5),
                  cs.surface,
                ],
                stops: const [0.0, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstOut,
              child: Image.network(
                novel.coverUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, e1, s1) => const SizedBox.shrink(),
              ),
            ),
          ),
        // Foreground content
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cover thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 100,
                      height: 140,
                      child: hasCover
                          ? Image.network(
                              novel.coverUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, e2, s2) => Container(
                                color: cs.surfaceContainerHighest,
                                child: Icon(Icons.book, size: 40, color: cs.onSurfaceVariant),
                              ),
                            )
                          : Container(
                              color: cs.surfaceContainerHighest,
                              child: Icon(Icons.book, size: 40, color: cs.onSurfaceVariant),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Title + metadata
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          novel.name,
                          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _extractSource(novel.novelUrl),
                          style: tt.bodySmall?.copyWith(color: cs.primary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          children: [
                            _InfoChip(icon: Icons.menu_book, label: '$chapterCount ch'),
                            if (downloadedCount > 0) _InfoChip(icon: Icons.download_done, label: '$downloadedCount saved'),
                            _InfoChip(icon: Icons.check_circle_outline, label: '$readCount read'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              // Resume row
              if (progress != null && onResume != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: Text('Resume \u2022 Chapter ${progress!.chapterN}'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _extractSource(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.replaceFirst('www.', '');
    } catch (_) {
      return url;
    }
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ],
    );
  }
}

// =============================================================================
// Filter / Sort / Display bottom sheet
// =============================================================================
class _FilterSortDisplaySheet extends StatefulWidget {
  const _FilterSortDisplaySheet({
    required this.downloadedFilter,
    required this.unreadFilter,
    required this.sortAscending,
    required this.chaptersGrid,
    required this.gridColumns,
    required this.onChanged,
  });

  final _TriState downloadedFilter;
  final _TriState unreadFilter;
  final bool sortAscending;
  final bool chaptersGrid;
  final int gridColumns;

  final void Function({
    _TriState? downloadedFilter,
    _TriState? unreadFilter,
    bool? sortAscending,
    bool? chaptersGrid,
    int? gridColumns,
  }) onChanged;

  @override
  State<_FilterSortDisplaySheet> createState() => _FilterSortDisplaySheetState();
}

class _FilterSortDisplaySheetState extends State<_FilterSortDisplaySheet> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  late _TriState _downloadedFilter;
  late _TriState _unreadFilter;
  late bool _sortAscending;
  late bool _chaptersGrid;
  late int _gridColumns;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _downloadedFilter = widget.downloadedFilter;
    _unreadFilter = widget.unreadFilter;
    _sortAscending = widget.sortAscending;
    _chaptersGrid = widget.chaptersGrid;
    _gridColumns = widget.gridColumns;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _notify({
    _TriState? downloadedFilter,
    _TriState? unreadFilter,
    bool? sortAscending,
    bool? chaptersGrid,
    int? gridColumns,
  }) {
    widget.onChanged(
      downloadedFilter: downloadedFilter,
      unreadFilter: unreadFilter,
      sortAscending: sortAscending,
      chaptersGrid: chaptersGrid,
      gridColumns: gridColumns,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Handle bar
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Filter'),
            Tab(text: 'Sort'),
            Tab(text: 'Display'),
          ],
        ),
        SizedBox(
          height: 200,
          child: TabBarView(
            controller: _tabController,
            children: [
              // ---- Filter tab ----
              ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _TriStateFilterTile(
                    label: 'Downloaded',
                    state: _downloadedFilter,
                    onTap: () {
                      final next = _nextTriState(_downloadedFilter);
                      setState(() => _downloadedFilter = next);
                      _notify(downloadedFilter: next);
                    },
                  ),
                  _TriStateFilterTile(
                    label: 'Unread',
                    state: _unreadFilter,
                    onTap: () {
                      final next = _nextTriState(_unreadFilter);
                      setState(() => _unreadFilter = next);
                      _notify(unreadFilter: next);
                    },
                  ),
                ],
              ),

              // ---- Sort tab ----
              ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  ListTile(
                    leading: Icon(
                      _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      color: cs.primary,
                    ),
                    title: const Text('By chapter number'),
                    subtitle: Text(_sortAscending ? 'Ascending' : 'Descending'),
                    onTap: () {
                      final next = !_sortAscending;
                      setState(() => _sortAscending = next);
                      _notify(sortAscending: next);
                    },
                  ),
                ],
              ),

              // ---- Display tab ----
              ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  SwitchListTile(
                    title: const Text('Grid view'),
                    secondary: Icon(_chaptersGrid ? Icons.grid_view : Icons.view_list),
                    value: _chaptersGrid,
                    onChanged: (v) {
                      setState(() => _chaptersGrid = v);
                      _notify(chaptersGrid: v);
                    },
                  ),
                  if (_chaptersGrid)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          const Text('Grid columns'),
                          const Spacer(),
                          for (final n in [2, 3, 4])
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: ChoiceChip(
                                label: Text('$n'),
                                selected: _gridColumns == n,
                                onSelected: (_) {
                                  setState(() => _gridColumns = n);
                                  _notify(gridColumns: n);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Tri-state checkbox tile for filter tab
class _TriStateFilterTile extends StatelessWidget {
  const _TriStateFilterTile({
    required this.label,
    required this.state,
    required this.onTap,
  });

  final String label;
  final _TriState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    switch (state) {
      case _TriState.off:
        icon = Icons.check_box_outline_blank;
        break;
      case _TriState.include:
        icon = Icons.check_box;
        break;
      case _TriState.exclude:
        icon = Icons.indeterminate_check_box;
        break;
    }
    return ListTile(
      leading: Icon(icon, color: state == _TriState.off ? null : Theme.of(context).colorScheme.primary),
      title: Text(label),
      subtitle: Text(_triStateLabel(state)),
      onTap: onTap,
    );
  }

  static String _triStateLabel(_TriState s) {
    switch (s) {
      case _TriState.off:
        return 'Off';
      case _TriState.include:
        return 'Include only';
      case _TriState.exclude:
        return 'Exclude';
    }
  }
}

// =============================================================================
// Chapter row (list mode)
// =============================================================================
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
      downloadIndicator = const Icon(Icons.download_done, size: 20);
    } else if (downloading) {
      downloadIndicator = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 3, value: progressValue),
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
          ? (downloaded ? const Icon(Icons.download_done, size: 20) : const SizedBox.shrink())
          : downloadIndicator,
    );
  }
}

// =============================================================================
// Chapter tile (grid mode)
// =============================================================================
class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.novelId,
    required this.chapter,
    required this.downloaded,
    required this.selectMode,
    required this.selected,
    required this.gridColumns,
    required this.onToggleSelect,
    required this.onOpen,
    required this.onLongPress,
  });

  final String novelId;
  final StoredChapter chapter;
  final bool downloaded;
  final bool selectMode;
  final bool selected;
  final int gridColumns;
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

    // Use compact label when columns >= 3 to ensure number is visible
    final label = gridColumns >= 3 ? '${chapter.n}' : 'Ch. ${chapter.n}';

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
                Checkbox(
                  value: selected,
                  onChanged: (_) => onToggleSelect(),
                  visualDensity: VisualDensity.compact,
                )
              else
                Icon(read ? Icons.check_circle : Icons.circle_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
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
