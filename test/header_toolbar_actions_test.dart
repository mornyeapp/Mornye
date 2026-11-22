import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/header_toolbar_actions.dart';

import 'support/tooltip_finder.dart';

const _more = 'Show menu';
const _sort = 'Sort';

/// A Library album page with [count] toolbar actions, the second disabled
/// when [disabledSecond], and a Sort button when [sort].
Future<List<String>> _pump(
  WidgetTester tester, {
  required bool mornye,
  required int count,
  bool sort = false,
  bool disabledSecond = false,
}) async {
  tester.view.physicalSize = const Size(1079, 2339);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final ran = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              AlbumDetailHeader(
                title: 'Album',
                expandedHeight: 534,
                showTitleInAppBar: false,
                background: const ColoredBox(color: Colors.indigo),
                coverBuilder: (context, size) =>
                    const ColoredBox(color: Colors.indigo),
                appBarActions: [
                  HeaderToolbarActions(
                    sort: sort
                        ? HeaderCircleButton(
                            icon: Icons.sort,
                            tooltip: _sort,
                            onPressed: () => ran.add(_sort),
                          )
                        : null,
                    actions: (context, ref) => [
                      for (var i = 1; i <= count; i++)
                        ContextMenuAction(
                          icon: Icons.star,
                          label: 'Action $i',
                          onSelected: disabledSecond && i == 2
                              ? null
                              : () => ran.add('Action $i'),
                        ),
                    ],
                  ),
                ],
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ran;
}

/// The trailing controls, start to end.
List<Rect> _controls(WidgetTester tester) {
  final rects = [
    for (final element
        in find
            .descendant(
              of: find.byType(HeaderToolbarActions),
              matching: find.byType(HeaderCircleButton),
            )
            .evaluate())
      tester.getRect(find.byWidget(element.widget)),
  ]..sort((a, b) => a.left.compareTo(b.left));
  return rects;
}

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final mornye in [false, true]) {
    for (final sort in [false, true]) {
      for (final count in [1, 2, 3, 5]) {
        final total = count + (sort ? 1 : 0);
        testWidgets('$count actions${sort ? ' and Sort' : ''} '
            '(${mornye ? 'Mornye' : 'Material'})', (tester) async {
          final ran = await _pump(
            tester,
            mornye: mornye,
            count: count,
            sort: sort,
          );
          final folds = total > headerToolbarLimit;
          final controls = _controls(tester);
          expect(controls, hasLength(folds ? (sort ? 2 : 1) : total));
          expect(findByTooltip(_more), folds ? findsOneWidget : findsNothing);
          expect(findByTooltip(_sort), sort ? findsOneWidget : findsNothing);
          for (var i = 1; i <= count; i++) {
            expect(
              findByTooltip('Action $i'),
              folds ? findsNothing : findsOneWidget,
            );
          }

          // Side by side they never touch in Material and share one
          // capsule in Mornye.
          for (var i = 1; i < controls.length; i++) {
            final gap = controls[i].left - controls[i - 1].right;
            expect(gap, mornye ? greaterThanOrEqualTo(0) : 8);
          }
          expect(
            find.byType(MornyeActionCapsule),
            mornye && controls.length == 2 ? findsOneWidget : findsNothing,
          );
          final back = tester.getRect(
            findByTooltip('Back').hitTestable().first,
          );
          expect(back.right, lessThan(controls.first.left));

          if (!folds) {
            await tester.tap(findByTooltip('Action $count'));
            await tester.pumpAndSettle();
            expect(ran, ['Action $count']);
            return;
          }
          await tester.tap(findByTooltip(_more));
          await tester.pumpAndSettle();
          for (var i = 1; i <= count; i++) {
            expect(find.text('Action $i'), findsOneWidget);
          }
          expect(find.text(_sort), findsNothing);
          await tester.tap(find.text('Action $count'));
          await tester.pumpAndSettle();
          expect(ran, ['Action $count']);
          expect(find.text('Action 1'), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('a disabled action stays disabled, as a button and in the '
        'menu (${mornye ? 'Mornye' : 'Material'})', (tester) async {
      var ran = await _pump(
        tester,
        mornye: mornye,
        count: 2,
        disabledSecond: true,
      );
      await tester.tap(findByTooltip('Action 2'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(ran, isEmpty);

      ran = await _pump(
        tester,
        mornye: mornye,
        count: 3,
        sort: true,
        disabledSecond: true,
      );
      await tester.tap(findByTooltip(_more));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Action 2'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(ran, isEmpty);
      expect(find.text('Action 2'), findsOneWidget);
    });
  }

  for (final mornye in [false, true]) {
    testWidgets('desktop shows every action as before '
        '(${mornye ? 'Mornye' : 'Material'})', (tester) async {
      debugDesktopPlatformOverride = true;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: HeaderToolbarActions(
                  sort: HeaderCircleButton(
                    icon: Icons.sort,
                    tooltip: _sort,
                    onPressed: () {},
                  ),
                  actions: (context, ref) => [
                    for (var i = 1; i <= 5; i++)
                      ContextMenuAction(
                        icon: Icons.star,
                        label: 'Action $i',
                        onSelected: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_controls(tester), hasLength(6));
      expect(find.byType(HeaderMoreButton), findsNothing);
      expect(find.byType(MornyeActionCapsule), findsNothing);
      final row = tester.widget<Row>(
        find
            .descendant(
              of: find.byType(HeaderToolbarGroup),
              matching: find.byType(Row),
            )
            .first,
      );
      expect(row.spacing, 0);
    });
  }
}
