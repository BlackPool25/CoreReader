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
import '../widgets/downloads_scope.dart';
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
  static const int _ttsPrefetchSentences = 5;

  late ReaderStreamController _stream;
  StreamSubscription? _sub;

  List<String> _voices = const ['af_bella'];
  String? _sessionVoice;

  /// TTS render speed: the tempo Kokoro generates audio at. Sent to the
  /// backend as the `speed` field. Changing this requires re-synthesis
  /// (restarts the WebSocket stream for live chapters).
  double? _sessionTtsSpeed;

  /// Reader playback multiplier: applied to SoLoud via setRelativePlaySpeed.
  /// Instant fast-forward — no re-synthesis, no stream restart.
  /// Works identically for both live-streamed and downloaded chapters.
  double _playbackMultiplier = 1.0;

  String? _title;
  String? _chapterUrl;
  String? _nextUrl;
  String? _prevUrl;
  String _sentence = '';
  int? _sentenceCharStart;
  int? _sentenceCharEnd;
  List<String> _paragraphs = const [];
  int _currentParagraphIndex = -1;

  bool _playingOffline = false;
  /// Baked TTS speed of the currently playing downloaded chapter (read-only display).
  double? _offlineBakedTtsSpeed;
  int _sentenceToken = 0;

  bool _showNowReading = false;
  bool _autoScroll = true;

  double _fontSize = 16.0;

  final _scrollController = ScrollController();
  List<GlobalKey> _paraKeys = const [];

  bool _busy = false;

  bool _didInit = false;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;

    final settings = AppSettingsScope.of(context);
    _fontSize = settings.fontSize;
    _sessionVoice = settings.defaultVoice;
    _sessionTtsSpeed = settings.defaultSpeed;
    _playbackMultiplier = settings.defaultPlaybackMultiplier;
    _showNowReading = settings.showNowReading;
    _autoScroll = settings.readerAutoScroll;

    unawaited(_loadVoices());

    if (!kIsWeb) {
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
        _sentenceCharStart = null;
        _sentenceCharEnd = null;
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
      final cs = (e['char_start'] as num?)?.toInt();
      final ce = (e['char_end'] as num?)?.toInt();

      final token = ++_sentenceToken;
      // Highlights are scheduled by the stream controller based on the exact
      // SoLoud consumed-sample position. No additional delay is applied here.
      Future<void>.delayed(Duration.zero, () {
        if (!mounted) return;
        if (token != _sentenceToken) return;
        setState(() {
          _sentence = s;
          _sentenceCharStart = cs;
          _sentenceCharEnd = ce;
          if (pIdx != null) _currentParagraphIndex = pIdx;
        });
        if (_autoScroll && _currentParagraphIndex >= 0 && _currentParagraphIndex < _paraKeys.length) {
          final key = _paraKeys[_currentParagraphIndex];
          final ctx = key.currentContext;
          if (ctx != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              Scrollable.ensureVisible(
                ctx,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                alignment: 0.25,
              );
            });
          }
        }
      });

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
        _playingOffline = false;
        _offlineBakedTtsSpeed = null;
      });

      final library = LibraryScope.of(context);
      final cache = library.cacheFor(widget.novel.id);
      final next = cache?.chapters.firstWhere(
        (c) => c.n == _chapter.n + 1,
        orElse: () => StoredChapter(n: 0, title: '', url: ''),
      );
      unawaited(
        library.completeChapterAndAdvance(
          novelId: widget.novel.id,
          completedChapterN: _chapter.n,
          nextChapterN: (next != null && next.n > 0) ? next.n : null,
        ),
      );
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

  /// TTS render speed sent to Kokoro (baked into the synthesised PCM).
  double get _effectiveTtsSpeed => (_sessionTtsSpeed ?? AppSettingsScope.of(context).defaultSpeed);

  Future<void> _playChapter(StoredChapter chapter, {int startParagraph = 0}) async {
    setState(() {
      _busy = true;
      _chapter = chapter;
      _currentParagraphIndex = max(0, startParagraph);
    });

    final settings = AppSettingsScope.of(context);
    final downloads = DownloadsScope.of(context);
    final treeUri = settings.downloadsTreeUri;
    final downloaded = downloads.downloadedChapter(widget.novel.id, chapter.n);
    if (downloaded != null && treeUri != null && treeUri.trim().isNotEmpty) {
      // Offline playback.
      _playingOffline = true;
      final meta = await downloads.loadMeta(treeUri: treeUri, chapter: downloaded);
      if (meta == null) {
        _playingOffline = false;
        throw Exception('Downloaded metadata missing');
      }
      // Expose the baked TTS speed so the session sheet can show it read-only.
      setState(() => _offlineBakedTtsSpeed = meta.ttsSpeed);
      await _stream.primeAudio(sampleRate: meta.sampleRate);
      await _stream.playDownloaded(
        treeUri: treeUri,
        pcmPath: downloaded.pcmPath,
        metaJson: meta.toJson(),
        // Pass current playback multiplier (fast-forward rate).
        // The TTS render speed is already baked; playback multiplier is applied
        // by the stream controller via setRelativePlaySpeed.
        playbackSpeed: _playbackMultiplier,
        startParagraph: max(0, startParagraph),
      );
      setState(() => _busy = false);
      unawaited(_manageAutoDownloads());
      return;
    }

    // Streaming playback.
    _playingOffline = false;
    _offlineBakedTtsSpeed = null;
    await _stream.primeAudio();
    await _stream.connectAndPlay(
      url: chapter.url,
      voice: _effectiveVoice,
      // Send TTS render speed to Kokoro via the backend.
      speed: _effectiveTtsSpeed,
      prefetch: _ttsPrefetchSentences,
      startParagraph: max(0, startParagraph),
    );
    // Apply the playback multiplier to the live stream immediately after start.
    if ((_playbackMultiplier - 1.0).abs() > 0.001) {
      await _stream.setPlaybackSpeed(_playbackMultiplier);
    }

    unawaited(_manageAutoDownloads());
  }

  Future<void> _manageAutoDownloads() async {
    if (!mounted) return;
    final settings = AppSettingsScope.of(context);
    final tree = settings.downloadsTreeUri;
    if (tree == null || tree.trim().isEmpty) return;

    final library = LibraryScope.of(context);
    final cache = library.cacheFor(widget.novel.id);
    final chapters = cache?.chapters ?? const <StoredChapter>[];
    if (chapters.isEmpty) return;

    final downloads = DownloadsScope.of(context);
    final ahead = settings.downloadsPrefetchAhead;
    final behind = settings.downloadsKeepBehind;
    final voice = _effectiveVoice;
    // Use session TTS render speed for auto-downloads so the downloaded PCM
    // matches what the user is currently hearing for live chapters.
    final ttsSpeed = _effectiveTtsSpeed;

    for (var i = 1; i <= ahead; i++) {
      final n = _chapter.n + i;
      final next = chapters.firstWhere(
        (c) => c.n == n,
        orElse: () => StoredChapter(n: 0, title: '', url: ''),
      );
      if (next.n <= 0) continue;
      if (downloads.isDownloaded(widget.novel.id, next.n)) continue;
      unawaited(
        () async {
          try {
            await downloads.enqueueDownloadChapter(
              treeUri: tree,
              novelId: widget.novel.id,
              chapterN: next.n,
              chapterUrl: next.url,
              voice: voice,
              speed: ttsSpeed,
              source: 'auto',
            );
          } catch (_) {}
        }(),
      );
    }

    final minKeep = _chapter.n - behind;
    if (minKeep <= 1) return;
    final toDelete = downloads
        .chaptersForNovel(widget.novel.id)
        .where((c) => c.chapterN < minKeep)
        .where((c) => c.source == 'auto')
        .where((c) => !downloads.isDownloading(widget.novel.id, c.chapterN))
        .toList(growable: false);
    for (final c in toDelete) {
      unawaited(downloads.deleteDownloadedChapter(treeUri: tree, novelId: widget.novel.id, chapterN: c.chapterN).catchError((_) {}));
    }
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
                    ttsSpeed: _effectiveTtsSpeed,
                    playbackMultiplier: _playbackMultiplier,
                    fontSize: _fontSize,
                    showNowReading: _showNowReading,
                    autoScroll: _autoScroll,
                    // Offline chapters have a baked TTS speed; the slider is read-only.
                    offlineBakedTtsSpeed: _offlineBakedTtsSpeed,
                  );
                },
              );
              if (result == null) return;

              final ttsSpeedChanged = (result.ttsSpeed - _effectiveTtsSpeed).abs() > 0.001;
              final voiceChanged = result.voice != _effectiveVoice;
              final multiplierChanged = (result.playbackMultiplier - _playbackMultiplier).abs() > 0.001;

              setState(() {
                _sessionVoice = result.voice;
                _sessionTtsSpeed = result.ttsSpeed;
                _playbackMultiplier = result.playbackMultiplier;
                _showNowReading = result.showNowReading;
                _autoScroll = result.autoScroll;
              });

              if (_stream.active) {
                if (_playingOffline) {
                  // TTS speed is baked; only apply the playback multiplier change.
                  if (multiplierChanged) {
                    await _stream.setPlaybackSpeed(_playbackMultiplier);
                  }
                } else {
                  if (ttsSpeedChanged || voiceChanged) {
                    // Re-synthesis needed: restart from current paragraph.
                    await _restartFromCurrentParagraph();
                  } else if (multiplierChanged) {
                    // Just update SoLoud speed — no restart, no gap.
                    await _stream.setPlaybackSpeed(_playbackMultiplier);
                  }
                }
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
                    if (_showNowReading) ...[
                      const SizedBox(height: 14),
                      Text(
                        _sentence.isEmpty ? 'Press Play to start reading.' : _sentence,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: _fontSize + 4),
                        textAlign: TextAlign.center,
                      ),
                    ],
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
                          child: HighlightInParagraph(
                            paragraph: p,
                            highlight: (i == _currentParagraphIndex) ? _sentence : '',
                            highlightStart: (i == _currentParagraphIndex) ? _sentenceCharStart : null,
                            highlightEnd: (i == _currentParagraphIndex) ? _sentenceCharEnd : null,
                            fontSize: _fontSize,
                          ),
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
                    onPressed: _stream.active
                        ? _pauseOrResume
                        : (_busy ? null : () => unawaited(_playChapter(_chapter, startParagraph: widget.startParagraph))),
                    iconSize: 30,
                    icon: Icon(
                      _stream.active && !_stream.paused ? Icons.pause : Icons.play_arrow,
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

// ---------------------------------------------------------------------------
// Session settings data class
// ---------------------------------------------------------------------------

class _SessionSettings {
  _SessionSettings({
    required this.voice,
    required this.ttsSpeed,
    required this.playbackMultiplier,
    required this.showNowReading,
    required this.autoScroll,
  });

  final String voice;

  /// TTS render speed — sent to Kokoro (baked into PCM).
  final double ttsSpeed;

  /// Playback multiplier — applied to SoLoud (instant fast-forward).
  final double playbackMultiplier;

  final bool showNowReading;
  final bool autoScroll;
}

// ---------------------------------------------------------------------------
// Session settings sheet
// ---------------------------------------------------------------------------

class _SessionSettingsSheet extends StatefulWidget {
  const _SessionSettingsSheet({
    required this.voices,
    required this.voice,
    required this.ttsSpeed,
    required this.playbackMultiplier,
    required this.fontSize,
    required this.showNowReading,
    required this.autoScroll,
    this.offlineBakedTtsSpeed,
  });

  final List<String> voices;
  final String voice;
  final double ttsSpeed;
  final double playbackMultiplier;
  final double fontSize;
  final bool showNowReading;
  final bool autoScroll;

  /// If non-null, the chapter is a downloaded offline chapter and the TTS
  /// speed is baked into its PCM. The TTS speed slider is shown read-only.
  final double? offlineBakedTtsSpeed;

  @override
  State<_SessionSettingsSheet> createState() => _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends State<_SessionSettingsSheet> {
  late String _voice;
  late double _ttsSpeed;
  late double _playbackMultiplier;
  late bool _showNowReading;
  late bool _autoScroll;

  @override
  void initState() {
    super.initState();
    _voice = widget.voice;
    _ttsSpeed = widget.ttsSpeed;
    _playbackMultiplier = widget.playbackMultiplier;
    _showNowReading = widget.showNowReading;
    _autoScroll = widget.autoScroll;
  }

  bool get _isOffline => widget.offlineBakedTtsSpeed != null;

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
            onChanged: _isOffline ? null : (v) => setState(() => _voice = v ?? _voice),
            decoration: InputDecoration(
              labelText: _isOffline ? 'Voice (baked into download)' : 'Voice (this session)',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          // ---- Playback Speed (instant fast-forward) ----
          Row(
            children: [
              const Icon(Icons.fast_forward, size: 18),
              const SizedBox(width: 6),
              Text('Playback Speed: ${_playbackMultiplier.toStringAsFixed(2)}×',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          Slider(
            value: _playbackMultiplier,
            min: 0.5,
            max: 3.0,
            divisions: 50,
            label: '${_playbackMultiplier.toStringAsFixed(2)}×',
            onChanged: (v) => setState(() => _playbackMultiplier = v),
          ),
          Text(
            'Instantly fast-forwards audio — like YouTube speed. Works for downloaded chapters too.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),

          // ---- TTS Render Speed (Kokoro baked speed) ----
          Row(
            children: [
              const Icon(Icons.record_voice_over, size: 18),
              const SizedBox(width: 6),
              Text(
                _isOffline
                    ? 'TTS Render Speed: ${widget.offlineBakedTtsSpeed!.toStringAsFixed(2)}× (baked)'
                    : 'TTS Render Speed: ${_ttsSpeed.toStringAsFixed(2)}×',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          if (_isOffline)
            Text(
              'This chapter was downloaded at ${widget.offlineBakedTtsSpeed!.toStringAsFixed(2)}×. '
              'Re-download at a different speed to change TTS tempo.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            )
          else ...[
            Slider(
              value: _ttsSpeed,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              label: '${_ttsSpeed.toStringAsFixed(2)}×',
              onChanged: (v) => setState(() => _ttsSpeed = v),
            ),
            Text(
              'Controls Kokoro TTS render tempo. Changing this will re-synthesise from the current paragraph.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _autoScroll,
            title: const Text('Auto-scroll'),
            onChanged: (v) => setState(() => _autoScroll = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showNowReading,
            title: const Text('Show "Now reading" box'),
            onChanged: (v) => setState(() => _showNowReading = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  _SessionSettings(
                    voice: _voice,
                    ttsSpeed: _isOffline ? widget.offlineBakedTtsSpeed! : _ttsSpeed,
                    playbackMultiplier: _playbackMultiplier,
                    showNowReading: _showNowReading,
                    autoScroll: _autoScroll,
                  ),
                ),
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
