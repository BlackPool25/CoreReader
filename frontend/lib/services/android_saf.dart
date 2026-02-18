import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidSaf {
  static const MethodChannel _channel = MethodChannel('ln_tts/saf');

  static bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<String?> pickDownloadsFolderTreeUri() async {
    if (!isSupported) return null;
    final uri = await _channel.invokeMethod<String>('pickTree');
    return uri;
  }

  static Future<void> persistTreePermission(String treeUri) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('persistPermission', {'treeUri': treeUri});
  }

  static Future<bool> exists({required String treeUri, required List<String> pathSegments}) async {
    if (!isSupported) return false;
    final ok = await _channel.invokeMethod<bool>('exists', {
      'treeUri': treeUri,
      'path': pathSegments,
    });
    return ok ?? false;
  }

  static Future<void> delete({required String treeUri, required List<String> pathSegments}) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('delete', {
      'treeUri': treeUri,
      'path': pathSegments,
    });
  }

  static Future<int> openWrite({
    required String treeUri,
    required List<String> pathSegments,
    required String mimeType,
    required bool append,
  }) async {
    if (!isSupported) return -1;
    final handle = await _channel.invokeMethod<int>('openWrite', {
      'treeUri': treeUri,
      'path': pathSegments,
      'mimeType': mimeType,
      'append': append,
    });
    return handle ?? -1;
  }

  static Future<void> write(int handle, Uint8List bytes) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('write', {
      'handle': handle,
      'bytes': bytes,
    });
  }

  static Future<void> closeWrite(int handle) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('closeWrite', {'handle': handle});
  }

  static Future<int> openRead({required String treeUri, required List<String> pathSegments}) async {
    if (!isSupported) return -1;
    final handle = await _channel.invokeMethod<int>('openRead', {
      'treeUri': treeUri,
      'path': pathSegments,
    });
    return handle ?? -1;
  }

  static Future<Uint8List?> read(int handle, {required int maxBytes}) async {
    if (!isSupported) return null;
    final bytes = await _channel.invokeMethod<Uint8List>('read', {
      'handle': handle,
      'maxBytes': maxBytes,
    });
    return bytes;
  }

  static Future<void> closeRead(int handle) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('closeRead', {'handle': handle});
  }

  static Future<List<String>> listChildren({required String treeUri, required List<String> pathSegments}) async {
    if (!isSupported) return const [];
    final items = await _channel.invokeMethod<List<dynamic>>('listChildren', {
      'treeUri': treeUri,
      'path': pathSegments,
    });
    if (items == null) return const [];
    return items.map((e) => e.toString()).toList(growable: false);
  }
}
