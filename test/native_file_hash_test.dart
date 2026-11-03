import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/native_file_hash.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('native-file-hash-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'sends the path to the worker without opening the file in Dart',
    () async {
      final digest = sha256.convert([1, 2, 3]).toString();
      final path = '${directory.path}/native-only.file';
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final arguments = call.arguments as Map;
        expect(jsonDecode(arguments['request_json'] as String), {
          'operation': 'hash_file',
          'path': path,
        });
        expect(arguments.containsKey('bytes'), isFalse);
        return {'sha256': digest};
      });
      expect(await hashFileSha256(path), digest);
      expect(await File(path).exists(), isFalse);
    },
  );

  test('unsupported hosts stream empty and multichunk files', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw MissingPluginException();
    });
    for (final bytes in [
      <int>[],
      List<int>.generate(1024 * 1024 + 7, (index) => index % 256),
    ]) {
      final file = await File('${directory.path}/input').writeAsBytes(bytes);
      expect(await hashFileSha256(file.path), sha256.convert(bytes).toString());
    }
    await expectLater(
      hashFileSha256('${directory.path}/missing'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('native failure or cancellation never falls back to Dart', () async {
    final file = await File('${directory.path}/input').writeAsString('valid');
    for (final code in ['ERROR', 'CANCELLED', 'backend_unavailable']) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code, message: 'Cannot hash file');
      });
      await expectLater(
        hashFileSha256(file.path),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
      );
    }
  });

  test(
    'malformed native digests fail closed even when a file exists',
    () async {
      final file = await File('${directory.path}/input').writeAsString('valid');
      for (final value in [null, 1, '', 'abcdef', 'A' * 64, '0' * 65]) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'sha256': value},
        );
        await expectLater(
          hashFileSha256(file.path),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
}
