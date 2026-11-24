import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';

void main() {
  testWidgets('explicit title badge follows the title alphabetic baseline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: ExplicitTrackTitle(
            title: 'Explicit Track',
            explicit: true,
            style: TextStyle(fontSize: 24, height: 1.2),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    final richText = tester.widget<Text>(
      find
          .descendant(
            of: find.byType(ExplicitTrackTitle),
            matching: find.byWidgetPredicate(
              (widget) => widget is Text && widget.textSpan != null,
            ),
          )
          .first,
    );
    final rootSpan = richText.textSpan! as TextSpan;
    final badgeSpan = rootSpan.children!.whereType<WidgetSpan>().single;
    final transform = badgeSpan.child as Transform;

    expect(badgeSpan.alignment, PlaceholderAlignment.baseline);
    expect(badgeSpan.baseline, TextBaseline.alphabetic);
    expect(transform.transform.getTranslation().y, -2);
    expect(find.byType(ExplicitBadge), findsOneWidget);
  });
}
