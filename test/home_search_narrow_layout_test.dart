import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
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
/// before search results gained cover grids and shelves on wide screens. A
/// narrow layout must paint exactly these. A deliberate change to the phone
/// rows records new values; the failure prints the fingerprint.
const _baseFingerprints = {
  'phone Material': '2aff7dd72f4ab0b8b9b811d046b1107a561e984a',
  'phone Mornye': 'b6eb17a3cc554345f3650308f908aeff80858f07',
  'landscape phone Material': '723e82905357faad4a0be91141ceeb37a3c1e671',
  'landscape phone Mornye': 'a52f2e86d51d48d56386bae6aed54e9964adb7f7',
  'portrait tablet Material': '73e90f62a9871050b91ff948583fe3f079d7462f',
  'portrait tablet Mornye': '4ed79340ac67aefb625dcb4418686de5458b0b79',
  'narrow desktop window Material': 'd8be719ac008b780d6b11ddbbece8297deaf19a7',
  'narrow desktop window Mornye': 'b0e19d226ab2aa594ba4d4e1f41407841790dd4a',
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
