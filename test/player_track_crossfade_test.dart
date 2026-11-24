import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/player_track_crossfade.dart';

double _opacity(WidgetTester tester, Finder finder) {
  var opacity = 1.0;
  tester.element(finder).visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is FadeTransition) opacity *= widget.opacity.value;
    return true;
  });
  return opacity;
}

void main() {
  for (final (style, mornye) in [('Material', false), ('Mornye', true)]) {
    for (final reducedMotion in [false, true]) {
      testWidgets('$style titles fade through without overlapping '
          '(reduced motion: $reducedMotion)', (tester) async {
        Widget app(String title) => MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: Center(
              child: SizedBox(
                width: 200,
                child: PlayerTrackCrossfade(
                  trackKey: title,
                  child: Text(title),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(app('First'));
        final size = tester.getSize(find.text('First'));
        await tester.pumpWidget(app('Second'));
        if (reducedMotion) {
          expect(find.text('First'), findsNothing);
          expect(find.text('Second'), findsOneWidget);
          return;
        }
        var sawBoth = false;
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final first = find.text('First');
          if (first.evaluate().isEmpty) break;
          sawBoth = true;
          // The lines keep their place and size while they change.
          expect(tester.getSize(first), size);
          final visible = [
            _opacity(tester, first),
            _opacity(tester, find.text('Second')),
          ].where((opacity) => opacity > 0.01);
          expect(visible.length, lessThanOrEqualTo(1), reason: '$frame');
        }
        expect(sawBoth, isTrue);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('First'), findsNothing);
        expect(_opacity(tester, find.text('Second')), 1);
        expect(
          tester.getTopLeft(find.text('Second')).dx,
          tester.getTopLeft(find.byType(PlayerTrackCrossfade)).dx,
        );
      });
    }
  }
}
