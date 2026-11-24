import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/player_artwork.dart';

void main() {
  testWidgets('player rotation shares a short-side artwork decode size', (
    tester,
  ) async {
    final widths = <int>[];
    for (final size in [
      const Size(400, 900),
      const Size(900, 400),
      const Size(400, 900),
    ]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: 3),
          child: Builder(
            builder: (context) {
              widths.add(PlayerArtwork.transitionCacheWidth(context));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    }
    expect(widths, [1200, 1200, 1200]);
  });

  testWidgets(
    'track changes retain the decoded cover while the next image loads',
    (tester) async {
      final cache = PaintingBinding.instance.imageCache;
      addTearDown(() {
        cache.clear();
        cache.clearLiveImages();
      });
      Future<ui.Image> pixel(Color color) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(color, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        picture.dispose();
        return image;
      }

      final first = await tester.runAsync(() => pixel(Colors.red));
      final second = await tester.runAsync(() => pixel(Colors.blue));
      final pending = Completer<ImageInfo>();
      cache.putIfAbsent(
        FileImage(File('/cover-first.png')),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: first!)),
        ),
      );
      cache.putIfAbsent(
        FileImage(File('/cover-second.png')),
        () => OneFrameImageStreamCompleter(pending.future),
      );
      Widget app(String path) => MaterialApp(
        home: PlayerArtwork(
          artUri: path,
          colorScheme: const ColorScheme.dark(),
        ),
      );
      await tester.pumpWidget(app('/cover-first.png'));
      await tester.pump();
      final displayed = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(displayed, isNotNull);
      await tester.pumpWidget(app('/cover-second.png'));
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        same(displayed),
      );
      expect(find.byIcon(Icons.music_note), findsNothing);
      pending.complete(ImageInfo(image: second!));
      await tester.pumpAndSettle();
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        isNot(same(displayed)),
      );
      expect(find.byIcon(Icons.music_note), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final reducedMotion in [false, true]) {
    testWidgets('a crossfade reveals the next cover only once it has a frame '
        '(reduced motion: $reducedMotion)', (tester) async {
      final cache = PaintingBinding.instance.imageCache;
      addTearDown(() {
        cache.clear();
        cache.clearLiveImages();
      });
      Future<ui.Image> pixel(Color color) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(color, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        picture.dispose();
        return image;
      }

      final first = await tester.runAsync(() => pixel(Colors.red));
      final second = await tester.runAsync(() => pixel(Colors.blue));
      final pending = Completer<ImageInfo>();
      cache.putIfAbsent(
        FileImage(File('/fade-first.png')),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: first!)),
        ),
      );
      cache.putIfAbsent(
        FileImage(File('/fade-second.png')),
        () => OneFrameImageStreamCompleter(pending.future),
      );
      Widget app(String path) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: PlayerArtwork(
            artUri: path,
            colorScheme: const ColorScheme.dark(),
            crossfade: const AppMotionSpec(
              Duration(milliseconds: 200),
              Curves.linear,
            ),
          ),
        ),
      );
      List<ui.Image?> shown() => [
        for (final image in tester.widgetList<RawImage>(find.byType(RawImage)))
          image.image,
      ];

      await tester.pumpWidget(app('/fade-first.png'));
      await tester.pump();
      final displayed = shown().single;
      expect(displayed, isNotNull);

      // The old cover stays while the next one decodes.
      await tester.pumpWidget(app('/fade-second.png'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(shown(), [same(displayed)]);

      pending.complete(ImageInfo(image: second!));
      // The decoded frame lands a frame later; the fade starts after it.
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (reducedMotion) {
        expect(shown().single, isNot(same(displayed)));
      } else {
        // Both covers paint mid-fade, the new one over the old one.
        expect(shown(), hasLength(2));
        expect(shown().first, same(displayed));
        final fade = tester.widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(RawImage).last,
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        expect(fade.opacity.value, inExclusiveRange(0, 1));
      }

      await tester.pump(const Duration(milliseconds: 200));
      expect(shown().single, isNot(same(displayed)));
      expect(find.byIcon(Icons.music_note), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a growing crossfade waits for the frame, then fades and grows', (
    tester,
  ) async {
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() {
      cache.clear();
      cache.clearLiveImages();
    });
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.green, BlendMode.src);
      final picture = recorder.endRecording();
      final result = await picture.toImage(1, 1);
      picture.dispose();
      return result;
    });
    final pending = Completer<ImageInfo>();
    cache.putIfAbsent(
      FileImage(File('/grow-first.png')),
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image!.clone())),
      ),
    );
    cache.putIfAbsent(
      FileImage(File('/grow-second.png')),
      () => OneFrameImageStreamCompleter(pending.future),
    );
    Widget app(String path) => MaterialApp(
      home: PlayerArtwork(
        artUri: path,
        colorScheme: const ColorScheme.dark(),
        crossfade: const AppMotionSpec(
          Duration(milliseconds: 100),
          Curves.linear,
        ),
        crossfadeScale: const AppMotionSpec(
          Duration(milliseconds: 400),
          Curves.linear,
        ),
      ),
    );
    ({double opacity, double scale}) top() {
      final layer = find.byType(KeyedSubtree).last;
      return (
        opacity: tester
            .widget<FadeTransition>(
              find.descendant(of: layer, matching: find.byType(FadeTransition)),
            )
            .opacity
            .value,
        scale: tester
            .widget<ScaleTransition>(
              find
                  .descendant(of: layer, matching: find.byType(ScaleTransition))
                  .first,
            )
            .scale
            .value,
      );
    }

    await tester.pumpWidget(app('/grow-first.png'));
    await tester.pump();
    expect(top(), (opacity: 1.0, scale: 1.0));
    await tester.pumpWidget(app('/grow-second.png'));
    await tester.pump(const Duration(milliseconds: 300));
    // No frame yet: the new cover waits, hidden and small.
    expect(top(), (opacity: 0.0, scale: 0.94));

    pending.complete(ImageInfo(image: image!));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The fade is done well before the growth.
    expect(top().opacity, 1);
    expect(top().scale, inExclusiveRange(0.94, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(top(), (opacity: 1.0, scale: 1.0));
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a skip in the middle of a fade keeps fading from there', (
    tester,
  ) async {
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() {
      cache.clear();
      cache.clearLiveImages();
    });
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.green, BlendMode.src);
      final picture = recorder.endRecording();
      final result = await picture.toImage(1, 1);
      picture.dispose();
      return result;
    });
    for (final name in ['first', 'second', 'third']) {
      cache.putIfAbsent(
        FileImage(File('/skip-$name.png')),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: image!.clone())),
        ),
      );
    }
    Widget app(String name) => MaterialApp(
      home: PlayerArtwork(
        artUri: '/skip-$name.png',
        colorScheme: const ColorScheme.dark(),
        crossfade: const AppMotionSpec(
          Duration(milliseconds: 200),
          Curves.linear,
        ),
      ),
    );
    List<double> opacities() => [
      for (final fade in tester.widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(PlayerArtwork),
          matching: find.byType(FadeTransition),
        ),
      ))
        fade.opacity.value,
    ];

    await tester.pumpWidget(app('first'));
    await tester.pump();
    await tester.pumpWidget(app('second'));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final halfway = opacities().last;
    expect(halfway, inExclusiveRange(0, 1));

    // The next song arrives mid-fade: the half-faded cover neither snaps
    // to full nor vanishes, and keeps fading in under the next one.
    await tester.pumpWidget(app('third'));
    expect(opacities(), [1, halfway, 0]);
    await tester.pump(const Duration(milliseconds: 16));
    expect(opacities()[1], greaterThan(halfway));

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 16));
    expect(opacities(), [1]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    image!.dispose();
  });

  testWidgets('covers with no file show the placeholder without throwing', (
    tester,
  ) async {
    for (final uri in [
      'file://nas/covers/a.jpg',
      'file:///covers/a.jpg?size=large',
      'content://media/cover',
      'covers/a.jpg',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerArtwork(
            artUri: uri,
            colorScheme: const ColorScheme.dark(),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: uri);
      expect(find.byType(Image), findsNothing, reason: uri);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is AppIcon && widget.icon == Icons.music_note,
        ),
        findsOneWidget,
        reason: uri,
      );
    }
  });
}
