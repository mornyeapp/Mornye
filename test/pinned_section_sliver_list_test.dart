import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/pinned_section_sliver_list.dart';

void main() {
  Widget list(
    ScrollController controller, {
    double textScale = 1,
    bool pinned = true,
    List<int>? sectionIds,
    ValueChanged<int>? onHeaderTap,
    ValueChanged<int>? onTrackTap,
    List<Widget> leadingSlivers = const [],
    List<Widget> trailingSlivers = const [],
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: CustomScrollView(
          controller: controller,
          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
          slivers: [
            ...leadingSlivers,
            PinnedSectionSliverList(
              headerIndexes: [
                if (pinned)
                  for (var i = 0; i < (sectionIds?.length ?? 120); i++) i * 9,
              ],
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index % 9 == 0) {
                  final section = sectionIds?[index ~/ 9] ?? index ~/ 9;
                  return GestureDetector(
                    key: ValueKey('section-$section'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onHeaderTap == null
                        ? null
                        : () => onHeaderTap(section),
                    child: Semantics(
                      header: true,
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'Section $section',
                            key: ValueKey('header-$section'),
                            style: const TextStyle(fontSize: 20, height: 1),
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return GestureDetector(
                  key: ValueKey('track-$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onTrackTap == null ? null : () => onTrackTap(index),
                  child: SizedBox(
                    height: index.isEven ? 50 : 70,
                    child: Text('Track $index'),
                  ),
                );
              }, childCount: (sectionIds?.length ?? 120) * 9),
            ),
            ...trailingSlivers,
          ],
        ),
      ),
    ),
  );

  testWidgets('offscreen sections do not build a sample row or header', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(list(controller));
    expect(find.textContaining('Track ').evaluate().length, lessThan(15));
    expect(find.text('Section 119'), findsNothing);
    expect(find.textContaining('Section ').evaluate().length, lessThan(4));
  });

  testWidgets('pins variable-height sections and restores a reverse header', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(list(controller));
    for (final (offset, section) in [
      (100.0, 0),
      (650.0, 1),
      (2700.0, 5),
      (650.0, 1),
      (100.0, 0),
    ]) {
      controller.jumpTo(offset);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getTopLeft(
              find.byKey(ValueKey('header-$section'), skipOffstage: false),
            )
            .dy,
        closeTo(8, 0.01),
      );
      expect(find.textContaining('Section ').evaluate().length, lessThan(4));
    }
    controller.jumpTo(500);
    await tester.pump();
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('header-0'), skipOffstage: false),
          )
          .dy,
      lessThan(8),
    );
  });

  testWidgets('large text and rebuilt data preserve header layout', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(list(controller));
    controller.jumpTo(150);
    await tester.pump();
    await tester.pumpWidget(list(controller, textScale: 2));
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('header-0'), skipOffstage: false),
          )
          .dy,
      closeTo(8, 0.01),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('header-0'), skipOffstage: false))
          .height,
      closeTo(40, 0.01),
    );
    controller.jumpTo(0);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained header stays accessible and releases after filtering', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(list(controller));
    controller.jumpTo(150);
    await tester.pump();
    final header = find.byKey(const ValueKey('header-0'), skipOffstage: false);
    expect(tester.getSemantics(header).getSemanticsData().label, 'Section 0');
    await tester.pumpWidget(list(controller, pinned: false));
    expect(header, findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('revealing a retained header preserves deep and reverse scroll', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(list(controller));
    for (final (offset, section) in [(2700.0, 5), (650.0, 1)]) {
      controller.jumpTo(offset);
      await tester.pump();
      final header = find.byKey(
        ValueKey('header-$section'),
        skipOffstage: false,
      );
      tester.renderObject(header).showOnScreen();
      await tester.pump();
      expect(
        controller.offset,
        offset,
        reason: 'showOnScreen section $section',
      );
      await Scrollable.ensureVisible(tester.element(header));
      await tester.pump();
      expect(
        controller.offset,
        offset,
        reason: 'ensureVisible section $section',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('retained header receives taps above the covered track', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final headers = <int>[];
    final rows = <int>[];
    await tester.pumpWidget(
      list(controller, onHeaderTap: headers.add, onTrackTap: rows.add),
    );
    controller.jumpTo(2700);
    await tester.pump();
    await tester.tapAt(const Offset(200, 18));
    expect(headers, [5]);
    expect(rows, isEmpty);
    await tester.tapAt(const Offset(200, 48));
    expect(rows, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('revealing rows respects both edges of the pinned header', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(list(controller));
    final covered = find.byKey(const ValueKey('track-47'));
    final trailing = find.byKey(const ValueKey('track-57'));
    for (final explicit in [false, true]) {
      controller.jumpTo(2700);
      await tester.pump();
      if (explicit) {
        await Scrollable.ensureVisible(tester.element(covered));
      } else {
        tester.renderObject(covered).showOnScreen();
      }
      await tester.pump();
      expect(tester.getTopLeft(covered).dy, closeTo(36, 0.01));

      controller.jumpTo(2700);
      await tester.pump();
      if (explicit) {
        await Scrollable.ensureVisible(tester.element(trailing), alignment: 1);
      } else {
        tester.renderObject(trailing).showOnScreen();
      }
      await tester.pump();
      expect(tester.getBottomLeft(trailing).dy, closeTo(600, 0.01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('following slivers do not inherit section obstruction', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      list(
        controller,
        sectionIds: [0, 1],
        trailingSlivers: const [
          SliverToBoxAdapter(
            child: SizedBox(height: 800, child: Text('Following content')),
          ),
        ],
      ),
    );
    controller.jumpTo(650);
    await tester.pump();
    final following = find.text('Following content');
    await Scrollable.ensureVisible(tester.element(following));
    await tester.pump();
    expect(tester.getTopLeft(following).dy, closeTo(0, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('row reveal combines section and preceding pinned headers', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (final (scale, offset, row, top) in [
      (1.0, 2740.0, 47, 76.0),
      (2.0, 690.0, 11, 96.0),
    ]) {
      if (controller.hasClients) {
        controller.jumpTo(0);
        await tester.pump();
      }
      await tester.pumpWidget(
        list(
          controller,
          textScale: scale,
          leadingSlivers: const [
            PinnedHeaderSliver(child: SizedBox(height: 40)),
          ],
        ),
      );
      for (final explicit in [false, true]) {
        controller.jumpTo(offset);
        await tester.pump();
        final target = find.byKey(ValueKey('track-$row'));
        if (explicit) {
          await Scrollable.ensureVisible(tester.element(target));
        } else {
          tester.renderObject(target).showOnScreen();
        }
        await tester.pump();
        expect(tester.getTopLeft(target).dy, closeTo(top, 0.01));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('removing the active section releases its retained header', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(list(controller));
    controller.jumpTo(2700);
    await tester.pump();
    expect(find.text('Section 5', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(
      list(
        controller,
        sectionIds: [
          for (var i = 0; i < 120; i++)
            if (i != 5) i,
        ],
      ),
    );
    expect(find.text('Section 5', skipOffstage: false), findsNothing);
    expect(find.text('Section 6', skipOffstage: false), findsOneWidget);
    expect(controller.offset, 2700);
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('header-6'), skipOffstage: false),
          )
          .dy,
      closeTo(8, 0.01),
    );
    expect(
      find.textContaining('Section ', skipOffstage: false).evaluate().length,
      lessThan(4),
    );
    await tester.pumpWidget(list(controller, sectionIds: []));
    expect(find.textContaining('Section ', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
