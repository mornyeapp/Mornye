import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_selection_pill.dart';

void _maskCullingTests() {
  for (final direction in TextDirection.values) {
    testWidgets(
      'selection masks cull and restore retained layers ($direction)',
      (tester) async {
        var selected = 0;
        Color color = Colors.red;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: direction,
              child: Center(
                child: SizedBox(
                  width: 300,
                  height: 64,
                  child: StatefulBuilder(
                    builder: (_, setState) {
                      update = setState;
                      return MornyeSelectionPill(
                        labels: const ['A', 'B', 'C', 'D', 'E'],
                        selectedIndex: selected,
                        selectionColor: color,
                        maskItemForeground: false,
                        padding: EdgeInsets.zero,
                        onChanged: (_) {},
                        itemBuilder: (_, _, _) => const Center(
                          child: MornyeSelectionForeground(
                            child: SizedBox(
                              width: 16,
                              height: 40,
                              child: ColoredBox(color: Colors.white),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => ui.FragmentProgram.fromAsset(
            'assets/shaders/mornye_selection_mask.frag',
          ),
        );
        await tester.pumpAndSettle();
        final masks = tester
            .renderObjectList<RenderShaderMask>(
              find.byWidgetPredicate((widget) => widget is ShaderMask),
            )
            .toList();
        int activeMasks() => masks.where((mask) => mask.layer != null).length;
        expect(masks, hasLength(5));
        expect(activeMasks(), 1);
        expect(masks.first.layer, isNotNull);

        update(() => selected = 4);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));
        expect(activeMasks(), inInclusiveRange(1, 2));
        await tester.pumpAndSettle();
        expect(activeMasks(), 1);
        expect(masks.first.layer, isNull);
        expect(masks.last.layer, isNotNull);

        update(() => color = Colors.transparent);
        await tester.pumpAndSettle();
        expect(activeMasks(), 0);
        update(() => color = Colors.red);
        await tester.pumpAndSettle();
        expect(activeMasks(), 1);
        expect(masks.last.layer, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('selection culling includes overflowing child paint bounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 64,
            child: MornyeSelectionPill(
              labels: const ['A', 'B', 'C', 'D', 'E'],
              selectedIndex: 0,
              selectionColor: Colors.red,
              maskItemForeground: false,
              padding: EdgeInsets.zero,
              onChanged: (_) {},
              itemBuilder: (_, index, _) => Center(
                child: MornyeSelectionForeground(
                  child: index == 4
                      ? const _OverflowForeground()
                      : const SizedBox(
                          width: 16,
                          height: 40,
                          child: ColoredBox(color: Colors.white),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => ui.FragmentProgram.fromAsset(
        'assets/shaders/mornye_selection_mask.frag',
      ),
    );
    await tester.pumpAndSettle();
    final masks = tester
        .renderObjectList<RenderShaderMask>(
          find.byWidgetPredicate((widget) => widget is ShaderMask),
        )
        .toList();
    expect(masks.last.child!.paintBounds.left, lessThan(0));
    expect(masks.last.layer, isNotNull);
    expect(masks.where((mask) => mask.layer != null), hasLength(2));
    expect(tester.takeException(), isNull);
  });
}

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('masked tab items survive press and drag ticks ($direction)', (
      tester,
    ) async {
      var builds = 0;
      var selected = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
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
                      selectionColor: Colors.red,
                      liquidInteraction: true,
                      onChanged: (value) => update(() => selected = value),
                      itemBuilder: (_, index, selected) {
                        builds++;
                        expect(selected, isFalse);
                        return Center(child: Text(['A', 'B', 'C'][index]));
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => ui.FragmentProgram.fromAsset(
          'assets/shaders/mornye_selection_mask.frag',
        ),
      );
      await tester.pumpAndSettle();
      final before = builds;
      final start = tester.getCenter(find.text('A'));
      final end = tester.getCenter(find.text('C'));
      final gesture = await tester.startGesture(start);
      for (var tick = 0; tick < 20; tick++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (var tick = 1; tick <= 20; tick++) {
        await gesture.moveTo(Offset.lerp(start, end, tick / 20)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(builds, before);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(builds, before + 3);
      final item = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == 'C',
        ),
      );
      expect(item.properties.selected, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('selection color follows rounded pill corners', (tester) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 200,
              child: MornyeSelectionPill(
                labels: const ['A', 'B'],
                selectedIndex: 0,
                onChanged: (_) {},
                padding: EdgeInsets.zero,
                selectionColor: Colors.red,
                itemBuilder: (_, _, _) => const SizedBox(
                  height: 64,
                  child: ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => ui.FragmentProgram.fromAsset(
        'assets/shaders/mornye_selection_mask.frag',
      ),
    );
    await tester.pumpAndSettle();
    final colors = (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData())!;
        return [
          for (final point in [
            const Offset(2, 2),
            const Offset(20, 32),
            const Offset(98, 2),
            const Offset(150, 32),
          ])
            Color.fromARGB(
              bytes.getUint8(
                (point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 3,
              ),
              bytes.getUint8(
                (point.dy.toInt() * image.width + point.dx.toInt()) * 4,
              ),
              bytes.getUint8(
                (point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 1,
              ),
              bytes.getUint8(
                (point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 2,
              ),
            ),
        ];
      } finally {
        image.dispose();
      }
    }))!;
    expect(
      colors.map((color) => color.toARGB32()),
      [
        Colors.white,
        Colors.red,
        Colors.white,
        Colors.white,
      ].map((color) => color.toARGB32()),
    );
    expect(tester.takeException(), isNull);
  });

  _maskCullingTests();

  for (final direction in TextDirection.values) {
    testWidgets('tab dragging previews, commits and cancels ($direction)', (
      tester,
    ) async {
      var selected = -1;
      final changes = <int>[];
      final capture = GlobalKey();
      final theme = MornyeTheme.build(Brightness.dark);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: theme,
            home: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 360,
                    child: StatefulBuilder(
                      builder: (context, setState) => RepaintBoundary(
                        key: capture,
                        child: MornyeTabBar(
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.home),
                              label: 'Home',
                            ),
                            NavigationDestination(
                              icon: MornyeNavigationIcon(
                                icon: Icons.music_note,
                                badgeCount: 7,
                              ),
                              label: 'Library',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.search),
                              label: 'Search',
                            ),
                          ],
                          selectedIndex: selected,
                          onSelected: (next) {
                            changes.add(next);
                            setState(() => selected = next);
                          },
                          blurEnabled: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // No selection must still allow activating the first destination.
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(changes, [0]);
      final home = tester.getCenter(find.text('Home'));
      final library = tester.getCenter(find.text('Library'));
      final pill = find.descendant(
        of: find.byType(MornyeSelectionPill),
        matching: find.byType(FractionallySizedBox),
      );
      final gesture = await tester.startGesture(home);
      // Move within tabs, across their boundaries, and reverse direction.
      // One frame must put the pill under the finger without a settling delay.
      for (final fraction in [0.35, 0.45, 0.5, 0.85, 1.2, 1.1, 0.9, 1.5]) {
        final position = Offset(
          home.dx + (library.dx - home.dx) * fraction,
          home.dy,
        );
        await gesture.moveTo(position);
        await tester.pump();
        expect(tester.getCenter(pill).dx, closeTo(position.dx, 0.1));
        expect(changes, [0]);
        if (fraction == 0.5) {
          // Halfway between destinations, both icons and both labels contain
          // active and inactive pixels. A nearest-index color swap cannot pass.
          for (final finder in [
            find.byIcon(Icons.home),
            find.byIcon(Icons.music_note),
            find.text('Home'),
            find.text('Library'),
          ]) {
            final colors = await _foregroundPixels(tester, capture, finder, [
              theme.colorScheme.primary,
              theme.colorScheme.onSurface,
            ]);
            expect(colors, everyElement(greaterThan(3)));
          }
          final badgePixels = await _foregroundPixels(
            tester,
            capture,
            find.text('7'),
            [theme.colorScheme.onError],
          );
          expect(badgePixels.single, greaterThan(3));
        }
      }
      await gesture.moveTo(tester.getCenter(find.text('Search')));
      await tester.pumpAndSettle();
      expect(changes, [0]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, [0, 2]);
      expect(
        tester.getCenter(pill).dx,
        closeTo(tester.getCenter(find.text('Search')).dx, 0.1),
      );
      final cancelled = await tester.startGesture(
        tester.getCenter(find.text('Search')),
      );
      await cancelled.moveTo(tester.getCenter(find.text('Home')));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(changes, [0, 2]);
      expect(
        tester.getCenter(pill).dx,
        closeTo(tester.getCenter(find.text('Search')).dx, 0.1),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(changes.length, 3);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switch drag toggles once with no filter ($direction)', (
      tester,
    ) async {
      var value = false;
      final changes = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) => AppSwitch(
                    value: value,
                    onChanged: (next) {
                      changes.add(next);
                      setState(() => value = next);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final sign = direction == TextDirection.ltr ? 1.0 : -1.0;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppSwitch)),
      );
      await gesture.moveBy(Offset(25 * sign, 0));
      await gesture.moveBy(Offset(25 * sign, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, [true]);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('nested glass uses one bounded filter and large text fits', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3)),
            child: Scaffold(
              body: Column(
                children: [
                  MornyeGlassPanel(
                    child: MornyeSegmentedControl(
                      labels: const ['A', 'B'],
                      selectedIndex: 0,
                      onChanged: (_) {},
                    ),
                  ),
                  MornyeTabBar(
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home),
                        label: 'Home',
                      ),
                    ],
                    selectedIndex: 0,
                    onSelected: (_) {},
                    blurEnabled: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(MornyeGlassPanel),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(MornyeTabBar)).height, greaterThan(80));
    expect(tester.takeException(), isNull);
  });
}

class _OverflowForeground extends LeafRenderObjectWidget {
  const _OverflowForeground();

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderOverflowForeground();
}

class _RenderOverflowForeground extends RenderBox {
  @override
  void performLayout() => size = constraints.constrain(const Size(16, 40));

  @override
  Rect get paintBounds => Rect.fromLTRB(-280, 0, size.width, size.height);

  @override
  void paint(PaintingContext context, Offset offset) => context.canvas.drawRect(
    paintBounds.shift(offset),
    Paint()..color = Colors.white,
  );
}

Future<List<int>> _foregroundPixels(
  WidgetTester tester,
  GlobalKey capture,
  Finder finder,
  List<Color> colors,
) async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final rect = tester
      .getRect(finder)
      .shift(-boundary.localToGlobal(Offset.zero));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      final counts = List.filled(colors.length, 0);
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          final offset = (y * image.width + x) * 4;
          for (var i = 0; i < colors.length; i++) {
            final argb = colors[i].toARGB32();
            if ((bytes.getUint8(offset) - ((argb >> 16) & 255)).abs() <= 2 &&
                (bytes.getUint8(offset + 1) - ((argb >> 8) & 255)).abs() <= 2 &&
                (bytes.getUint8(offset + 2) - (argb & 255)).abs() <= 2) {
              counts[i]++;
            }
          }
        }
      }
      return counts;
    } finally {
      image.dispose();
    }
  }))!;
}
