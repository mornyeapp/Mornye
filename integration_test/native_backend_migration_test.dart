import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/native_file_hash.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('translation reply reaches the real native worker', (
    tester,
  ) async {
    const reply =
        '<think>reasoning</think>```json\n'
        '{"lines":[{"id":1,"text":"Hello world",'
        '"alignment":[[0,"Hello "],[1,"world"]],'
        '"romanization":"Konnichiwa"},'
        '{"id":2,"text":"Second","alignment":[[512,"Second"]]}]}\n```';
    // Prove this installed binary has the new operation before testing the
    // application adapter, which supports hosts without a native plugin.
    final native = await PlatformBridge.runNativeDataJob({
      'operation': 'parse_lyrics_translation_reply',
      'ids': [1, 2],
    }, bytes: utf8.encode(reply));
    expect(native['lines'], hasLength(2));
    final parsed = await parseLyricsTranslationReplyInBackground(reply, {1, 2});
    expect(parsed[1]!.text, 'Hello world');
    expect(parsed[1]!.romanization, 'Konnichiwa');
    expect(parsed[1]!.alignment.map((chunk) => chunk.source), [0, 1]);
    expect(parsed[2]!.text, 'Second');
    expect(parsed[2]!.alignment, isEmpty);
    await expectLater(
      parseLyricsTranslationReplyInBackground('invalid response', {1}),
      throwsA(isA<LyricsAiException>()),
    );
  });

  testWidgets('file hashing reaches the native worker', (tester) async {
    final root = await (await getTemporaryDirectory()).createTemp(
      'native-hash-',
    );
    try {
      final bytes = List<int>.generate(200000, (index) => index % 251);
      final file = await File('${root.path}/input.bin').writeAsBytes(bytes);
      final native = await PlatformBridge.runNativeDataJob({
        'operation': 'hash_file',
        'path': file.path,
      });
      expect(native['sha256'], sha256.convert(bytes).toString());
      expect(await hashFileSha256(file.path), native['sha256']);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
