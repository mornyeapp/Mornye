import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

// The shared cover store keeps a warm-up started in an earlier test's zone,
// so the test reading it lives in this file of its own.
void main() {
  const ref = 'network://nas/Album/cover.jpg';

  testWidgets('a network cover the store holds shows its stored file', (
    tester,
  ) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('stored-cover-'),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => directory!.path);
    try {
      // Stored by an earlier run, which the shared store reads on warm-up.
      final stored = await tester.runAsync(() async {
        final png = await _png();
        final earlier = CoverStore(
          directory: () async => Directory('${directory!.path}/covers'),
          fetch: (_, output) => output.writeAsBytes(png),
        );
        final path = await earlier.file(ref);
        await earlier.dispose();
        expect(coverFilePath(ref), isNull);
        await CoverStore.instance.warmUp();
        return path;
      });
      expect(stored, isNotNull);
      expect(coverFilePath(ref), stored);
      expect(coverImageSource(ref), stored);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LocalOrNetworkCoverImage(
              url: ref,
              width: 56,
              height: 56,
              placeholder: (_) => const SizedBox.square(
                key: ValueKey('placeholder'),
                dimension: 56,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('placeholder')), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      messenger.setMockMethodCallHandler(paths, null);
      await tester.runAsync(() => directory!.delete(recursive: true));
    }
  });

  testWidgets('a network cover not stored yet shows once it is fetched', (
    tester,
  ) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('pending-cover-'),
    );
    final arrive = Completer<void>();
    var fetches = 0;
    final covers = CoverStore(
      directory: () async => directory!,
      fetch: (_, output) async {
        fetches++;
        await arrive.future;
        await output.writeAsBytes([0xFF, 0xD8, 0xFF, 0]);
      },
    );
    Widget cover(String? source) => MaterialApp(
      home: pendingCover(
        source,
        covers: covers,
        placeholder: const Text('placeholder'),
        builder: (_) => Text('stored ${covers.indexedFile(source)}'),
      ),
    );
    final stored = find.textContaining('stored');
    try {
      await tester.pumpWidget(cover(ref));
      expect(find.text('placeholder'), findsOneWidget);
      arrive.complete();
      // The fetch reads and writes real files between frames.
      for (var i = 0; i < 200 && stored.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(covers.indexedFile(ref), isNotNull);
      expect(find.text('stored ${covers.indexedFile(ref)}'), findsOneWidget);
      expect(fetches, 1);

      for (final source in [
        null,
        'content://media/cover',
        '${directory!.path}/missing.jpg',
      ]) {
        await tester.pumpWidget(cover(source));
        expect(find.text('placeholder'), findsOneWidget, reason: source);
      }
      expect(fetches, 1);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await covers.dispose();
        await directory!.delete(recursive: true);
      });
    }
  });
}

Future<List<int>> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}
