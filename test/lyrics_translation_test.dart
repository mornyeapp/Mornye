import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/utils/lyrics_parser.dart';

ParsedLyrics _lyrics(List<String> texts, {int offsetMs = 0}) => ParsedLyrics(
  synced: true,
  wordSynced: false,
  lines: [
    for (var i = 0; i < texts.length; i++)
      LyricLine(
        time: Duration(milliseconds: offsetMs + i * 1000),
        text: texts[i],
      ),
  ],
  plainText: texts.join('\n'),
);

const _config = LyricsAiConfig(
  provider: LyricsAiProvider.openAi,
  model: 'gpt-4.1-mini',
  apiKey: 'key',
);

/// Answers each batch by echoing its texts in upper case, unless [reply]
/// returns a raw model reply for the batch.
LyricsAiClient _client(
  List<List<int>> batches, {
  String? Function(List<Map<String, dynamic>> items, int call)? reply,
  String finish = 'stop',
  int status = 200,
}) {
  var calls = 0;
  return LyricsAiClient(
    _config,
    client: MockClient((request) async {
      if (status != 200) return http.Response('', status);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final user = (body['messages'] as List).last as Map;
      final items = (jsonDecode(user['content'] as String) as List)
          .cast<Map<String, dynamic>>();
      batches.add([for (final item in items) item['id'] as int]);
      final content =
          reply?.call(items, calls++) ??
          jsonEncode({
            'lines': [
              for (final item in items)
                {
                  'id': item['id'],
                  'text': (item['text'] as String).toUpperCase(),
                },
            ],
          });
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
                'finish_reason': finish,
              },
            ],
          }),
        ),
        200,
      );
    }),
    delay: (_) async {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('source', () {
    test('strips timing tags and skips instrumental lines', () {
      expect(
        translatableLyricText('<00:01.00>Hello <00:01.50>world '),
        'Hello world',
      );
      expect(translatableLyricText('[00:12.30]Hi'), 'Hi');
      for (final text in ['', '   ', '♪', '...', '(Instrumental)', '[Music]']) {
        expect(translatableLyricText(text), isEmpty, reason: text);
      }
    });

    test('sends a repeated line once and maps it back', () {
      final source = LyricsTranslationSource.of(
        _lyrics(['Chorus', '', 'Verse', 'Chorus', '♪']),
      );
      expect(source.texts, ['Chorus', 'Verse']);
      expect(source.lineSegments, [0, null, 1, 0, null]);
    });

    test('the hash ignores timing but follows the text', () {
      final a = LyricsTranslationSource.of(_lyrics(['One', 'Two']));
      final shifted = LyricsTranslationSource.of(
        _lyrics(['One', 'Two'], offsetMs: 500),
      );
      final other = LyricsTranslationSource.of(_lyrics(['One', 'Three']));
      expect(shifted.hash, a.hash);
      expect(other.hash, isNot(a.hash));
    });

    test('cache keys separate language, provider, model and server', () {
      String key({String language = 'ja', LyricsAiConfig config = _config}) =>
          lyricsTranslationCacheKey(
            sourceHash: 'hash',
            language: language,
            config: config,
          );
      final base = key();
      expect(key(), base);
      expect(key(language: 'ko'), isNot(base));
      expect(
        key(
          config: const LyricsAiConfig(
            provider: LyricsAiProvider.openAi,
            model: 'gpt-6-luna',
          ),
        ),
        isNot(base),
      );
      expect(
        key(
          config: const LyricsAiConfig(
            provider: LyricsAiProvider.openRouter,
            model: 'gpt-4.1-mini',
          ),
        ),
        isNot(base),
      );
      const local = LyricsAiConfig(
        provider: LyricsAiProvider.custom,
        model: 'llama',
        baseUrl: 'http://a/v1',
      );
      expect(
        key(config: local),
        isNot(
          key(
            config: const LyricsAiConfig(
              provider: LyricsAiProvider.custom,
              model: 'llama',
              baseUrl: 'http://b/v1',
            ),
          ),
        ),
      );
      // The key itself is not part of the cache identity.
      expect(
        key(
          config: const LyricsAiConfig(
            provider: LyricsAiProvider.openAi,
            model: 'gpt-4.1-mini',
            apiKey: 'another',
          ),
        ),
        base,
      );
    });
  });

  group('merge', () {
    test('fills every line of a repeated text and keeps the original', () {
      final lyrics = _lyrics(['Chorus', 'Verse', 'Chorus']);
      final source = LyricsTranslationSource.of(lyrics);
      final merged = applyLyricsTranslation(lyrics, source, ['Coro', null]);
      expect(merged.lines.map((line) => line.translation), [
        'Coro',
        null,
        'Coro',
      ]);
      expect(merged.lines.map((line) => line.text), [
        'Chorus',
        'Verse',
        'Chorus',
      ]);
      expect(lyrics.lines.first.translation, isNull);
    });

    test('an AI translation replaces a provider one only where it exists', () {
      final lyrics = ParsedLyrics(
        synced: true,
        wordSynced: false,
        lines: const [
          LyricLine(time: Duration.zero, text: 'A', translation: 'provider a'),
          LyricLine(
            time: Duration(seconds: 1),
            text: 'B',
            translation: 'provider b',
          ),
        ],
        plainText: 'A\nB',
      );
      final source = LyricsTranslationSource.of(lyrics);
      final merged = applyLyricsTranslation(lyrics, source, ['ai a', null]);
      expect(merged.lines.map((line) => line.translation), [
        'ai a',
        'provider b',
      ]);
      expect(applyLyricsTranslation(lyrics, source, [null, null]), lyrics);
    });

    test('a line returned as it was shows no translation', () {
      final lyrics = _lyrics(['Hello there', 'Hola amigo']);
      final source = LyricsTranslationSource.of(lyrics);
      final merged = applyLyricsTranslation(lyrics, source, [
        'hello, there!',
        'Hello friend',
      ]);
      expect(merged.lines.map((line) => line.translation), [
        null,
        'Hello friend',
      ]);
      expect(
        lyricsTranslationUnchanged(source, ['Hello there', 'Hola amigo']),
        isTrue,
      );
      expect(
        lyricsTranslationUnchanged(source, ['Hello there', 'Hello friend']),
        isFalse,
      );
      expect(lyricsTranslationUnchanged(source, [null, null]), isFalse);
    });

    test('romanizes only lines outside the Latin alphabet without one', () {
      final lyrics = ParsedLyrics(
        synced: true,
        wordSynced: false,
        lines: const [
          LyricLine(time: Duration.zero, text: '愛してる'),
          LyricLine(time: Duration(seconds: 1), text: 'Baby'),
          LyricLine(
            time: Duration(seconds: 2),
            text: '사랑해',
            romanization: 'saranghae',
          ),
          LyricLine(time: Duration(seconds: 3), text: '愛してる'),
        ],
        plainText: '',
      );
      expect(lyricsNeedRomanization(lyrics), isTrue);
      final source = LyricsTranslationSource.of(lyrics);
      final merged = applyLyricsTranslation(
        lyrics,
        source,
        [null, null, 'I love you'],
        romanizations: ['aishiteru', 'beibii', 'salanghae'],
      );
      expect(merged.lines.map((line) => line.romanization), [
        'aishiteru',
        null,
        'saranghae',
        'aishiteru',
      ]);
      expect(merged.lines.map((line) => line.translation), [
        null,
        null,
        'I love you',
        null,
      ]);
      expect(lyricsNeedRomanization(merged), isFalse);
      expect(lyricsNeedRomanization(_lyrics(['Hello', 'Hola'])), isFalse);
    });
  });

  group('batching', () {
    test('respects the line and character limits in order', () {
      final items = [
        for (var i = 0; i < 7; i++) LyricsAiItem(i, 'x' * (i == 3 ? 40 : 5)),
      ];
      final batches = batchLyricsItems(items, maxItems: 3, maxChars: 49);
      expect(
        batches.map((batch) => [for (final item in batch) item.id]).toList(),
        [
          [0, 1, 2],
          [3, 4],
          [5, 6],
        ],
      );
      expect(batchLyricsItems(const []), isEmpty);
    });
  });

  group('translator', () {
    final texts = [for (var i = 0; i < 5; i++) 'line $i'];

    test('translates in sequential batches with progress', () async {
      final batches = <List<int>>[];
      final progress = <int>[];
      final result =
          await LyricsTranslator(
            _client(batches),
            maxItems: 2,
            maxConcurrentRequests: 1,
          ).translate(
            texts,
            systemPrompt: 's',
            onProgress: (done, _) => progress.add(done),
          );
      expect(batches, [
        [0, 1],
        [2, 3],
        [4],
      ]);
      expect(result.translations, [for (final t in texts) t.toUpperCase()]);
      expect(result.missing, 0);
      expect(progress, [0, 2, 4, 5]);
    });

    test(
      'unrepaired missing ids stay untranslated after one targeted retry',
      () async {
        final batches = <List<int>>[];
        final result = await LyricsTranslator(
          _client(
            batches,
            reply: (items, _) => jsonEncode({
              'lines': [
                {'id': items.first['id'], 'text': 'only'},
              ],
            }),
          ),
        ).translate(texts, systemPrompt: 's');
        expect(result.translations.first, 'only');
        expect(result.missing, 3);
        expect(batches, [
          [0, 1, 2, 3, 4],
          [1, 2, 3, 4],
        ]);
      },
    );

    test('keeps the romanizations the model returns', () async {
      final result = await LyricsTranslator(
        _client(
          [],
          reply: (items, _) => jsonEncode({
            'lines': [
              for (final item in items)
                {
                  'id': item['id'],
                  'text': 'T${item['id']}',
                  if (item['id'] == 1) 'romanization': ' r1 ',
                },
            ],
          }),
        ),
      ).translate(texts, systemPrompt: 's');
      expect(result.romanizations, [null, 'r1', null, null, null]);
      expect(result.romanized, isTrue);
      final plain = await LyricsTranslator(
        _client([]),
      ).translate(texts, systemPrompt: 's');
      expect(plain.romanizations, isEmpty);
      expect(plain.romanized, isFalse);
    });

    test('a malformed batch is retried once, then split', () async {
      final batches = <List<int>>[];
      final result = await LyricsTranslator(
        _client(
          batches,
          // The full batch always fails; halves succeed.
          reply: (items, _) => items.length == texts.length ? 'not json' : null,
        ),
      ).translate(texts, systemPrompt: 's');
      expect(batches, [
        [0, 1, 2, 3, 4],
        [0, 1, 2, 3, 4],
        [0, 1],
        [2, 3, 4],
      ]);
      expect(result.missing, 0);
    });

    test('a truncated batch is split without a retry', () async {
      final batches = <List<int>>[];
      var call = 0;
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final user = (body['messages'] as List).last as Map;
          final items = (jsonDecode(user['content'] as String) as List)
              .cast<Map<String, dynamic>>();
          batches.add([for (final item in items) item['id'] as int]);
          final truncated = call++ == 0;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'lines': [
                        for (final item in items)
                          {'id': item['id'], 'text': 'ok'},
                      ],
                    }),
                  },
                  'finish_reason': truncated ? 'length' : 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      final result = await LyricsTranslator(
        client,
      ).translate(texts.take(4).toList(), systemPrompt: 's');
      expect(batches, [
        [0, 1, 2, 3],
        [0, 1],
        [2, 3],
      ]);
      expect(result.missing, 0);
    });

    test('fatal errors stop the whole song', () async {
      await expectLater(
        LyricsTranslator(
          _client([], status: 401),
        ).translate(texts, systemPrompt: 's'),
        throwsA(
          isA<LyricsAiException>().having(
            (e) => e.kind,
            'kind',
            LyricsAiErrorKind.invalidKey,
          ),
        ),
      );
    });

    test('nothing usable at all is an error', () async {
      await expectLater(
        LyricsTranslator(
          _client([], reply: (_, _) => 'nope'),
        ).translate(texts.take(1).toList(), systemPrompt: 's'),
        throwsA(
          isA<LyricsAiException>().having(
            (e) => e.kind,
            'kind',
            LyricsAiErrorKind.badResponse,
          ),
        ),
      );
      await expectLater(
        LyricsTranslator(_client([])).translate(const [], systemPrompt: 's'),
        throwsA(
          isA<LyricsAiException>().having(
            (e) => e.kind,
            'kind',
            LyricsAiErrorKind.noLyrics,
          ),
        ),
      );
    });

    test('cancelling stops before the next queued batch', () async {
      final batches = <List<int>>[];
      final cancel = LyricsTranslationCancelToken();
      await expectLater(
        LyricsTranslator(_client(batches), maxItems: 2).translate(
          texts,
          systemPrompt: 's',
          cancel: cancel,
          onProgress: (done, _) {
            if (done > 0) cancel.cancel();
          },
        ),
        throwsA(isA<LyricsTranslationCancelled>()),
      );
      expect(batches, [
        [0, 1],
        [2, 3],
      ]);
    });
  });

  group('cache', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('lyrics_cache_test');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('persists across instances and clears', () async {
      final cache = LyricsTranslationCache(directory: () async => directory);
      await cache.write('a', const LyricsTranslationResult(['Uno', null]));
      await cache.write(
        'ja',
        const LyricsTranslationResult(
          ['Love', 'Hi'],
          romanizations: ['ai', null],
        ),
      );
      final reopened = LyricsTranslationCache(directory: () async => directory);
      final plain = await reopened.read('a');
      expect(plain!.translations, ['Uno', null]);
      expect(plain.romanized, isFalse);
      final romanized = await reopened.read('ja');
      expect(romanized!.translations, ['Love', 'Hi']);
      expect(romanized.romanizations, ['ai', null]);
      expect(await reopened.read('b'), isNull);
      expect(await reopened.count(), 2);
      await reopened.clear();
      expect(
        await LyricsTranslationCache(directory: () async => directory).count(),
        0,
      );
    });

    test('evicts the least recently used entry', () async {
      final cache = LyricsTranslationCache(
        directory: () async => directory,
        maxEntries: 2,
      );
      await cache.write('a', const LyricsTranslationResult(['a']));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.write('b', const LyricsTranslationResult(['b']));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.read('a');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await cache.write('c', const LyricsTranslationResult(['c']));
      expect(await cache.read('b'), isNull);
      expect((await cache.read('a'))!.translations, ['a']);
      expect((await cache.read('c'))!.translations, ['c']);
    });

    test('an unreadable file starts empty', () async {
      await File(
        '${directory.path}/lyrics_translations.json',
      ).writeAsString('{broken');
      final cache = LyricsTranslationCache(directory: () async => directory);
      expect(await cache.count(), 0);
      await cache.write('a', const LyricsTranslationResult(['a']));
      expect((await cache.read('a'))!.translations, ['a']);
    });
  });
}
