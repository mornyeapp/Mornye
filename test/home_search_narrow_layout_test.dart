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
/// before search results gained cover grids and shelves on wide screens, with
/// the Material values re-recorded when sort and view became a grouped
/// toolbar, and the Material desktop value when Home took M3's 24dp window
/// margin and 720dp search width. A narrow layout must paint exactly these.
/// A deliberate change to
/// the phone rows records new values; the failure prints the fingerprint.
const _baseFingerprints = {
  'phone Material': 'c975d61edc1fef90079a8ac06bf1a8c5307ac43b',
  'phone Mornye': 'b6eb17a3cc554345f3650308f908aeff80858f07',
  'landscape phone Material': '88fd46463538cd4b3d728743a1174612da7a9731',
  'landscape phone Mornye': 'a52f2e86d51d48d56386bae6aed54e9964adb7f7',
  'portrait tablet Material': '94d41e2ff5146d50d53d7b50f33ec371b88fc11f',
  'portrait tablet Mornye': '4ed79340ac67aefb625dcb4418686de5458b0b79',
  'narrow desktop window Material': 'b60f25b64b7171e20c34e3805d00ab3ea4971bf2',
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
