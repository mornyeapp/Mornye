import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';

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
    final play = find.byTooltip('Play');
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
        tester.getCenter(find.byTooltip('Play')),
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
        tester.getSize(find.byTooltip('Play')).width,
        moreOrLessEquals((432 - 128) * 104 / 240),
      );
    },
  );

  testWidgets('a press widens the button inside the row', (tester) async {
    await pumpTransport(tester, width: 432, fill: true);
    final play = find.byTooltip('Play');
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
    final previous = tester.getRect(find.byTooltip('Previous'));
    final play = tester.getRect(find.byTooltip('Play'));
    expect(previous.height, moreOrLessEquals(40));
    expect(previous.width, moreOrLessEquals(48));
    expect(play.width, moreOrLessEquals(64));
    await tester.tap(find.byTooltip('Play'), warnIfMissed: false);
    expect(tester.takeException(), isNull);
  });
}
