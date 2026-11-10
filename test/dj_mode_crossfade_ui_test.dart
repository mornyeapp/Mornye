import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/widgets/mornye_player_actions_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _TestCollections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PlaybackSettingsPage displays DJ Mode (Smart Crossfade)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(const AppSettings(autoMix: true)),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('it'),
          home: Scaffold(body: PlaybackSettingsPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Modalità DJ (Smart Crossfade)'), findsOneWidget);
  });

  testWidgets(
    'MornyePlayerActionsSheet displays DJ Mode quick toggle with status',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mediaItem = MediaItem(
        id: 'track-1',
        title: 'Track Title',
        artist: 'Artist Name',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(const AppSettings(autoMix: true)),
            ),
            playerCollectionTrackProvider.overrideWith(
              (ref, item) async => Track(
                id: item.id,
                name: item.title,
                artistName: item.artist ?? '',
                albumName: item.album ?? '',
                duration: 180,
                source: 'local',
              ),
            ),
            libraryCollectionsProvider.overrideWith(_TestCollections.new),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('it'),
            home: Scaffold(
              body: MornyePlayerActionsSheet(mediaItem: mediaItem),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Modalità DJ (Smart Crossfade)'), findsOneWidget);
      expect(find.text('Attiva'), findsOneWidget);
    },
  );
}
