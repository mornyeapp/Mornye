import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/home_layout.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_album_pick.dart';

import 'support/fixed_settings.dart';

const _title = 'From your Library';

LibraryBrowseEntry _album(int index, {String? name}) => LibraryBrowseEntry(
  source: 'downloaded',
  key: 'album-$index',
  name: name ?? 'Album $index',
  artist: 'Artist',
  samplePath: '',
  trackCount: 2,
);

List<String> _keys(List<LibraryBrowseEntry> albums) => [
  for (final album in albums) album.key,
];

/// Home without extensions, a feed or a played song, with [albums] as the
/// Library's albums of the day.
Widget _home({
  required bool mornye,
  required bool recordListening,
  required List<LibraryBrowseEntry> albums,
}) => ProviderScope(
  overrides: [
    homeNewReleasesProvider.overrideWith(
      (ref) => Stream.value(const <WeeklyRelease>[]),
    ),
    settingsProvider.overrideWith(
      () => FixedSettingsNotifier(
        AppSettings(
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          listeningStatisticsEnabled: recordListening,
          // The shelf sits in On repeat, which ships turned off.
          homeLayout: const HomeLayout().withVisible(
            HomeSection.onRepeat,
            true,
          ),
        ),
      ),
    ),
    extensionProvider.overrideWith(_Extensions.new),
    exploreProvider.overrideWith(_Explore.new),
    downloadHistoryProvider.overrideWith(_History.new),
    recentAccessProvider.overrideWith(_Recent.new),
    libraryMixesProvider.overrideWith((ref) async => const []),
    homeTopPicksProvider.overrideWith((ref) async => const <ExploreItem>[]),
    homeRecentlyAddedProvider.overrideWith(
      (ref) async => (items: const <UnifiedLibraryItem>[], trackCount: 0),
    ),
    homeRecentlyPlayedProvider.overrideWith((ref) async => const []),
    homeOnRepeatProvider.overrideWith((ref) async => const []),
    homeQuickSongsProvider.overrideWith((ref) async => const []),
    homeLibraryAlbumsProvider.overrideWith((ref) async => albums),
    playerUiEnabledProvider.overrideWithValue(true),
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream<MediaItem?>.value(null),
    ),
    playbackResumeProvider.overrideWith((ref) async => null),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const HomeTab(mode: HomeTabMode.browse),
  ),
);

Future<void> _open(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(home);
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('the day\'s albums', () {
    final pool = [for (var index = 0; index < 40; index++) _album(index)];

    test('are the same however the Library lists them', () {
      final picks = homeLibraryAlbumPicks(pool, day: '2026-11-19');
      expect(picks, hasLength(10));
      expect(
        _keys(homeLibraryAlbumPicks(pool.reversed.toList(), day: '2026-11-19')),
        _keys(picks),
      );
    });

    test('change with the day', () {
      expect(
        _keys(homeLibraryAlbumPicks(pool, day: '2026-11-20')),
        isNot(_keys(homeLibraryAlbumPicks(pool, day: '2026-11-19'))),
      );
    });

    test('keep their order when the Library gains an album', () {
      final before = _keys(homeLibraryAlbumPicks(pool, day: '2026-11-19'));
      for (var index = 40; index < 60; index++) {
        final after = _keys(
          homeLibraryAlbumPicks([...pool, _album(index)], day: '2026-11-19'),
        )..remove('album-$index');
        expect(after, before.take(after.length));
      }
    });

    test('leave out an album without a name', () {
      final picks = homeLibraryAlbumPicks([
        _album(0, name: ' '),
        _album(1),
      ], day: '2026-11-19');
      expect(_keys(picks), ['album-1']);
    });

    test('come from a window inside a large Library', () {
      expect(homeLibraryAlbumPoolOffset(0, '2026-11-19'), 0);
      expect(homeLibraryAlbumPoolOffset(300, '2026-11-19'), 0);
      final offsets = {
        for (var day = 10; day < 30; day++)
          homeLibraryAlbumPoolOffset(1000, '2026-11-$day'),
      };
      expect(offsets.every((offset) => offset >= 0 && offset <= 700), isTrue);
      expect(offsets.length, greaterThan(1));
    });
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('the $style Home shows Library albums without a listening '
        'record', (tester) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          recordListening: false,
          albums: [for (var index = 0; index < 5; index++) _album(index)],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(_shelfTitles(), 1);
      expect(find.text('Album 0'), findsOneWidget);
      expect(find.text('On repeat'), findsNothing);
      if (mornye) {
        // The first three are offered among Top Picks, and the shelf goes
        // on after them.
        expect(_picked('Album 0'), findsOneWidget);
        expect(find.text('Album 3'), findsOneWidget);
        expect(_picked('Album 3'), findsNothing);
      } else {
        expect(find.byType(MornyeAlbumPick), findsNothing);
      }
    });

    testWidgets('the $style Home leaves the shelf out while listening is '
        'recorded', (tester) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          recordListening: true,
          albums: [_album(0), _album(1)],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(_shelfTitles(), 0);
      // Mornye's Top Picks offer them whatever is recorded.
      expect(find.text('Album 0'), mornye ? findsOneWidget : findsNothing);
      expect(_picked('Album 0'), mornye ? findsOneWidget : findsNothing);
    });
  }
}

/// [text] on an album card of Mornye's Top Picks.
Finder _picked(String text) => find.descendant(
  of: find.byType(MornyeAlbumPick),
  matching: find.text(text),
);

/// How often the shelf's header shows. An album card of Mornye's Top Picks
/// carries the same words as its small label.
int _shelfTitles() =>
    find.text(_title).evaluate().length - _picked(_title).evaluate().length;

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
