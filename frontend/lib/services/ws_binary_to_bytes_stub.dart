import 'dart:typed_data';

/// Converts a WebSocket binary message into bytes.
///
/// Non-web platforms typically deliver `Uint8List` or `List<int>`.
Future<Uint8List?> wsBinaryToBytes(dynamic event) async {
  if (event is Uint8List) return event;
  if (event is List<int>) return Uint8List.fromList(event);
  if (event is ByteBuffer) return Uint8List.view(event);
  return null;
}
