import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/reader_controller_factory.dart';
import '../services/reader_stream_controller.dart';
import '../services/local_store.dart';
import '../services/settings_store.dart';
import '../widgets/glass_container.dart';
import '../widgets/app_settings_scope.dart';
import '../widgets/library_scope.dart';
import 'highlight_in_paragraph.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.novel,
    required this.chapter,
    this.startParagraph = 0,
  });

  final StoredNovel novel;
  final StoredChapter chapter;
  final int startParagraph;

  @override
  State<ReaderScreen> createState() => ReaderScreenState();
}

class ReaderScreenState extends State<ReaderScreen> {
  static const int _ttsPrefetchSentences = 8;

  late ReaderStreamController _stream;
  StreamSubscription? _sub;

  List<String> _voices = const ['af_bella'];
  String? _sessionVoice;
  double? _sessionSpeed;

  String? _title;
  String? _chapterUrl;
  String? _nextUrl;
  String? _prevUrl;
  String _sentence = '';
  List<String> _paragraphs = const [];
  int _currentParagraphIndex = -1;

  double _fontSize = 16.0;

  final _scrollController = ScrollController();
  List<GlobalKey> _paraKeys = const [];

  bool _busy = false;

  late StoredChapter _chapter;

  void _showError(Object e) {
    final raw = e.toString();
    var msg = raw;
    if (raw.contains('Failed host lookup')) {
      msg = 'Network/DNS error while fetching NovelCool. Check your internet connection.';
    } else if (raw.contains('SocketException')) {
      msg = 'Network error. Check your internet connection.';
    } else if (raw.contains('Connection refused') || raw.contains('timed out')) {
      msg = 'Could not reach backend. Check Settings → Server URL (use ws://<PC_LAN_IP>:8000).';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void initState() {
    super.initState();
    _chapter = widget.chapter;
    _stream = createReaderController();
    _sub = _stream.events.listen(_onEvent);
    unawaited(_loadVoices());

    final settings = AppSettingsScope.of(context);
    _fontSize = settings.fontSize;
    _sessionVoice = settings.defaultVoice;
    _sessionSpeed = settings.defaultSpeed;

    if (!kIsWeb) {
      // Auto-start on mobile/desktop. Web often requires a user gesture.
      unawaited(_playChapter(_chapter, startParagraph: widget.startParagraph));
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = e['type'];
    if (type == 'voices') {
      final list = (e['voices'] as List?)?.map((x) => x.toString()).toList() ?? const <String>[];
      if (list.isNotEmpty) {
        setState(() {
          _voices = list;
          final desired = _sessionVoice;
          if (desired == null || !_voices.contains(desired)) {
            _sessionVoice = _voices.first;
          }
        });
      }
      return;
    }
    if (type == 'chapter_info') {
      final paras = (e['paragraphs'] as List?)?.map((x) => x.toString()).toList() ?? const <String>[];
      setState(() {
        _title = e['title'] as String?;
        _chapterUrl = e['url'] as String?;
        _nextUrl = e['next_url'] as String?;
        _prevUrl = e['prev_url'] as String?;
        _sentence = '';
        _paragraphs = paras;
        _paraKeys = List.generate(paras.length, (_) => GlobalKey());
        _currentParagraphIndex = -1;
        _busy = false;
      });
      return;
    }

    if (type == 'sentence') {
      final s = (e['text'] as String?) ?? '';

      final pIdx = (e['paragraph_index'] as num?)?.toInt();

      setState(() {
        _sentence = s;
        if (pIdx != null) _currentParagraphIndex = pIdx;
      });

      // Persist progress (paragraph-level resume is sufficient).
      final library = LibraryScope.of(context);
      unawaited(
        library.setProgress(
          (library.progressFor(widget.novel.id) ?? StoredReadingProgress(
            novelId: widget.novel.id,
            chapterN: _chapter.n,
            paragraphIndex: max(0, _currentParagraphIndex),
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            completedChapters: <int>{},
          )).copyWith(
            chapterN: _chapter.n,
            paragraphIndex: max(0, _currentParagraphIndex),
          ),
        ),
      );
      return;
    }

    if (type == 'chapter_complete') {
      setState(() {
        _nextUrl = e['next_url'] as String?;
        _prevUrl = e['prev_url'] as String?;
        _busy = false;
      });

      final library = LibraryScope.of(context);
      unawaited(library.markRead(widget.novel.id, _chapter.n, read: true));

      // Auto-advance progress to next chapter (if present) for "Continue".
      final cache = library.cacheFor(widget.novel.id);
      final next = cache?.chapters.firstWhere(
        (c) => c.n == _chapter.n + 1,
        orElse: () => StoredChapter(n: 0, title: '', url: ''),
      );
      if (next != null && next.n > 0) {
        unawaited(
          library.setProgress(
            StoredReadingProgress(
              novelId: widget.novel.id,
              chapterN: next.n,
              paragraphIndex: 0,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
              completedChapters: (library.progressFor(widget.novel.id)?.completedChapters ?? <int>{}).toSet(),
            ),
          ),
        );
      }
      return;
    }

    if (type == 'error') {
      setState(() => _busy = false);
      final msg = (e['message'] as String?) ?? 'Unknown error';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _loadVoices() async {
    try {
      final base = AppSettingsScope.of(context).serverBaseUrl;
      final uri = SettingsStore.httpUri(base, '/voices');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw Exception('Backend /voices failed (${res.statusCode})');
      }
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['voices'] is List) {
        final voices = (decoded['voices'] as List).map((e) => e.toString()).toList();
        if (voices.isNotEmpty) {
          setState(() {
            _voices = voices;
            if (_sessionVoice == null || !_voices.contains(_sessionVoice)) {
              _sessionVoice = _voices.first;
            }
          });
        }
      }
    } catch (e) {
      _showError(e);
    }
  }

  String get _effectiveVoice => _sessionVoice ?? (_voices.isNotEmpty ? _voices.first : 'af_bella');
  double get _effectiveSpeed => (_sessionSpeed ?? AppSettingsScope.of(context).defaultSpeed);

  Future<void> _playChapter(StoredChapter chapter, {int startParagraph = 0}) async {
    setState(() {
      _busy = true;
      _chapter = chapter;
      _currentParagraphIndex = max(0, startParagraph);
    });
    await _stream.primeAudio();
    await _stream.connectAndPlay(
      url: chapter.url,
      voice: _effectiveVoice,
      speed: _effectiveSpeed,
      prefetch: _ttsPrefetchSentences,
      startParagraph: max(0, startParagraph),
    );
  }

  Future<void> _restartFromCurrentParagraph() async {
    final idx = _currentParagraphIndex < 0 ? 0 : _currentParagraphIndex;
    await _playChapter(_chapter, startParagraph: idx);
  }

  Future<void> _pauseOrResume() async {
    if (_stream.paused) {
      await _stream.resume();
      setState(() {});
    } else {
      await _stream.pause();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _stream.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final cache = library.cacheFor(widget.novel.id);
    final chapters = cache?.chapters ?? const <StoredChapter>[];
    final curIdx = chapters.indexWhere((c) => c.n == _chapter.n);
    final prevChapter = (curIdx > 0) ? chapters[curIdx - 1] : null;
    final nextChapter = (curIdx >= 0 && curIdx < chapters.length - 1) ? chapters[curIdx + 1] : null;

    final canNext = nextChapter != null || (_nextUrl != null && _nextUrl!.isNotEmpty);
    final canPrev = prevChapter != null || (_prevUrl != null && _prevUrl!.isNotEmpty);
    final canPrevPara = _paragraphs.isNotEmpty && _currentParagraphIndex > 0;
    final canNextPara = _paragraphs.isNotEmpty && _currentParagraphIndex >= 0 && _currentParagraphIndex < _paragraphs.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? 'Chapter ${_chapter.n}'),
        actions: [
          IconButton(
            tooltip: 'Reload voices',
            onPressed: _loadVoices,
            icon: const Icon(Icons.record_voice_over),
          ),
          IconButton(
            tooltip: 'Session voice/speed',
            onPressed: () async {
              final result = await showModalBottomSheet<_SessionSettings>(
                context: context,
                showDragHandle: true,
                builder: (context) {
                  return _SessionSettingsSheet(
                    voices: _voices,
                    voice: _effectiveVoice,
                    speed: _effectiveSpeed,
                    fontSize: _fontSize,
                  );
                },
              );
              if (result == null) return;
              setState(() {
                _sessionVoice = result.voice;
                _sessionSpeed = result.speed;
              });
              if (_stream.connected) {
                await _restartFromCurrentParagraph();
              }
            },
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
            children: [
              GlassContainer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.novel.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text('Chapter ${_chapter.n}', style: Theme.of(context).textTheme.bodySmall),
                    if (_chapterUrl != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _chapterUrl!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      _sentence.isEmpty ? 'Press Play to start reading.' : _sentence,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: _fontSize + 4),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (_paragraphs.isNotEmpty)
                GlassContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: List.generate(_paragraphs.length, (i) {
                      final p = _paragraphs[i];
                      final key = _paraKeys[i];
                      return Padding(
                        key: key,
                        padding: const EdgeInsets.only(bottom: 14),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => unawaited(_playChapter(_chapter, startParagraph: i)),
                          child: HighlightInParagraph(paragraph: p, highlight: _sentence, fontSize: _fontSize),
                        ),
                      );
                    }),
                  ),
                ),
            ],
          ),

          // Bottom glass player.
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: GlassContainer(
              borderRadius: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _stream.connected
                        ? _pauseOrResume
                        : (_busy ? null : () => unawaited(_playChapter(_chapter, startParagraph: widget.startParagraph))),
                    iconSize: 30,
                    icon: Icon(
                      _stream.connected && !_stream.paused ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Prev paragraph',
                    onPressed: canPrevPara ? () => unawaited(_playChapter(_chapter, startParagraph: _currentParagraphIndex - 1)) : null,
                    icon: const Icon(Icons.keyboard_double_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Next paragraph',
                    onPressed: canNextPara ? () => unawaited(_playChapter(_chapter, startParagraph: _currentParagraphIndex + 1)) : null,
                    icon: const Icon(Icons.keyboard_double_arrow_down),
                  ),
                  IconButton(
                    tooltip: 'Prev',
                    onPressed: canPrev
                        ? () {
                            if (prevChapter != null) {
                              unawaited(_playChapter(prevChapter));
                              return;
                            }
                            final u = _prevUrl;
                            if (u != null && u.isNotEmpty) {
                              // Fallback: unknown chapter number; try mapping by url.
                              final mapped = chapters.firstWhere(
                                (c) => c.url == u,
                                orElse: () => StoredChapter(n: 0, title: '', url: ''),
                              );
                              if (mapped.n > 0) {
                                unawaited(_playChapter(mapped));
                              } else {
                                unawaited(_playChapter(StoredChapter(n: _chapter.n, title: '', url: u)));
                              }
                            }
                          }
                        : null,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: canNext
                        ? () {
                            if (nextChapter != null) {
                              unawaited(_playChapter(nextChapter));
                              return;
                            }
                            final u = _nextUrl;
                            if (u != null && u.isNotEmpty) {
                              final mapped = chapters.firstWhere(
                                (c) => c.url == u,
                                orElse: () => StoredChapter(n: 0, title: '', url: ''),
                              );
                              if (mapped.n > 0) {
                                unawaited(_playChapter(mapped));
                              } else {
                                unawaited(_playChapter(StoredChapter(n: _chapter.n, title: '', url: u)));
                              }
                            }
                          }
                        : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ),
          ),

          if (_busy)
            const Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Color(0x22000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionSettings {
  _SessionSettings({required this.voice, required this.speed});

  final String voice;
  final double speed;
}

class _SessionSettingsSheet extends StatefulWidget {
  const _SessionSettingsSheet({
    required this.voices,
    required this.voice,
    required this.speed,
    required this.fontSize,
  });

  final List<String> voices;
  final String voice;
  final double speed;
  final double fontSize;

  @override
  State<_SessionSettingsSheet> createState() => _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends State<_SessionSettingsSheet> {
  late String _voice;
  late double _speed;

  @override
  void initState() {
    super.initState();
    _voice = widget.voice;
    _speed = widget.speed;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Session settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _voice,
            items: widget.voices
                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                .toList(growable: false),
            onChanged: (v) => setState(() => _voice = v ?? _voice),
            decoration: const InputDecoration(
              labelText: 'Voice (this session)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text('Speed: ${_speed.toStringAsFixed(2)}x'),
          Slider(
            value: _speed,
            min: 0.7,
            max: 1.4,
            divisions: 28,
            label: '${_speed.toStringAsFixed(2)}x',
            onChanged: (v) => setState(() => _speed = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_SessionSettings(voice: _voice, speed: _speed)),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

extension on StoredReadingProgress {
  StoredReadingProgress copyWith({
    int? chapterN,
    int? paragraphIndex,
    Set<int>? completedChapters,
  }) {
    return StoredReadingProgress(
      novelId: novelId,
      chapterN: chapterN ?? this.chapterN,
      paragraphIndex: paragraphIndex ?? this.paragraphIndex,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      completedChapters: completedChapters ?? this.completedChapters,
    );
  }
}
