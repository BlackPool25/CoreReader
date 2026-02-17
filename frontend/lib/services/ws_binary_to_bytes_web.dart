// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

Future<Uint8List?> wsBinaryToBytes(dynamic event) async {
  if (event is Uint8List) return event;
  if (event is List<int>) return Uint8List.fromList(event);
  if (event is ByteBuffer) return Uint8List.view(event);
  if (event is html.Blob) {
    final completer = Completer<Uint8List?>();
    final reader = html.FileReader();
    reader.onError.listen((_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result is ByteBuffer) {
        completer.complete(Uint8List.view(result));
      } else if (result is Uint8List) {
        completer.complete(result);
      } else {
        completer.complete(null);
      }
    });
    reader.readAsArrayBuffer(event);
    return completer.future;
  }
  return null;
}
