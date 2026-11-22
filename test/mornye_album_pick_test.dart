import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/mornye_album_pick.dart';

const _width = 240.0;
const _height = _width * 4 / 3;

/// A one-colour cover file, decoded into the image cache the way the card
/// asks for it.
Future<String> _cover(WidgetTester tester, Directory directory, Color color) =>
    tester
        .runAsync(() async {
          final file = File('${directory.path}/${color.toARGB32()}.png');
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(color, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(32, 32);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          final provider = coverImageProvider(
            file.path,
            cacheWidth: _width.round(),
          )!;
          final stream = provider.resolve(ImageConfiguration.empty);
          final done = Completer<void>();
          late final ImageStreamListener listener;
          listener = ImageStreamListener((info, _) {
            info.dispose();
            stream.removeListener(listener);
            done.complete();
          });
          stream.addListener(listener);
          await done.future;
          return file.path;
        })
        .then((path) => path!);

ByteData _pixels(int width, int height, int Function(int y) grey) {
  final data = ByteData(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        data.setUint8(index + channel, grey(y));
      }
      data.setUint8(index + 3, 255);
    }
  }
  return data;
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('album-pick-');
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(400, 800);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.single.reset();
  });

  /// Shows the card and lets it decode its cover and read the soft copy.
  Future<void> pumpPick(WidgetTester tester, {required String? artUri}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: MornyeAlbumPick(
            artUri: artUri,
            title: 'Album',
            eyebrow: 'New release',
            subtitle: 'Artist',
            width: _width,
          ),
        ),
      ),
    );
    for (var round = 0; round < 2; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(MornyeAlbumPick),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  /// How dark the caption's end is.
  double dim(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(MornyeAlbumPick),
        matching: find.byType(DecoratedBox),
      ),
    );
    final gradient = (box.decoration as BoxDecoration).gradient!;
    return gradient.colors.last.a;
  }

  group('how dark the caption\'s end is', () {
    test('a dark cover keeps the least', () {
      expect(
        MornyeAlbumPick.captionDim(
          _pixels(8, 8, (_) => 20),
          width: 8,
          height: 8,
        ),
        MornyeAlbumPick.leastDim,
      );
    });

    test('a white cover is brought down for white labels', () {
      final dim = MornyeAlbumPick.captionDim(
        _pixels(8, 8, (_) => 255),
        width: 8,
        height: 8,
      );
      expect(dim, inInclusiveRange(0.45, 0.6));
      // What is left is no lighter than the labels can sit on.
      final left = (255 * (1 - dim)).round();
      expect(
        Color.fromARGB(255, left, left, left).computeLuminance(),
        lessThan(0.25),
      );
    });

    test('only the part under the caption counts', () {
      expect(
        MornyeAlbumPick.captionDim(
          _pixels(8, 8, (y) => y < 4 ? 255 : 10),
          width: 8,
          height: 8,
        ),
        MornyeAlbumPick.leastDim,
      );
    });
  });

  testWidgets('without a cover the card still says what it is', (tester) async {
    await pumpPick(tester, artUri: null);

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(MornyeAlbumPick)), const Size(240, 320));
    expect(find.text('New release'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    expect(opacity(tester), 0);
  });

  testWidgets('the cover goes on under the caption as a soft copy', (
    tester,
  ) async {
    final blue = await _cover(tester, directory, const Color(0xff2040c0));
    await pumpPick(tester, artUri: blue);

    expect(tester.takeException(), isNull);
    expect(opacity(tester), 1);
    final layers = find.byType(RawImage);
    expect(layers, findsNWidgets(2));
    // The cover is the card's top square; its soft copy starts over its
    // last fifth and runs to the card's end.
    expect(
      tester.getRect(layers.first),
      const Rect.fromLTWH(0, 0, _width, _width),
    );
    expect(
      tester.getRect(layers.last),
      const Rect.fromLTRB(0, _width * 0.8, _width, _height),
    );

    final soft = tester.widget<RawImage>(layers.last).image!;
    final data = (await tester.runAsync(
      () => soft.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    List<int> pixel(int x, int y) {
      final index = (y * soft.width + x) * 4;
      return [for (var i = 0; i < 4; i++) data.getUint8(index + i)];
    }

    // Clear where it meets the sharp cover, the cover's colour below it.
    expect(pixel(soft.width ~/ 2, 0)[3], lessThan(40));
    final end = pixel(soft.width ~/ 2, soft.height - 1);
    expect(end[3], 255);
    expect(end[0], closeTo(0x20, 6));
    expect(end[1], closeTo(0x40, 6));
    expect(end[2], closeTo(0xc0, 6));
    // A dark cover is not darkened more than the least.
    expect(dim(tester), MornyeAlbumPick.leastDim);
  });

  testWidgets('a light cover is darkened under the caption', (tester) async {
    final white = await _cover(tester, directory, const Color(0xffffffff));
    await pumpPick(tester, artUri: white);

    expect(opacity(tester), 1);
    expect(dim(tester), greaterThan(0.45));
  });

  testWidgets('another cover takes the first one\'s place', (tester) async {
    final blue = await _cover(tester, directory, const Color(0xff2040c0));
    final white = await _cover(tester, directory, const Color(0xffffffff));
    await pumpPick(tester, artUri: blue);
    final first = tester.widget<RawImage>(find.byType(RawImage).last).image;

    await pumpPick(tester, artUri: white);
    expect(tester.takeException(), isNull);
    expect(opacity(tester), 1);
    final second = tester.widget<RawImage>(find.byType(RawImage).last).image;
    expect(second, isNot(same(first)));
    expect(dim(tester), greaterThan(0.45));
  });
}
