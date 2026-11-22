import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyric_supplement_tags.dart';
import 'package:mornye/utils/lyrics_parser.dart';

LyricWord _word(String text, int start, int end) => LyricWord(
  time: Duration(milliseconds: start),
  end: Duration(milliseconds: end),
  text: text,
);

List<(String, int, int?)> _spans(List<LyricWord> words) => [
  for (final word in words)
    (word.text, word.time.inMilliseconds, word.end?.inMilliseconds),
];

void main() {
  test('text is written as it reads and comes back the same', () {
    const text = 'Line ]one\nline \\two <3';
    final row = lyricSupplementRow(
      'translation',
      1000,
      encodeLyricTextTag(text),
    );
    expect(row, r'[x-translated:1000:Line ]one\nline \\two <3]');
    final tag = readLyricSupplementTag(row)!;
    expect((tag.kind, tag.key, tag.text), ('translation', 1000, text));
    expect(encodeLyricTextTag('a\r\nb\rc'), r'a\nb\nc');
  });

  test('word timing is enhanced LRC with its gaps and last end', () {
    final words = [
      _word('Hel', 1000, 1300),
      _word('lo <you>', 1300, 1600),
      _word('there', 1800, 2009),
    ];
    final value = encodeLyricWordsTag(words);
    expect(
      value,
      r'<00:01.00>Hel<00:01.30>lo \<you><00:01.60><00:01.80>there<00:02.009>',
    );
    final tag = readLyricSupplementTag(
      lyricSupplementRow('romaji-words', 1000, value),
    )!;
    expect(tag.kind, 'romaji-words');
    expect(_spans(tag.words), _spans(words));
  });

  test('a word without an end lasts until the next one starts', () {
    expect(_spans(decodeLyricWordsTag('<00:01.00>a <00:01.50>b')), [
      ('a ', 1000, 1500),
      ('b', 1500, 1500),
    ]);
  });

  test('damaged word timing is dropped', () {
    for (final value in [
      'lead<00:01.00>a',
      '<00:01.00><00:01.50>a',
      '<00:02.00>a<00:01.00>b',
      '<00:01.00>a<00:01.50>  <00:02.00>b',
      '<00:01.00>a<00:01.50><00:01.60><00:02.00>b',
    ]) {
      expect(decodeLyricWordsTag(value), isEmpty, reason: value);
    }
    expect(encodeLyricWordsTag([_word('a', 2000, 1000)]), isEmpty);
    expect(encodeLyricWordsTag([_word(' ', 0, 1000)]), isEmpty);
  });

  test('base64 tags of earlier versions are still read', () {
    String b64(String text) => base64.encode(utf8.encode(text));
    final text = readLyricSupplementTag('[x-romaji:1000:${b64(' Reading ')}]');
    expect((text!.kind, text.text), ('romaji', 'Reading'));
    final words = readLyricSupplementTag(
      '[x-translation-words:1000:${b64(jsonEncode([
        {'text': 'Hi', 'startTimeMs': 1000, 'endTimeMs': 1400},
      ]))}]',
    );
    expect(words!.kind, 'translation-words');
    expect(_spans(words.words), [('Hi', 1000, 1400)]);
    expect(readLyricSupplementTag('[x-translation:1000:%%%]')!.text, isNull);
  });

  test('other rows are not supplement tags', () {
    expect(readLyricSupplementTag('[00:01.00]Line'), isNull);
    expect(readLyricSupplementTag('[ti:Title]'), isNull);
    expect(readLyricSupplementTag('[x-translated:bad:Text]'), isNull);
  });
}
