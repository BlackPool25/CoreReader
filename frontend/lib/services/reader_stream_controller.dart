abstract class ReaderStreamController {
  Stream<Map<String, dynamic>> get events;

  bool get connected;
  bool get paused;

  Future<void> primeAudio({int sampleRate = 24000});

  Future<void> connectAndPlay({
    required String url,
    required String voice,
    required double speed,
    int prefetch = 3,
    int startParagraph = 0,
  });

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}
