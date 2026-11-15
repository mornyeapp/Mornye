import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_playback_time.dart';

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

        await tester.pumpAndSettle();
        expect(find.text(oldDigit), findsNothing);
        expect(tester.getTopLeft(find.text(newDigit)), oldPosition);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    await tester.pumpAndSettle();
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
}
