import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';

Set<int> _active(List<LyricLine> lines, Duration position, int currentIndex) =>
    LyricTimelineIndex(lines).activeIndices(position, currentIndex);

/// Reference contract: hold the latest lead until the next lead starts,
/// including instrumental gaps. Earlier overlapping parts and backing vocals
/// keep their timed ends.
Set<int> _reference(
  List<LyricLine> lines,
  Duration position,
  int currentIndex,
) {
  final active = <int>{};
  var heldLead = -1;
  for (var i = 0; i <= currentIndex; i++) {
    final line = lines[i];
    if (!line.isBackground &&
        line.text.isNotEmpty &&
        (heldLead < 0 || line.time != lines[heldLead].time)) {
      heldLead = i;
    }
    final timedVoice =
        (i < currentIndex || line.voice != null || line.isBackground) &&
        line.text.isNotEmpty &&
        line.end != null;
    final simultaneous =
        line.text.isNotEmpty && line.time == lines[currentIndex].time;
    if (timedVoice ? line.end! > position : i == currentIndex || simultaneous) {
      active.add(i);
    }
  }
  if (heldLead >= 0) active.add(heldLead);
  return active;
}

void main() {
  test('indexed active voices match the timeline contract across seeks', () {
    final random = Random(412);
    final lines = List.generate(600, (index) {
      final start = Duration(milliseconds: index ~/ 3 * 400);
      return LyricLine(
        time: start,
        end: index % 4 == 0
            ? null
            : start + Duration(milliseconds: random.nextInt(10000)),
        text: index % 11 == 0 ? '' : 'Line $index',
        isBackground: index % 5 == 0,
        voice: index % 7 == 0 ? const LyricVoice(id: 'v2', index: 1) : null,
      );
    });
    final timeline = LyricTimelineIndex(lines);
    expect(timeline.starts, lines.map((line) => line.time));
    for (var sample = 0; sample < 2000; sample++) {
      final position = Duration(milliseconds: random.nextInt(100000) - 1000);
      final current = LyricsParser.activeIndex(lines, position);
      expect(
        timeline.activeIndices(position, current),
        _reference(lines, position, current),
        reason: 'Position $position, current line $current',
      );
    }
    expect(
      LyricTimelineIndex(const []).activeIndices(Duration.zero, -1),
      isEmpty,
    );
  });

  group('display ends for an unanchored final word', () {
    List<LyricLine> display(String lrc) => lyricsWithDisplayEnds(
      lyricsTimelineWithGaps(LyricsParser.parse(lrc).lines),
    );

    test('a close next line receives the remaining time', () {
      final lines = display('''
[00:01.00]<00:01.00>Hold <00:01.40>on
[00:04.50]<00:04.50>Next<00:05.00>
''');
      expect(lines.first.words.last.end, const Duration(milliseconds: 4500));
      expect(lines.first.end, const Duration(milliseconds: 4500));
    });

    test('a distant next line ends the word from the line pace', () {
      final lines = display('''
[00:01.00]<00:01.00>Hold <00:01.40>on
[00:20.00]<00:20.00>Next<00:21.00>
''');
      // 400 ms per word, held 2.5 times as long as a typical word.
      expect(lines.first.words.last.end, const Duration(milliseconds: 2400));
    });

    test('explicit word and line ends are kept', () {
      final lines = display('''
[00:01.00]<00:01.00>Hold <00:01.40>on<00:02.00>
[00:03.00]<00:03.00>Next<00:03.50>
''');
      expect(lines.first.words.last.end, const Duration(seconds: 2));
      expect(lines.first.end, const Duration(seconds: 2));
    });

    test('a blank timestamp bounds the final word', () {
      final lines = display('''
[00:01.00]<00:01.00>Hold <00:01.40>on
[00:03.00]
[00:12.00]<00:12.00>Next<00:13.00>
''');
      expect(lines[0].words.last.end, const Duration(seconds: 3));
      expect(lines[1].text, isEmpty);
    });
  });

  test('simultaneous untimed singers share highlighting and scroll focus', () {
    final lines = LyricsParser.parse('''
[00:01.00]v1:Lead
[00:01.00]v2:Guest
[00:05.00]Next
''').lines;
    final layout = LyricDisplayLayout(lines);
    expect(layout.focusForLine, [0, 0, 2]);
    for (final seconds in [1, 2, 4]) {
      final position = Duration(seconds: seconds);
      expect(
        _active(lines, position, LyricsParser.activeIndex(lines, position)),
        {0, 1},
      );
    }
    expect(_active(lines, const Duration(seconds: 5), 2), {2});
  });

  test(
    'simultaneous timed singers hold the primary and respect reply ends',
    () {
      final lines = LyricsParser.parse('''
[00:01.00]v1:<00:01.00>Lead<00:05.00>
[00:01.00]v2:<00:01.00>Guest<00:03.00>
[00:06.00]Next
''').lines;
      expect(LyricDisplayLayout(lines).focusForLine, [0, 0, 2]);
      expect(_active(lines, const Duration(seconds: 2), 1), {0, 1});
      expect(_active(lines, const Duration(seconds: 4), 1), {0});
      expect(_active(lines, const Duration(seconds: 5), 1), {0});
    },
  );

  test('backing stays under its lead without changing the timing order', () {
    final lines = LyricsParser.parse('''
[00:01.00]v1:<00:01.00>Lead<00:06.00>
[bg:<00:04.00>Echo<00:06.00>]
[bg:<00:05.00>Again<00:06.00>]
[00:03.00]v2:<00:03.00>Guest<00:06.00>
''').lines;
    final layout = LyricDisplayLayout(lines);
    expect(lines.map((line) => line.text), ['Lead', 'Guest', 'Echo', 'Again']);
    expect(layout.lineOrder.map((i) => lines[i].text), [
      'Lead',
      'Echo',
      'Again',
      'Guest',
    ]);
    expect(layout.rowForLine, [0, 3, 1, 2]);
    expect(layout.leadForLine, [0, 1, 0, 0]);
    expect(layout.focusForLine, [0, 1, 1, 1]);
    expect(_active(lines, const Duration(seconds: 5), 3), {0, 1, 2, 3});
  });

  test('background onset keeps focus on the lead and gaps remain separate', () {
    final lines = lyricsTimelineWithGaps(
      LyricsParser.parse('''
[00:05.00]v2:<00:05.00>Lead<00:10.00>
[bg:<00:06.00>Echo<00:11.00>]
[00:15.00]Next
''').lines,
    );
    final layout = LyricDisplayLayout(lines);
    expect(lines.map((line) => line.text), ['', 'Lead', 'Echo', '', 'Next']);
    expect(layout.lineOrder, [0, 1, 2, 3, 4]);
    expect(layout.focusForLine, [0, 1, 1, 3, 4]);
    expect(lines[3].time, const Duration(seconds: 11));
  });

  test(
    'a backing pickup can start before the lead without losing its parent',
    () {
      final lines = LyricsParser.parse('''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata">
<body><p begin="1s" end="6s" m:agent="v2"><span m:role="x-bg" begin="1s" end="5s">Pickup</span><span begin="2s" end="6s">Lead</span></p></body></tt>
''').lines;
      final layout = LyricDisplayLayout(lines);
      expect(lines.map((line) => line.text), ['Pickup', 'Lead']);
      expect(layout.lineOrder, [1, 0]);
      expect(layout.focusForLine, [1, 1]);
    },
  );

  test(
    'backing vocals do not dim an unlabelled lead that is still singing',
    () {
      final lines = LyricsParser.parse('''
[00:01.00]<00:01.00>Main<00:05.00>
[bg:<00:02.00>Echo<00:03.00>]
''').lines;
      expect(_active(lines, const Duration(seconds: 2), 1), {0, 1});
      expect(_active(lines, const Duration(seconds: 4), 1), {0});
    },
  );

  test('overlapping singers retain earlier ends and hold the current lead', () {
    final lines = LyricsParser.parse('''
[00:01.00]v1:<00:01.00>Lead<00:05.00>
[00:02.00]v2:<00:02.00>Guest<00:04.00>
[00:06.00]v3:Third
''').lines;
    Set<int> active(int seconds) {
      final position = Duration(seconds: seconds);
      return _active(
        lines,
        position,
        LyricsParser.activeIndex(lines, position),
      );
    }

    expect(active(0), isEmpty);
    expect(active(1), {0});
    expect(active(3), {0, 1});
    expect(active(4), {0, 1});
    expect(active(5), {1});
    expect(active(6), {2});
    expect(active(3), {0, 1});
    expect(active(1), {0});
  });

  for (final timed in [false, true]) {
    test('holds the last vocal through a countdown and seeks ($timed)', () {
      final lines = lyricsTimelineWithGaps(
        LyricsParser.parse(
          timed
              ? '[00:01.00]v1:<00:01.00>Held<00:02.00>\n'
                    '[00:07.00]v2:<00:07.00>Next<00:08.00>'
              : '[00:01.00]Held\n[00:02.00]\n[00:07.00]Next',
        ).lines,
      );
      Set<int> active(int milliseconds) {
        final position = Duration(milliseconds: milliseconds);
        return _active(
          lines,
          position,
          LyricsParser.activeIndex(lines, position),
        );
      }

      expect(lines.map((line) => line.text), ['Held', '', 'Next']);
      expect(active(0), isEmpty);
      expect(active(1000), {0});
      expect(active(2000), {0, 1});
      expect(active(6999), {0, 1});
      expect(active(7000), {2});
      expect(active(8000), {2});
      expect(active(6999), {0, 1});
      expect(active(1000), {0});
      expect(active(0), isEmpty);
    });
  }

  test('an ended backing part cannot replace the held lead', () {
    final lines = lyricsTimelineWithGaps(
      LyricsParser.parse('''
[00:01.00]v1:<00:01.00>Lead<00:02.00>
[bg:<00:03.00>Echo<00:04.00>]
[00:07.00]v2:<00:07.00>Next<00:08.00>
''').lines,
    );
    expect(lines.map((line) => line.text), ['Lead', 'Echo', '', 'Next']);
    expect(_active(lines, const Duration(seconds: 3), 1), {0, 1});
    expect(_active(lines, const Duration(seconds: 5), 2), {0, 2});
    expect(_active(lines, const Duration(seconds: 7), 3), {3});
  });

  List<(int, int)> gaps(String text) =>
      lyricsTimelineWithGaps(LyricsParser.parse(text).lines)
          .where((line) => line.text.isEmpty)
          .map((line) => (line.time.inMilliseconds, line.end!.inMilliseconds))
          .toList();

  test('intro and explicit LRC breaks count down, never the outro', () {
    const text = '''
[00:00.00]
[00:09.00]First
[00:12.00]
[00:14.00]
[00:21.00]Second
[00:25.00]
[00:30.00]
''';
    expect(gaps(text), [(0, 9000), (12000, 21000)]);
    expect(
      lyricsTimelineWithGaps(LyricsParser.parse(text).lines).last.text,
      'Second',
    );
  });

  test('TTML line ends identify breaks without empty timestamps', () {
    expect(
      gaps('''
<tt><body><div>
<p begin="9s" end="12s">First</p>
<p begin="21s" end="24s">Second</p>
<p begin="25s" end="28s">Third</p>
</div></body></tt>
'''),
      [(0, 9000), (12000, 21000)],
    );
  });

  test('enhanced LRC word ends retain held vocals before a break', () {
    expect(
      gaps('''
[00:00.00]<00:00.00>Held<00:16.00>
[00:20.00]<00:20.00>Last<00:24.00>
'''),
      [(16000, 20000)],
    );
  });

  test('overlapping lines cannot start a countdown during a held vocal', () {
    expect(
      gaps('''
<tt><body><div>
<p begin="0s" end="16s">Held</p>
<p begin="8s" end="10s">Backing vocal</p>
<p begin="20s" end="24s">Last</p>
</div></body></tt>
'''),
      [(16000, 20000)],
    );
  });

  test('plain LRC does not invent an end time from distance between lines', () {
    expect(gaps('[00:00]Held\n[00:30]Last'), isEmpty);
    expect(gaps('[00:00]\n[00:30]'), isEmpty);
    expect(gaps('Unsynced text'), isEmpty);
  });

  test('short rests and immediate vocals have no flashing countdown', () {
    expect(gaps('[00:02]First\n[00:04]\n[00:06]Last'), isEmpty);
    expect(gaps('[00:00]First\n[00:04]\n[00:07]Last'), [(4000, 7000)]);
  });

  test('offset correction also moves the countdown boundaries', () {
    expect(gaps('[offset:500]\n[00:09]First\n[00:12]\n[00:21]Last'), [
      (0, 8500),
      (11500, 20500),
    ]);
  });

  test('word ends protect against an early or invalid paragraph end', () {
    expect(
      gaps('''
<tt><body><div>
<p begin="0s" end="2s"><span begin="0s" end="8s">Held</span></p>
<p begin="12s" end="14s">Last</p>
</div></body></tt>
'''),
      [(8000, 12000)],
    );
    expect(
      gaps('''
<tt><body><div>
<p begin="0s" end="2s"><span begin="5s">Unknown end</span></p>
<p begin="12s" end="14s">Last</p>
</div></body></tt>
'''),
      isEmpty,
    );
  });
}
