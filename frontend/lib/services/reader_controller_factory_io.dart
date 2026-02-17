import 'dart:io' show Platform;

import 'local_novel_stream_controller.dart';
import 'novel_stream_controller.dart';
import 'reader_stream_controller.dart';

ReaderStreamController createReaderControllerImpl({required bool useLocalTts}) {
  if (useLocalTts && Platform.isAndroid) {
    return LocalNovelStreamController();
  }
  return NovelStreamController();
}
