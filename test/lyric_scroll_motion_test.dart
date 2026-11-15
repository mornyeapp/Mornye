import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/lyric_scroll_motion.dart';

void main() {
  testWidgets(
    'later lyric rows trail earlier rows and settle to their layout',
    (tester) async {
      final clock = AnimationController(
        vsync: tester,
        duration: LyricScrollMotion.duration,
      );
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              for (final row in [1, 3])
                LyricScrollMotion(
                  progress: clock,
                  distance: 64,
                  rowsAfterFocus: row,
                  child: Text('Row $row'),
                ),
            ],
          ),
        ),
      );
      final first = tester.getTopLeft(find.text('Row 1')).dy;
      final third = tester.getTopLeft(find.text('Row 3')).dy;
      clock.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final firstLag = tester.getTopLeft(find.text('Row 1')).dy - first;
      final thirdLag = tester.getTopLeft(find.text('Row 3')).dy - third;
      expect(thirdLag, greaterThan(firstLag));
      expect(thirdLag, greaterThan(0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Row 1')).dy, first);
      expect(tester.getTopLeft(find.text('Row 3')).dy, third);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion and the focused lyric never acquire visual lag', (
    tester,
  ) async {
    for (final reduced in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Column(
              children: [
                for (final row in [0, 3])
                  LyricScrollMotion(
                    progress: const AlwaysStoppedAnimation(0.3),
                    distance: 64,
                    rowsAfterFocus: row,
                    child: Text('Row $row'),
                  ),
              ],
            ),
          ),
        ),
      );
      final first = find.descendant(
        of: find.byType(LyricScrollMotion).first,
        matching: find.byType(Transform),
      );
      expect(first, findsNothing);
      if (reduced) expect(find.byType(Transform), findsNothing);
    }
  });
}
