import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/platform_bridge.dart';

final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

Future<String> _hashFileInBackground(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

/// Streams a file through the native worker without loading it into Dart.
/// Unsupported hosts retain a streaming isolate implementation.
Future<String> hashFileSha256(String path) async {
  try {
    final result = await PlatformBridge.runNativeDataJob({
      'operation': 'hash_file',
      'path': path,
    });
    final digest = result['sha256'];
    if (digest is! String || !_sha256Pattern.hasMatch(digest)) {
      throw const FormatException('Invalid native file digest');
    }
    return digest;
  } on MissingPluginException {
    return compute(_hashFileInBackground, path);
  }
}
