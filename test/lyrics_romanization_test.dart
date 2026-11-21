import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/lyrics_romanization.dart';
import 'package:mornye/services/romanization/cyrillic.dart';
import 'package:mornye/services/romanization/pinyin.dart';
import 'package:mornye/services/romanization/text_romanizer.dart';
import 'package:mornye/utils/lyrics_parser.dart';

// Every sample line below was written for these tests.

final _pinyin = PinyinData.decode(File(pinyinDataAsset).readAsBytesSync());

/// Each line of [song] romanized with what the whole song tells.
List<String?> _romanize(List<String> song, {PinyinData? pinyin}) {
  final romanizer = TextRomanizer.forTexts(song, pinyin: pinyin);
  return [for (final line in song) romanizer.romanize(line)?.join().trim()];
}

ParsedLyrics _lyrics(List<LyricLine> lines) => ParsedLyrics(
  synced: true,
  wordSynced: lines.any((line) => line.hasWordTiming),
  lines: lines,
  plainText: lines.map((line) => line.text).join('\n'),
);

LyricLine _line(int second, String text, {List<String> words = const []}) =>
    LyricLine(
      time: Duration(seconds: second),
      text: text,
      words: [
        for (var i = 0; i < words.length; i++)
          LyricWord(
            time: Duration(milliseconds: second * 1000 + i * 200),
            text: words[i],
          ),
      ],
    );

