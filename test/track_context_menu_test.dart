import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  final track = const Track(
    id: 'test-1',
    name: 'Sample Track',
    artistName: 'Sample Artist',
    albumName: 'Sample Album',
    duration: 180,
  );

  testWidgets(
    'TrackCollectionQuickActions displays context menu across platforms',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: TrackCollectionQuickActions(
                  track: track,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final buttonFinder = find.byType(TrackCollectionQuickActions);
      expect(buttonFinder, findsOneWidget);

      await tester.tap(buttonFinder);
      await tester.pumpAndSettle();

      // In Mornye context menu, Download option is shown
      expect(find.text('Download'), findsOneWidget);
    },
  );

  testWidgets(
    'TrackCollectionQuickActions displays context menu on mobile Android',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Center(
                  child: TrackCollectionQuickActions(
                    track: track,
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        final buttonFinder = find.byType(TrackCollectionQuickActions);
        expect(buttonFinder, findsOneWidget);

        await tester.tap(buttonFinder);
        await tester.pumpAndSettle();

        // In Mornye context menu on Android, Download option is shown
        expect(find.text('Download'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
