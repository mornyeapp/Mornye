import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/player_artwork.dart';

// The shared cover store keeps its warm-up for the rest of the isolate, so
// this test lives in a file of its own.
void main() {
  testWidgets('a crossfade to a network cover the store cannot fetch shows '
      'its placeholder instead of keeping the previous cover', (tester) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('unavailable-cover-'),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => directory!.path);
    final cache = PaintingBinding.instance.imageCache;
    try {
      // Only adopted song covers answer this reference, and none is stored.
      const unavailable = 'network://nas/Album/song.flac#cover';
      await tester.runAsync(CoverStore.instance.warmUp);
      final first = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.red, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        picture.dispose();
        return image;
      });
      cache.putIfAbsent(
        FileImage(File('/unavailable-first.png')),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: first!)),
        ),
      );
      Widget app(String path) => MaterialApp(
        home: PlayerArtwork(
          artUri: path,
          colorScheme: const ColorScheme.dark(),
          crossfade: const AppMotionSpec(
            Duration(milliseconds: 200),
            Curves.linear,
          ),
        ),
      );

      await tester.pumpWidget(app('/unavailable-first.png'));
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);

      await tester.pumpWidget(app(unavailable));
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(AppIcon), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache
        ..clear()
        ..clearLiveImages();
      messenger.setMockMethodCallHandler(paths, null);
      await tester.runAsync(() => directory!.delete(recursive: true));
    }
  });
}
