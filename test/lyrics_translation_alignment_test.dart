import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';
import 'package:mornye/services/lyrics_translation_sharing.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';

LyricLine _line({int offset = 0}) => LyricLine(
  time: Duration(seconds: offset),
  end: Duration(seconds: offset + 4),
  text: 'Hello world',
  words: [
    LyricWord(
      time: Duration(seconds: offset),
      end: Duration(seconds: offset + 1),
      text: 'Hel',
    ),
    LyricWord(
      time: Duration(seconds: offset + 1),
      end: Duration(seconds: offset + 2),
      text: 'lo ',
    ),
    LyricWord(
      time: Duration(seconds: offset + 2),
      end: Duration(seconds: offset + 4),
      text: 'world',
    ),
  ],
  romanization: 'Pronunciation',
  romanizationWords: const [
    LyricWord(time: Duration.zero, text: 'Pronunciation'),
  ],
);

ParsedLyrics _lyrics(List<LyricLine> lines) => ParsedLyrics(
  synced: true,
  wordSynced: true,
  lines: lines,
  plainText: 'Hello world',
);

const _chunks = [
  LyricsTranslationChunk('Halo ', 0),
  LyricsTranslationChunk('dunia', 1),
];

void main() {
  test('projects one alignment onto repeated lines and peer timing', () {
    final lyrics = _lyrics([_line(), _line(offset: 10)]);
    final source = LyricsTranslationSource.of(lyrics);
    expect(source.words, [
      ['Hello', 'world'],
    ]);
    final result = applyLyricsTranslation(
      lyrics,
      source,
      ['Halo dunia'],
      alignments: [_chunks],
    );
    for (var i = 0; i < result.lines.length; i++) {
      final line = result.lines[i];
      expect(
        line.translationWords.map((word) => word.text).join(),
        'Halo dunia',
      );
      expect(line.translationWords.map((word) => word.time.inSeconds), [
        i * 10,
        i * 10 + 2,
      ]);
      expect(line.translationWords.last.end!.inSeconds, i * 10 + 4);
      expect(line.romanization, 'Pronunciation');
      expect(line.romanizationWords, same(lyrics.lines[i].romanizationWords));
    }
    final peer = _lyrics([_line(offset: 30)]);
    expect(LyricsTranslationSource.of(peer).hash, source.hash);
    final displayed = applyLyricsTranslation(
      peer,
      LyricsTranslationSource.of(peer),
      ['Halo dunia'],
      alignments: [_chunks],
    );
    expect(
      displayed.lines.single.translationWords.first.time,
      const Duration(seconds: 30),
    );
  });

  test('splits phrases sharing a source unit within its interval', () {
    final words = timedLyricsTranslation(
      _line(),
      ['Hello', 'world'],
      const [
        LyricsTranslationChunk('Hai ', 0),
        LyricsTranslationChunk('semua ', 0),
        LyricsTranslationChunk('orang', 1),
      ],
    );
    expect(words.map((word) => word.time.inSeconds), [0, 1, 2]);
    expect(words.map((word) => word.end!.inSeconds), [1, 2, 4]);
  });

  test('lyrics end normalization and user offset retain translated words', () {
    final lyrics = _lyrics([_line(offset: 10)]);
    final line = applyLyricsTranslation(
      lyrics,
      LyricsTranslationSource.of(lyrics),
      ['Halo dunia'],
      alignments: [_chunks],
    ).lines.single;
    for (final offset in [
      const Duration(seconds: -2),
      const Duration(seconds: 2),
    ]) {
      final shifted = lyricsShiftedBy([line], offset).single;
      expect(
        shifted.translationWords.first.time,
        line.translationWords.first.time + offset,
      );
      expect(
        shifted.translationWords.last.end,
        line.translationWords.last.end! + offset,
      );
    }
    final normalized = lyricsWithDisplayEnds([
      LyricLine(
        time: line.time,
        text: line.text,
        words: line.words,
        translation: line.translation,
        translationWords: line.translationWords,
      ),
    ]);
    expect(normalized.single.translationWords, same(line.translationWords));
  });

  test('translated words stop at explicit vocal ends before a gap', () {
    const line = LyricLine(
      time: Duration.zero,
      end: Duration(seconds: 6),
      text: 'Hello world',
      words: [
        LyricWord(
          time: Duration.zero,
          end: Duration(seconds: 1),
          text: 'Hello ',
        ),
        LyricWord(
          time: Duration(seconds: 4),
          end: Duration(seconds: 6),
          text: 'world',
        ),
      ],
    );
    final words = timedLyricsTranslation(line, ['Hello', 'world'], _chunks);
    expect(words.first.end, const Duration(seconds: 1));
    expect(words.last.time, const Duration(seconds: 4));
  });

  test('uses stable units for Japanese without spaces and combining marks', () {
    expect(lyricsTranslationUnits('君を love'), ['君', 'を', 'love']);
    expect(lyricsTranslationUnits('cafe\u0301 déjà'), ['cafe\u0301', 'déjà']);
  });

  test('line-only, mismatched and invalid timing keep plain translation', () {
    for (final line in [
      const LyricLine(time: Duration.zero, text: 'Hello world'),
      const LyricLine(
        time: Duration.zero,
        text: 'Hello world',
        words: [LyricWord(time: Duration.zero, text: 'Different')],
      ),
      const LyricLine(
        time: Duration.zero,
        text: 'Hello world',
        words: [
          LyricWord(
            time: Duration(seconds: 2),
            end: Duration(seconds: 1),
            text: 'Hello world',
          ),
        ],
      ),
    ]) {
      final lyrics = _lyrics([line]);
      final result = applyLyricsTranslation(
        lyrics,
        LyricsTranslationSource.of(lyrics),
        ['Halo dunia'],
        alignments: [_chunks],
      );
      expect(result.lines.single.translation, 'Halo dunia');
      expect(result.lines.single.translationWords, isEmpty);
    }
  });

  test('alignment validation rejects bad indices, text and payloads', () {
    for (final value in [
      [
        {'text': 'Halo dunia', 'source': -1},
      ],
      [
        {'text': 'Halo ', 'source': 1},
        {'text': 'dunia', 'source': 0},
      ],
      [
        {'text': 'Halo dunia', 'source': 2},
      ],
      [
        {'text': 'Other', 'source': 0},
      ],
      List.filled(257, {'text': 'x', 'source': 0}),
    ]) {
      expect(
        readLyricsTranslationChunks(value, 'Halo dunia', sourceCount: 2),
        isNull,
      );
    }
  });

  test(
    'AI alignment passes through a request, cache and Link without timestamps',
    () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final messages = body['messages'] as List;
        final input =
            jsonDecode((messages.last as Map)['content'] as String) as List;
        expect((input.single as Map)['words'], ['Hello', 'world']);
        expect((messages.first as Map)['content'], contains('zero-based'));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'lines': [
                      {
                        'id': 0,
                        'text': 'Halo dunia',
                        'alignment': [
                          for (final chunk in _chunks) chunk.toJson(),
                        ],
                      },
                    ],
                  }),
                },
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final result =
          await LyricsTranslator(
            LyricsAiClient(
              const LyricsAiConfig(
                provider: LyricsAiProvider.custom,
                model: 'fixture',
                baseUrl: 'http://localhost/v1',
              ),
              client: client,
            ),
          ).translate(
            ['Hello world'],
            sourceWords: [
              ['Hello', 'world'],
            ],
            systemPrompt: lyricsTranslationSystemPrompt(
              languageName: 'Indonesian',
              languageCode: 'id',
              wordSync: true,
            ),
          );
      expect(result.wordSynced, isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'translation-alignment-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = LyricsTranslationCache(directory: () async => directory);
      await cache.write('fixture', result);
      final restored = await LyricsTranslationCache(
        directory: () async => directory,
      ).read('fixture');
      expect(restored!.alignments.single.map((chunk) => chunk.source), [0, 1]);
      final shared = SharedLyricsTranslation(
        sourceHash: 'a' * 64,
        language: 'id',
        result: restored,
        updatedMs: 1,
      );
      final json = jsonDecode(jsonEncode(shared.toJson()));
      final received = SharedLyricsTranslation.fromJson(json)!;
      expect(received.result.alignments.single.map((chunk) => chunk.text), [
        'Halo ',
        'dunia',
      ]);
      expect(jsonEncode(json), isNot(contains('time')));
      final peer = _lyrics([_line(offset: 20)]);
      final displayed = applyLyricsTranslation(
        peer,
        LyricsTranslationSource.of(peer),
        received.result.translations,
        alignments: received.result.alignments,
      );
      expect(displayed.lines.single.translationWords.last.time.inSeconds, 22);
    },
  );

  test(
    'legacy Link payload remains usable and malformed alignment is rejected',
    () {
      final shared = SharedLyricsTranslation(
        sourceHash: 'a' * 64,
        language: 'id',
        result: const LyricsTranslationResult(['Halo dunia']),
        updatedMs: 1,
      );
      expect(
        SharedLyricsTranslation.fromJson(shared.toJson())!.result.alignments,
        isEmpty,
      );
      expect(
        SharedLyricsTranslation.fromJson({
          ...shared.toJson(),
          'alignments': [
            [
              {'text': 'Other', 'source': 0},
            ],
          ],
        }),
        isNull,
      );
      final parsed = parseLyricsTranslationReply(
        '{"lines":[{"id":0,"text":"Halo dunia","alignment":[{"text":"wrong","source":0}]}]}',
        {0},
      );
      expect(parsed[0]!.text, 'Halo dunia');
      expect(parsed[0]!.alignment, isEmpty);
    },
  );
}
