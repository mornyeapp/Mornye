import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/player_artwork.dart';

import 'support/fixed_settings.dart';

void main() {
  testWidgets('Continue listening shows a network cover not stored yet', (
    tester,
  ) async {
    const cover = 'network://nas/Album/cover.jpg';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(
                searchProvider: 'example',
                homeFeedProvider: AppSettings.homeFeedProviderOff,
                hasSearchedBefore: true,
              ),
            ),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          libraryMixesProvider.overrideWith((ref) async => const []),
          playerUiEnabledProvider.overrideWithValue(true),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream<MediaItem?>.value(null),
          ),
          playbackResumeProvider.overrideWith(
            (ref) async => (
              media: const PlayableMedia(
                id: 'network://nas/Album/song.flac',
                source: 'network://nas/Album/song.flac',
                title: 'Saved song',
                artist: 'Artist',
                networkArtworkSource: cover,
              ),
              position: const Duration(seconds: 23),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeTab(mode: HomeTabMode.combined),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final card = find.ancestor(
      of: find.text('Saved song'),
      matching: find.byType(InkWell),
    );
    final artwork = find.descendant(
      of: card.first,
      matching: find.byType(PlayerArtwork),
    );
    expect(tester.widget<PlayerArtwork>(artwork).artUri, cover);
  });
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}
