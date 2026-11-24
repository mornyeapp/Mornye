import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';

import 'support/tooltip_finder.dart';

void main() {
  Future<void> pumpTransport(
    WidgetTester tester, {
    required double width,
    required bool fill,
    bool settle = true,
  }) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ExpressivePlaybackTransport(
                colorScheme: scheme,
                playing: false,
                loading: false,
                playTooltip: 'Play',
                previousTooltip: 'Previous',
                nextTooltip: 'Next',
                onPlayPause: () {},
                onPrevious: () {},
                onNext: () {},
                fill: fill,
                leading: const SizedBox(
                  key: ValueKey('leading'),
                  width: 48,
                  height: 48,
                ),
                trailing: const SizedBox(
                  key: ValueKey('trailing'),
                  width: 48,
                  height: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  testWidgets('a filled row puts the side actions at its ends', (tester) async {
    await pumpTransport(tester, width: 800, fill: true);
    expect(rectOf(tester, 'leading').left, moreOrLessEquals(0));
    expect(rectOf(tester, 'trailing').right, moreOrLessEquals(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a resize never pushes a filled row past its width', (
    tester,
  ) async {
    await pumpTransport(tester, width: 432, fill: true);
    for (final width in [300.0, 600.0, 432.0]) {
      await pumpTransport(tester, width: width, fill: true);
      expect(tester.takeException(), isNull);
      expect(rectOf(tester, 'trailing').right, moreOrLessEquals(width));
    }
  });

  testWidgets('resizing follows the parent without a second width animation', (
    tester,
  ) async {
    await pumpTransport(tester, width: 300, fill: true);
    final play = findByTooltip('Play');
    for (final width in [432.0, 480.0, 520.0, 600.0, 432.0]) {
      await pumpTransport(tester, width: width, fill: true, settle: false);
      await tester.pump(const Duration(milliseconds: 16));
      final expectedPlayWidth = (width - 128) * 104 / 240;
      expect(tester.getSize(play).width, moreOrLessEquals(expectedPlayWidth));
      expect(rectOf(tester, 'trailing').right, moreOrLessEquals(width));
      expect(tester.binding.transientCallbackCount, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a resize during a press keeps the row within its current width',
    (tester) async {
      await pumpTransport(tester, width: 432, fill: true);
      final gesture = await tester.startGesture(
        tester.getCenter(findByTooltip('Play')),
      );
      await tester.pump(const Duration(milliseconds: 32));
      for (final width in [600.0, 480.0, 360.0, 432.0]) {
        await pumpTransport(tester, width: width, fill: true, settle: false);
        await tester.pump(const Duration(milliseconds: 16));
        expect(rectOf(tester, 'leading').left, moreOrLessEquals(0));
        expect(rectOf(tester, 'trailing').right, moreOrLessEquals(width));
        expect(tester.takeException(), isNull);
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(findByTooltip('Play')).width,
        moreOrLessEquals((432 - 128) * 104 / 240),
      );
    },
  );

  testWidgets('a press widens the button inside the row', (tester) async {
    await pumpTransport(tester, width: 432, fill: true);
    final play = findByTooltip('Play');
    final resting = tester.getSize(play).width;
    final gesture = await tester.startGesture(tester.getCenter(play));
    // The spring overshoots; the neighbours give way every frame of it.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(rectOf(tester, 'leading').left, moreOrLessEquals(0));
      expect(rectOf(tester, 'trailing').right, moreOrLessEquals(432));
    }
    expect(tester.getSize(play).width, greaterThan(resting * 1.1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(play).width, moreOrLessEquals(resting));
    expect(tester.takeException(), isNull);
  });

  testWidgets('without fill the row keeps its resting width, centered', (
    tester,
  ) async {
    await pumpTransport(tester, width: 800, fill: false);
    final leading = rectOf(tester, 'leading');
    final trailing = rectOf(tester, 'trailing');
    expect(leading.left, greaterThan(0));
    expect(800 - trailing.right, moreOrLessEquals(leading.left));
  });

  testWidgets('the dense size fits a desktop bar and disables without songs', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 192,
              child: ExpressivePlaybackTransport(
                colorScheme: scheme,
                playing: false,
                loading: false,
                dense: true,
                playTooltip: 'Play',
                previousTooltip: 'Previous',
                nextTooltip: 'Next',
                onPlayPause: null,
                onPrevious: null,
                onNext: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final previous = tester.getRect(findByTooltip('Previous'));
    final play = tester.getRect(findByTooltip('Play'));
    expect(previous.height, moreOrLessEquals(40));
    expect(previous.width, moreOrLessEquals(48));
    expect(play.width, moreOrLessEquals(64));
    await tester.tap(findByTooltip('Play'), warnIfMissed: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the mini pair holds play and next, and a press trades width', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExpressivePlaybackTransport(
                  colorScheme: scheme,
                  playing: false,
                  loading: false,
                  mini: true,
                  playTooltip: 'Play',
                  previousTooltip: 'Previous',
                  nextTooltip: 'Next',
                  onPlayPause: () => calls.add('play'),
                  onPrevious: () => calls.add('previous'),
                  onNext: () => calls.add('next'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(findByTooltip('Previous'), findsNothing);
    final play = tester.getRect(findByTooltip('Play'));
    final next = tester.getRect(findByTooltip('Next'));
    expect(play.size, const Size(60, 44));
    expect(next.size, const Size(44, 44));
    expect(next.left - play.right, moreOrLessEquals(8));

    final gesture = await tester.startGesture(play.center);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final pressedPlay = tester.getRect(findByTooltip('Play'));
      final pressedNext = tester.getRect(findByTooltip('Next'));
      expect(pressedPlay.left, moreOrLessEquals(play.left));
      expect(pressedNext.right, moreOrLessEquals(next.right));
    }
    expect(
      tester.getSize(findByTooltip('Play')).width,
      greaterThan(play.width),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(findByTooltip('Next'));
    expect(calls, ['play', 'next']);
    expect(tester.takeException(), isNull);
  });
}
