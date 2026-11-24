import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/mornye_selection_pill.dart';

/// The Mornye controls a finger moves keep the finger's velocity when let
/// go, and go on from their own velocity when a new value interrupts them.
void main() {
  group('selection pill', () {
    late int selected;
    late StateSetter update;

    Future<void> pumpPill(WidgetTester tester, {bool reduced = false}) async {
      selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Center(
              child: SizedBox(
                width: 300,
                height: 64,
                child: StatefulBuilder(
                  builder: (_, setState) {
                    update = setState;
                    return MornyeSelectionPill(
                      labels: const ['A', 'B', 'C'],
                      selectedIndex: selected,
                      padding: EdgeInsets.zero,
                      onChanged: (value) => update(() => selected = value),
                      itemBuilder: (_, index, _) =>
                          Center(child: Text(['A', 'B', 'C'][index])),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The resting pill's directional alignment: -1, 0 and 1 for the slots.
    double pill(WidgetTester tester) {
      final align = tester.widget<Align>(
        find
            .descendant(
              of: find.byType(MornyeSelectionPill),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Align && widget.alignment is AlignmentDirectional,
              ),
            )
            .first,
      );
      return (align.alignment as AlignmentDirectional).start;
    }

    testWidgets('a new selection mid-move goes on from the pill velocity', (
      tester,
    ) async {
      await pumpPill(tester);
      update(() => selected = 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final before = pill(tester);
      expect(before, inExclusiveRange(-1.0, 1.0));

      // Back to the first slot: the pill first carries on to the right,
      // without a jump, before it turns.
      update(() => selected = 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final after = pill(tester);
      expect(after, greaterThan(before));
      expect(after - before, lessThan(0.25));

      await tester.pumpAndSettle();
      expect(pill(tester), -1);
    });

    Future<double> furthestAfterRelease(
      WidgetTester tester,
      Duration dragTime,
    ) async {
      await pumpPill(tester);
      // From the first slot's center to the middle slot's center.
      final start = tester.getCenter(find.text('A'));
      await tester.timedDragFrom(start, const Offset(100, 0), dragTime);
      var furthest = pill(tester);
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (pill(tester) > furthest) furthest = pill(tester);
      }
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(pill(tester), 0);
      return furthest;
    }

    testWidgets('a released pill keeps the finger velocity', (tester) async {
      final quick = await furthestAfterRelease(
        tester,
        const Duration(milliseconds: 100),
      );
      final slow = await furthestAfterRelease(
        tester,
        const Duration(seconds: 2),
      );
      // A quick drag carries the pill past its slot before it settles.
      expect(quick, greaterThan(0.05));
      expect(quick, greaterThan(slow + 0.04));
    });

    testWidgets('reduced motion moves the pill at once', (tester) async {
      await pumpPill(tester, reduced: true);
      update(() => selected = 2);
      await tester.pump();
      expect(pill(tester), 1);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('switch', () {
    late bool value;

    Future<void> pumpSwitch(WidgetTester tester, {bool reduced = false}) async {
      value = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.light),
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: Center(
                  child: StatefulBuilder(
                    builder: (context, setState) => AppSwitch(
                      value: value,
                      onChanged: (next) => setState(() => value = next),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The thumb's directional alignment: -1 off, 1 on.
    double thumb(WidgetTester tester) {
      final align = tester.widget<Align>(
        find
            .descendant(
              of: find.byType(AppSwitch),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Align && widget.alignment is AlignmentDirectional,
              ),
            )
            .first,
      );
      return (align.alignment as AlignmentDirectional).start;
    }

    testWidgets('a second tap mid-move goes on from the thumb velocity', (
      tester,
    ) async {
      await pumpSwitch(tester);
      await tester.tap(find.byType(AppSwitch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final before = thumb(tester);
      expect(value, isTrue);
      expect(before, inExclusiveRange(-1.0, 1.0));

      await tester.tap(find.byType(AppSwitch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(value, isFalse);
      // Still travelling on, then back, with no jump to either side.
      expect(thumb(tester), greaterThanOrEqualTo(before));
      expect(thumb(tester) - before, lessThan(0.5));

      await tester.pumpAndSettle();
      expect(thumb(tester), -1);
    });

    Future<double> thumbAfterRelease(
      WidgetTester tester,
      Duration dragTime,
    ) async {
      await pumpSwitch(tester);
      // Just past the middle of the 22dp travel, after the drag slop.
      final center = tester.getCenter(find.byType(AppSwitch));
      final gesture = await tester.startGesture(center - const Offset(20, 0));
      for (var step = 1; step <= 8; step++) {
        await gesture.moveBy(
          const Offset(4, 0),
          timeStamp: dragTime * step ~/ 8,
        );
        await tester.pump(dragTime ~/ 8);
      }
      await gesture.up(timeStamp: dragTime);
      expect(thumb(tester), closeTo(1 / 11, 0.001));
      // The spring starts with the next build, then moves a frame.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final early = thumb(tester);
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(thumb(tester), 1);
      return early;
    }

    testWidgets('a released thumb keeps the finger velocity', (tester) async {
      final quick = await thumbAfterRelease(
        tester,
        const Duration(milliseconds: 80),
      );
      final slow = await thumbAfterRelease(tester, const Duration(seconds: 2));
      // A frame after release a quick drag has carried the thumb further.
      expect(quick, greaterThan(slow + 0.05));
    });

    testWidgets('reduced motion moves the thumb at once', (tester) async {
      await pumpSwitch(tester, reduced: true);
      await tester.tap(find.byType(AppSwitch));
      await tester.pump();
      expect(thumb(tester), 1);
    });
  });
}
