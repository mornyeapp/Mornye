import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/mornye_mix_banner.dart';

Widget _banner({ValueNotifier<double>? drift}) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: MornyeMixBanner(
      seed: mornyeBannerSeed('genre/rock'),
      title: 'Rock Mix',
      eyebrow: 'Made for You',
      subtitle: 'Two artists',
      width: 240,
      drift: drift,
    ),
  ),
);

/// The banner's own layer, which holds its text, and the layer of its color
/// field.
(RenderObject, RenderObject) _layers(WidgetTester tester) {
  final boundaries = find.descendant(
    of: find.byType(MornyeMixBanner),
    matching: find.byType(RepaintBoundary),
  );
  return (
    tester.renderObject(boundaries.at(0)),
    tester.renderObject(boundaries.at(1)),
  );
}

void main() {
  testWidgets('a drift repaints the color field, not the text over it', (
    tester,
  ) async {
    final drift = ValueNotifier<double>(0);
    addTearDown(drift.dispose);
    await tester.pumpWidget(_banner(drift: drift));
    // The lockup's picture arrives a frame late.
    await tester.pump(const Duration(seconds: 1));
    final (text, field) = _layers(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);

    drift.value = 0.25;
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(field.debugNeedsPaint, isTrue);
    expect(text.debugNeedsPaint, isFalse);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a drift the field is still', (tester) async {
    await tester.pumpWidget(_banner());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text('Rock Mix'), findsOneWidget);
    expect(tester.getSize(find.byType(MornyeMixBanner)), const Size(240, 320));
  });
}
