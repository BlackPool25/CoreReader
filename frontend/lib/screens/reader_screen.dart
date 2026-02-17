import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/reader_controller_factory.dart';
import '../services/reader_stream_controller.dart';
import '../services/local_defaults.dart';
import '../services/novel_index_resolver.dart';
import '../services/settings_store.dart';
import '../widgets/glass_container.dart';
import '../services/local_voice_list.dart';
import 'highlight_in_paragraph.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _novelController = TextEditingController(
    text: 'https://www.novelcool.com/novel/Shadow-Slave.html',
  );
  final _urlController = TextEditingController(
    text: 'https://www.novelcool.com/chapter/Shadow-Slave-Chapter-15/7332162/',
  );

  late ReaderStreamController _stream;
  StreamSubscription? _sub;

  bool _useLocalTts = false;

  final NovelIndexResolver _indexResolver = NovelIndexResolver();
  NovelIndex? _localIndex;

  List<String> _voices = const ['af_bella'];
  String _voice = 'af_bella';

  double _speed = 1.0;

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

  int? _chapterCount;
  int? _selectedChapterNum;

  static const int _chapterRangeSize = 50;
  int _chapterRangeStart = 1; // 1-indexed

  bool _busy = false;

  void _applyModeDefaults() {
    if (_useLocalTts) {
      // Local Kokoro runs from assets; voices will be loaded from assets/voices.json.
      _voices = const ['af_heart'];
      _voice = 'af_heart';
      return;
    }
    // Backend mode defaults; voices list will be refreshed from /voices.
    _voices = const ['af_bella'];
    _voice = 'af_bella';
  }

  void _showError(Object e) {
    final raw = e.toString();
    var msg = raw;
    if (raw.contains('Failed host lookup')) {
      msg = 'Network/DNS error while fetching NovelCool. Check your internet connection.';
    } else if (raw.contains('SocketException')) {
      msg = 'Network error. Check your internet connection.';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void initState() {
    super.initState();
    _useLocalTts = defaultUseLocalTts();
    _applyModeDefaults();
    _stream = createReaderController(useLocalTts: _useLocalTts);
    _sub = _stream.events.listen(_onEvent);
    unawaited(_loadUseLocalTtsAndMaybeSwitch());
    unawaited(_loadVoices());
    unawaited(_loadFontSize());
  }

  Future<void> refreshFromSettings() async {
    await _loadUseLocalTtsAndMaybeSwitch();
    await _loadVoices();
    await _loadFontSize();
  }

  Future<void> _loadUseLocalTtsAndMaybeSwitch() async {
    final v = await SettingsStore.getUseLocalTts();
    if (!mounted) return;

    final desired = createReaderController(useLocalTts: v);
    if (desired.runtimeType == _stream.runtimeType) {
      await desired.dispose();
      setState(() {
        _useLocalTts = v;
        _applyModeDefaults();
      });
      return;
    }

    await _sub?.cancel();
    await _stream.dispose();
    _stream = desired;
    _sub = _stream.events.listen(_onEvent);
    if (!mounted) return;
    setState(() {
      _useLocalTts = v;
      _applyModeDefaults();
    });
  }

  Future<void> _loadFontSize() async {
    final v = await SettingsStore.getReaderFontSize();
    if (!mounted) return;
    setState(() => _fontSize = v);
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = e['type'];
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

      // Find paragraph index before setState so we can update together.
      int idx = -1;
      if (s.isNotEmpty) {
        idx = _paragraphs.indexWhere((p) => p.contains(s));
      }

      setState(() {
        _sentence = s;
        if (idx >= 0) _currentParagraphIndex = idx;
      });

      // Auto-scroll to the paragraph that contains the current sentence.
      if (_sentence.isNotEmpty) {
        if (idx >= 0 && idx < _paraKeys.length) {
          final ctx = _paraKeys[idx].currentContext;
          if (ctx != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Scrollable.ensureVisible(
                ctx,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                alignment: 0.2,
              );
            });
          }
        }
      }
      return;
    }

    if (type == 'chapter_complete') {
      setState(() {
        _nextUrl = e['next_url'] as String?;
        _prevUrl = e['prev_url'] as String?;
        _busy = false;
      });
      return;
    }

    if (type == 'error') {
      setState(() => _busy = false);
      final msg = (e['message'] as String?) ?? 'Unknown error';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _loadVoices() async {
    if (_useLocalTts) {
      await _loadLocalVoices();
      return;
    }
    try {
      final base = await SettingsStore.getServerBaseUrl();
      final uri = SettingsStore.httpUri(base, '/voices');
      final res = await http.get(uri);
      if (res.statusCode != 200) return;
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['voices'] is List) {
        final voices = (decoded['voices'] as List).map((e) => e.toString()).toList();
        if (voices.isNotEmpty) {
          setState(() {
            _voices = voices;
            if (!_voices.contains(_voice)) _voice = _voices.first;
          });
        }
      }
    } catch (_) {
      // ignore; allow offline UI
    }
  }

  Future<void> _loadLocalVoices() async {
    try {
      final keys = await loadLocalVoiceIds();
      if (keys.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _voices = keys;
        if (!_voices.contains(_voice)) {
          _voice = _voices.first;
        }
      });
    } catch (e) {
      // If assets are missing, surface a clear message.
      _showError(e);
    }
  }

  Future<void> _playUrl(String url) async {
    setState(() => _busy = true);
    await _stream.primeAudio();
    await _stream.connectAndPlay(url: url, voice: _voice, speed: _speed);
  }

  Future<void> _playFromParagraph(int paragraphIndex) async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final idx = paragraphIndex
        .clamp(0, max(0, _paragraphs.length - 1))
        .toInt();
    setState(() {
      _busy = true;
      _currentParagraphIndex = idx;
    });
    await _stream.primeAudio();
    await _stream.connectAndPlay(
      url: url,
      voice: _voice,
      speed: _speed,
      startParagraph: idx,
    );
  }

  Future<void> _loadChapters() async {
    setState(() => _busy = true);
    try {
      if (_useLocalTts) {
        final novelUrl = _novelController.text.trim();
        final idx = await _indexResolver.load(novelUrl);
        if (idx.count <= 0) throw Exception('No chapters found');
        final firstUrl = idx.urlForChapterNum(1);
        if (firstUrl == null || firstUrl.isEmpty) throw Exception('Could not resolve chapter 1');
        setState(() {
          _localIndex = idx;
          _chapterCount = idx.count;
          _selectedChapterNum = 1;
          _chapterRangeStart = 1;
          _urlController.text = firstUrl;
          _busy = false;
        });
        return;
      }

      final base = await SettingsStore.getServerBaseUrl();
      final metaUri = SettingsStore.httpUri(base, '/novel_meta').replace(
        queryParameters: {'url': _novelController.text.trim()},
      );
      final metaRes = await http.get(metaUri);
      if (metaRes.statusCode != 200) throw Exception('Failed to load chapter count');
      final decoded = jsonDecode(metaRes.body);
      final count = (decoded is Map ? decoded['count'] : null);
      final chapterCount = (count as num?)?.toInt() ?? 0;
      if (chapterCount <= 0) throw Exception('No chapters found');

      setState(() {
        _chapterCount = chapterCount;
        _selectedChapterNum = 1;
        _chapterRangeStart = 1;
        _busy = false;
      });

      // Resolve chapter #1 to a concrete URL.
      await _selectChapterNum(1);
    } catch (e) {
      setState(() => _busy = false);
      _showError(e);
    }
  }

  Future<void> _selectChapterNum(int n) async {
    setState(() {
      _busy = true;
      _selectedChapterNum = n;
    });
    try {
      if (_useLocalTts) {
        final novelUrl = _novelController.text.trim();
        final idx = _localIndex ?? await _indexResolver.load(novelUrl);
        final url = idx.urlForChapterNum(n);
        if (url == null || url.isEmpty) throw Exception('Could not resolve chapter $n');
        setState(() {
          _localIndex = idx;
          _urlController.text = url;
          _busy = false;
        });
        return;
      }

      final base = await SettingsStore.getServerBaseUrl();
      final uri = SettingsStore.httpUri(base, '/novel_chapter').replace(
        queryParameters: {
          'url': _novelController.text.trim(),
          'n': n.toString(),
        },
      );
      final res = await http.get(uri);
      if (res.statusCode != 200) throw Exception('Failed to resolve chapter URL');
      final decoded = jsonDecode(res.body);
      final url = (decoded is Map ? decoded['url'] : null)?.toString() ?? '';
      if (url.isEmpty) throw Exception('Backend returned empty chapter URL');
      setState(() {
        _urlController.text = url;
        _busy = false;
      });
    } catch (e) {
      setState(() => _busy = false);
      _showError(e);
    }
  }

  int _rangeEnd(int start) {
    final count = _chapterCount ?? start;
    return min(start + _chapterRangeSize - 1, count);
  }

  List<DropdownMenuEntry<int>> _rangeEntries() {
    final count = _chapterCount;
    if (count == null || count <= 0) return const [];
    final ranges = ((count - 1) ~/ _chapterRangeSize) + 1;
    return List.generate(
      ranges,
      (i) {
        final start = i * _chapterRangeSize + 1;
        final end = _rangeEnd(start);
        return DropdownMenuEntry(value: start, label: '$start-$end');
      },
      growable: false,
    );
  }

  List<DropdownMenuEntry<int>> _chapterEntriesForCurrentRange() {
    final count = _chapterCount;
    if (count == null || count <= 0) return const [];
    final start = _chapterRangeStart;
    final end = _rangeEnd(start);
    return List.generate(
      end - start + 1,
      (i) {
        final n = start + i;
        return DropdownMenuEntry(value: n, label: 'Chapter $n');
      },
      growable: false,
    );
  }

  Future<void> _playCurrent() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await _playUrl(url);
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
    _novelController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canNext = _nextUrl != null && _nextUrl!.isNotEmpty;
    final canPrev = _prevUrl != null && _prevUrl!.isNotEmpty;
    final canPrevPara = _paragraphs.isNotEmpty && _currentParagraphIndex > 0;
    final canNextPara = _paragraphs.isNotEmpty && _currentParagraphIndex >= 0 && _currentParagraphIndex < _paragraphs.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? 'CoreReader'),
        actions: [
          IconButton(
            tooltip: 'Reload voices',
            onPressed: _loadVoices,
            icon: const Icon(Icons.record_voice_over),
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
                    const Text('Novel', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _novelController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'https://www.novelcool.com/novel/...',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _loadChapters,
                        icon: const Icon(Icons.list),
                        label: const Text('Load chapters'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        SizedBox(
                          width: 130,
                          child: DropdownMenu<int>(
                            label: const Text('Range'),
                            requestFocusOnTap: true,
                            enableFilter: false,
                            menuHeight: 320,
                            initialSelection: _chapterRangeStart,
                            dropdownMenuEntries: _rangeEntries(),
                            onSelected: (start) {
                              if (start == null) return;
                              setState(() => _chapterRangeStart = start);

                              // Keep selection within range.
                              final selected = _selectedChapterNum;
                              final end = _rangeEnd(start);
                              if (selected == null || selected < start || selected > end) {
                                unawaited(_selectChapterNum(start));
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownMenu<int>(
                            label: const Text('Chapter #'),
                            requestFocusOnTap: true,
                            enableFilter: true,
                            menuHeight: 360,
                            initialSelection: _selectedChapterNum,
                            dropdownMenuEntries: _chapterEntriesForCurrentRange(),
                            onSelected: (c) {
                              if (c == null) return;
                              unawaited(_selectChapterNum(c));
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _voice,
                            items: _voices
                                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                                .toList(growable: false),
                            onChanged: (v) => setState(() => _voice = v ?? _voice),
                            decoration: const InputDecoration(
                              labelText: 'Voice',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _busy ? null : _playCurrent,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Speed: ${_speed.toStringAsFixed(2)}x'),
                    Slider(
                      value: _speed,
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      label: '${_speed.toStringAsFixed(2)}x',
                      onChanged: (v) => setState(() => _speed = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              GlassContainer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title ?? 'No chapter loaded',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
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
                          onTap: () => unawaited(_playFromParagraph(i)),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_busy || (_stream.connected && !_stream.paused))
                          LinearProgressIndicator(
                            value: null,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(999),
                          )
                        else
                          SizedBox(
                            height: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('${_speed.toStringAsFixed(2)}x', style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(width: 12),
                            Text(
                              _stream.paused ? 'Paused' : (_stream.connected ? 'Live' : 'Idle'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _stream.connected ? _pauseOrResume : (_busy ? null : _playCurrent),
                    iconSize: 30,
                    icon: Icon(
                      _stream.connected && !_stream.paused ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Prev paragraph',
                    onPressed: canPrevPara ? () => unawaited(_playFromParagraph(_currentParagraphIndex - 1)) : null,
                    icon: const Icon(Icons.keyboard_double_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Next paragraph',
                    onPressed: canNextPara ? () => unawaited(_playFromParagraph(_currentParagraphIndex + 1)) : null,
                    icon: const Icon(Icons.keyboard_double_arrow_down),
                  ),
                  IconButton(
                    tooltip: 'Prev',
                    onPressed: canPrev ? () => _playUrl(_prevUrl!) : null,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: canNext ? () => _playUrl(_nextUrl!) : null,
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
