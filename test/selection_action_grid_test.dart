import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/selection_action_button.dart';

Widget _app(bool mornye, Widget child) => ProviderScope(
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  for (final mornye in [false, true]) {
    for (final (width, columns, itemWidth) in [
      (360.0, 2, 176.0),
      (960.0, 3, 944 / 3),
      (1280.0, 4, 314.0),
    ]) {
      testWidgets('selection grid geometry ($mornye, $columns columns)', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var tapped = -1;
        await tester.pumpWidget(
          _app(
            mornye,
            Builder(
              builder: (context) => SelectionActionGrid(
                children: [
                  for (var index = 0; index < 5; index++)
                    SelectionActionButton(
                      key: ValueKey(index),
                      icon: Icons.edit,
                      label: 'Action $index',
                      onPressed: () => tapped = index,
                      colorScheme: Theme.of(context).colorScheme,
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final first = tester.getRect(find.byKey(const ValueKey(0)));
        for (var index = 0; index < 5; index++) {
          final rect = tester.getRect(find.byKey(ValueKey(index)));
          expect(rect.width, closeTo(itemWidth, 0.001));
          expect(
            rect.left,
            closeTo((index % columns) * (itemWidth + 8), 0.001),
          );
          expect(
            rect.top,
            closeTo(first.top + (index ~/ columns) * (first.height + 8), 0.001),
          );
        }
        await tester.tap(find.text('Action 4'));
        expect(tapped, 4);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('selection grid retains conditional actions ($mornye)', (
      tester,
    ) async {
      var queued = false;
      var converted = false;
      for (final (selectedCount, eligibleCount, canQueue) in [
        (0, 0, true),
        (1, 0, true),
        (1, 1, false),
        (1, 1, true),
        (0, 0, true),
      ]) {
        converted = false;
        await tester.pumpWidget(
          _app(
            mornye,
            LibraryTrackSelectionBar(
              selectedCount: selectedCount,
              allSelected: false,
              onClose: () {},
              onToggleSelectAll: () {},
              bottomPadding: 0,
              onReEnrich: () {},
              onConvert: () => converted = true,
              onReplayGain: ({required remove}) {},
              onDelete: () {},
              flacEligibleCount: eligibleCount,
              onQueueFlac: canQueue ? () => queued = true : null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final queue = find.byWidgetPredicate(
          (widget) =>
              widget is SelectionActionButton &&
              widget.icon == Icons.download_for_offline_outlined,
        );
        final hasQueue = eligibleCount > 0 && canQueue;
        expect(queue, hasQueue ? findsOneWidget : findsNothing);
        expect(
          find.byType(SelectionActionButton),
          findsNWidgets(hasQueue ? 5 : 4),
        );
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectionActionButton &&
                widget.icon == Icons.swap_horiz,
          ),
        );
        expect(converted, selectedCount > 0);
        if (hasQueue) {
          await tester.tap(queue);
          expect(queued, isTrue);
        }
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('desktop delete leads the Remove RG row ($mornye)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var deleted = false;
      await tester.pumpWidget(
        _app(
          mornye,
          Align(
            alignment: Alignment.bottomCenter,
            child: LibraryTrackSelectionBar(
              selectedCount: 1,
              allSelected: false,
              onClose: () {},
              onToggleSelectAll: () {},
              bottomPadding: 0,
              onReEnrich: () {},
              onConvert: () {},
              onReplayGain: ({required remove}) {},
              onDelete: () => deleted = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Rect button(IconData icon) => tester.getRect(
        find.byWidgetPredicate(
          (widget) => widget is SelectionActionButton && widget.icon == icon,
        ),
      );
      final delete = button(Icons.delete_outline);
      final removeGain = button(Icons.remove_circle_outline);
      expect(delete.top, removeGain.top);
      expect(delete.height, removeGain.height);
      expect(delete.right, lessThan(removeGain.left));
      final lowest = tester
          .widgetList<SelectionActionButton>(find.byType(SelectionActionButton))
          .map((widget) => button(widget.icon).top)
          .reduce((a, b) => a > b ? a : b);
      expect(lowest, delete.top);
      await tester.tap(find.text('Delete 1 track'));
      expect(deleted, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
