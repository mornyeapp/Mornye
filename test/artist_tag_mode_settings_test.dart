import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/metadata_settings_page.dart';
import 'package:mornye/utils/artist_utils.dart';

import 'support/fixed_settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('primary artist mode survives settings round trips', () {
    final settings = const AppSettings().copyWith(
      artistTagMode: artistTagModePrimary,
    );
    expect(
      AppSettings.fromJson(settings.toJson()).artistTagMode,
      artistTagModePrimary,
    );
  });

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('picker offers and saves the primary artist mode ($size)', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MetadataSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Single joined value'), findsOneWidget);
      await tester.tap(find.text('Artist Tag Mode'));
      await tester.pumpAndSettle();
      Finder inSheet(String text) => find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(text),
      );
      expect(inSheet('Single joined value'), findsOneWidget);
      expect(inSheet('Split tags for FLAC/Opus'), findsOneWidget);
      final primary = inSheet('Primary artist only');
      await tester.ensureVisible(primary);
      await tester.pumpAndSettle();
      await tester.tap(primary);
      await tester.pumpAndSettle();

      expect(container.read(settingsProvider).artistTagMode, 'primary');
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Primary artist only'), findsOneWidget);
      expect(tester.takeException(), isNull);

      container.read(settingsProvider.notifier).setArtistTagMode('unknown');
      expect(container.read(settingsProvider).artistTagMode, 'primary');
    });
  }
}
