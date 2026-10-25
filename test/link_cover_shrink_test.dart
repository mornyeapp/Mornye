import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';

Future<Uint8List> _image(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final drawn = await picture.toImage(width, height);
  final png = await drawn.toByteData(format: ui.ImageByteFormat.png);
  drawn.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

Future<(int, int)> _size(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = (await codec.getNextFrame()).image;
  final result = (frame.width, frame.height);
  frame.dispose();
  codec.dispose();
  return result;
}

void main() {
  testWidgets('shrinks a cover to its longer side, keeping its shape', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final wide = await shrinkLinkCover(await _image(1600, 1200));
      expect(await _size(wide!), (800, 600));
      final tall = await shrinkLinkCover(await _image(900, 1800));
      expect(await _size(tall!), (400, 800));
      final small = await shrinkLinkCover(await _image(300, 200));
      expect(await _size(small!), (300, 200));
      expect(await shrinkLinkCover(utf8.encode('<html>')), isNull);
    });
  });
}
