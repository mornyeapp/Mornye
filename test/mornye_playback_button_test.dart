import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required VoidCallback onPressed,
    IconData icon = CupertinoIcons.play_fill,
    bool reduceMotion = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Center(
            child: MornyePlaybackButton(
              icon: icon,
              tooltip: 'Playback action',
              color: Colors.white,
              onPressed: onPressed,
            ),
          ),
        ),
      ),
    ),
  );

  double feedbackOpacity(WidgetTester tester) {
    final feedback = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.byType(IconButton),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return (feedback.decoration as BoxDecoration).color!.a;
  }

  testWidgets('the capsule press shrinks the glyph over a growing disc', (
    tester,
  ) async {
    final style = IconButton.styleFrom(
      minimumSize: const Size.square(32),
      fixedSize: const Size.square(32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: IconButtonTheme(
              data: IconButtonThemeData(style: style),
              child: MornyePlaybackButton(
                icon: CupertinoIcons.play_fill,
                tooltip: 'Playback action',
                color: Colors.white,
                iconSize: 22,
                padding: const EdgeInsets.all(5),
                pointerPress: true,
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byType(IconButton);
    final icon = find.byIcon(CupertinoIcons.play_fill);
    final disc = find.byKey(const ValueKey('mornye-playback-press-disc'));
    final bounds = tester.getRect(button);
    final iconWidth = tester.getRect(icon).width;
    expect(tester.getSize(disc).width, 32);

    final press = await tester.startGesture(bounds.center);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(icon).width, closeTo(iconWidth * 0.9, 0.01));
    expect(tester.getRect(button), bounds);
    final grown = tester.widget<Transform>(disc).transform.getMaxScaleOnAxis();
    expect(grown * 32, closeTo(38, 0.01));

    await press.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(icon).width, iconWidth);
  });

  testWidgets('press feedback keeps the tap target fixed and cancels safely', (
    tester,
  ) async {
    var calls = 0;
    await pumpButton(tester, onPressed: () => calls++);
    final button = find.byType(IconButton);
    final icon = find.byIcon(CupertinoIcons.play_fill);
    final bounds = tester.getRect(button);
    final iconBounds = tester.getRect(icon);
    expect(feedbackOpacity(tester), 0);
    final press = await tester.startGesture(bounds.center);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(icon).width, lessThan(iconBounds.width));
    expect(tester.getRect(button), bounds);
    expect(feedbackOpacity(tester), closeTo(0.14, 0.001));
    await press.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.getRect(icon), iconBounds);
    expect(feedbackOpacity(tester), 0);

    final cancelled = await tester.startGesture(bounds.center);
    await tester.pump(const Duration(milliseconds: 100));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.getRect(icon), iconBounds);
    expect(feedbackOpacity(tester), 0);
  });

  for (final icon in [
    CupertinoIcons.play_fill,
    CupertinoIcons.pause_fill,
    CupertinoIcons.forward_fill,
    CupertinoIcons.backward_fill,
  ]) {
    testWidgets('quick tap on $icon fades a circular highlight in and out', (
      tester,
    ) async {
      var calls = 0;
      await pumpButton(tester, icon: icon, onPressed: () => calls++);
      final button = find.byType(IconButton);
      final bounds = tester.getRect(button);
      await tester.tap(button);
      expect(calls, 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final entering = feedbackOpacity(tester);
      expect(entering, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 60));
      final peak = feedbackOpacity(tester);
      expect(peak, greaterThan(entering));
      await tester.pump(const Duration(milliseconds: 220));
      expect(feedbackOpacity(tester), lessThan(peak));
      expect(tester.getRect(button), bounds);
      await tester.pumpAndSettle();
      expect(feedbackOpacity(tester), 0);
      expect(calls, 1);
    });
  }

  for (final icon in [
    CupertinoIcons.forward_fill,
    CupertinoIcons.backward_fill,
  ]) {
    testWidgets(
      'skip $icon animates without delaying repeated playback actions',
      (tester) async {
        var calls = 0;
        await pumpButton(tester, icon: icon, onPressed: () => calls++);
        final button = find.byType(IconButton);
        final bounds = tester.getRect(button);
        for (var index = 0; index < 3; index++) {
          await tester.tap(button);
          await tester.pump(const Duration(milliseconds: 60));
          expect(calls, index + 1);
          expect(find.byIcon(CupertinoIcons.play_fill), findsNWidgets(3));
          expect(tester.getRect(button), bounds);
        }
        await tester.pumpAndSettle();
        expect(find.byIcon(icon), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.play_fill), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Reduce Motion keeps skip glyphs stationary and actions usable', (
    tester,
  ) async {
    var calls = 0;
    await pumpButton(
      tester,
      icon: CupertinoIcons.forward_fill,
      reduceMotion: true,
      onPressed: () => calls++,
    );
    final icon = find.byIcon(CupertinoIcons.forward_fill);
    final bounds = tester.getRect(icon);
    final press = await tester.startGesture(tester.getCenter(icon));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(icon), bounds);
    await press.up();
    await tester.pump(const Duration(milliseconds: 60));
    expect(calls, 1);
    expect(find.byIcon(CupertinoIcons.play_fill), findsNothing);
    expect(tester.getRect(icon), bounds);
    await tester.pumpAndSettle();
  });
}
