import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_selection_pill.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('held foreground reaches the curved glass edge', (tester) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        // Measure the foreground mask independently of the rim's lighting.
        theme: MornyeTheme.build(Brightness.dark, glassOutlines: false),
        home: Center(
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 360,
              child: MornyeSelectionPill(
                labels: const ['Home', 'Library', 'Repo', 'Search'],
                selectedIndex: 0,
                onChanged: (_) {},
                padding: EdgeInsets.zero,
                liquidInteraction: true,
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
    await tester.runAsync(() async {
      await LiquidGlassShaders.ensureLoaded();
      await ui.FragmentProgram.fromAsset(
        'assets/shaders/mornye_selection_mask.frag',
      );
    });
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byType(MornyeSelectionPill));
    final gesture = await tester.startGesture(
      row.topLeft + const Offset(45, 32),
    );
    await gesture.moveTo(row.topLeft + const Offset(90, 32));
    await tester.pump();
    final lens = find.byWidgetPredicate(
      (widget) => widget is MornyeLiquidBackdrop && widget.interaction,
    );
    for (final duration in [
      const Duration(milliseconds: 60),
      const Duration(milliseconds: 240),
    ]) {
      await tester.pump(duration);
      final bounds = tester.getRect(lens).shift(-row.topLeft);
      final pixels = (await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData())!;
          return [
            for (final point in [
              Offset(bounds.left + 2, 32),
              Offset(bounds.right - 3, 32),
              Offset(bounds.left + 2, 2),
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
      // The package's edge blur can soften RGB values. A clipped foreground
      // would expose the white fixture instead of red on either curved edge.
      for (final pixel in pixels.take(2)) {
        expect(pixel.a, 1);
        expect(pixel.r - pixel.g, greaterThan(0.55));
        expect(pixel.r - pixel.b, greaterThan(0.55));
      }
      expect(pixels.last.toARGB32(), Colors.white.toARGB32());
    }
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Impeller lens refracts its own bounds and preserves foreground',
    (tester) async {
      expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
      final key = GlobalKey();
      final movement = ValueNotifier<double>(0);
      addTearDown(movement.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: LiquidGlassBatch(
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.black, Colors.white],
                        ),
                      ),
                    ),
                  ),
                  for (final top in [160.0, 320.0])
                    Positioned(
                      left: 40,
                      top: top,
                      width: 300,
                      height: 80,
                      child: ValueListenableBuilder<double>(
                        valueListenable: movement,
                        builder: (context, value, child) => Transform.translate(
                          offset: Offset(value, 0),
                          child: Transform.scale(
                            scale: top == 320 ? 0.8 : 1,
                            child: child,
                          ),
                        ),
                        child: RepaintBoundary(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(40),
                            child: MornyeLiquidBackdrop(
                              borderRadius: BorderRadius.circular(40),
                              clarity: 1,
                              blurSigma: 2,
                              child: const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: ColoredBox(color: Color(0xff00ff00)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      // Asset compilation completes outside the fake widget-test clock.
      await tester.runAsync(() => LiquidGlassShaders.ensureLoaded());
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final pixelRatio = tester.view.devicePixelRatio;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final bytes = (await image.toByteData())!;
      int channel(int x, int y, int c) => bytes.getUint8(
        ((y * pixelRatio).round() * image.width + (x * pixelRatio).round()) *
                4 +
            c,
      );
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final directory = await getTemporaryDirectory();
      await File('${directory.path}/mornye-lens-check.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      debugPrint('Glass diagnostic: ${directory.path}/mornye-lens-check.png');
      for (final y in [200, 360]) {
        // An inward lens shifts the left edge into the brighter background.
        final edgeX = y == 200 ? 42 : 72;
        expect(channel(edgeX, y, 0), greaterThan(channel(edgeX, 100, 0) + 4));
        // The middle of the backdrop remains at its original screen position.
        expect(channel(150, y, 0), closeTo(channel(150, 100, 0), 2));
        if (y == 200) {
          expect(channel(190, y, 0), 0);
          expect(channel(190, y, 1), 255);
          expect(channel(190, y, 2), 0);
        }
      }
      expect(channel(20, 200, 0), channel(20, 100, 0));
      image.dispose();
      movement.value = 20;
      await tester.pumpAndSettle();
      final moved = await boundary.toImage(pixelRatio: pixelRatio);
      final movedBytes = (await moved.toByteData())!;
      int red(int x, int y) => movedBytes.getUint8(
        ((y * pixelRatio).round() * moved.width + (x * pixelRatio).round()) * 4,
      );
      expect(red(62, 200), greaterThan(red(62, 100) + 4));
      expect(red(92, 360), greaterThan(red(92, 100) + 4));
      moved.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('held lens follows a drag and releases without changing taps', (
    tester,
  ) async {
    var selected = 0;
    final changes = <int>[];
    final theme = MornyeTheme.build(Brightness.dark, glassClarity: 1);
    final lens = find.byWidgetPredicate(
      (widget) => widget is MornyeLiquidBackdrop && widget.interaction,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceSupportsLiquidGlassProvider.overrideWithValue(true)],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xffb35c28),
                          Color(0xff3f276d),
                          Color(0xff264e75),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (var i = 0; i < 10; i++)
                        Text(
                          'Music • Library • Albums',
                          style: theme.textTheme.headlineMedium,
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 40,
                  child: StatefulBuilder(
                    builder: (context, setState) => MornyeTabBar(
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home),
                          label: 'Home',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.library_music),
                          label: 'Library',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.search),
                          label: 'Search',
                        ),
                      ],
                      selectedIndex: selected,
                      blurEnabled: true,
                      onSelected: (value) {
                        changes.add(value);
                        setState(() => selected = value);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LiquidGlassLens), findsOneWidget);
    final pill = find.descendant(
      of: find
          .descendant(
            of: find.byType(MornyeSelectionPill),
            matching: find.byType(AnimatedAlign),
          )
          .first,
      matching: find.byType(FractionallySizedBox),
    );
    final restingSurface = find.descendant(
      of: pill,
      matching: find.byType(DecoratedBox),
    );
    final icons = find.descendant(
      of: find.byType(MornyeSelectionPill),
      matching: find.byType(Icon),
    );
    final iconSizes = [for (final icon in icons.evaluate()) icon.size];
    void expectSingleContour() {
      // Both surfaces must share one silhouette throughout the transition;
      // the fixed smaller pill must never show through the growing lens.
      expect(tester.getRect(restingSurface), tester.getRect(lens));
      expect([for (final icon in icons.evaluate()) icon.size], iconSizes);
    }

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Home')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expectSingleContour();
    await tester.pumpAndSettle();
    expect(tester.widget<MornyeLiquidBackdrop>(lens).progress, 1);
    expect(find.byType(LiquidGlassLens), findsNWidgets(2));
    expectSingleContour();
    final heldRestingDecoration =
        tester.widget<DecoratedBox>(restingSurface).decoration as BoxDecoration;
    expect(heldRestingDecoration.color!.a, 0);
    expect((heldRestingDecoration.border! as Border).top.color.a, 0);
    expect(heldRestingDecoration.boxShadow!.single.color.a, 0);
    final home = tester.getCenter(find.text('Home'));
    final library = tester.getCenter(find.text('Library'));
    final heldWidth =
        tester.getBottomRight(lens).dx - tester.getTopLeft(lens).dx;
    expect(heldWidth, greaterThan(tester.getSize(pill).width * 1.2));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<MornyeLiquidBackdrop>(lens).progress, 1);
    expect(changes, isEmpty);
    for (final fraction in [0.35, 0.45, 0.85, 1.2, 1.1, 0.9, 1.5]) {
      final position = Offset(
        home.dx + (library.dx - home.dx) * fraction,
        home.dy,
      );
      await gesture.moveTo(position);
      await tester.pump();
      expect(tester.getCenter(pill).dx, closeTo(position.dx, 0.1));
      expect(tester.getCenter(lens).dx, closeTo(position.dx, 0.1));
      expectSingleContour();
      expect(changes, isEmpty);
    }
    if (const bool.fromEnvironment('GLASS_PREVIEW')) {
      debugPrint('GLASS_PREVIEW: holding Home');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 25)),
      );
    }
    await gesture.moveTo(tester.getCenter(find.text('Search')));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(
      tester.getCenter(pill).dx,
      closeTo(tester.getCenter(find.text('Search')).dx, 0.1),
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expectSingleContour();
    await tester.pumpAndSettle();
    expect(changes, [2]);
    expect(tester.widget<MornyeLiquidBackdrop>(lens).progress, 0);
    expectSingleContour();
    expect(find.byType(LiquidGlassLens), findsOneWidget);
    final cancel = await tester.startGesture(
      tester.getCenter(find.text('Search')),
    );
    await cancel.moveTo(tester.getCenter(find.text('Home')));
    await tester.pumpAndSettle();
    await cancel.cancel();
    await tester.pumpAndSettle();
    expect(changes, [2]);
    expect(
      tester.getCenter(pill).dx,
      closeTo(tester.getCenter(find.text('Search')).dx, 0.1),
    );
    expect(tester.takeException(), isNull);
  });
}
