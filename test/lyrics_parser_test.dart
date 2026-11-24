import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyrics_parser.dart';

String _tag(String kind, int time, String text) =>
    '[x-$kind:$time:${base64.encode(utf8.encode(text))}]';

void main() {
  test('zero starts retain genuine line, word and TTML timing', () {
    for (final raw in [
      '[00:00.00]First line\n[00:02.00]Second line',
      '[00:00.00]<00:00.00>First <00:01.00>line<00:02.00>',
      '<tt><body><p begin="0s" end="2s">First line</p></body></tt>',
    ]) {
      final lyrics = LyricsParser.parse(raw);
      expect(lyrics.synced, isTrue);
      expect(lyrics.lines.first.time, Duration.zero);
      expect(lyrics.plainText, contains('First line'));
    }
  });

  test('classification uses source timing before clamping a valid offset', () {
    final lyrics = LyricsParser.parse(
      '[offset:5000]\n[00:00.00]First line\n[00:02.00]Second line',
    );
    expect(lyrics.synced, isTrue);
    expect(lyrics.lines.map((line) => line.time), [
      Duration.zero,
      Duration.zero,
    ]);
  });

  test('all eLRC voices retain timing and supplements without visible IDs', () {
    final lyrics = LyricsParser.parse('''
[offset:100]
${_tag('romaji', 2000, 'Second reading')}
${_tag('translation', 2000, 'Second translation')}
[00:01.00]v1:<00:01.00>First<00:03.00>
[00:02.00]<00:02.00> V2: Second<00:04.00>
[00:04.00]v3:Third
[00:06.00]v12:Twelfth
[00:08.00]The v2: label stays inside a sentence
''');
    expect(lyrics.lines.map((line) => line.voice?.id), [
      'v1',
      'v2',
      'v3',
      'v12',
      null,
    ]);
    expect(lyrics.lines.map((line) => line.voice?.index), [0, 1, 2, 11, null]);
    final second = lyrics.lines[1];
    expect(second.text, 'Second');
    expect(second.words.single.text, 'Second');
    expect(second.words.single.time.inMilliseconds, 1900);
    expect(second.end?.inMilliseconds, 3900);
    expect(second.romanization, 'Second reading');
    expect(second.translation, 'Second translation');
    expect(lyrics.lines.last.text, 'The v2: label stays inside a sentence');
  });

  test('background eLRC retains the parent voice and its own word times', () {
    final lyrics = LyricsParser.parse('''
[00:01.00]v2:<00:01.00>Main<00:05.00>
[bg:<00:02.00>Backing<00:04.00>]
''');
    expect(lyrics.lines.map((line) => line.text), ['Main', 'Backing']);
    final backing = lyrics.lines.last;
    expect(backing.voice?.id, 'v2');
    expect(backing.isBackground, isTrue);
    expect(backing.time.inMilliseconds, 2000);
    expect(backing.end?.inMilliseconds, 4000);
    expect(backing.vocalGroup, lyrics.lines.first.vocalGroup);
  });

  test('V3 is a collaboration even without TTML group metadata', () {
    for (final source in [
      '[00:01.00]V1:Lead\n[00:02.00]V3:Together\n[00:03.00]V2:Guest',
      '<tt xmlns:m="http://www.w3.org/ns/ttml#metadata"><body>'
          '<p begin="1s" m:agent="v1">Lead</p>'
          '<p begin="2s" m:agent="v3">Together</p>'
          '<p begin="3s" m:agent="v2">Guest</p></body></tt>',
    ]) {
      final lyrics = LyricsParser.parse(source);
      expect(lyrics.lines[1].voice?.isGroup, isTrue);
      expect(lyrics.lines[2].voice?.isGroup, isFalse);
    }
  });

  test(
    'backing groups survive sorting, offsets and repeated backing parts',
    () {
      final lyrics = LyricsParser.parse('''
[offset:100]
[00:01.00]v2:<00:01.00>Lead<00:06.00>
[bg:<00:04.00>Echo<00:05.00>]
[bg:[00:05.00]<00:05.00>Again<00:06.00>]
[00:03.00]v1:<00:03.00>Other lead<00:06.00>
''');
      expect(lyrics.lines.map((line) => line.text), [
        'Lead',
        'Other lead',
        'Echo',
        'Again',
      ]);
      final lead = lyrics.lines.first;
      expect(lyrics.lines[1].vocalGroup, isNot(lead.vocalGroup));
      for (final backing in lyrics.lines.skip(2)) {
        expect(backing.vocalGroup, lead.vocalGroup);
        expect(backing.voice?.id, 'v2');
        expect(backing.isBackground, isTrue);
      }
      expect(lyrics.lines[2].time.inMilliseconds, 3900);
    },
  );

  test('TTML resolves inherited voices and explicit groups by namespace', () {
    final lyrics = LyricsParser.parse('''
<t:tt xmlns:t="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata">
<t:head><t:metadata>
<m:agent xml:id="lead" type="person"/>
<m:agent xml:id="guest" type="person"/>
<m:agent xml:id="v3" type="group"/>
<m:agent xml:id="third" type="person"/>
</t:metadata></t:head>
<t:body><t:div m:agent="lead">
<t:p begin="1s" end="3s">Lead</t:p>
<t:p begin="3s" end="5s" m:agent="guest">Guest</t:p>
<t:p begin="5s" end="7s" m:agent="v3">Together</t:p>
<t:p begin="7s" end="9s" m:agent="third">Third</t:p>
</t:div></t:body></t:tt>
''');
    expect(lyrics.lines.map((line) => line.voice?.id), [
      'lead',
      'guest',
      'v3',
      'third',
    ]);
    expect(lyrics.lines.map((line) => line.voice?.index), [0, 1, 2, 2]);
    expect(lyrics.lines.map((line) => line.voice?.isGroup), [
      false,
      false,
      true,
      false,
    ]);
  });

  test(
    'TTML splits span voices and backing parts without adding syllable gaps',
    () {
      final lyrics = LyricsParser.parse('''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata">
<head><metadata><m:agent xml:id="v1" type="person"/><m:agent xml:id="v2" type="person"/></metadata></head>
<body><div><p begin="1s" end="5s"><span m:agent="v1"><span begin="1s" end="2s">日本</span><span begin="2s" end="3s">語</span></span><span m:agent="v2" begin="2s" end="4s">Reply</span><span m:agent="v1" m:role="x-bg" begin="2s" end="3s">Echo</span></p></div></body></tt>
''');
      expect(lyrics.lines.map((line) => line.text), ['日本語', 'Reply', 'Echo']);
      expect(lyrics.lines.first.words.map((word) => word.text), ['日本', '語']);
      expect(lyrics.lines.map((line) => line.time.inSeconds), [1, 2, 2]);
      expect(lyrics.lines.map((line) => line.end?.inSeconds), [3, 4, 3]);
      expect(lyrics.lines.last.isBackground, isTrue);
      expect(lyrics.lines.last.voice?.id, 'v1');
      expect(lyrics.lines.last.vocalGroup, lyrics.lines.first.vocalGroup);
      expect(lyrics.lines[1].vocalGroup, isNot(lyrics.lines.first.vocalGroup));
    },
  );

  test('TTML partial word timing never loses untimed text', () {
    final line = LyricsParser.parse('''
<tt><body><p begin="1s" end="5s">Untimed <span begin="2s" end="3s">timed</span> ending</p></body></tt>
''').lines.single;
    expect(line.text, 'Untimed timed ending');
    expect(line.words, isEmpty);
  });

  test(
    'writer tags and stored provider attribution remain separate from lyric rows',
    () {
      final lyrics = LyricsParser.parse('''
[au:Example Writer, Another Writer]
[by:SpotiFLAC-Mobile via Example Lyrics API (source: upstream)]
[00:01.00]First line
[00:04.00]Last line
''');
      expect(lyrics.writers, 'Example Writer, Another Writer');
      expect(lyrics.provider, 'Example Lyrics');
      expect(lyrics.lines, hasLength(2));
      expect(lyrics.lines.last.time, const Duration(seconds: 4));
    },
  );

  test(
    'an LRC uploader or performing artist is not invented as the songwriter or provider',
    () {
      final lyrics = LyricsParser.parse(
        '[ar:Performer]\n[by:Uploader]\n[00:01.00]Line',
      );
      expect(lyrics.writers, isNull);
      expect(lyrics.provider, isNull);
      expect(
        LyricsParser.parse(
          '[by:SpotiFLAC-Mobile (source: extension:example.lyrics)]\n[00:01]Line',
        ).provider,
        'example.lyrics',
      );
    },
  );

  test(
    'explicit ending credits become a footer rather than a seekable lyric',
    () {
      final lyrics = LyricsParser.parse(
        '[00:01]Last lyric\n[00:04]Written By: Example Writer',
      );
      expect(lyrics.lines.single.text, 'Last lyric');
      expect(lyrics.writers, 'Example Writer');
      expect(lyrics.plainText, 'Last lyric');
    },
  );

  test(
    'TTML songwriter metadata is retained without treating performers as writers',
    () {
      final lyrics = LyricsParser.parse('''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:meta="urn:example:metadata">
<head><metadata><meta:songwriters><meta:songwriter>Example Writer</meta:songwriter>
<meta:songwriter>Second Writer</meta:songwriter></meta:songwriters></metadata></head>
<body><div><p begin="00:01.00">Lyric</p></div></body></tt>
''');
      expect(lyrics.writers, 'Example Writer, Second Writer');
      expect(lyrics.lines.single.text, 'Lyric');
    },
  );

  test('word timing preserves spaces after closing timestamps', () {
    final lyrics = LyricsParser.parse(
      '[00:01.00]<00:01.00>First<00:01.50> '
      '<00:02.00>second<00:02.50> '
      '<00:03.00>line<00:04.00>',
    );
    final line = lyrics.lines.single;
    expect(line.text, 'First second line');
    expect(line.words.map((word) => word.text).join(), line.text);
    expect(line.words.map((word) => word.text), ['First ', 'second ', 'line']);
    expect(line.words.map((word) => word.time.inMilliseconds), [
      1000,
      2000,
      3000,
    ]);
    expect(line.words.map((word) => word.end?.inMilliseconds), [
      1500,
      2500,
      4000,
    ]);
  });

  test(
    'word separators preserve whitespace and the first closing timestamp',
    () {
      for (final separator in ['  ', '\t', '\u00a0']) {
        final line = LyricsParser.parse(
          '[00:01.00]<00:01.00>First<00:01.50>$separator'
          '<00:01.75> <00:02.00>second<00:04.00>',
        ).lines.single;
        expect(line.text, 'First$separator second');
        expect(line.words.map((word) => word.text).join(), line.text);
        expect(line.words, hasLength(2));
        expect(line.words.first.end, const Duration(milliseconds: 1500));
        expect(line.words.last.time, const Duration(seconds: 2));
        expect(line.words.last.end, const Duration(seconds: 4));
      }
    },
  );

  test(
    'adjacent Latin and CJK syllables keep their original word boundaries',
    () {
      final line = LyricsParser.parse(
        '[00:01.00]<00:01.00>To<00:01.50>gether<00:02.00> '
        '<00:03.00>日<00:04.00>本<00:05.00>語<00:06.00>',
      ).lines.single;
      expect(line.text, 'Together 日本語');
      expect(line.words.map((word) => word.text), [
        'To',
        'gether ',
        '日',
        '本',
        '語',
      ]);
      expect(line.words.map((word) => word.text).join(), line.text);
    },
  );

  test('retains all three texts, word ends and millisecond timing', () {
    final lyrics = LyricsParser.parse('''
${_tag('romaji', 1009, 'Romanized')}
${_tag('translation', 1009, 'English')}
[00:01.009]<00:01.009>First <00:01.307><00:02.003>second<00:02.497>
''');
    final line = lyrics.lines.single;
    expect(lyrics.wordSynced, isTrue);
    expect(line.text, 'First second');
    expect(line.romanization, 'Romanized');
    expect(line.translation, 'English');
    expect(line.time.inMilliseconds, 1009);
    expect(line.end?.inMilliseconds, 2497);
    expect(line.words.map((word) => word.end?.inMilliseconds), [1307, 2497]);
    expect(lyrics.plainText, 'First second');
  });

  test('matches legacy and rounded eLRC tags within ten milliseconds', () {
    final lyrics = LyricsParser.parse('''
${_tag('romaji', 1009, 'Rounded up')}
${_tag('translation', 2009, 'Truncated')}
${_tag('romaji', 2990, 'Boundary')}
${_tag('translation', 4011, 'Too far')}
[00:01.01]A
[00:02.00]B
[00:03.00]C
[00:04.00]D
''');
    expect(lyrics.lines[0].romanization, 'Rounded up');
    expect(lyrics.lines[1].translation, 'Truncated');
    expect(lyrics.lines[2].romanization, 'Boundary');
    expect(lyrics.lines[3].translation, isNull);
  });

  test(
    'romanization timing aligns with rounded lines and applies the offset',
    () {
      final words = [
        {'text': 'Ro', 'startTimeMs': 1009, 'endTimeMs': 1107},
        {'text': 'ma ', 'startTimeMs': 1107, 'endTimeMs': 1307},
        {'text': 'nized', 'startTimeMs': 2003, 'endTimeMs': 2497},
      ];
      final line = LyricsParser.parse('''
[offset:109]
${_tag('romaji-words', 1009, jsonEncode(words))}
${_tag('romaji', 1009, 'Roma nized')}
[00:01.01]Original
''').lines.single;
      expect(line.romanization, 'Roma nized');
      expect(line.romanizationWords.map((word) => word.text), [
        'Ro',
        'ma ',
        'nized',
      ]);
      expect(line.romanizationWords.first.time.inMilliseconds, 900);
      expect(line.romanizationWords[1].end?.inMilliseconds, 1198);
      expect(line.romanizationWords.last.time.inMilliseconds, 1894);
      expect(line.romanizationWords.last.end?.inMilliseconds, 2388);
    },
  );

  test(
    'missing or corrupt romanization timings preserve plain romanization',
    () {
      for (final timing in [
        'bad json',
        '{}',
        '[null]',
        '[{"text":"Other","startTimeMs":1000,"endTimeMs":1300}]',
        '[{"text":"Romanized","startTimeMs":1000,"endTimeMs":900}]',
      ]) {
        final line = LyricsParser.parse('''
${_tag('romaji', 1000, 'Romanized')}
${_tag('romaji-words', 1000, timing)}
[00:01.00]Original
''').lines.single;
        expect(line.romanization, 'Romanized');
        expect(line.romanizationWords, isEmpty);
      }
    },
  );

  test('exact matches win collisions and a tie goes to one earlier line', () {
    final lyrics = LyricsParser.parse('''
${_tag('romaji', 1009, 'Near')}
${_tag('romaji', 1010, 'Exact')}
${_tag('romaji', 1001, 'Further')}
${_tag('translation', 2005, 'Tie')}
[00:01.010]A
[00:02.000]B
[00:02.010]C
''');
    expect(lyrics.lines[0].romanization, 'Exact');
    expect(lyrics.lines[1].translation, 'Tie');
    expect(lyrics.lines[2].translation, isNull);
  });

  test('offset moves word ends and line end after supplement matching', () {
    final lyrics = LyricsParser.parse('''
[offset:109]
${_tag('romaji', 1009, 'Romanized')}
[00:01.009]<00:01.009>Word<00:01.307>
''');
    final line = lyrics.lines.single;
    expect(line.romanization, 'Romanized');
    expect(line.time.inMilliseconds, 900);
    expect(line.end?.inMilliseconds, 1198);
    expect(line.words.single.time.inMilliseconds, 900);
    expect(line.words.single.end?.inMilliseconds, 1198);
  });

  test('invalid optional tags do not appear or hide the original text', () {
    const tags = '''
[x-romaji:1000:%%%]
[x-romaji:1000:/w==]
[x-translation:bad:YQ==]
[x-translation:1000:]
''';
    expect(LyricsParser.parse(tags).isEmpty, isTrue);
    final lyrics = LyricsParser.parse('$tags[00:01.00]Original');
    expect(lyrics.lines.single.text, 'Original');
    expect(lyrics.lines.single.romanization, isNull);
    expect(lyrics.lines.single.translation, isNull);
    expect(lyrics.plainText, 'Original');
    expect(LyricsParser.parse('${tags}Plain text').plainText, 'Plain text');
  });

  test('supplement text safely retains Unicode and embedded newlines', () {
    const text = '日本語 ]\nSecond line';
    final lyrics = LyricsParser.parse(
      '${_tag('translation', 1000, text)}\n[00:01.00]Original',
    );
    expect(lyrics.lines.single.translation, text);
  });

  test('start-only eLRC retains its existing fallback timing', () {
    final line = LyricsParser.parse(
      '[00:01.00]<00:01.00>First <00:02.00>second',
    ).lines.single;
    expect(line.words.map((word) => word.end), [null, null]);
    expect(line.end, isNull);
  });

  test('empty tags retain the first valid end and reject backward ends', () {
    final line = LyricsParser.parse(
      '[00:01.00]<00:01.00>First <00:00.90><00:01.30><00:01.40>'
      '<00:02.00>second<00:02.00>',
    ).lines.single;
    expect(line.words.map((word) => word.end?.inMilliseconds), [1300, 2000]);
  });

  test('TTML span ends survive independently of the paragraph end', () {
    final line = LyricsParser.parse('''
<tt xmlns="http://www.w3.org/ns/ttml"><body><div>
<p begin="00:01.009" end="00:05.000">
<span begin="00:01.009" end="00:01.307">First</span>
<span begin="00:02.003" end="00:02.497">second</span>
</p></div></body></tt>
''').lines.single;
    expect(line.end?.inMilliseconds, 5000);
    expect(line.words.map((word) => word.end?.inMilliseconds), [1307, 2497]);
  });
}
