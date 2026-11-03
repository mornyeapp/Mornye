import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lyrics_ai_client.dart';

Map<String, dynamic> _line(
  int id,
  String text, {
  String? romanization,
  List<Map<String, Object>> alignment = const [],
  List<Map<String, Object>> romanizationAlignment = const [],
}) => {
  'id': id,
  'text': text,
  'romanization': romanization,
  'alignment': alignment,
  'romanizationAlignment': romanizationAlignment,
};

List<Map<String, dynamic>> _dto(Map<int, LyricsAiLine> lines) => [
  for (final entry in lines.entries)
    _line(
      entry.key,
      entry.value.text,
      romanization: entry.value.romanization,
      alignment: entry.value.alignment.map((chunk) => chunk.toJson()).toList(),
      romanizationAlignment: entry.value.romanizationAlignment
          .map((chunk) => chunk.toJson())
          .toList(),
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final fixtures =
      (jsonDecode(
                File(
                  'test/fixtures/native_lyrics_translation_replies.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  for (final fixture in fixtures) {
    test('shared parser contract: ${fixture['name']}', () async {
      final request = fixture['request'] as Map;
      final reply = request['reply'] as String;
      final ids = (request['ids'] as List).cast<int>().toSet();
      final expected = fixture['expected'] as Map;
      if (expected['error'] != null) {
        final matcher = throwsA(
          isA<LyricsAiException>().having(
            (error) => error.kind,
            'kind',
            LyricsAiErrorKind.badResponse,
          ),
        );
        expect(() => parseLyricsTranslationReply(reply, ids), matcher);
        await expectLater(
          parseLyricsTranslationReplyInBackground(reply, ids),
          matcher,
        );
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => jsonEncode(expected),
        );
        await expectLater(
          parseLyricsTranslationReplyInBackground(reply, ids),
          matcher,
        );
      } else {
        expect(
          _dto(parseLyricsTranslationReply(reply, ids)),
          expected['lines'],
        );
        expect(
          _dto(await parseLyricsTranslationReplyInBackground(reply, ids)),
          expected['lines'],
        );
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => jsonEncode(expected),
        );
        expect(
          _dto(await parseLyricsTranslationReplyInBackground(reply, ids)),
          expected['lines'],
        );
      }
    });
  }

  test(
    'translation client sends only reply bytes and requested ids to Rust',
    () async {
      const reply = 'provider output parsed only by the native worker';
      final expected = [
        _line(
          7,
          'Hello world',
          romanization: 'konnichiwa',
          alignment: [
            {'text': 'Hello ', 'source': 0},
            {'text': 'world', 'source': 1},
          ],
          romanizationAlignment: [
            {'text': 'konnichiwa', 'source': 0},
          ],
        ),
      ];
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final args = call.arguments as Map;
        expect(jsonDecode(args['request_json'] as String), {
          'operation': 'parse_lyrics_translation_reply',
          'ids': [7, 9],
        });
        expect(args['bytes'] as Uint8List, utf8.encode(reply));
        nativeCalls++;
        return jsonEncode({'lines': expected});
      });
      final client = LyricsAiClient(
        const LyricsAiConfig(
          provider: LyricsAiProvider.custom,
          model: 'test-model',
          apiKey: 'never-forward-this-key',
          baseUrl: 'https://translator.example/v1',
        ),
        client: MockClient((_) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': reply},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final actual = await client.translate(const [
        LyricsAiItem(7, 'original line'),
        LyricsAiItem(9, 'missing translation'),
      ], systemPrompt: 'private preference');
      expect(_dto(actual), expected);
      expect(nativeCalls, 1);
      expect(() => actual[7]!.alignment.clear(), throwsUnsupportedError);
    },
  );

  test(
    'missing native plugin preserves compatibility parsing and alignment',
    () async {
      const reply = '''<think>omit these notes</think>
```json
{"lines":[{"id":"7","text":" Hello world ","romanization":" hi ","alignment":[[0,"Hello "],[1,"world"]],"romanizationAlignment":[[0,"hi"]]},
{"id":7,"text":"duplicate"},{"id":9,"text":" "},{"id":99,"text":"unknown"}]}
```''';
      final expected = parseLyricsTranslationReply(reply, {7, 9});
      expect(
        _dto(await parseLyricsTranslationReplyInBackground(reply, {7, 9})),
        _dto(expected),
      );
    },
  );

  test('native parse rejection maps to the existing typed error', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return jsonEncode({
        'error': 'badResponse',
        'detail': 'reply is not a JSON list',
      });
    });
    await expectLater(
      parseLyricsTranslationReplyInBackground('[{"id":7,"text":"valid"}]', {7}),
      throwsA(
        isA<LyricsAiException>()
            .having(
              (error) => error.kind,
              'kind',
              LyricsAiErrorKind.badResponse,
            )
            .having(
              (error) => error.detail,
              'detail',
              'reply is not a JSON list',
            ),
      ),
    );
  });

  test(
    'native system failures propagate instead of rerunning Dart parsing',
    () async {
      final failure = PlatformException(
        code: 'CANCELLED',
        message: 'cancelled',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => throw failure);
      await expectLater(
        parseLyricsTranslationReplyInBackground('[{"id":7,"text":"valid"}]', {
          7,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'CANCELLED',
          ),
        ),
      );
    },
  );

  for (final malformed in [
    <String, Object>{},
    {'lines': 'invalid'},
    {
      'lines': [false],
    },
    {
      'lines': [_line(99, 'unexpected id')],
    },
    {
      'lines': [_line(7, 'one'), _line(7, 'duplicate')],
    },
    {
      'lines': [
        {..._line(7, 'text'), 'alignment': false},
      ],
    },
    {
      'lines': [
        {..._line(7, 'text'), 'romanization': 1},
      ],
    },
  ]) {
    test(
      'malformed native DTO remains a typed response error: $malformed',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => jsonEncode(malformed),
        );
        await expectLater(
          parseLyricsTranslationReplyInBackground('reply', {7}),
          throwsA(
            isA<LyricsAiException>().having(
              (error) => error.kind,
              'kind',
              LyricsAiErrorKind.badResponse,
            ),
          ),
        );
      },
    );
  }
}
