import 'dart:math' as math;
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
    final box = tester.renderObject<RenderBox>(find.byType(MornyeGlassPanel));
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  MornyeGlassPanel panel(WidgetTester tester) =>
      tester.widget<MornyeGlassPanel>(find.byType(MornyeGlassPanel));

  /// The box the menu keeps throughout its flight.
  Size resting(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byType(MornyeContextMenu)).size;

  Future<Color> surfaceColor(WidgetTester tester, GlobalKey capture) async =>
      (await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final menu = tester.renderObject<RenderBox>(
          find.byType(MornyeGlassPanel),
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
      // The second frame has measured the menu and placed the drop.
      await tester.pump();
      final first = visibleBounds(tester);
      expect(first.center.dx, closeTo(anchor.center.dx, 0.01));
      expect(first.center.dy, closeTo(anchor.center.dy, 0.01));
      expect(first.size, const Size.square(44));
      expect(panel(tester).radius, 22, reason: 'a round drop at the control');
      expect(find.byType(BackdropFilter), findsOneWidget);
      final backdrop = tester.element(find.byType(BackdropFilter));
      await tester.pump(const Duration(milliseconds: 100));
      final flying = visibleBounds(tester);
      expect(flying.width, greaterThan(first.width));
      expect(flying.width, lessThan(320));
      expect(
        flying.height / resting(tester).height,
        greaterThan(flying.width / 320),
        reason: 'the height runs ahead of the width',
      );
      expect(panel(tester).glassProgress, 1);
      expect(tester.element(find.byType(BackdropFilter)), same(backdrop));
      final openingColor = await surfaceColor(tester, capture);
      await tester.pump(const Duration(milliseconds: 140));
      var widest = 0.0;
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        widest = math.max(widest, visibleBounds(tester).width);
      }
      expect(widest, greaterThan(320), reason: 'the glass runs past its size');
      expect(widest, lessThan(320 * 1.04));
      expect(panel(tester).glassProgress, 1);
      expect(tester.element(find.byType(BackdropFilter)), same(backdrop));
      await tester.pumpAndSettle();
      final resting_ = visibleBounds(tester);
      expect(resting_.width, closeTo(320, 0.01));
      expect(panel(tester).glassProgress, 1);
      final settledColor = await surfaceColor(tester, capture);
      // The material keeps its tint while it grows. Only the modal barrier
      // darkens the backdrop slightly as the route finishes opening.
      expect(openingColor.r, closeTo(settledColor.r, 0.02));
      expect(openingColor.g, closeTo(settledColor.g, 0.02));
      expect(openingColor.b, closeTo(settledColor.b, 0.02));
      expect(resting_.left, greaterThanOrEqualTo(16));
      expect(resting_.right, lessThanOrEqualTo(374));
      expect(resting_.top, greaterThanOrEqualTo(40));
      expect(resting_.bottom, lessThanOrEqualTo(804));
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
