import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';

void main() {
  test('symmetric padding lets the final lyric line reach center', () {
    const viewport = 500.0;
    const lineExtent = 64.0;
    const lineCount = 20;
    final padding = syncedLyricsCenterPadding(
      viewportDimension: viewport,
      estimatedLineExtent: lineExtent,
    );
    final contentExtent = (padding * 2) + (lineCount * lineExtent);
    final maxScrollExtent = contentExtent - viewport;
    final lastLineOffset = syncedLyricsEstimatedOffset(
      index: lineCount - 1,
      estimatedLineExtent: lineExtent,
    );

    expect(padding, 218);
    expect(lastLineOffset, maxScrollExtent);
  });

  test('small viewports retain minimum breathing room', () {
    expect(
      syncedLyricsCenterPadding(viewportDimension: 80, estimatedLineExtent: 64),
      24,
    );
  });

  test('advances at the exact next line boundary', () {
    const starts = [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 3),
      Duration(seconds: 6),
    ];

    expect(
      syncedLyricsDueLineIndex(
        lineStarts: starts,
        currentIndex: 0,
        position: const Duration(milliseconds: 2999),
      ),
      0,
    );
    expect(
      syncedLyricsDueLineIndex(
        lineStarts: starts,
        currentIndex: 0,
        position: const Duration(seconds: 3),
      ),
      2,
    );
  });

  test('keeps the shown line over a slightly late position', () {
    int steady(int index, int position) => steadySyncedLyricsIndex(
      index: index,
      shown: 3,
      shownStart: const Duration(seconds: 6),
      position: Duration(milliseconds: position),
    );

    // A report up to 750 ms behind the shown line keeps it.
    expect(steady(2, 5800), 3);
    expect(steady(2, 5251), 3);
    // Further back is a seek, and a later line always moves on.
    expect(steady(2, 5250), 2);
    expect(steady(0, 1000), 0);
    expect(steady(4, 9000), 4);
  });

  test('only held words glow, rising while sung and fading after', () {
    double glowAt(int position, {required int end}) => syncedLyricSegmentGlow(
      position: Duration(milliseconds: position),
      start: const Duration(seconds: 1),
      end: Duration(milliseconds: end),
    );

    expect(glowAt(1300, end: 1500), 0);
    expect(glowAt(1100, end: 4000), 0);
    expect(glowAt(1800, end: 4000), inExclusiveRange(0, 1));
    expect(glowAt(3000, end: 4000), 1);
    expect(glowAt(4250, end: 4000), inExclusiveRange(0, 1));
    expect(glowAt(4600, end: 4000), 0);
  });

  group('smooth timed lyric highlight', () {
    double liftAt(int position, {int end = 1500}) => syncedLyricSegmentLift(
      position: Duration(milliseconds: position),
      start: const Duration(seconds: 1),
      end: Duration(milliseconds: end),
    );

    test('short words anticipate gently and remain raised after singing', () {
      expect(liftAt(800), 0);
      expect(liftAt(950), inExclusiveRange(0, 1));
      expect(liftAt(1000), greaterThan(liftAt(950)));
      expect(liftAt(1000), lessThan(0.2));
      expect(liftAt(1200), inExclusiveRange(0.4, 0.7));
      expect(liftAt(1500), lessThan(1));
      expect(liftAt(1540), 1);
      expect(liftAt(3000), 1);
    });

    test('held words rise further then settle to the normal highlight', () {
      final peak = liftAt(2300, end: 4000);
      expect(liftAt(1200, end: 4000), inExclusiveRange(0.4, 0.7));
      expect(peak, greaterThan(1));
      expect(liftAt(3900, end: 4000), inExclusiveRange(1, peak));
      expect(liftAt(4000, end: 4000), 1);
      expect(liftAt(4200, end: 4000), 1);
      expect(liftAt(2300, end: 4000), peak);
      expect(liftAt(800, end: 4000), 0);
    });

    test('short syllables keep the slow rise and trail their color sweep', () {
      expect(liftAt(1100, end: 1100), lessThan(0.4));
      expect(liftAt(1200, end: 1100), lessThan(0.7));
      expect(liftAt(1540, end: 1100), 1);
      for (var position = 820; position < 1540; position += 16) {
        final before = liftAt(position, end: 1100);
        final after = liftAt(position + 16, end: 1100);
        expect(after - before, inInclusiveRange(0, 0.034));
      }
    });

    test('invalid or zero-length timing does not move the text', () {
      expect(liftAt(1200, end: 1000), 0);
      expect(liftAt(1200, end: 500), 0);
    });

    test('interpolates position only while playback is advancing', () {
      expect(
        interpolatedSyncedLyricsPosition(
          anchorPosition: const Duration(seconds: 10),
          elapsedSinceAnchor: const Duration(milliseconds: 250),
          isPlaying: true,
        ),
        const Duration(milliseconds: 10250),
      );
      expect(
        interpolatedSyncedLyricsPosition(
          anchorPosition: const Duration(seconds: 10),
          elapsedSinceAnchor: const Duration(milliseconds: 250),
          isPlaying: false,
        ),
        const Duration(seconds: 10),
      );
    });

    test(
      'closes small clock differences by pace and applies seeks at once',
      () {
        double? rate(int predicted, int reported) => syncedLyricsCatchUpRate(
          predictedPosition: Duration(milliseconds: predicted),
          reportedPosition: Duration(milliseconds: reported),
        );
        expect(rate(1000, 1000), 1);
        // A quarter of the difference is made up by the next report, half a
        // second later.
        expect(rate(1000, 1100), closeTo(1.05, 1e-9));
        expect(rate(1000, 900), closeTo(0.95, 1e-9));
        // Always forward, whatever the difference.
        expect(rate(1000, 251), greaterThan(0.5));
        expect(rate(1000, 5000), isNull);
        expect(rate(5000, 1000), isNull);
      },
    );

    test('calculates continuous progress inside a timed segment', () {
      const start = Duration(seconds: 2);
      const end = Duration(seconds: 3);

      expect(
        syncedLyricSegmentProgress(
          position: const Duration(milliseconds: 1500),
          start: start,
          end: end,
        ),
        0,
      );
      expect(
        syncedLyricSegmentProgress(
          position: const Duration(milliseconds: 2250),
          start: start,
          end: end,
        ),
        0.25,
      );
      expect(
        syncedLyricSegmentProgress(
          position: const Duration(milliseconds: 3500),
          start: start,
          end: end,
        ),
        1,
      );
    });
  });
}
