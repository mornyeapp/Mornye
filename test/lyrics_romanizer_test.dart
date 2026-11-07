import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lyrics_romanizer.dart';
import 'package:mornye/utils/lyrics_parser.dart';

ParsedLyrics _lyrics(List<LyricLine> lines) => ParsedLyrics(
  synced: true,
  wordSynced: false,
  lines: lines,
  plainText: lines.map((line) => line.text).join('\n'),
);

LyricLine _line(String text, {String? romanization}) => LyricLine(
  time: Duration.zero,
  text: text,
  romanization: romanization,
);

void main() {
  group('romanizeKorean', () {
    test('resolves final consonants against the next syllable', () {
      expect(LyricsRomanizer.romanizeKorean('안녕'), 'annyeong');
      expect(LyricsRomanizer.romanizeKorean('안녕하세요'), 'annyeonghaseyo');
      expect(LyricsRomanizer.romanizeKorean('사랑해'), 'saranghae');
      expect(LyricsRomanizer.romanizeKorean('한국어'), 'hangugeo');
    });

    test('keeps text outside Hangul as written', () {
      expect(LyricsRomanizer.romanizeKorean('Hello 사랑'), 'Hello sarang');
    });
  });

  group('script detection', () {
    test('kana marks Japanese, Han needs kana elsewhere in the lyrics', () {
      expect(LyricsRomanizer.isJapanese('こんにちは'), isTrue);
      expect(LyricsRomanizer.isJapanese('君の名は'), isTrue);
      expect(LyricsRomanizer.isJapanese('夜空'), isFalse);
      expect(
        LyricsRomanizer.isJapanese('夜空', entireLyricsHasKana: true),
        isTrue,
      );
    });

    test('detects Hangul', () {
      expect(LyricsRomanizer.isKorean('안녕'), isTrue);
      expect(LyricsRomanizer.isKorean('hello'), isFalse);
    });
  });

  group('fillMissing', () {
    test('adds pronunciation to Korean lines without one', () async {
      final filled = await LyricsRomanizer.fillMissing(
        _lyrics([_line('안녕'), _line('hello')]),
      );
      expect(filled.lines[0].romanization, 'Annyeong');
      expect(filled.lines[1].romanization, isNull);
      expect(filled.lines[0].text, '안녕');
    });

    test('keeps a romanization the provider already supplied', () async {
      final filled = await LyricsRomanizer.fillMissing(
        _lyrics([_line('안녕', romanization: 'Provider')]),
      );
      expect(filled.lines.single.romanization, 'Provider');
    });

    test('adds a pronunciation per line to lyrics without timing', () async {
      final filled = await LyricsRomanizer.fillMissing(
        const ParsedLyrics(
          synced: false,
          wordSynced: false,
          lines: [],
          plainText: '안녕\nhello\n사랑해',
        ),
      );
      expect(filled.plainPronunciations, ['Annyeong', null, 'Saranghae']);
      expect(filled.plainText, '안녕\nhello\n사랑해');
    });

    test('returns Latin-only lyrics untouched', () async {
      final lyrics = _lyrics([_line('hello')]);
      final filled = await LyricsRomanizer.fillMissing(lyrics);
      expect(identical(filled, lyrics), isTrue);
    });

    test('leaves Japanese lines alone where no reader is available', () async {
      final filled = await LyricsRomanizer.fillMissing(
        _lyrics([_line('こんにちは')]),
      );
      expect(filled.lines.single.romanization, isNull);
    });
  });
}
