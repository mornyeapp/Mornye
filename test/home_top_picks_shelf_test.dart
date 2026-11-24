import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_database_models.dart';
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
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/mornye_album_pick.dart';
import 'package:mornye/widgets/mornye_mix_banner.dart';

import 'support/fixed_settings.dart';

final _songs = [
  for (var i = 0; i < 4; i++)
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'song$i',
        trackName: 'Song $i',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/song$i.flac',
        scannedAt: DateTime(2026, 11, 23),
        duration: 180,
      ),
    ),
];

LibraryMixView _mix(String label) => LibraryMixView(
  mix: LibraryMix(
    kind: LibraryMixKind.genre,
    key: label.toLowerCase(),
    label: label,
    artists: const ['One', 'Two'],
    songIds: [for (final song in _songs) song.id],
  ),
  items: _songs,
);

ExploreItem _feed(String id, String type) => ExploreItem(
  id: id,
  uri: id,
  type: type,
  name: 'Feed $id',
  artists: 'Feed artist',
  providerId: 'example',
);

LibraryBrowseEntry _album(int index) => LibraryBrowseEntry(
  source: 'downloaded',
  key: 'album-$index',
  name: 'Owned $index',
  artist: 'Owner',
  samplePath: '',
  trackCount: 2,
);

/// Mornye's Home with every kind of Top Pick to offer.
Widget _home({
  bool lowEnd = false,
  bool reducedMotion = false,
  bool banners = true,
}) => ProviderScope(
  overrides: [
    homeNewReleasesProvider.overrideWith(
      (ref) => Stream.value([
        WeeklyRelease(
          id: 'new',
          name: 'Fresh',
          artist: 'Favorite',
          providerId: 'example',
          date: DateTime(2026, 11, 20),
        ),
      ]),
    ),
    settingsProvider.overrideWith(
      () => FixedSettingsNotifier(
        const AppSettings(homeFeedProvider: AppSettings.homeFeedProviderOff),
      ),
    ),
    extensionProvider.overrideWith(_Extensions.new),
    exploreProvider.overrideWith(_Explore.new),
    downloadHistoryProvider.overrideWith(_History.new),
    recentAccessProvider.overrideWith(_Recent.new),
    libraryMixesProvider.overrideWith(
      (ref) async => banners ? [_mix('Rock'), _mix('Jazz')] : const [],
    ),
    homeTopPicksProvider.overrideWith(
      (ref) async => [
        _feed('a', 'album'),
        if (banners) _feed('p', 'playlist'),
        // The feed's copy of the new release.
        _feed('new', 'album'),
        if (banners) _feed('q', 'playlist'),
      ],
    ),
    homeRecentlyAddedProvider.overrideWith(
      (ref) async => (items: const <UnifiedLibraryItem>[], trackCount: 0),
    ),
    homeRecentlyPlayedProvider.overrideWith((ref) async => const []),
    homeOnRepeatProvider.overrideWith((ref) async => const []),
    homeQuickSongsProvider.overrideWith((ref) async => const []),
    homeLibraryAlbumsProvider.overrideWith(
      (ref) async => [for (var index = 0; index < 5; index++) _album(index)],
    ),
    playerUiEnabledProvider.overrideWithValue(true),
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream<MediaItem?>.value(null),
    ),
    playbackResumeProvider.overrideWith((ref) async => null),
    lowEndDeviceProvider.overrideWithValue(lowEnd),
    homeTopPicksExtensionProvider.overrideWithValue('example'),
  ],
  child: MaterialApp(
    theme: MornyeTheme.build(Brightness.dark),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: child!,
    ),
    home: const HomeTab(mode: HomeTabMode.browse),
  ),
);

