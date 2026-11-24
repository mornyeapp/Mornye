import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';

import 'support/tooltip_finder.dart';

void main() {
  for (final mornye in [false, true]) {
    final name = mornye ? 'Mornye' : 'Material';

    Future<void> showPanel(
      WidgetTester tester,
      VoidCallback onClose, {
      bool tall = false,
      int selectedCount = 1,
      double textScale = 1,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: [
                  ListView(children: const [SizedBox(height: 2000)]),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SelectionBottomBar(
                      selectedCount: selectedCount,
                      allSelected: true,
                      onClose: onClose,
                      onToggleSelectAll: () {},
                      bottomPadding: 0,
                      children: [
                        SizedBox(height: tall ? 900 : 140),
                        TextButton(
                          onPressed: () {},
                          child: const Text('Action'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('$name: first swipe collapses and second swipe closes once', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      final expandedHeight = tester
          .getSize(find.byType(SelectionBottomBar))
          .height;
      final handle = find.byType(AppSheetHandle);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(0, 25));
      await gesture.moveBy(const Offset(0, 110));
      await tester.pump();
      expect(tester.getTopLeft(surface).dy, greaterThan(initial.dy + 90));
      final background = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(background.position.pixels, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Action').hitTestable(), findsNothing);
      expect(
        tester.getSize(find.byType(SelectionBottomBar)).height,
        lessThan(expandedHeight - 100),
      );
      await tester.drag(handle, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(closed, 1);
      await tester.pumpWidget(const SizedBox());
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    });

    /// How far the actions close in the first frames after a collapsing
    /// drag of the same length, made over [dragTime], is let go.
    Future<double> closingAfterRelease(
      WidgetTester tester,
      Duration dragTime,
    ) async {
      await showPanel(tester, () {});
      final actions = find
          .ancestor(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(SizeTransition),
          )
          .first;
      double expansion() =>
          tester.widget<SizeTransition>(actions).sizeFactor.value;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppSheetHandle)),
      );
      for (var step = 1; step <= 10; step++) {
        await gesture.moveBy(
          const Offset(0, 12),
          timeStamp: dragTime * step ~/ 10,
        );
        await tester.pump(dragTime ~/ 10);
      }
      final released = expansion();
      await gesture.up(timeStamp: dragTime);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final early = expansion();
      await tester.pumpAndSettle();
      expect(find.text('Action').hitTestable(), findsNothing);
      expect(expansion(), 0);
      return released - early;
    }

    testWidgets('$name: a released collapse keeps the finger velocity', (
      tester,
    ) async {
      final quick = await closingAfterRelease(
        tester,
        const Duration(milliseconds: 80),
      );
      final slow = await closingAfterRelease(
        tester,
        const Duration(seconds: 2),
      );
      expect(quick, greaterThan(slow + 0.02));
    });

    testWidgets('$name: a long first swipe cannot cancel selection', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      await tester.drag(find.byType(AppSheetHandle), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(find.text('Action').hitTestable(), findsNothing);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('$name: collapsed panel stays compact as selection changes', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      await tester.drag(find.byType(AppSheetHandle), const Offset(0, 150));
      await tester.pumpAndSettle();
      final compactHeight = tester
          .getSize(find.byType(SelectionBottomBar))
          .height;

      await showPanel(tester, () => closed++, selectedCount: 9);

      expect(find.text('9 selected'), findsOneWidget);
      expect(closed, 0);
      expect(find.text('Action').hitTestable(), findsNothing);
      expect(
        tester.getSize(find.byType(SelectionBottomBar)).height,
        compactHeight,
      );
      // The area occupied by the expanded panel must belong to Library again.
      await tester.timedDragFrom(
        tester.getTopLeft(find.byType(SelectionBottomBar)) -
            const Offset(-100, 50),
        const Offset(0, -100),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      final background = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(background.position.pixels, greaterThan(80));
      expect(closed, 0);
    });

    testWidgets('$name: tap handle and upward swipe restore actions', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final handle = find.byType(AppSheetHandle);
      final initial = tester.getSize(find.byType(SelectionBottomBar));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(find.text('Action').hitTestable(), findsNothing);
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SelectionBottomBar)), initial);
      expect(find.text('Action').hitTestable(), findsOneWidget);

      await tester.drag(handle, const Offset(0, 150));
      await tester.pumpAndSettle();
      await tester.timedDrag(
        handle,
        const Offset(0, -140),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SelectionBottomBar)), initial);
      expect(find.text('Action').hitTestable(), findsOneWidget);
      expect(closed, 0);
    });

    testWidgets('$name: close button still cancels immediately', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      await tester.tap(findByTooltip('Close'));
      await tester.pumpAndSettle();
      expect(closed, 1);
    });

    testWidgets('$name: short drag returns without closing', (tester) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      await tester.timedDrag(
        find.byType(AppSheetHandle),
        const Offset(0, 40),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(tester.getTopLeft(surface), initial);
    });

    testWidgets('$name: reversing a pull returns the whole panel', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppSheetHandle)),
      );
      await gesture.moveBy(const Offset(0, 25));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(tester.getTopLeft(surface).dy, greaterThan(initial.dy));
      await gesture.moveBy(const Offset(0, -140));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(tester.getTopLeft(surface), initial);
    });

    testWidgets('$name: route disposal cancels pending dismiss callback', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      await tester.tap(find.byType(AppSheetHandle));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(AppSheetHandle), const Offset(0, 150));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name: tall actions scroll before dragging the panel', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++, tall: true);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      final headerPosition = tester.getTopLeft(find.text('1 selected'));
      final scroll = tester.widget<SingleChildScrollView>(surface).controller!;
      await tester.timedDrag(
        surface,
        const Offset(0, -220),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(180));
      expect(tester.getTopLeft(surface), initial);
      expect(tester.getTopLeft(find.text('1 selected')), headerPosition);
      final offset = scroll.offset;
      await tester.timedDrag(
        surface,
        const Offset(0, 80),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(offset));
      expect(tester.getTopLeft(surface), initial);
      expect(closed, 0);
      // The fixed header can collapse actions even when they are scrolled.
      await tester.drag(find.byType(AppSheetHandle), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(find.text('1 selected'), findsOneWidget);
      expect(
        tester.getSize(find.byType(SelectionBottomBar)).height,
        lessThan(160),
      );
      expect(closed, 0);
    });

    testWidgets('$name: pulling actions at the top also collapses the panel', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      await tester.timedDrag(
        find.byType(SingleChildScrollView),
        const Offset(0, 150),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(find.text('Action').hitTestable(), findsNothing);
    });

    testWidgets('$name: large text leaves the compact header usable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var closed = 0;
      await showPanel(tester, () => closed++, tall: true, textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(AppSheetHandle));
      await tester.pumpAndSettle();
      expect(find.text('1 selected').hitTestable(), findsOneWidget);
      expect(findByTooltip('Close').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(closed, 0);
    });

    testWidgets('$name: compact actions are hidden from accessibility', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await showPanel(tester, () {});
        expect(find.semantics.byLabel('Collapse'), findsOne);
        await tester.tap(find.byType(AppSheetHandle));
        await tester.pumpAndSettle();
        expect(find.semantics.byLabel('Expand'), findsOne);
        expect(find.semantics.byLabel('Action'), findsNothing);
        expect(find.text('1 selected').hitTestable(), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });
  }
}
