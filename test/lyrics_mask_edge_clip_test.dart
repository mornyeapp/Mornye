import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/player_lyrics.dart';

/// Rows that show white content through a fully transparent mask.
Future<List<int>> _leakedRows(
  WidgetTester tester, {
  required double height,
  required double pixelRatio,
}) async {
  final boundary = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: boundary,
        child: ColoredBox(
          color: Colors.black,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 100,
              height: height,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Color(0x00FFFFFF), Color(0x00FFFFFF)],
                ).createShader(bounds),
                child: const LyricsMaskEdgeClip(
                  child: ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return (await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rows = [
      for (var y = 0; y < image.height; y++)
        if (bytes!.getUint8((y * image.width + 50) * 4) > 0) y,
    ];
    image.dispose();
    return rows;
  }))!;
}

void main() {
  for (final (height, pixelRatio) in const [
    (300.1, 2.0),
    (300.05, 2.0),
    (300.3, 1.875),
  ]) {
    testWidgets('no lyrics show through a mask edge at $height x $pixelRatio', (
      tester,
    ) async {
      expect(
        await _leakedRows(tester, height: height, pixelRatio: pixelRatio),
        isEmpty,
      );
    });
  }

  testWidgets('the clip stays valid in a slot shorter than its inset', (
    tester,
  ) async {
    expect(await _leakedRows(tester, height: 0.5, pixelRatio: 2), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
