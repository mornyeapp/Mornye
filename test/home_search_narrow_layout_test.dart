import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/home_tab.dart';

import 'support/search_results_fixture.dart';

/// What the Search tab paints, as text: every painting box with its global
/// rect and paint attributes, in paint order. Layout-only wrappers are left
/// out, so moving code between widgets keeps the fingerprint while any
/// change to the pixels changes it.
String _paintFingerprint(WidgetTester tester) {
  final lines = <String>[];
  String rect(RenderBox box) {
    final r = box.localToGlobal(Offset.zero) & box.size;
    return '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)} '
        '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';
  }

  void visit(RenderObject object) {
    if (object is RenderBox && object.hasSize) {
      final description = switch (object) {
        RenderParagraph() =>
          'text ${object.text.toStringDeep(minLevel: DiagnosticLevel.info)}',
        RenderDecoratedBox() => 'box ${object.decoration}',
        RenderPhysicalShape() =>
          'shape ${object.color} ${object.elevation} ${object.clipper}',
        RenderPhysicalModel() =>
          'model ${object.color} ${object.elevation} ${object.borderRadius}',
        RenderClipRRect() => 'clip ${object.borderRadius}',
        RenderClipPath() => 'path ${object.clipper}',
        RenderClipOval() => 'oval',
        RenderImage() => 'image',
        RenderOpacity() => 'opacity ${object.opacity}',
        RenderCustomPaint() =>
          'paint ${object.painter?.runtimeType} '
              '${object.foregroundPainter?.runtimeType}',
        _ => null,
      };
      if (description != null) lines.add('${rect(object)} $description');
    }
    object.visitChildren(visit);
  }

  visit(tester.renderObject(find.byType(HomeTab)));
  return lines.join('\n');
}

/// SHA-1 of each fingerprint, recorded on the base layout (commit 44cbb57b)
/// before search results gained cover grids and shelves on wide screens, with
/// the Material values re-recorded when sort and view became a grouped
/// toolbar, the Material desktop value when Home took M3's 24dp window
/// margin, the Mornye values when blue became the default accent, and all
/// values after Search became its own tab and Mornye search rows and filter
/// chips dropped content-layer Liquid Glass. A narrow layout must paint
/// exactly these.
/// A deliberate change to
/// the phone rows records new values; the failure prints the fingerprint.
const _baseFingerprints = {
  'phone Material': '204a86619c8ca221608ac2b91683b7c6058df265',
  'phone Mornye': 'ef2c73eedb07c1a280e65fa4bf2c24240551fa8f',
  'landscape phone Material': 'e77f8703f41dae3c3f99aebb584e0be139e06278',
  'landscape phone Mornye': 'c21d1b43e558a2a0f3ad09c0a37aeb0d8f573bb1',
  'portrait tablet Material': '748e753957c7b4d253afdd6e2ba6e97310b05640',
  'portrait tablet Mornye': '6d63c676d43e71d0bc3660d7ccce31f12b64f19a',
  'narrow desktop window Material': 'c8382dbf1a9de137e68eb17799561f71ddcb3045',
  'narrow desktop window Mornye': '27e8e8751f82f03a3685b320a202febecbbb5771',
};

void main() {
  for (final (name, size, desktop) in [
    ('phone', const Size(430, 1400), false),
    ('landscape phone', const Size(932, 430), false),
    ('portrait tablet', const Size(800, 1280), false),
    ('narrow desktop window', const Size(820, 1400), true),
  ]) {
    for (final mornye in [false, true]) {
      final key = '$name ${mornye ? 'Mornye' : 'Material'}';
      testWidgets('Search results on a $key paint the base layout', (
        tester,
      ) async {
        await pumpSearchFixture(
          tester,
          size: size,
          mornye: mornye,
          desktop: desktop,
        );
        expect(find.text('Found artist 0'), findsOneWidget);
        expect(find.byType(SliverGrid), findsNothing);

        final fingerprint = _paintFingerprint(tester);
        final hash = sha1.convert(utf8.encode(fingerprint)).toString();
        final expected = _baseFingerprints[key];
        if (hash != expected) debugPrint('$key: $hash\n$fingerprint');
        expect(hash, expected);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
