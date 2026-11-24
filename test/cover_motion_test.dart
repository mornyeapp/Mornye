import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/hover_play_button.dart';

const _url = 'https://covers.example.com/cover.jpg';
const _placeholderKey = ValueKey('placeholder');
const _artKey = ValueKey('art');

Widget _app(Widget child, {bool mornye = false, bool reduced = false}) =>
    MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

Widget _cover({Duration? fadeInDuration}) => CachedCoverImage(
  imageUrl: _url,
  width: 100,
  height: 100,
  memCacheWidth: 100,
  fadeInDuration: fadeInDuration,
  placeholder: (_, _) => const ColoredBox(
    key: _placeholderKey,
    color: Colors.grey,
    child: SizedBox.square(dimension: 100),
  ),
);

/// Seeds the memory cache entry the cover above resolves to, so no network
/// or disk cache is involved.
Object _cacheKey() {
  late Object key;
  ResizeImage(
    cachedCoverImageProvider(_url),
    width: 100,
  ).obtainKey(ImageConfiguration.empty).then((value) => key = value);
  return key;
}

double? _placeholderOpacity(WidgetTester tester) {
  final placeholder = find.byKey(_placeholderKey);
  if (placeholder.evaluate().isEmpty) return null;
  final fades = find.ancestor(
    of: placeholder,
    matching: find.byType(FadeTransition),
  );
  if (fades.evaluate().isEmpty) return 1;
  return tester.widget<FadeTransition>(fades.first).opacity.value;
}

void main() {
  late ui.Image image;

  setUpAll(() async {
    image = await createTestImage(width: 4, height: 4);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    debugDesktopPlatformOverride = null;
  });

  group('network cover fade', () {
    Future<Completer<ImageInfo>> seedPending() async {
      final pending = Completer<ImageInfo>();
      PaintingBinding.instance.imageCache.putIfAbsent(
        _cacheKey(),
        () => OneFrameImageStreamCompleter(pending.future),
      );
      return pending;
    }

    testWidgets('dissolves the placeholder once the cover decodes', (
      tester,
    ) async {
      final pending = await seedPending();
      await tester.pumpWidget(_app(_cover()));
      expect(_placeholderOpacity(tester), 1);

      pending.complete(ImageInfo(image: image.clone()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final opacity = _placeholderOpacity(tester)!;
      expect(opacity, greaterThan(0));
      expect(opacity, lessThan(1));
      // The cover underneath is already opaque, so the page never shows.
      final cover = find.ancestor(
        of: find.byType(RawImage),
        matching: find.byType(FadeTransition),
      );
      expect(tester.widget<FadeTransition>(cover.first).opacity.value, 1);

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(_placeholderKey), findsNothing);
    });

    testWidgets('a cover in the memory cache shows without a fade', (
      tester,
    ) async {
      PaintingBinding.instance.imageCache.putIfAbsent(
        _cacheKey(),
        () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: image.clone())),
        ),
      );
      await tester.pumpWidget(_app(_cover()));
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.byKey(_placeholderKey), findsNothing);
      // Only the route's own transitions sit above it, all at rest.
      final fades = tester.widgetList<FadeTransition>(
        find.ancestor(
          of: find.byType(RawImage),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fades.map((fade) => fade.opacity.value), everyElement(1));
    });

    testWidgets('each style fades on its own effects spring', (tester) async {
      await tester.pumpWidget(_app(_cover()));
      var widget = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      final material = AppMotion.effectsFast(
        tester.element(find.byType(CachedCoverImage)),
        const AppMotionSpec(Duration.zero, Curves.linear),
      );
      expect(material.duration, greaterThan(Duration.zero));
      expect(widget.fadeOutDuration, material.duration);
      expect(widget.fadeOutCurve, material.curve);
      expect(widget.fadeInDuration, Duration.zero);

      await tester.pumpWidget(_app(_cover(), mornye: true));
      // Let the app's theme animation reach the Mornye theme.
      await tester.pump(const Duration(seconds: 1));
      widget = tester.widget(find.byType(CachedNetworkImage));
      expect(widget.fadeOutDuration, MornyeMotion.effectsFast.duration);
      expect(widget.fadeOutCurve, MornyeMotion.effectsFast.curve);
    });

    testWidgets('reduced motion and an explicit zero cut the cover in', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_cover(), reduced: true));
      var widget = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(widget.fadeInDuration, Duration.zero);
      expect(widget.fadeOutDuration, Duration.zero);

      await tester.pumpWidget(_app(_cover(fadeInDuration: Duration.zero)));
      widget = tester.widget(find.byType(CachedNetworkImage));
      expect(widget.fadeInDuration, Duration.zero);
      expect(widget.fadeOutDuration, Duration.zero);
    });
  });

  group('desktop cover hover', () {
    Widget tile({bool mornye = false, bool reduced = false}) => _app(
      SizedBox.square(
        dimension: 160,
        child: GestureDetector(
          onTap: () {},
          child: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(key: _artKey, color: Colors.grey),
              ),
              DesktopCoverHover(borderRadius: BorderRadius.circular(10)),
            ],
          ),
        ),
      ),
      mornye: mornye,
      reduced: reduced,
    );

    double layerAlpha(WidgetTester tester) {
      final box = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('desktop-hover-layer')),
      );
      return (box.decoration! as BoxDecoration).color!.a;
    }

    for (final reduced in [false, true]) {
      testWidgets('Material shows the hover and press state layer'
          '${reduced ? ' under reduced motion' : ''}', (tester) async {
        debugDesktopPlatformOverride = true;
        await tester.pumpWidget(tile(reduced: reduced));
        expect(layerAlpha(tester), 0);
        expect(find.byType(IconButton), findsNothing);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(find.byKey(_artKey)));
        await tester.pump();
        expect(layerAlpha(tester), closeTo(0.08, 0.001));
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );

        await mouse.down(tester.getCenter(find.byKey(_artKey)));
        await tester.pump();
        expect(layerAlpha(tester), closeTo(0.10, 0.001));
        await mouse.up();
        await tester.pump();
        expect(layerAlpha(tester), closeTo(0.08, 0.001));

        await mouse.moveTo(const Offset(1, 1));
        await tester.pump();
        expect(layerAlpha(tester), 0);
        await tester.pump(const Duration(milliseconds: 400));
        await mouse.removePointer();
      });
    }

    testWidgets('Mornye dims the cover and darkens it while pressed', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      await tester.pumpWidget(tile(mornye: true));
      final scrim = find.byKey(const ValueKey('desktop-hover-scrim'));
      expect(tester.widget<AnimatedOpacity>(scrim).opacity, 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final center = tester.getCenter(find.byKey(_artKey));
      await mouse.addPointer(location: center);
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(scrim).opacity, 1);
      Color scrimColor() =>
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: scrim,
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      final resting = scrimColor();
      await mouse.down(center);
      await tester.pump();
      expect(scrimColor().a, greaterThan(resting.a));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 400));
      await mouse.removePointer();
    });

    testWidgets('phones show no hover', (tester) async {
      debugDesktopPlatformOverride = false;
      await tester.pumpWidget(tile());
      expect(find.byKey(const ValueKey('desktop-hover-layer')), findsNothing);
    });
  });
}
