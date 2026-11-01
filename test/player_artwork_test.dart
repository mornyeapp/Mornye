import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
