import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/in_library_badge.dart';

void main() {
  testWidgets('track metadata badges wrap on a narrow result row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            child: SizedBox(
              width: 180,
              child: Builder(
                builder: (context) {
                  final colorScheme = Theme.of(context).colorScheme;
                  return TrackMetadataBadgesLine(
                    primary: const Text(
                      'RADWIMPS',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    badges: [
                      AudioQualityBadge(
                        label: '16-bit',
                        colorScheme: colorScheme,
                      ),
                      DolbyAtmosBadge(colorScheme: colorScheme),
                      const InLibraryBadge(),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byType(InLibraryBadge)).dy,
      greaterThan(tester.getTopLeft(find.text('RADWIMPS')).dy),
    );
  });
}
