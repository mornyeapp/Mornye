import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';

const _items = [LyricsAiItem(0, 'First line'), LyricsAiItem(1, 'Second line')];

LyricsAiConfig _config(
  LyricsAiProvider provider, {
  String model = 'model-a',
  String apiKey = 'secret-key',
  String baseUrl = '',
}) => LyricsAiConfig(
  provider: provider,
  model: model,
  apiKey: apiKey,
  baseUrl: baseUrl,
);

String _openAiReply(String content, {String finish = 'stop'}) => jsonEncode({
  'choices': [
    {
      'message': {'role': 'assistant', 'content': content},
      'finish_reason': finish,
    },
  ],
});

void main() {
  group('request building', () {
    test(
      'all providers keep song context separate from requested line ids',
      () {
        const context = [
          'Before this line',
          'Requested line',
          'After this line',
        ];
        const items = [
          LyricsAiItem(1, 'Requested line', words: ['Requested', 'line']),
        ];
        for (final provider in LyricsAiProvider.values) {
          final request = buildLyricsTranslationRequest(
            _config(provider, baseUrl: 'https://example.test/v1'),
            items,
            systemPrompt: 'system',
            context: context,
          );
          final String sourceContext;
          final String requested;
          if (provider == LyricsAiProvider.gemini) {
            final parts =
                ((request.body['contents'] as List).single as Map)['parts']
                    as List;
            sourceContext = (parts.first as Map)['text'] as String;
            requested = (parts.last as Map)['text'] as String;
          } else {
            final messages = request.body['messages'] as List;
            final users = messages.cast<Map<Object?, Object?>>().where(
              (message) => message['role'] == 'user',
            );
            sourceContext = users.first['content'] as String;
            requested = users.last['content'] as String;
          }
          expect(
            sourceContext,
            contains(jsonEncode(context)),
            reason: provider.name,
          );
          expect(jsonDecode(requested), [
            items.single.toJson(),
          ], reason: provider.name);
        }
      },
    );

    test('OpenAI classic models send temperature and JSON mode', () {
      final request = buildLyricsTranslationRequest(
        _config(LyricsAiProvider.openAi, model: 'gpt-4.1-mini'),
        _items,
        systemPrompt: 'system',
      );
      expect(
        request.uri.toString(),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(request.headers['Authorization'], 'Bearer secret-key');
      expect(request.body['temperature'], 0.2);
      expect(request.body['max_tokens'], isA<int>());
      expect(request.body.containsKey('max_completion_tokens'), isFalse);
      expect(request.body['response_format'], {'type': 'json_object'});
      final messages = request.body['messages']! as List;
      expect(messages.first, {'role': 'system', 'content': 'system'});
      expect(jsonDecode((messages.last as Map)['content'] as String), [
        {'id': 0, 'text': 'First line'},
        {'id': 1, 'text': 'Second line'},
      ]);
    });

    test('OpenAI reasoning models drop temperature', () {
      for (final model in ['gpt-6-luna', 'o4-mini', 'gpt-5-mini']) {
        final request = buildLyricsTranslationRequest(
          _config(LyricsAiProvider.openAi, model: model),
          _items,
          systemPrompt: 'system',
        );
        expect(request.body.containsKey('temperature'), isFalse, reason: model);
        expect(request.body.containsKey('max_tokens'), isFalse, reason: model);
        expect(request.body['max_completion_tokens'], isA<int>());
        expect(request.body['reasoning_effort'], 'low');
      }
    });

    test('OpenRouter keeps the classic parameters and names the app', () {
      final request = buildLyricsTranslationRequest(
        _config(LyricsAiProvider.openRouter, model: 'openai/gpt-6-luna'),
        _items,
        systemPrompt: 'system',
      );
      expect(
        request.uri.toString(),
        'https://openrouter.ai/api/v1/chat/completions',
      );
      expect(request.headers['X-Title'], 'Mornye');
      expect(request.body['temperature'], 0.2);
      expect(request.body.containsKey('response_format'), isFalse);
    });

    test('a custom server accepts pasted endpoint URLs and no key', () {
      final request = buildLyricsTranslationRequest(
        _config(
          LyricsAiProvider.custom,
          apiKey: '',
          baseUrl: ' http://localhost:11434/v1/chat/completions/ ',
        ),
        _items,
        systemPrompt: 'system',
      );
      expect(
        request.uri.toString(),
        'http://localhost:11434/v1/chat/completions',
      );
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.body.containsKey('reasoning_effort'), isFalse);
      expect(isValidLyricsAiBaseUrl('localhost:11434'), isFalse);
      expect(isValidLyricsAiBaseUrl('https://example.com/v1'), isTrue);
    });

    test('Gemini sends the key in a header with a system instruction', () {
      final request = buildLyricsTranslationRequest(
        _config(LyricsAiProvider.gemini, model: 'gemini-3.5-flash-lite'),
        _items,
        systemPrompt: 'system',
      );
      expect(
        request.uri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-3.5-flash-lite:generateContent',
      );
      expect(request.uri.toString(), isNot(contains('secret-key')));
      expect(request.headers['x-goog-api-key'], 'secret-key');
      expect(request.body['systemInstruction'], {
        'parts': [
          {'text': 'system'},
        ],
      });
      final config = request.body['generationConfig']! as Map;
      expect(config['responseMimeType'], 'application/json');
      expect(config['thinkingConfig'], {'thinkingLevel': 'low'});
      expect(config.containsKey('temperature'), isFalse);

      final older = buildLyricsTranslationRequest(
        _config(LyricsAiProvider.gemini, model: 'gemini-2.5-flash'),
        _items,
        systemPrompt: 'system',
      );
      expect((older.body['generationConfig']! as Map)['temperature'], 0.2);
    });

    test('Anthropic uses the Messages API headers without sampling', () {
      final request = buildLyricsTranslationRequest(
        _config(LyricsAiProvider.anthropic, model: 'claude-haiku-5-5'),
        _items,
        systemPrompt: 'system',
      );
      expect(request.uri.toString(), 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'secret-key');
      expect(request.headers['anthropic-version'], isNotEmpty);
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.body['system'], 'system');
      expect(request.body['max_tokens'], isA<int>());
      expect(request.body.containsKey('temperature'), isFalse);
    });

    test('the prompt names the target and appends the instruction', () {
      final prompt = lyricsTranslationSystemPrompt(
        languageName: 'Japanese',
        languageCode: 'ja',
        instruction: '  keep it poetic ',
      );
      expect(prompt, contains('Japanese (ja)'));
      expect(prompt, contains('"lines"'));
      expect(prompt, endsWith('keep it poetic'));
      expect(prompt, isNot(contains(String.fromCharCode(0x2014))));
      expect(prompt, isNot(contains('The song is')));
      expect(
        lyricsTranslationSystemPrompt(
          languageName: 'Japanese',
          languageCode: 'ja',
          title: ' Night Drive ',
          artist: 'Some Band',
        ),
        contains('The song is "Night Drive" by Some Band.'),
      );
      expect(prompt, contains('do not add notes, quotes, romanization'));
      expect(prompt, isNot(contains('"romanization"')));
    });

    test('a romanizing prompt asks for each language\'s usual system', () {
      final prompt = lyricsTranslationSystemPrompt(
        languageName: 'English',
        languageCode: 'en',
        romanize: true,
      );
      expect(prompt, contains('"romanization":"<romanization>"'));
      expect(prompt, contains('Hepburn'));
      expect(prompt, contains('Revised Romanization'));
      expect(prompt, contains('Pinyin'));
      expect(prompt, isNot(contains('quotes, romanization')));
      expect(prompt, isNot(contains(String.fromCharCode(0x2014))));
    });

    test('model list requests per provider', () {
      expect(
        buildLyricsModelListRequest(
          _config(LyricsAiProvider.custom, baseUrl: 'http://host:1234/v1/'),
        ).uri.toString(),
        'http://host:1234/v1/models',
      );
      final gemini = buildLyricsModelListRequest(
        _config(LyricsAiProvider.gemini),
      );
      expect(gemini.uri.query, isNot(contains('key=')));
      expect(gemini.headers['x-goog-api-key'], 'secret-key');
      expect(
        buildLyricsModelListRequest(
          _config(LyricsAiProvider.anthropic),
        ).headers['anthropic-version'],
        isNotEmpty,
      );
    });
  });

  group('reply parsing', () {
    const ids = {0, 1, 2};

    Map<int, String> texts(String reply) => parseLyricsTranslationReply(
      reply,
      ids,
    ).map((id, line) => MapEntry(id, line.text));

    test('reads the requested object', () {
      expect(texts('{"lines":[{"id":0,"text":"Uno"},{"id":1,"text":"Dos"}]}'), {
        0: 'Uno',
        1: 'Dos',
      });
    });

    test('reads romanizations and drops blank ones', () {
      expect(
        parseLyricsTranslationReply(
          '{"lines":[{"id":0,"text":"Love","romanization":" ai "},'
          '{"id":1,"text":"Hi","romanization":""},{"id":2,"text":"Yes"}]}',
          ids,
        ),
        {
          0: (
            text: 'Love',
            romanization: 'ai',
            alignment: const <LyricsTranslationChunk>[],
            romanizationAlignment: const <LyricsTranslationChunk>[],
          ),
          1: (
            text: 'Hi',
            romanization: null,
            alignment: const <LyricsTranslationChunk>[],
            romanizationAlignment: const <LyricsTranslationChunk>[],
          ),
          2: (
            text: 'Yes',
            romanization: null,
            alignment: const <LyricsTranslationChunk>[],
            romanizationAlignment: const <LyricsTranslationChunk>[],
          ),
        },
      );
    });

    test('accepts fences, bare arrays, prose and string ids', () {
      expect(
        texts(
          '```json\n[{"id":"0","text":"Uno"},{"id":2,"translation":"Tres"}]\n```',
        ),
        {0: 'Uno', 2: 'Tres'},
      );
      expect(
        texts(
          '<think>hmm</think>Here you go: {"translations":[{"id":1,"text":"Dos"}]}',
        ),
        {1: 'Dos'},
      );
    });

    test('drops unknown, duplicate and blank entries', () {
      expect(
        texts(
          '{"lines":[{"id":0,"text":"Uno"},{"id":0,"text":"Otra"},'
          '{"id":9,"text":"Nueve"},{"id":1,"text":"  "},{"text":"x"}]}',
        ),
        {0: 'Uno'},
      );
    });

    test('rejects text that holds no JSON list', () {
      for (final reply in ['Sorry, I cannot.', '{"lines": "none"}', '']) {
        expect(
          () => parseLyricsTranslationReply(reply, ids),
          throwsA(
            isA<LyricsAiException>().having(
              (e) => e.kind,
              'kind',
              LyricsAiErrorKind.badResponse,
            ),
          ),
          reason: reply,
        );
      }
    });

    Matcher kind(LyricsAiErrorKind kind) =>
        throwsA(isA<LyricsAiException>().having((e) => e.kind, 'kind', kind));

    test('maps refusals and truncation per provider', () {
      expect(
        () => extractLyricsAiText(LyricsAiProvider.openAi, {
          'choices': [
            {
              'message': {'content': '{"li'},
              'finish_reason': 'length',
            },
          ],
        }),
        kind(LyricsAiErrorKind.truncated),
      );
      expect(
        () => extractLyricsAiText(LyricsAiProvider.custom, {
          'choices': [
            {
              'message': {'content': null, 'refusal': 'No.'},
              'finish_reason': 'stop',
            },
          ],
        }),
        kind(LyricsAiErrorKind.refused),
      );
      expect(
        () => extractLyricsAiText(LyricsAiProvider.anthropic, {
          'stop_reason': 'refusal',
          'content': const [],
        }),
        kind(LyricsAiErrorKind.refused),
      );
      expect(
        () => extractLyricsAiText(LyricsAiProvider.anthropic, {
          'stop_reason': 'max_tokens',
          'content': const [],
        }),
        kind(LyricsAiErrorKind.truncated),
      );
      expect(
        () => extractLyricsAiText(LyricsAiProvider.gemini, {
          'promptFeedback': {'blockReason': 'OTHER'},
        }),
        kind(LyricsAiErrorKind.refused),
      );
      expect(
        () => extractLyricsAiText(LyricsAiProvider.gemini, {
          'candidates': [
            {'finishReason': 'MAX_TOKENS'},
          ],
        }),
        kind(LyricsAiErrorKind.truncated),
      );
    });

    test('skips thinking parts and blocks', () {
      expect(
        extractLyricsAiText(LyricsAiProvider.gemini, {
          'candidates': [
            {
              'finishReason': 'STOP',
              'content': {
                'parts': [
                  {'text': 'plan', 'thought': true},
                  {'text': '[]'},
                ],
              },
            },
          ],
        }),
        '[]',
      );
      expect(
        extractLyricsAiText(LyricsAiProvider.anthropic, {
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'thinking', 'thinking': ''},
            {'type': 'text', 'text': '{"lines":[]}'},
          ],
        }),
        '{"lines":[]}',
      );
    });

    test('reads model lists', () {
      expect(
        parseLyricsModelList(
          LyricsAiProvider.openAi,
          '{"data":[{"id":"b"},{"id":"a"},{"id":"a"}]}',
        ),
        ['a', 'b'],
      );
      expect(
        parseLyricsModelList(
          LyricsAiProvider.gemini,
          jsonEncode({
            'models': [
              {
                'name': 'models/gemini-x',
                'supportedGenerationMethods': ['generateContent'],
              },
              {
                'name': 'models/embedding',
                'supportedGenerationMethods': ['embedContent'],
              },
            ],
          }),
        ),
        ['gemini-x'],
      );
    });
  });

  group('error mapping', () {
    LyricsAiErrorKind kindOf(
      int status, [
      String body = '',
      LyricsAiProvider provider = LyricsAiProvider.openAi,
    ]) => lyricsAiErrorForResponse(provider, status, body).kind;

    test('maps statuses and provider codes', () {
      expect(kindOf(401), LyricsAiErrorKind.invalidKey);
      expect(kindOf(403), LyricsAiErrorKind.invalidKey);
      expect(
        kindOf(
          400,
          '{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}',
          LyricsAiProvider.gemini,
        ),
        LyricsAiErrorKind.invalidKey,
      );
      expect(kindOf(429), LyricsAiErrorKind.rateLimited);
      expect(
        kindOf(429, '{"error":{"code":"insufficient_quota"}}'),
        LyricsAiErrorKind.quota,
      );
      expect(kindOf(402), LyricsAiErrorKind.quota);
      expect(
        kindOf(
          400,
          'Your credit balance is too low',
          LyricsAiProvider.anthropic,
        ),
        LyricsAiErrorKind.quota,
      );
      expect(kindOf(404), LyricsAiErrorKind.modelNotFound);
      expect(kindOf(408), LyricsAiErrorKind.timeout);
      expect(kindOf(500), LyricsAiErrorKind.service);
      expect(kindOf(529), LyricsAiErrorKind.service);
    });

    test('reads the wait of a rate limit', () {
      expect(
        lyricsAiErrorForResponse(
          LyricsAiProvider.openAi,
          429,
          '',
          headers: {'retry-after': '3'},
        ).retryAfter,
        const Duration(seconds: 3),
      );
      expect(
        lyricsAiErrorForResponse(
          LyricsAiProvider.gemini,
          429,
          '{"details":[{"retryDelay":"7s"}]}',
        ).retryAfter,
        const Duration(seconds: 7),
      );
      expect(parseRetryAfter('soon'), isNull);
      expect(parseRetryAfter('1.5'), const Duration(milliseconds: 1500));
    });

    test('the key never appears in an error', () {
      final error = lyricsAiErrorForResponse(
        LyricsAiProvider.openAi,
        401,
        'Incorrect API key provided: secret-key',
      );
      expect(error.toString(), isNot(contains('secret-key')));
    });
  });

  group('client', () {
    test('waits out a rate limit, then succeeds', () async {
      final waits = <Duration>[];
      var calls = 0;
      final client = LyricsAiClient(
        _config(LyricsAiProvider.openAi, model: 'gpt-4.1-mini'),
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response('', 429, headers: {'retry-after': '2'});
          }
          return http.Response(
            _openAiReply('{"lines":[{"id":0,"text":"Uno"}]}'),
            200,
          );
        }),
        delay: (wait) async => waits.add(wait),
      );
      expect(await client.translate(_items, systemPrompt: 's'), {
        0: (
          text: 'Uno',
          romanization: null,
          alignment: const <LyricsTranslationChunk>[],
          romanizationAlignment: const <LyricsTranslationChunk>[],
        ),
      });
      expect(waits, [const Duration(seconds: 2)]);
    });

    test('reports a long rate limit instead of waiting', () async {
      final client = LyricsAiClient(
        _config(LyricsAiProvider.openAi),
        client: MockClient(
          (_) async => http.Response('', 429, headers: {'retry-after': '3600'}),
        ),
        delay: (_) async => fail('should not wait'),
      );
      await expectLater(
        client.translate(_items, systemPrompt: 's'),
        throwsA(
          isA<LyricsAiException>().having(
            (e) => e.kind,
            'kind',
            LyricsAiErrorKind.rateLimited,
          ),
        ),
      );
    });

    test('switches chat style when a parameter is unsupported', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = LyricsAiClient(
        _config(LyricsAiProvider.custom, baseUrl: 'http://host/v1'),
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          if (body.containsKey('temperature')) {
            return http.Response(
              '{"error":{"message":"Unsupported parameter: \'temperature\'"}}',
              400,
            );
          }
          return http.Response(_openAiReply('[{"id":1,"text":"Dos"}]'), 200);
        }),
      );
      expect(await client.translate(_items, systemPrompt: 's'), {
        1: (
          text: 'Dos',
          romanization: null,
          alignment: const <LyricsTranslationChunk>[],
          romanizationAlignment: const <LyricsTranslationChunk>[],
        ),
      });
      expect(bodies, hasLength(2));
      expect(bodies.last.containsKey('max_completion_tokens'), isTrue);
    });

    test('network failures are typed', () async {
      final client = LyricsAiClient(
        _config(LyricsAiProvider.anthropic),
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        client.translate(_items, systemPrompt: 's'),
        throwsA(
          isA<LyricsAiException>().having(
            (e) => e.kind,
            'kind',
            LyricsAiErrorKind.network,
          ),
        ),
      );
    });
  });
}
