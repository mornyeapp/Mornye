import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/native_file_hash.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

Map<String, Object?> _lines(Map<int, LyricsAiLine> lines) => {
  for (final entry in lines.entries)
    '${entry.key}': {
      'text': entry.value.text,
      'romanization': entry.value.romanization,
      'alignment': entry.value.alignment
          .map((chunk) => chunk.toJson())
          .toList(),
      'romanizationAlignment': entry.value.romanizationAlignment
          .map((chunk) => chunk.toJson())
          .toList(),
    },
};

/// Run against a freshly built desktop library with MORNYE_DESKTOP_LIB set.
/// Unlike mock channel tests, these cases cross the actual Dart C ABI worker.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled =
      Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
      false;

  group('actual Rust backend migration', () {
    late Directory root;

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('mornye-migration-ffi-');
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: FfiBackendTransport.open,
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: root.path,
          documentsDir: root.path,
          tempDir: root.path,
        ),
      );
    });

    tearDownAll(() async {
      RustFfiBackend.debugShared = null;
      debugDesktopPlatformOverride = null;
      await root.delete(recursive: true);
    });

    test('translation reply matches Dart compatibility semantics', () async {
      final replies = <String>[
        '[{"id":1,"text":"First"},{"id":2,"translation":"Second"}]',
        '<think>discard reasoning</think>\n```json\n'
            '{"lines":[{"id":1,"text":"  Hello  "}]}\n```',
        'Here is the result: [{"id":1,"text":"Hello"}] Done.',
        '{"z":[{"id":1,"text":"First list"}],'
            '"a":[{"id":1,"text":"Wrong list"}]}',
        '{"lines":null,"translations":[{"id":1,"text":"Fallback"}]}',
        '[{"id":"0x1","text":"Hex"},{"id":2.9,"text":"Fraction"},'
            '{"id":"3","text":"Third"},{"id":3,"text":"Duplicate"},'
            '{"id":999,"text":"Unknown"},{"id":1,"text":"Later"}]',
        '[{"id":1,"text":"   "},{"id":1,"text":"Usable"}]',
        jsonEncode({
          'lines': [
            {
              'id': 1,
              'text': 'Hello world',
              'alignment': [
                [0, 'Hello '],
                [1, 'world'],
              ],
              'romanization': 'Konnichiwa',
              'romanizationAlignment': [
                {'source': 0, 'text': 'Konnichiwa'},
              ],
            },
            {
              'id': 2,
              'text': 'Still usable',
              'alignment': [
                [0, 'Does not match'],
              ],
            },
          ],
        }),
        jsonEncode([
          {
            'id': 1,
            'text': '😀' * 2001,
            'alignment': [
              [0, '😀' * 2001],
            ],
          },
          {'id': 2, 'text': '\uFEFF hello \uFEFF'},
        ]),
        '[]',
      ];
      for (final reply in replies) {
        // This direct call makes a missing/stale native job fail instead of
        // allowing the compatibility parser to make the test pass.
        final native = await PlatformBridge.runNativeDataJob({
          'operation': 'parse_lyrics_translation_reply',
          'ids': [1, 2, 3],
        }, bytes: utf8.encode(reply));
        expect(native['lines'], isA<List<dynamic>>(), reason: reply);
        final expected = parseLyricsTranslationReply(reply, {1, 2, 3});
        final actual = await parseLyricsTranslationReplyInBackground(reply, {
          1,
          2,
          3,
        });
        expect(_lines(actual), _lines(expected), reason: reply);
        expect(actual.keys.toList(), expected.keys.toList(), reason: reply);
      }
    });

    test('invalid reply remains a typed error', () async {
      for (final reply in ['not JSON', '{}', 'null', '{"lines":false}']) {
        await expectLater(
          parseLyricsTranslationReplyInBackground(reply, {1}),
          throwsA(
            isA<LyricsAiException>().having(
              (error) => error.kind,
              'kind',
              LyricsAiErrorKind.badResponse,
            ),
          ),
        );
      }
    });

    test('native file hashes preserve streamed digest', () async {
      final bytes = List<int>.generate(200000, (index) => index % 251);
      final file = await File('${root.path}/hash.bin').writeAsBytes(bytes);
      final native = await PlatformBridge.runNativeDataJob({
        'operation': 'hash_file',
        'path': file.path,
      });
      expect(native['sha256'], sha256.convert(bytes).toString());
      expect(await hashFileSha256(file.path), native['sha256']);
    });
  }, skip: !enabled);
}
