import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/mornye_playback_time.dart';
import 'package:mornye/widgets/player_lyrics_controls.dart';

Widget _app(int seconds, {bool remaining = false, bool reduceMotion = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: MornyePlaybackTime(
              seconds: seconds,
              remaining: remaining,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );

void main() {
  tearDown(DecorativePhase.debugResetClock);

  testWidgets('A roll draws at most 30 frames a second on a 120 Hz screen', (
    tester,
  ) async {
    await tester.pumpWidget(_app(34));
    await tester.pumpWidget(_app(35));
    // Draw a frame at each 8 ms vsync only when something asked for one.
    var frames = 0;
    for (var elapsed = 0; elapsed < 1000; elapsed += 8) {
      await tester.binding.delayed(const Duration(milliseconds: 8));
      if (!tester.binding.hasScheduledFrame) continue;
      frames++;
      await tester.pump();
    }
    expect(frames, inInclusiveRange(1, 10));
    expect(find.text('4'), findsNothing);
    expect(DecorativePhase.debugClockRunning, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final increasing in [true, false]) {
    testWidgets(
      'Time digits roll ${increasing ? 'up' : 'down'} without drift',
      (tester) async {
        final oldDigit = increasing ? '4' : '5';
        final newDigit = increasing ? '5' : '4';
        await tester.pumpWidget(_app(increasing ? 34 : 35));
        final oldPosition = tester.getTopLeft(find.text(oldDigit));
        final colonPosition = tester.getTopLeft(find.text(':'));
        final initialSize = tester.getSize(find.byType(MornyePlaybackTime));

        await tester.pumpWidget(_app(increasing ? 35 : 34));
        await tester.pump(const Duration(milliseconds: 80));
        final oldY = tester.getTopLeft(find.text(oldDigit)).dy;
        final newY = tester.getTopLeft(find.text(newDigit)).dy;
        expect(
          oldY,
          increasing ? lessThan(oldPosition.dy) : greaterThan(oldPosition.dy),
        );
        expect(
          newY,
          increasing ? greaterThan(oldPosition.dy) : lessThan(oldPosition.dy),
        );
        expect(tester.getTopLeft(find.text(':')), colonPosition);
        expect(tester.getSize(find.byType(MornyePlaybackTime)), initialSize);

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.text(oldDigit), findsNothing);
        expect(tester.getTopLeft(find.text(newDigit)), oldPosition);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('A roll keeps its slide and fade curves', (tester) async {
    await tester.pumpWidget(_app(34));
    final rest = tester.getTopLeft(find.text('4')).dy;
    final height = tester.getSize(find.text('4')).height;
    await tester.pumpWidget(_app(35));
    // 136 ms is a whole number of decorative clock ticks.
    await tester.pump(const Duration(milliseconds: 136));
    const t = 136 / 280;
    final entering = Curves.easeOutCubic.transform(t);
    final leaving = Curves.easeInCubic.transform(1 - t);
    double opacityOf(String digit) {
      RenderObject? node = tester.renderObject(find.text(digit));
      while (node != null) {
        if (node is RenderOpacity) return node.opacity;
        if (node is RenderAnimatedOpacity) return node.opacity.value;
        node = node.parent;
      }
      return 1;
    }

    expect(
      tester.getTopLeft(find.text('5')).dy - rest,
      closeTo(0.7 * height * (1 - entering), 0.01),
    );
    expect(
      tester.getTopLeft(find.text('4')).dy - rest,
      closeTo(-0.7 * height * (1 - leaving), 0.01),
    );
    expect(opacityOf('5'), closeTo(entering, 0.01));
    expect(opacityOf('4'), closeTo(leaving, 0.01));
  });

  testWidgets('Minute rollover and rapid seeks expose only the current time', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(599, remaining: true));
    final colonPosition = tester.getTopLeft(find.text(':'));
    await tester.pumpWidget(_app(600, remaining: true));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.bySemanticsLabel('-10:00'), findsOneWidget);
    expect(find.bySemanticsLabel('-9:59'), findsNothing);
    expect(find.text('-'), findsOneWidget);
    expect(tester.getTopLeft(find.text(':')), colonPosition);

    await tester.pumpWidget(_app(598, remaining: true));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.bySemanticsLabel('-9:58'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('-'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Reduce Motion updates time without rolling digits', (
    tester,
  ) async {
    await tester.pumpWidget(_app(34));
    await tester.pumpWidget(_app(35));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(_app(36, reduceMotion: true));
    expect(find.text('0:36'), findsOneWidget);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('Hidden lyric controls update time without drawing a roll', (
    tester,
  ) async {
    Widget hidden(int seconds, {required bool hidden}) =>
        PlayerLyricsControlsVisibility(hidden: hidden, child: _app(seconds));
    await tester.pumpWidget(hidden(34, hidden: true));
    await tester.pumpWidget(hidden(35, hidden: true));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('4'), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(DecorativePhase.debugClockRunning, isFalse);

    // Shown again, the digits roll as before.
    await tester.pumpWidget(hidden(35, hidden: false));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(hidden(36, hidden: false));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