void main() {
  group('Korean', () {
    test('follows the Revised Romanization and its sound changes', () {
      expect(
        _romanize([
          '사랑해',
          '좋아',
          '같이 가자',
          '먹어',
          '국물',
          '신라',
          '설날',
          '종로',
          '좋다',
          '않아',
          '없어',
          '읽어요',
          '합니다',
          '닫히다',
          '축하해',
        ]),
        [
          'saranghae',
          'joa',
          'gachi gaja',
          'meogeo',
          'gungmul',
          'silla',
          'seollal',
          'jongno',
          'jota',
          'ana',
          'eopseo',
          'ilgeoyo',
          'hamnida',
          'dachida',
          'chukahae',
        ],
      );
    });

    test('keeps English words and lone jamo', () {
      expect(_romanize(['오늘 밤 baby', 'ㅋㅋ']), ['oneul bam baby', 'kk']);
    });
  });

  group('Cyrillic', () {
    test('guesses the language from its letters', () {
      expect(
        guessCyrillicLanguage('Привіт, як справи'),
        CyrillicLanguage.ukrainian,
      );
      expect(
        guessCyrillicLanguage('Ён ішоў дадому'),
        CyrillicLanguage.belarusian,
      );
      expect(guessCyrillicLanguage('Љубав и ђаци'), CyrillicLanguage.serbian);
      expect(
        guessCyrillicLanguage('Ѓавол и ќерка'),
        CyrillicLanguage.macedonian,
      );
      expect(guessCyrillicLanguage('Жаңы күн'), CyrillicLanguage.kyrgyz);
      expect(
        guessCyrillicLanguage('България и пътят към морето'),
        CyrillicLanguage.bulgarian,
      );
      expect(guessCyrillicLanguage('Мы идём домой'), CyrillicLanguage.russian);
    });

    test('Russian', () {
      expect(_romanize(['Я тебя люблю', 'Ещё жизнь', 'ЖИЗНЬ', 'Чёрный']), [
        'Ya tebya lyublyu',
        'Yeshcho zhizn',
        'ZHIZN',
        'Chornyy',
      ]);
    });

    test('Ukrainian', () {
      expect(
        _romanize(['Привіт, як справи', 'Їжак', "П'ять", 'Згода', 'Україна']),
        ['Pryvit, yak spravy', 'Yizhak', 'Piat', 'Zghoda', 'Ukraina'],
      );
    });

    test('Belarusian', () {
      expect(_romanize(['Ён ішоў дадому', 'Беларусь']), [
        'Yon ishow dadomu',
        'Bielarus',
      ]);
    });

    test('Bulgarian', () {
      expect(_romanize(['България', 'пътят', 'Щастие']), [
        'Balgaria',
        'patyat',
        'Shtastie',
      ]);
    });

    test('Serbian', () {
      expect(_romanize(['Љубав и ђаци', 'Џеп', 'Хвала']), [
        'Ljubav i đaci',
        'Džep',
        'Hvala',
      ]);
    });

    test('Macedonian', () {
      expect(_romanize(['Ѓавол и ќерка', 'Џеб', 'Ѕвезда']), [
        'Gjavol i kjerka',
        'Djeb',
        'Dzvezda',
      ]);
    });

    test('Kyrgyz', () {
      expect(_romanize(['Жаңы күн', 'Өмүр']), ['Jangy kün', 'Ömür']);
    });
  });

  group('Hindi', () {
    test('drops the vowels speech drops and spells long vowels', () {
      expect(
        _romanize([
          'दिल',
          'प्यार',
          'मेरा',
          'ज़िंदगी',
          'समझना',
          'धड़कन',
          'तुम हो',
          'मैं',
          'नहीं',
          'कमल',
          'अंबर',
          'जीवन',
        ]),
        [
          'dil',
          'pyaar',
          'mera',
          'zindagi',
          'samajhna',
          'dhadkan',
          'tum ho',
          'main',
          'nahin',
          'kamal',
          'ambar',
          'jeevan',
        ],
      );
    });
  });

  group('Punjabi', () {
    test('doubles after addak and nasalizes with tippi', () {
      expect(_romanize(['ਸੱਚਾ', 'ਕੁੜੀ', 'ਮੁੰਡਾ', 'ਦਿਲ', 'ਗੱਲ', 'ਪ੍ਰੀਤ']), [
        'saccha',
        'kudi',
        'munda',
        'dil',
        'gall',
        'preet',
      ]);
    });
  });

  group('Japanese', () {
    test('romanizes kana by Hepburn', () {
      expect(
        _romanize([
          'ありがとう',
          'きょう',
          'ちょっと',
          'まっちゃ',
          'しんや',
          'コーヒー',
          'ファン',
          'ねぇ',
          'ティー',
          'ジェット',
        ]),
        [
          'arigatou',
          'kyou',
          'chotto',
          'matcha',
          "shin'ya",
          'koohii',
          'fan',
          'nee',
          'tii',
          'jetto',
        ],
      );
    });

    test('leaves lines with kanji alone, even with the pinyin loaded', () {
      expect(_romanize(['きみのなまえ', '君の名前'], pinyin: _pinyin), [
        'kiminonamae',
        null,
      ]);
    });
  });

  group('Chinese', () {
    test('reads polyphones by their phrase', () {
      expect(
        _romanize([
          '我爱你',
          '长大了',
          '头发很长',
          '银行',
          '音乐',
          '跑得快',
          '得到',
          '你好，世界',
        ], pinyin: _pinyin),
        [
          'wǒ ài nǐ',
          'zhǎng dà le',
          'tóu fà hěn cháng',
          'yín háng',
          'yīn yuè',
          'pǎo de kuài',
          'dé dào',
          'nǐ hǎo, shì jiè',
        ],
      );
    });

    test('reads traditional characters and spaces Latin words', () {
      expect(_romanize(['頭髮很長', 'I love 你'], pinyin: _pinyin), [
        'tóu fà hěn cháng',
        'I love nǐ',
      ]);
    });

    test('waits for the data', () {
      expect(_romanize(['我爱你']), [null]);
    });
  });

  group('lyrics', () {
    test('keeps word timing, with sounds that run across words', () {
      final lyrics = _lyrics([
        _line(1, '먹어', words: ['먹', '어']),
        _line(2, '我爱你', words: ['我', '爱', '你']),
      ]);
      final romanized = lyricsWithOfflineRomanization(lyrics, pinyin: _pinyin);
      final korean = romanized.lines[0];
      expect(korean.romanization, 'meogeo');
      expect(korean.romanizationWords.map((word) => word.text), ['meo', 'geo']);
      expect(korean.romanizationWords.map((word) => word.time), [
        for (final word in lyrics.lines[0].words) word.time,
      ]);
      expect(romanized.lines[1].romanizationWords.map((word) => word.text), [
        'wǒ ',
        'ài ',
        'nǐ',
      ]);
    });

    test('keeps a provider romanization and plain lyrics', () {
      final lyrics = _lyrics([
        const LyricLine(
          time: Duration(seconds: 1),
          text: '사랑해',
          romanization: 'salanghae',
        ),
        _line(2, 'Hello'),
      ]);
      expect(lyricsWithOfflineRomanization(lyrics), same(lyrics));
      const plain = ParsedLyrics(
        synced: false,
        wordSynced: false,
        lines: [],
        plainText: '사랑해\n\n좋아',
      );
      final romanized = lyricsWithOfflineRomanization(plain);
      expect(romanized.lines.map((line) => line.romanization), [
        'saranghae',
        'joa',
      ]);
      expect(
        lyricsWithRomanizedMainLines(romanized).plainText,
        'saranghae\n\njoa',
      );
    });

    test('leaves to the AI only what it cannot romanize', () {
      expect(
        linesNeedingAiRomanization(_lyrics([_line(1, '사랑해'), _line(2, '我爱你')])),
        isEmpty,
      );
      expect(
        linesNeedingAiRomanization(
          _lyrics([_line(1, 'きみのなまえ'), _line(2, '君の名前')]),
        ).map((line) => line.text),
        ['君の名前'],
      );
      expect(
        linesNeedingAiRomanization(
          _lyrics([_line(1, 'สวัสดี')]),
        ).map((line) => line.text),
        ['สวัสดี'],
      );
      expect(lyricsNeedPinyin(_lyrics([_line(1, '我爱你')])), isTrue);
      expect(lyricsNeedPinyin(_lyrics([_line(1, '君の名前は')])), isFalse);
    });

    test('shows the romanization as the main line', () {
      final romanized = lyricsWithOfflineRomanization(
        _lyrics([
          _line(1, '먹어', words: ['먹', '어']),
          _line(2, '좋아'),
        ]),
      );
      final swapped = lyricsWithRomanizedMainLines(romanized);
      expect(swapped.lines.map((line) => line.text), ['meogeo', 'joa']);
      expect(swapped.lines.map((line) => line.romanization), ['먹어', '좋아']);
      expect(swapped.lines[0].words.map((word) => word.text), ['meo', 'geo']);
      expect(swapped.lines[0].romanizationWords.map((word) => word.text), [
        '먹',
        '어',
      ]);
    });

    test('keeps the original main on a word-timed line with untimed '
        'romanization', () {
      final lyrics = _lyrics([
        LyricLine(
          time: Duration.zero,
          text: '먹어',
          words: const [
            LyricWord(time: Duration.zero, text: '먹'),
            LyricWord(time: Duration(milliseconds: 200), text: '어'),
          ],
          romanization: 'meogeo',
        ),
      ]);
      expect(lyricsWithRomanizedMainLines(lyrics), same(lyrics));
    });
  });

  group('the reader language', () {
    test('maps to the scripts it reads', () {
      for (final code in ['ru', 'uk', 'be', 'bg', 'sr', 'mk', 'ky', 'kk']) {
        expect(scriptsReadIn(code), {LyricsScript.cyrillic}, reason: code);
      }
      expect(scriptsReadIn('zh'), {LyricsScript.han});
      expect(scriptsReadIn('ja'), {LyricsScript.kana, LyricsScript.han});
      expect(scriptsReadIn('ko'), {LyricsScript.hangul});
      expect(scriptsReadIn('hi'), {LyricsScript.devanagari});
      expect(scriptsReadIn('pa'), {LyricsScript.gurmukhi});
      expect(scriptsReadIn('sr', scriptCode: 'Latn'), isEmpty);
      expect(scriptsReadIn('pa', scriptCode: 'Arab'), isEmpty);
      expect(scriptsReadIn('en'), isEmpty);
      expect(scriptsReadIn('id'), isEmpty);
      for (final locale in const [
        Locale('zh'),
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
      ]) {
        expect(lyricsReaderScripts(locale), {LyricsScript.han});
      }
    });

    test('keeps its script as written and romanizes the others', () {
      final lyrics = _lyrics([
        _line(1, '사랑해'),
        _line(2, 'Я тебя люблю'),
        _line(3, '我爱你'),
      ]);
      final romanized = lyricsWithOfflineRomanization(
        lyrics,
        pinyin: _pinyin,
        readerScripts: scriptsReadIn('ko'),
      );
      expect(romanized.lines.map((line) => line.romanization), [
        null,
        'Ya tebya lyublyu',
        'wǒ ài nǐ',
      ]);
      expect(
        lyricsNeedPinyin(lyrics, readerScripts: scriptsReadIn('zh')),
        isFalse,
      );
    });

    test('sends none of its lines to the AI', () {
      final lyrics = _lyrics([
        _line(1, 'きみのなまえ'),
        _line(2, '君の名前'),
        _line(3, 'สวัสดี'),
        _line(4, '사랑해'),
      ]);
      final japanese = scriptsReadIn('ja');
      expect(
        linesNeedingAiRomanization(
          lyrics,
          readerScripts: japanese,
        ).map((line) => line.text),
        ['สวัสดี'],
      );
      expect(
        lyricsWithOfflineRomanization(
          lyrics,
          readerScripts: japanese,
        ).lines.map((line) => line.romanization),
        [null, null, null, 'saranghae'],
      );
    });

    test('drops what an AI translation romanized in its script', () {
      final original = _lyrics([
        _line(1, '君の名前'),
        _line(2, 'สวัสดี'),
        const LyricLine(
          time: Duration(seconds: 3),
          text: 'きみ',
          romanization: 'kimi',
        ),
      ]);
      final translated = _lyrics([
        for (final (line, romanization) in [
          (original.lines[0], 'kimi no namae'),
          (original.lines[1], 'sawatdi'),
          (original.lines[2], 'kimi'),
        ])
          line.withTranslation('x', romanization: romanization),
      ]);
      final shown = lyricsWithoutReaderRomanization(
        original,
        translated,
        scriptsReadIn('ja'),
      );
      expect(shown.lines.map((line) => line.romanization), [
        null,
        'sawatdi',
        'kimi',
      ]);
      expect(shown.lines.map((line) => line.translation), ['x', 'x', 'x']);
      expect(
        lyricsWithoutReaderRomanization(original, translated, const {}),
        same(translated),
      );
    });
  });

  group('settings', () {
    test('offline romanization starts as the AI switch was', () {
      expect(AppSettings.fromJson(const {}).lyricsRomanize, isTrue);
      expect(
        AppSettings.fromJson(const {'lyricsAiRomanize': false}).lyricsRomanize,
        isFalse,
      );
      expect(
        AppSettings.fromJson(const {
          'lyricsAiRomanize': false,
          'lyricsRomanize': true,
        }).lyricsRomanize,
        isTrue,
      );
      expect(AppSettings.fromJson(const {}).lyricsRomanizedMainLine, isFalse);
    });
  });
}
