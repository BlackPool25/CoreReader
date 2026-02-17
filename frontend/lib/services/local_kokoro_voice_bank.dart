import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class LocalKokoroVoiceBank {
  static const String voicesUrl =
      'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin';

  File? _voicesFile;
  List<String>? _voiceIds;
  final Map<String, _NpyFloat32> _voiceCache = {};

  Future<File> _ensureVoicesFile() async {
    if (_voicesFile != null && await _voicesFile!.exists()) return _voicesFile!;

    final dir = await getApplicationSupportDirectory();
    final kokoroDir = Directory('${dir.path}/kokoro');
    if (!await kokoroDir.exists()) {
      await kokoroDir.create(recursive: true);
    }
    final voicesFile = File('${kokoroDir.path}/voices-v1.0.bin');
    if (!await voicesFile.exists() || (await voicesFile.length()) < 1_000_000) {
      final req = http.Request('GET', Uri.parse(voicesUrl));
      final client = http.Client();
      try {
        final res = await client.send(req);
        if (res.statusCode != 200) {
          throw Exception('Download failed (${res.statusCode}) for $voicesUrl');
        }
        final sink = voicesFile.openWrite();
        try {
          await res.stream.pipe(sink);
        } finally {
          await sink.flush();
          await sink.close();
        }
      } finally {
        client.close();
      }
    }

    _voicesFile = voicesFile;
    return voicesFile;
  }

  Future<List<String>> listVoiceIds() async {
    if (_voiceIds != null) return _voiceIds!;
    final f = await _ensureVoicesFile();
    final bytes = await f.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final ids = <String>[];
    for (final file in archive.files) {
      final name = file.name;
      if (!name.endsWith('.npy')) continue;
      final id = name.substring(0, name.length - 4);
      if (id.isNotEmpty) ids.add(id);
    }
    ids.sort();
    _voiceIds = List.unmodifiable(ids);
    return _voiceIds!;
  }

  Future<Float32List> styleVectorForTokens({
    required String voiceId,
    required int tokenLength,
  }) async {
    final npy = await _loadVoiceNpy(voiceId);

    // voices-v1.0.bin arrays are (510, 1, 256)
    final safeIndex = tokenLength.clamp(0, npy.shape0 - 1);
    final base = safeIndex * npy.shape1 * npy.shape2;
    final offset = (base + 0 * npy.shape2);
    return npy.float32View(offset, npy.shape2);
  }

  Future<_NpyFloat32> _loadVoiceNpy(String voiceId) async {
    final cached = _voiceCache[voiceId];
    if (cached != null) return cached;

    final f = await _ensureVoicesFile();
    final bytes = await f.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final targetName = '$voiceId.npy';
    final entry = archive.files.firstWhere(
      (e) => e.name == targetName,
      orElse: () => throw Exception('Voice $voiceId not found in voices file'),
    );
    final contentBytes = entry.content;
    final npy = _NpyFloat32.fromBytes(contentBytes);
    _voiceCache[voiceId] = npy;
    return npy;
  }
}

class _NpyFloat32 {
  _NpyFloat32({
    required this.raw,
    required this.dataOffsetBytes,
    required this.shape0,
    required this.shape1,
    required this.shape2,
  });

  final Uint8List raw;
  final int dataOffsetBytes;
  final int shape0;
  final int shape1;
  final int shape2;

  static _NpyFloat32 fromBytes(Uint8List bytes) {
    // https://numpy.org/devdocs/reference/generated/numpy.lib.format.html
    const magic = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]; // \x93NUMPY
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw Exception('Invalid NPY magic header');
      }
    }
    final major = bytes[6];
    final minor = bytes[7];
    int headerLen;
    int headerStart;
    if (major == 1) {
      headerLen = bytes[8] | (bytes[9] << 8);
      headerStart = 10;
    } else if (major == 2) {
      headerLen = bytes[8] | (bytes[9] << 8) | (bytes[10] << 16) | (bytes[11] << 24);
      headerStart = 12;
    } else {
      throw Exception('Unsupported NPY version $major.$minor');
    }
    final headerBytes = bytes.sublist(headerStart, headerStart + headerLen);
    final header = String.fromCharCodes(headerBytes).trim();

    final descr = RegExp(r"'descr'\s*:\s*'([^']+)'")
      .firstMatch(header)
      ?.group(1);
    if (descr == null || descr != '<f4') {
      throw Exception('Unsupported dtype in NPY: $descr');
    }
    final shapeMatch = RegExp(r"'shape'\s*:\s*\(([^\)]*)\)").firstMatch(header);
    if (shapeMatch == null) {
      throw Exception('Missing shape in NPY header');
    }
    final dims = shapeMatch.group(1)!
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(int.parse)
        .toList(growable: false);
    if (dims.length != 3) {
      throw Exception('Expected 3D voice tensor, got shape $dims');
    }
    final dataOffset = headerStart + headerLen;
    return _NpyFloat32(
      raw: bytes,
      dataOffsetBytes: dataOffset,
      shape0: dims[0],
      shape1: dims[1],
      shape2: dims[2],
    );
  }

  Float32List float32View(int floatIndex, int length) {
    final byteOffset = dataOffsetBytes + floatIndex * 4;
    return Float32List.view(raw.buffer, raw.offsetInBytes + byteOffset, length);
  }
}
