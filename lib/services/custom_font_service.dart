import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Copies imported fonts into app storage; never persists a picker/container path.
class CustomFontService {
  CustomFontService({
    Future<Directory> Function()? directory,
    Future<void> Function(String, Uint8List)? loadFont,
  }) : _directory = directory ?? _fontDirectory,
       _loadFont = loadFont ?? _register;

  static const maxBytes = 10 * 1024 * 1024;
  static final instance = CustomFontService();
  final Future<Directory> Function() _directory;
  final Future<void> Function(String, Uint8List) _loadFont;
  final Map<String, Future<String>> _loads = {};
  static final _idPattern = RegExp(r'^[a-f0-9]{64}$');

  static Future<Directory> _fontDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/custom_fonts',
  ).create(recursive: true);

  static Future<void> _register(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  static void validate(Uint8List bytes) {
    if (bytes.length < 12 || bytes.length > maxBytes) {
      throw const FormatException('Invalid font size');
    }
    final data = ByteData.sublistView(bytes);
    final signature = data.getUint32(0);
    if (signature != 0x00010000 && signature != 0x4f54544f) {
      throw const FormatException('Expected a TTF or OTF font');
    }
    final count = data.getUint16(4);
    if (count == 0 || 12 + count * 16 > bytes.length) {
      throw const FormatException('Invalid font table directory');
    }
    for (var i = 0; i < count; i++) {
      final table = 12 + i * 16;
      final offset = data.getUint32(table + 8);
      final length = data.getUint32(table + 12);
      if (offset > bytes.length || length > bytes.length - offset) {
        throw const FormatException('Truncated font table');
      }
    }
  }

  static String _validatedId(Uint8List bytes) {
    validate(bytes);
    return sha256.convert(bytes).toString();
  }

  // Hashing a large font would block the UI isolate (at launch, for restore).
  static Future<String> _idOf(Uint8List bytes) =>
      Isolate.run(() => _validatedId(bytes));

  static Future<Uint8List?> _readStored(String path, String id) =>
      Isolate.run(() async {
        final file = File(path);
        if (await file.length() > maxBytes) return null;
        final bytes = await file.readAsBytes();
        return _validatedId(bytes) == id ? bytes : null;
      });

  Future<String> import(Uint8List bytes) async {
    final id = await _idOf(bytes);
    await _load(id, bytes);
    final directory = await _directory();
    final destination = File('${directory.path}/$id.font');
    if (!await destination.exists()) {
      final staged = await File(
        '${directory.path}/$id.tmp',
      ).writeAsBytes(bytes, flush: true);
      await staged.rename(destination.path);
    }
    return id;
  }

  Future<String> _load(String id, Uint8List bytes) =>
      _loads.putIfAbsent(id, () async {
        final family = 'ImportedFont_$id';
        try {
          await _loadFont(family, bytes);
          return family;
        } catch (_) {
          _loads.remove(id);
          rethrow;
        }
      });

  Future<String?> restore(String id) async {
    if (!_idPattern.hasMatch(id)) return null;
    try {
      final bytes = await _readStored(
        '${(await _directory()).path}/$id.font',
        id,
      );
      if (bytes == null) return null;
      return await _load(id, bytes);
    } catch (_) {
      // Missing fonts after restoring preferences fall back to the theme font.
      return null;
    }
  }
}