Future<void> _open(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(home);
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The Top Picks' own list, held by its element: its first banner scrolls
/// away.
Finder _shelf() {
  final list = find
      .ancestor(
        of: find.byType(MornyeMixBanner).first,
        matching: find.byType(Scrollable),
      )
      .evaluate()
      .first;
  return find.byElementPredicate((element) => identical(element, list));
}

void main() {
  tearDown(DecorativePhase.debugResetClock);

  test('by turns takes one of each list a round', () {
    expect(
      homeTakeByTurns([
        [1, 2, 3, 4],
        [10],
        <int>[],
        [20, 21],
      ]),
      [1, 10, 20, 2, 21, 3, 4],
    );
    expect(homeTakeByTurns(<List<int>>[]), isEmpty);
  });

  testWidgets('the shelf offers a mix, then an album or a playlist, by turns', (
    tester,
  ) async {
    await _open(tester, _home());
    expect(tester.takeException(), isNull);

    final shelf = _shelf();
    final position = tester.state<ScrollableState>(shelf).position;
    expect(position.axis, Axis.horizontal);

    // Where each card's title sits along the shelf.
    const titles = [
      'Rock Mix',
      'Fresh',
      'Jazz Mix',
      'Feed p',
      'Owned 0',
      'Feed q',
      'Feed a',
      'Owned 1',
      'Owned 2',
    ];
    final places = <double>[];
    for (final title in titles) {
      final text = find.descendant(of: shelf, matching: find.text(title));
      await tester.scrollUntilVisible(text, 120, scrollable: shelf);
      expect(text, findsOneWidget);
      // A card's left edge, whichever art it has.
      final card = find
          .ancestor(of: text, matching: find.byType(ClipRRect))
          .first;
      places.add(position.pixels + tester.getTopLeft(card).dx);
    }
    expect(places, [...places]..sort());
    expect(places.toSet(), hasLength(titles.length));
    // The feed's copy of the new release is not a card of its own.
    expect(find.text('Feed new'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card says where its album or playlist is from', (
    tester,
  ) async {
    await _open(tester, _home());

    String eyebrowOf(Type card, String title) {
      final column = find
          .ancestor(
            of: find.descendant(
              of: find.byType(card),
              matching: find.text(title),
            ),
            matching: find.byType(card),
          )
          .first;
      return tester
          .widgetList<Text>(
            find.descendant(of: column, matching: find.byType(Text)),
          )
          .map((text) => text.data!)
          .firstWhere(
            const {
              'Made for You',
              'New release',
              'From your Library',
              'Album',
              'Playlist',
            }.contains,
          );
    }

    expect(eyebrowOf(MornyeMixBanner, 'Rock Mix'), 'Made for You');
    expect(eyebrowOf(MornyeAlbumPick, 'Fresh'), 'New release');
    final shelf = _shelf();
    for (final (card, title, eyebrow) in [
      (MornyeMixBanner, 'Feed p', 'Playlist'),
      (MornyeAlbumPick, 'Owned 0', 'From your Library'),
      (MornyeAlbumPick, 'Feed a', 'Album'),
    ]) {
      await tester.scrollUntilVisible(
        find.descendant(of: shelf, matching: find.text(title)),
        120,
        scrollable: shelf,
      );
      expect(eyebrowOf(card, title), eyebrow);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the title opens Top Picks kind by kind, a shelf each', (
    tester,
  ) async {
    await _open(tester, _home(), size: const Size(400, 2400));
    await tester.tap(find.text('Top Picks for You'));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    Finder headed(String title) => find
        .ancestor(
          of: find
              .ancestor(
                of: find.text(title),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics &&
                      (widget.properties.header ?? false),
                ),
              )
              .first,
          matching: find.byType(Column),
        )
        .first;

    final shelves = {
      'Made for You': ['Rock Mix', 'Jazz Mix'],
      // Every album of the day, not only the three Home offers.
      'From your Library': [
        for (var index = 0; index < 5; index++) 'Owned $index',
      ],
      'New releases': ['Fresh'],
      'From Example Feed': ['Feed a', 'Feed p', 'Feed q'],
    };
    for (final MapEntry(key: title, value: cards) in shelves.entries) {
      final section = headed(title);
      final shelf = find
          .descendant(of: section, matching: find.byType(Scrollable))
          .first;
      for (final card in cards) {
        await tester.scrollUntilVisible(
          find.descendant(of: section, matching: find.text(card)),
          120,
          scrollable: shelf,
        );
      }
      // No card of another kind joins the shelf.
      for (final other in shelves.entries) {
        if (other.key == title) continue;
        for (final card in other.value) {
          expect(
            find.descendant(of: section, matching: find.text(card)),
            findsNothing,
          );
        }
      }
    }
    expect(find.text('Feed new'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('the banners\' color fields', () {
    testWidgets('move while Home shows them', (tester) async {
      await _open(tester, _home());

      expect(DecorativePhase.debugClockRunning, isTrue);
      final drift = tester
          .widget<MornyeMixBanner>(find.byType(MornyeMixBanner).first)
          .drift!;
      final before = drift.value;
      await tester.pump(const Duration(seconds: 1));
      expect(drift.value, isNot(before));
    });

    testWidgets('stand still under reduced motion', (tester) async {
      await _open(tester, _home(reducedMotion: true));

      expect(find.byType(MornyeMixBanner), findsWidgets);
      expect(DecorativePhase.debugClockRunning, isFalse);
    });

    testWidgets('stand still on a slow device', (tester) async {
      await _open(tester, _home(lowEnd: true));

      expect(DecorativePhase.debugClockRunning, isFalse);
      expect(
        tester
            .widget<MornyeMixBanner>(find.byType(MornyeMixBanner).first)
            .drift,
        isNull,
      );
    });

    testWidgets('stand still while another tab shows', (tester) async {
      await _open(tester, TickerMode(enabled: false, child: _home()));
      expect(DecorativePhase.debugClockRunning, isFalse);

      await tester.pumpWidget(TickerMode(enabled: true, child: _home()));
      await tester.pump();
      expect(DecorativePhase.debugClockRunning, isTrue);
    });

    testWidgets('leave the clock alone on a shelf of albums only', (
      tester,
    ) async {
      await _open(tester, _home(banners: false));

      expect(find.byType(MornyeAlbumPick), findsWidgets);
      expect(find.byType(MornyeMixBanner), findsNothing);
      expect(DecorativePhase.debugClockRunning, isFalse);
    });
  });
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example Feed',
        version: '1.0.0',
        description: 'Home feed',
        enabled: true,
        status: 'loaded',
      ),
    ],
  );
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
