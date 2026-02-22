class DownloadedChapter {
  DownloadedChapter({
    required this.novelId,
    required this.chapterN,
    required this.title,
    required this.chapterUrl,
    required this.createdAtMs,
    required this.sampleRate,
    required this.voice,
    required this.ttsSpeed,
    required this.source,
    required this.pcmPath,
    required this.metaPath,
  });

  final String novelId;
  final int chapterN;
  final String title;
  final String chapterUrl;
  final int createdAtMs;

  final int sampleRate;
  final String voice;
  final double ttsSpeed;

  /// Where this download came from.
  /// - manual: user-triggered
  /// - auto: queued by auto-download
  final String source;

  /// Storage-relative path segments under the configured downloads root.
  /// Example: ["LN-TTS", novelId, "chapters", "12", "audio.pcm"]
  final List<String> pcmPath;

  /// Example: ["LN-TTS", novelId, "chapters", "12", "meta.json"]
  final List<String> metaPath;

  Map<String, dynamic> toJson() => {
        'novelId': novelId,
        'chapterN': chapterN,
        'title': title,
        'chapterUrl': chapterUrl,
        'createdAtMs': createdAtMs,
        'sampleRate': sampleRate,
        'voice': voice,
        'ttsSpeed': ttsSpeed,
        'source': source,
        'pcmPath': pcmPath,
        'metaPath': metaPath,
      };

  static DownloadedChapter fromJson(Map<String, dynamic> json) {
    final pcm = (json['pcmPath'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    final meta = (json['metaPath'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    return DownloadedChapter(
      novelId: (json['novelId'] as String?) ?? '',
      chapterN: (json['chapterN'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      chapterUrl: (json['chapterUrl'] as String?) ?? '',
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 24000,
      voice: (json['voice'] as String?) ?? '',
      ttsSpeed: (json['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
      source: (json['source'] as String?) ?? 'manual',
      pcmPath: pcm,
      metaPath: meta,
    );
  }
}

class ChapterTimelineItem {
  ChapterTimelineItem({
    required this.ms,
    required this.text,
    required this.paragraphIndex,
    required this.sentenceIndex,
    this.charStart,
    this.charEnd,
  });

  final int ms;
  final String text;
  final int paragraphIndex;
  final int sentenceIndex;
  final int? charStart;
  final int? charEnd;

  Map<String, dynamic> toJson() => {
        'ms': ms,
        'text': text,
        'p': paragraphIndex,
        's': sentenceIndex,
      if (charStart != null) 'cs': charStart,
      if (charEnd != null) 'ce': charEnd,
      };

  static ChapterTimelineItem fromJson(Map<String, dynamic> json) {
    return ChapterTimelineItem(
      ms: (json['ms'] as num?)?.toInt() ?? 0,
      text: (json['text'] as String?) ?? '',
      paragraphIndex: (json['p'] as num?)?.toInt() ?? 0,
      sentenceIndex: (json['s'] as num?)?.toInt() ?? 0,
      charStart: (json['cs'] as num?)?.toInt(),
      charEnd: (json['ce'] as num?)?.toInt(),
    );
  }
}

class DownloadedChapterMeta {
  DownloadedChapterMeta({
    required this.title,
    required this.url,
    required this.sampleRate,
    required this.voice,
    required this.ttsSpeed,
    required this.complete,
    required this.source,
    required this.paragraphs,
    required this.timeline,
  });

  final String title;
  final String url;
  final int sampleRate;
  final String voice;
  final double ttsSpeed;
  final bool complete;
  final String source;
  final List<String> paragraphs;
  final List<ChapterTimelineItem> timeline;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'title': title,
        'url': url,
        'sampleRate': sampleRate,
        'voice': voice,
        'ttsSpeed': ttsSpeed,
      'complete': complete,
      'source': source,
        'paragraphs': paragraphs,
        'timeline': timeline.map((e) => e.toJson()).toList(growable: false),
      };

  static DownloadedChapterMeta fromJson(Map<String, dynamic> json) {
    final paras = (json['paragraphs'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    final rawTimeline = json['timeline'];
    final timeline = <ChapterTimelineItem>[];
    if (rawTimeline is List) {
      for (final item in rawTimeline) {
        if (item is Map<String, dynamic>) {
          timeline.add(ChapterTimelineItem.fromJson(item));
        } else if (item is Map) {
          timeline.add(ChapterTimelineItem.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    return DownloadedChapterMeta(
      title: (json['title'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 24000,
      voice: (json['voice'] as String?) ?? '',
      ttsSpeed: (json['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
      complete: (json['complete'] as bool?) ?? true,
      source: (json['source'] as String?) ?? 'manual',
      paragraphs: paras,
      timeline: timeline,
    );
  }
}
