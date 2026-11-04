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
/// toolbar, the Material desktop value when Home took M3's 24dp window
/// margin, and the Mornye values when blue became the default accent and the
/// filter chips gained their glass press layer. A narrow layout must paint
/// exactly these.
/// A deliberate change to
/// the phone rows records new values; the failure prints the fingerprint.
const _baseFingerprints = {
  'phone Material': 'c975d61edc1fef90079a8ac06bf1a8c5307ac43b',
  'phone Mornye': 'd72fe45a3f9638e3ebe47b549dee17232cd13e4f',
  'landscape phone Material': '88fd46463538cd4b3d728743a1174612da7a9731',
  'landscape phone Mornye': 'ad2081a7237deca37d087111c28546cdec9f1781',
  'portrait tablet Material': '94d41e2ff5146d50d53d7b50f33ec371b88fc11f',
  'portrait tablet Mornye': 'c4d77afbdcda7e4fbd3b90b586068aa134b1b30b',
  'narrow desktop window Material': '74198bcea5c9b07d7e5a90075abcb974b99f876e',
  'narrow desktop window Mornye': '481b5d5c69fc3a5b171e0124a6244c306b9489c0',
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
