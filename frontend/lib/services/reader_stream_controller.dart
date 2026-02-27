abstract class ReaderStreamController {
  Stream<Map<String, dynamic>> get events;

  /// True when the WebSocket is connected to the backend for live streaming.
  bool get connected;

  /// True when audio is actively playing or paused — covers both live
  /// streaming (connected == true) and offline downloaded-chapter playback.
  bool get active;

  bool get paused;

  /// The paragraph index of the last sentence that was actually emitted as a
  /// highlight (i.e. the sentence the user heard). Returns -1 if nothing
  /// has been highlighted yet.
  int get lastHeardParagraphIndex;

  Future<void> primeAudio({int sampleRate = 24000});

  Future<void> connectAndPlay({
    required String url,
    required String voice,
    required double speed,
    int prefetch = 3,
    int startParagraph = 0,
  });

  /// Play a locally downloaded chapter (PCM16 mono) and emit the same event
  /// types as the backend stream (`chapter_info`, `sentence`, `chapter_complete`).
  Future<void> playDownloaded({
    required String treeUri,
    required List<String> pcmPath,
    required Map<String, dynamic> metaJson,
    required double playbackSpeed,
    int startParagraph,
  });

  /// Adjust playback speed for the current audio handle (offline chapters use this).
  Future<void> setPlaybackSpeed(double speed);

  /// Returns true if audio data for the given [url] starting at [startParagraph]
  /// is available in the in-memory cache and can be replayed without hitting
  /// the backend.
  bool hasCachedAudio(String url, int startParagraph);

  /// Replay audio from the in-memory cache for [url] starting at [startParagraph].
  /// Returns false if the cache doesn't have sufficient data.
  Future<bool> replayFromCache({
    required String url,
    required int startParagraph,
  });

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}
