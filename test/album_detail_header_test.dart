import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/settled_blur.dart';

const _page = ValueKey('page');

late ui.Image _cover;

/// A collection page on a 411 x 891 dp phone with a blurred cover header.
/// [playing] stands in for the mini player, which draws a frame every 33 ms.
Widget _collection(
  ScrollController controller, {
  ThemeData? theme,
  bool playing = false,
}) => MaterialApp(
  theme: theme ?? AppTheme.light(),
  home: RepaintBoundary(
    key: _page,
    child: Scaffold(
      body: CustomScrollView(
        controller: controller,
        slivers: [
          AlbumDetailHeader(
            title: 'Album',
            expandedHeight: 534,
            showTitleInAppBar: false,
            background: RawImage(image: _cover, fit: BoxFit.cover),
            coverBuilder: (context, size) =>
                RawImage(image: _cover, fit: BoxFit.cover),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 2000)),
        ],
      ),
      bottomNavigationBar: playing ? const LinearProgressIndicator() : null,
    ),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1079, 2339);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

bool _blursLive(WidgetTester tester) =>
    tester.layers.whereType<ImageFilterLayer>().isNotEmpty;

ui.Image? _image(WidgetTester tester) =>
    tester.renderObject<RenderSettledBlur>(find.byType(SettledBlur)).debugImage;

Future<Uint8List> _pixels(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_page),
      );
      final image = await boundary.toImage(pixelRatio: 2.625);
      try {
        return (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Colour blocks and a bright band, so the blur has edges to soften.
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 300, 300),
        Paint()..color = const Color(0xFF283593),
      )
      ..drawRect(
        const Rect.fromLTWH(0, 0, 150, 180),
        Paint()..color = const Color(0xFFE64A19),
      )
      ..drawCircle(
        const Offset(210, 110),
        60,
        Paint()..color = const Color(0xFFFFD54F),
      )
      ..drawRect(
        const Rect.fromLTWH(0, 200, 300, 30),
        Paint()..color = Colors.white,
      );
    _cover = await recorder.endRecording().toImage(300, 300);
  });

  tearDownAll(() => _cover.dispose());

  testWidgets('the Material header blurs its cover once, not per scroll or '
      'playback frame', (tester) async {
    _phone(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_collection(controller, playing: true));
    var liveFrames = _blursLive(tester) ? 1 : 0;
    final images = <ui.Image?>{};
    for (var frame = 1; frame <= 90; frame++) {
      // Collapses the header part way while the mini player keeps drawing.
      if (frame >= 10 && frame < 40) controller.jumpTo((frame - 9) * 8.0);
      await tester.pump(const Duration(milliseconds: 16));
      if (_blursLive(tester)) liveFrames++;
      if (frame > 2) images.add(_image(tester));
    }
    // The page's first frame and the unchanged one after it, then never.
    expect(liveFrames, 2);
    expect(images, hasLength(1));
    expect(images.single!.debugDisposed, isFalse);
  });

  testWidgets('a new window size or theme blurs the header cover again', (
    tester,
  ) async {
    _phone(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    Future<ui.Image> settle() async {
      expect(_blursLive(tester), isTrue);
      tester.binding.scheduleFrame();
      await tester.pump();
      await tester.pump();
      expect(_blursLive(tester), isFalse);
      return _image(tester)!;
    }

    await tester.pumpWidget(_collection(controller));
    final portrait = await settle();

    tester.view.physicalSize = const Size(2339, 1079);
    await tester.pump();
    expect(portrait.debugDisposed, isTrue);
    final landscape = await settle();
    expect((
      landscape.width,
      landscape.height,
    ), isNot((portrait.width, portrait.height)));

    await tester.pumpWidget(_collection(controller, theme: AppTheme.dark()));
    await tester.pump();
    expect(landscape.debugDisposed, isTrue);
    await settle();

    await tester.pumpWidget(const SizedBox());
    expect(_blursLive(tester), isFalse);
  });

  testWidgets('the settled header matches its live blur', (tester) async {
    _phone(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_collection(controller));
    // The first frame draws the blur live, as the header did before.
    expect(_blursLive(tester), isTrue);
    final live = await _pixels(tester);

    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump();
    expect(_blursLive(tester), isFalse);
    final settled = await _pixels(tester);

    expect(settled.length, live.length);
    var sum = 0;
    var largest = 0;
    for (var i = 0; i < live.length; i++) {
      final difference = (settled[i] - live[i]).abs();
      sum += difference;
      if (difference > largest) largest = difference;
    }
    // Mean and largest channel difference out of 255 over the whole page.
    expect(sum / live.length, lessThan(0.5));
    expect(largest, lessThan(8));
  });
}
