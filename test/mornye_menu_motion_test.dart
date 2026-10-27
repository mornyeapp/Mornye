import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/mornye_squircle_border.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(
    WidgetTester tester,
    Rect anchor, {
    bool reduced = false,
    GlobalKey? capture,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.frosted),
          mornyeBlurEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark, glassClarity: 1),
          builder: (context, child) => RepaintBoundary(
            key: capture,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: reduced,
                padding: const EdgeInsets.symmetric(vertical: 24),
              ),
              child: child!,
            ),
          ),
          home: Scaffold(
            backgroundColor: const Color(0xff366a77),
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showMornyeContextMenu<void>(
                    context: context,
                    anchor: anchor,
                    builder: (context) => MornyeContextMenu(
                      groups: [
                        [
                          MornyeMenuAction(
                            icon: Icons.play_arrow,
                            label: 'Play',
                            onPressed: () => Navigator.pop(context),
                          ),
                          MornyeMenuAction(
                            icon: Icons.queue_music,
                            label: 'Add to queue',
                            onPressed: () {},
                          ),
                          MornyeMenuAction(
                            icon: Icons.album,
                            label: 'Go to album',
                            onPressed: () {},
                          ),
                        ],
                      ],
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
  }

  Rect visibleBounds(WidgetTester tester) {
    final box = tester.renderObject<RenderBox>(find.byType(MornyeContextMenu));
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  MornyeGlassPanel panel(WidgetTester tester) =>
      tester.widget<MornyeGlassPanel>(find.byType(MornyeGlassPanel));

  Future<Color> surfaceColor(WidgetTester tester, GlobalKey capture) async =>
      (await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final menu = tester.renderObject<RenderBox>(
          find.byType(MornyeContextMenu),
        );
        final point = boundary.globalToLocal(
          menu.localToGlobal(Offset(12, menu.size.height / 2)),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final index = (point.dy.floor() * image.width + point.dx.floor()) * 4;
          return Color.fromARGB(
            pixels.getUint8(index + 3),
            pixels.getUint8(index),
            pixels.getUint8(index + 1),
            pixels.getUint8(index + 2),
          );
        } finally {
          image.dispose();
        }
      }))!;

  for (final anchor in [
    const Rect.fromLTWH(325, 100, 44, 44),
    const Rect.fromLTWH(16, 720, 44, 44),
  ]) {
    testWidgets('menu carries glass throughout its flight from $anchor', (
      tester,
    ) async {
      final capture = GlobalKey();
      await open(tester, anchor, capture: capture);
      final first = visibleBounds(tester);
      expect(first.center.dx, closeTo(anchor.center.dx, 0.01));
      expect(first.center.dy, closeTo(anchor.center.dy, 0.01));
      expect(first.width, closeTo(320 * 0.16, 0.01));
      expect(find.byType(BackdropFilter), findsOneWidget);
      final backdrop = tester.element(find.byType(BackdropFilter));
      await tester.pump(const Duration(milliseconds: 100));
      final flying = visibleBounds(tester);
      expect(flying.width, greaterThan(first.width));
      expect(flying.width, lessThan(320));
      expect(panel(tester).glassProgress, 1);
      expect(tester.element(find.byType(BackdropFilter)), same(backdrop));
      final openingColor = await surfaceColor(tester, capture);
      await tester.pump(const Duration(milliseconds: 140));
      final resting = visibleBounds(tester);
      expect(resting.width, closeTo(320, 0.01));
      expect(panel(tester).glassProgress, 1);
      expect(tester.element(find.byType(BackdropFilter)), same(backdrop));
      await tester.pumpAndSettle();
      expect(visibleBounds(tester), resting);
      expect(panel(tester).glassProgress, 1);
      final settledColor = await surfaceColor(tester, capture);
      // The material keeps its tint while it grows. Only the modal barrier
      // darkens the backdrop slightly as the route finishes opening.
      expect(openingColor.r, closeTo(settledColor.r, 0.02));
      expect(openingColor.g, closeTo(settledColor.g, 0.02));
      expect(openingColor.b, closeTo(settledColor.b, 0.02));
      expect(resting.left, greaterThanOrEqualTo(16));
      expect(resting.right, lessThanOrEqualTo(374));
      expect(resting.top, greaterThanOrEqualTo(40));
      expect(resting.bottom, lessThanOrEqualTo(804));
      expect(panel(tester).smoothCorners, isTrue);
      expect(panel(tester).radius, 28);
      // The outside clip follows the same squircle as the lens and rim.
      final shapes = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<ShapeDecoration>();
      expect(shapes.any((d) => d.shape is MornyeSquircleBorder), isTrue);
      await tester.tap(find.text('Play'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(panel(tester).glassProgress, 1);
      expect(tester.element(find.byType(BackdropFilter)), same(backdrop));
      await tester.pumpAndSettle();
      expect(find.byType(MornyeContextMenu), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Reduce Motion opens the finished glass menu immediately', (
    tester,
  ) async {
    await open(tester, const Rect.fromLTWH(325, 100, 44, 44), reduced: true);
    await tester.pump();
    expect(visibleBounds(tester).width, 320);
    expect(panel(tester).glassProgress, 1);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(find.byType(MornyeContextMenu), findsNothing);
  });
}
