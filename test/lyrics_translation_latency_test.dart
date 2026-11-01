import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';

const _config = LyricsAiConfig(
  provider: LyricsAiProvider.anthropic,
  model: 'claude-haiku-5-5',
  apiKey: 'test-key',
);

List<Map<String, dynamic>> _items(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final messages = body['messages'] as List;
  return (jsonDecode((messages.last as Map)['content'] as String) as List)
      .cast<Map<String, dynamic>>();
}

http.Response _reply(
  List<Map<String, Object?>> lines, {
  bool truncated = false,
}) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'content': [
        {
          'type': 'text',
          'text': jsonEncode({'lines': lines}),
        },
      ],
      'stop_reason': truncated ? 'max_tokens' : 'end_turn',
    }),
  ),
  200,
);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue);
}

void main() {
  test('compact alignment preserves timing and rejects invalid pairs', () {
    final compact = readLyricsTranslationChunks(
      [
        [0, 'Hello '],
        [1, 'world'],
      ],
      'Hello world',
      sourceCount: 2,
    )!;
    expect(compact.map((chunk) => chunk.toJson()), [
      {'text': 'Hello ', 'source': 0},
      {'text': 'world', 'source': 1},
    ]);
    for (final invalid in [
      [
        [0],
      ],
      [
        ['0', 'Hello world'],
      ],
      [
        [-1, 'Hello world'],
      ],
      [
        [2, 'Hello world'],
      ],
      [
        [1, 'Hello '],
        [0, 'world'],
      ],
      [
        [0, 'Different'],
      ],
    ]) {
      expect(
        readLyricsTranslationChunks(invalid, 'Hello world', sourceCount: 2),
        isNull,
      );
    }
  });

  test(
    'repairs omitted ids without translating successful lines again',
    () async {
      final batches = <List<int>>[];
      final progress = <int>[];
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          final items = _items(request);
          batches.add([for (final item in items) item['id'] as int]);
          return _reply([
            for (final item in items)
              if (batches.length > 1 || item['id'] != 1)
                {'id': item['id'], 'text': 'translated ${item['id']}'},
          ]);
        }),
      );
      addTearDown(client.close);
      final result = await LyricsTranslator(client).translate(
        ['zero', 'one', 'two'],
        systemPrompt: 's',
        onProgress: (done, _) => progress.add(done),
      );
      expect(batches, [
        [0, 1, 2],
        [1],
      ]);
      expect(result.translations, [
        'translated 0',
        'translated 1',
        'translated 2',
      ]);
      expect(progress, [0, 2, 3]);
    },
  );

  for (final wordSync in [false, true]) {
    test(
      'batches overlap at most two requests and retain ids out of order (wordSync=$wordSync)',
      () async {
        final calls = <List<int>>[];
        final gates = <Completer<http.Response>>[];
        var active = 0, peak = 0;
        final client = LyricsAiClient(
          _config,
          client: MockClient((request) async {
            final items = _items(request);
            expect(items.single.containsKey('words'), wordSync);
            calls.add([for (final item in items) item['id'] as int]);
            final gate = Completer<http.Response>();
            gates.add(gate);
            active++;
            if (active > peak) peak = active;
            try {
              return await gate.future;
            } finally {
              active--;
            }
          }),
        );
        addTearDown(client.close);
        final pending = LyricsTranslator(client, maxItems: 1).translate(
          ['zero', 'one', 'two'],
          systemPrompt: 's',
          sourceWords: wordSync
              ? [
                  ['zero'],
                  ['one'],
                  ['two'],
                ]
              : const [],
        );
        await _until(() => calls.length == 2);
        expect(peak, 2);
        gates[1].complete(
          _reply([
            {
              'id': 1,
              'text': 'ONE',
              'alignment': [
                [0, 'ONE'],
              ],
            },
          ]),
        );
        await _until(() => calls.length == 3);
        gates[2].complete(
          _reply([
            {
              'id': 2,
              'text': 'TWO',
              'alignment': [
                [0, 'TWO'],
              ],
            },
          ]),
        );
        gates[0].complete(
          _reply([
            {
              'id': 0,
              'text': 'ZERO',
              'alignment': [
                [0, 'ZERO'],
              ],
            },
          ]),
        );
        final result = await pending;
        expect(result.translations, ['ZERO', 'ONE', 'TWO']);
        expect(
          result.alignments.map((chunks) => chunks.single.source),
          wordSync ? [0, 0, 0] : isEmpty,
        );
        expect(peak, 2);
      },
    );
  }

  test(
    'cancelling parallel work starts no further batches or late progress',
    () async {
      final gates = <Completer<http.Response>>[];
      final progress = <int>[];
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          final gate = Completer<http.Response>();
          gates.add(gate);
          return gate.future;
        }),
      );
      addTearDown(client.close);
      final cancel = LyricsTranslationCancelToken();
      final pending = LyricsTranslator(client, maxItems: 1).translate(
        ['zero', 'one', 'two'],
        systemPrompt: 's',
        sourceWords: [
          ['zero'],
          ['one'],
          ['two'],
        ],
        cancel: cancel,
        onProgress: (done, _) => progress.add(done),
      );
      await _until(() => gates.length == 2);
      final checking = expectLater(
        pending,
        throwsA(isA<LyricsTranslationCancelled>()),
      );
      cancel.cancel();
      await checking;
      for (final gate in gates) {
        gate.complete(_reply([]));
      }
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(2));
      expect(progress, [0]);
    },
  );

  test(
    'repairing cached text preserves its existing pronunciation and timing',
    () async {
      final requestedIds = <int>[];
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          requestedIds.addAll([
            for (final item in _items(request)) item['id'] as int,
          ]);
          return _reply([
            {'id': 1, 'text': 'Filled'},
          ]);
        }),
      );
      addTearDown(client.close);
      final result = await LyricsTranslator(client).translate(
        ['zero', 'one'],
        systemPrompt: 's',
        sourceWords: [
          ['zero'],
          ['one'],
        ],
        initialResult: const LyricsTranslationResult(
          ['Kept', null],
          romanizations: ['reading zero', 'reading one'],
          romanizationAlignments: [
            [LyricsTranslationChunk('reading zero', 0)],
            [LyricsTranslationChunk('reading one', 0)],
          ],
        ),
      );
      expect(requestedIds, [1]);
      expect(result.translations, ['Kept', 'Filled']);
      expect(result.romanizations, ['reading zero', 'reading one']);
      expect(result.romanizationAlignments[1].single.text, 'reading one');
    },
  );

  test(
    'a fatal parallel failure returns promptly and suppresses remaining work',
    () async {
      final gates = <Completer<http.Response>>[];
      final progress = <int>[];
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          final gate = Completer<http.Response>();
          gates.add(gate);
          return gate.future;
        }),
      );
      addTearDown(client.close);
      final pending = LyricsTranslator(client, maxItems: 1).translate(
        ['zero', 'one', 'two'],
        systemPrompt: 's',
        sourceWords: [
          ['zero'],
          ['one'],
          ['two'],
        ],
        onProgress: (done, _) => progress.add(done),
      );
      await _until(() => gates.length == 2);
      final checking = expectLater(
        pending,
        throwsA(
          isA<LyricsAiException>().having(
            (error) => error.kind,
            'kind',
            LyricsAiErrorKind.invalidKey,
          ),
        ),
      );
      gates[0].complete(http.Response('', 401));
      await checking;
      gates[1].complete(
        _reply([
          {'id': 1, 'text': 'Ignored after failure'},
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(2));
      expect(progress, [0]);
    },
  );

  test(
    'one oversized alignment falls back to a readable translated line',
    () async {
      final requests = <List<Map<String, dynamic>>>[];
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          final items = _items(request);
          requests.add(items);
          return _reply([
            {'id': 0, 'text': 'Readable translation'},
          ], truncated: items.single.containsKey('words'));
        }),
      );
      addTearDown(client.close);
      final result = await LyricsTranslator(client).translate(
        ['A long sung line'],
        systemPrompt: 's',
        sourceWords: [
          ['A', 'long', 'sung', 'line'],
        ],
      );
      expect(requests, hasLength(2));
      expect(requests.last.single.containsKey('words'), isFalse);
      expect(result.translations, ['Readable translation']);
      expect(result.missing, 0);
      expect(result.alignments, isEmpty);
    },
  );

  test(
    'Fast reduces sequential request rounds on long 5.3.0-style lyrics',
    () async {
      final texts = [for (var i = 0; i < 181; i++) 'Original lyric line $i'];
      Future<({int requests, int rounds, LyricsTranslationResult result})> run(
        int workers,
      ) async {
        final gates =
            <(Completer<http.Response>, List<Map<String, dynamic>>)>[];
        final client = LyricsAiClient(
          _config,
          client: MockClient((request) async {
            final items = _items(request);
            expect(items.every((item) => !item.containsKey('words')), isTrue);
            final gate = Completer<http.Response>();
            gates.add((gate, items));
            return gate.future;
          }),
        );
        addTearDown(client.close);
        var finished = false;
        final pending = LyricsTranslator(client, maxConcurrentRequests: workers)
            .translate(
              texts,
              systemPrompt: lyricsTranslationSystemPrompt(
                languageName: 'Indonesian',
                languageCode: 'id',
              ),
            )
            .whenComplete(() => finished = true);
        var completed = 0, rounds = 0;
        while (!finished) {
          await _until(() => finished || completed < gates.length);
          if (finished) break;
          rounds++;
          final wave = gates.sublist(completed);
          completed = gates.length;
          for (final (gate, items) in wave) {
            gate.complete(
              _reply([
                for (final item in items)
                  {'id': item['id'], 'text': 'Translated ${item['text']}'},
              ]),
            );
          }
        }
        return (requests: gates.length, rounds: rounds, result: await pending);
      }

      final sequential = await run(1);
      final parallel = await run(2);
      expect(sequential.requests, 4);
      expect(parallel.requests, sequential.requests);
      expect(sequential.rounds, 4);
      expect(parallel.rounds, 2);
      expect(parallel.result.translations, sequential.result.translations);
      expect(parallel.result.missing, 0);
      debugPrint(
        'Fast fixture: 181 lines, 4 requests, sequential rounds 4 -> 2',
      );
    },
  );

  test('output-aware batches avoid the large-response split cascade', () async {
    final texts = [for (var i = 0; i < 24; i++) '${'天地人風雨月星海山川' * 4}$i'];
    final words = texts.map(lyricsTranslationUnits).toList();
    Future<
      ({
        int requests,
        int truncated,
        int successfulBytes,
        LyricsTranslationResult result,
      })
    >
    run(bool compact) async {
      var requests = 0, truncated = 0, successfulBytes = 0;
      final client = LyricsAiClient(
        _config,
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final compactReply = (body['system'] as String).contains(
            'compact [sourceIndex',
          );
          expect(body['output_config'], {'effort': 'low'});
          final messages = body['messages'] as List;
          if (messages.length > 1) {
            expect(
              (messages.first as Map)['content'],
              contains(jsonEncode(texts)),
            );
          }
          final lines = <Map<String, Object?>>[];
          for (final item in _items(request)) {
            final units = item['words'] as List;
            String part(String prefix, int i) =>
                '$prefix$i${i == units.length - 1 ? '' : ' '}';
            List<Object> chunks(String prefix) => [
              for (var i = 0; i < units.length; i++)
                if (compactReply)
                  [i, part(prefix, i)]
                else
                  {'source': i, 'text': part(prefix, i)},
            ];
            String text(String prefix) =>
                [for (var i = 0; i < units.length; i++) part(prefix, i)].join();
            lines.add({
              'id': item['id'],
              'text': text('w'),
              'romanization': text('r'),
              'alignment': chunks('w'),
              'romanizationAlignment': chunks('r'),
            });
          }
          final bytes = utf8.encode(jsonEncode({'lines': lines})).length;
          final tooLarge = bytes > 12000;
          if (tooLarge) {
            truncated++;
          } else {
            successfulBytes += bytes;
          }
          return _reply(lines, truncated: tooLarge);
        }),
      );
      addTearDown(client.close);
      final result =
          await LyricsTranslator(
            client,
            maxAlignmentUnits: compact ? 240 : 1 << 30,
            maxConcurrentRequests: compact ? 2 : 1,
          ).translate(
            texts,
            sourceWords: words,
            systemPrompt: compact
                ? lyricsTranslationSystemPrompt(
                    languageName: 'English',
                    languageCode: 'en',
                    romanize: true,
                    wordSync: true,
                  )
                : 'Return translated text and romanization, with alignment arrays of objects containing source and text.',
          );
      return (
        requests: requests,
        truncated: truncated,
        successfulBytes: successfulBytes,
        result: result,
      );
    }

    final before = await run(false);
    final after = await run(true);
    expect(before.truncated, greaterThan(0));
    expect(after.truncated, 0);
    expect(after.requests, lessThan(before.requests));
    expect(after.successfulBytes, lessThan(before.successfulBytes * 0.65));
    expect(after.result.translations, before.result.translations);
    expect(after.result.romanizations, before.result.romanizations);
    expect(
      after.result.alignments.first.map((chunk) => chunk.toJson()),
      before.result.alignments.first.map((chunk) => chunk.toJson()),
    );
    debugPrint(
      'Timed fixture: ${before.requests} requests (${before.truncated} truncated) -> ${after.requests} requests, 0 truncated; successful response bytes ${before.successfulBytes} -> ${after.successfulBytes}',
    );
  });
}
