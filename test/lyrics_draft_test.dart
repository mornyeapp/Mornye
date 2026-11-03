import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/lyrics_parser.dart';

String _b64(String value) => base64.encode(utf8.encode(value));

void main() {
  test('unchanged LRC keeps its tags, word timing and translations', () {
    final raw = [
      '[ti:Example]',
      '[ar:Artist]',
      '[00:01.00]v1: <00:01.00>First <00:01.50>line',
      '[x-translation:1000:${_b64('Primera')}]',
      '[bg:<00:01.20>(ooh)]',
      '[00:04.25]Second line',
      'Written by: Someone',
    ].join('\n');
    final draft = LyricsDraft.parse(raw);
    expect(draft.header, ['[ti:Example]', '[ar:Artist]']);
    expect(draft.footer, ['Written by: Someone']);
    expect(draft.lines.map((line) => line.text), ['First line', 'Second line']);
    expect(draft.lines.first.voice, 'v1:');
    expect(draft.toLrc(), raw);
  });

  test('a moved line carries its word timing and translation key', () {
    final draft = LyricsDraft.parse(
      [
        '[00:01.00]<00:01.00>First <00:01.50>line',
        '[x-translation:1000:${_b64('Primera')}]',
        '[00:04.00]Second',
      ].join('\n'),
    );
    final moved = LyricsDraft(
      lines: [
        draft.lines.first.copyWith(time: const Duration(milliseconds: 2000)),
        draft.lines.last,
      ],
    );
    expect(
      moved.toLrc(),
      [
        '[00:02.00]<00:02.00>First <00:02.50>line',
        '[x-translation:2000:${_b64('Primera')}]',
        '[00:04.00]Second',
      ].join('\n'),
    );
    final parsed = LyricsParser.parse(moved.toLrc());
    expect(parsed.lines.first.translation, 'Primera');
    expect(
      parsed.lines.first.words.last.time,
      const Duration(seconds: 2, milliseconds: 500),
    );
  });

  test('changed text drops the word timing it no longer matches', () {
    final draft = LyricsDraft.parse('[00:01.00]<00:01.00>Frist <00:01.50>line');
    final edited = LyricsDraft(
      lines: [draft.lines.single.copyWith(text: 'First line')],
    );
    expect(edited.toLrc(), '[00:01.00]First line');
  });

  test('the file offset moves into the times', () {
    final draft = LyricsDraft.parse(
      [
        '[offset:500]',
        '[00:02.00]<00:02.00>Line',
        '[x-translation:2000:${_b64('Linea')}]',
      ].join('\n'),
    );
    expect(draft.lines.single.time, const Duration(milliseconds: 1500));
    expect(
      draft.toLrc(),
      [
        '[00:01.50]<00:01.50>Line',
        '[x-translation:1500:${_b64('Linea')}]',
      ].join('\n'),
    );
  });

  test('plain lyrics stay plain until a line gets a time', () {
    final draft = LyricsDraft.parse('First\n\nSecond');
    expect(draft.synced, isFalse);
    expect(draft.lines.map((line) => line.time), [null, null]);
    expect(draft.toLrc(), 'First\nSecond');
    final timed = LyricsDraft(
      lines: [
        draft.lines.first.copyWith(time: const Duration(milliseconds: 12340)),
        draft.lines.last,
      ],
    );
    expect(timed.toLrc(), '[00:12.34]First\nSecond');
  });

  test('a repeated chorus becomes one line per time', () {
    final draft = LyricsDraft.parse('[00:01.00][00:09.00]Chorus');
    expect(draft.lines.map((line) => line.time), const [
      Duration(seconds: 1),
      Duration(seconds: 9),
    ]);
    expect(draft.toLrc(), '[00:01.00]Chorus\n[00:09.00]Chorus');
  });

  test('TTML is not editable', () {
    expect(
      LyricsDraft.canEdit('<tt xmlns="http://www.w3.org/ns/ttml">'),
      isFalse,
    );
    expect(LyricsDraft.canEdit('[00:01.00]Line'), isTrue);
    expect(LyricsDraft.canEdit(''), isTrue);
  });

  test('times keep milliseconds that centiseconds would round', () {
    expect(formatLyricsTime(const Duration(milliseconds: 61230)), '01:01.23');
    expect(formatLyricsTime(const Duration(milliseconds: 61234)), '01:01.234');
    expect(formatLyricsTime(const Duration(minutes: 125)), '125:00.00');
  });
}
