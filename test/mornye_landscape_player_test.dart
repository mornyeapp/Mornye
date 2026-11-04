import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_landscape_player.dart';

void main() {
  Future<void> pumpPlayer(
    WidgetTester tester, {
    GlobalKey? capture,
    bool blur = true,
    bool playing = true,
    TextDirection direction = TextDirection.ltr,
    double? playerWidth,
    bool accessibleNavigation = false,
  }) async {
    tester.view.physicalSize = const Size(852, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var page = 1;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lowEndDeviceProvider.overrideWithValue(true),
          backdropBlurEnabledProvider.overrideWithValue(blur),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(accessibleNavigation: accessibleNavigation),
            child: Directionality(textDirection: direction, child: child!),
          ),
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: const Color(0xFF303030),
            body: SizedBox(
              width: playerWidth,
              child: RepaintBoundary(
                key: capture,
                child: StatefulBuilder(
                  builder: (context, setState) => MornyeLandscapePlayer(
                    page: page,
                    isPlaying: playing,
                    onPageChanged: (value) => setState(() => page = value),
                    artwork: const SizedBox.expand(
                      child: ColoredBox(
                        key: ValueKey('artwork'),
                        color: Colors.transparent,
                      ),
                    ),
                    header: const SizedBox(height: 48),
                    lyrics: const CustomPaint(painter: _Stripes()),
                    queue: const SizedBox.expand(),
                    controls: const SizedBox(height: 68),
                    volume: const SizedBox(height: 48),
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

  for (final direction in TextDirection.values) {
    for (final playing in [false, true]) {
      testWidgets('artwork toggles actions in a constrained $direction player '
          '(playing: $playing)', (tester) async {
        await pumpPlayer(
          tester,
          playing: playing,
          direction: direction,
          playerWidth: 600,
        );
        final toggle = find.byIcon(CupertinoIcons.quote_bubble);
        final artwork = find.byKey(const ValueKey('artwork'));
        expect(toggle.hitTestable(), findsOneWidget);
        await tester.tap(artwork);
        await tester.pumpAndSettle();
        expect(toggle.hitTestable(), findsNothing);
        await tester.tap(artwork);
        await tester.pumpAndSettle();
        expect(toggle.hitTestable(), findsOneWidget);

        await tester.tap(artwork);
        await tester.pumpAndSettle();
        expect(toggle.hitTestable(), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('landscape-lyrics-viewport')),
        );
        await tester.pumpAndSettle();
        expect(toggle.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('accessible navigation keeps actions visible on artwork taps', (
    tester,
  ) async {
    await pumpPlayer(tester, accessibleNavigation: true);
    await tester.tap(find.byKey(const ValueKey('artwork')));
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.byIcon(CupertinoIcons.quote_bubble).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape selected tabs use the neutral portrait colors', (
    tester,
  ) async {
    await pumpPlayer(tester);
    final lyrics = find.byIcon(CupertinoIcons.quote_bubble);
    final queue = find.byIcon(CupertinoIcons.list_bullet);
    void expectColors(Finder icon, {required bool selected}) {
      expect(IconTheme.of(tester.element(icon)).color, Colors.white);
      final surface = tester.widget<Material>(
        find.ancestor(of: icon, matching: find.byType(Material)).first,
      );
      expect(
        surface.color,
        selected ? Colors.white.withValues(alpha: 0.16) : Colors.transparent,
      );
    }

    expectColors(lyrics, selected: true);
    expectColors(queue, selected: false);
    await tester.tap(queue);
    await tester.pumpAndSettle();
    expectColors(lyrics, selected: false);
    expectColors(queue, selected: true);
    expect(tester.takeException(), isNull);
  });

  for (final blur in [false, true]) {
    testWidgets('landscape footer clears text behind controls (blur: $blur)', (
      tester,
    ) async {
      final capture = GlobalKey();
      await pumpPlayer(tester, capture: capture, blur: blur);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('landscape-lyrics-viewport')),
      );
      Future<int?> contrast(double aboveBottom) => tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage();
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final origin = boundary.globalToLocal(
            Offset(viewport.left + 100, viewport.bottom - aboveBottom),
          );
          final samples = List.generate(
            64,
            (x) => pixels.getUint8(
              ((origin.dy.floor() * image.width) + origin.dx.floor() + x) * 4,
            ),
          )..sort();
          return samples.last - samples.first;
        } finally {
          image.dispose();
        }
      });

      expect(await contrast(10), lessThan(5));
      final transitionContrast = (await contrast(74))!;
      // A longer opacity fade clears the footer on every GPU, without three
      // overlapping backdrop filters over the moving lyric content.
      expect(transitionContrast, lessThan(110));
      expect(find.byType(BackdropFilter), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(await contrast(10), greaterThan(240));
      expect(tester.takeException(), isNull);
    });
  }
}

class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 8, size.height),
        Paint()..color = (x ~/ 8).isEven ? Colors.white : Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}
