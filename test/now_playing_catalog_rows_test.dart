import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:mornye/widgets/song_row_tap.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/track_list_tile.dart';

import 'support/fixed_settings.dart';
import 'support/tooltip_finder.dart';

/// The playing track, a different track, and a track another provider lists
/// under the same catalog id.
const _tracks = [
  Track(
    id: 'catalog-1',
    name: 'Current song',
    artistName: 'Example artist',
    albumName: 'Example album',
    duration: 180,
    trackNumber: 1,
  ),
  Track(
    id: 'catalog-2',
    name: 'Other song',
    artistName: 'Example artist',
    albumName: 'Example album',
    duration: 180,
    trackNumber: 2,
  ),
  Track(
    id: 'catalog-1',
    name: 'Same id song',
    artistName: 'Another artist',
    albumName: 'Another album',
    duration: 180,
    trackNumber: 3,
    source: 'other-provider',
  ),
];

/// The downloaded file of the first track is playing.
final _identity = CurrentTrackIdentity(
  recordIds: const {'/music/current.flac', 'download-row'},
  catalogIds: const {'catalog-1'},
  matchKey: catalogTrackKey(_tracks.first).matchKey,
);

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      UserPlaylistCollection(
        id: 'playlist',
        name: 'Playlist',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: [
          for (final (index, track) in _tracks.indexed)
            CollectionTrackEntry(
              key: 'entry-$index',
              track: track,
              addedAt: DateTime(2026),
            ),
        ],
      ),
    ],
  );

  @override
  Future<void> ensurePlaylistLoaded(String playlistId) async {}
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

List<Override> _overrides({MediaItem? current, required bool identified}) => [
  settingsProvider.overrideWith(FixedSettingsNotifier.new),
  libraryCollectionsProvider.overrideWith(_Collections.new),
  localLibraryProvider.overrideWith(_Library.new),
  downloadHistoryProvider.overrideWith(_History.new),
  downloadHistoryVisibleBatchExistsProvider.overrideWith(
    (ref, request) => const {},
  ),
  localLibraryCoverProvider.overrideWith((ref, request) async => null),
  localLibraryFirstCoverProvider.overrideWith((ref, request) async => null),
  currentMediaItemProvider.overrideWithBuild(
    (ref, notifier) => Stream.value(current),
  ),
  currentTrackIdentityProvider.overrideWith(
    (ref) async => identified ? _identity : null,
  ),
  playbackPlayingProvider.overrideWith((ref) => true),
  playbackLoadingProvider.overrideWith((ref) => false),
];

Widget _app(
  Widget home, {
  bool mornye = false,
  MediaItem? current,
  bool identified = true,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: [
    ..._overrides(current: current, identified: identified),
    ...overrides,
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

/// Pumps in bounded steps: a playing indicator loops, so the tree never
/// settles.
Future<void> _pumpFor(
  WidgetTester tester, [
  Duration duration = const Duration(seconds: 1),
]) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < duration; elapsed += step) {
    await tester.pump(step);
  }
}

/// Whether the row of type [row] that shows [title] carries the glyph.
bool _hasGlyph(Type row, String title) => find
    .descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(row)).first,
      matching: find.byType(NowPlayingIndicator),
    )
    .evaluate()
    .isNotEmpty;

TrackCard _card(WidgetTester tester, String title) => tester.widget<TrackCard>(
  find.ancestor(of: find.text(title), matching: find.byType(TrackCard)),
);

/// Mornye marks the current row with its title's colour alone.
void _expectOnlyCurrentAccented(WidgetTester tester) {
  Color? titleColor(String title) =>
      tester.widget<Text>(find.text(title)).style?.color;
  final accent = Theme.of(
    tester.element(find.text('Current song')),
  ).colorScheme.primary;
  expect(titleColor('Current song'), accent);
  expect(titleColor('Other song'), isNot(accent));
  expect(titleColor('Same id song'), isNot(accent));
  expect(find.byType(NowPlayingIndicator), findsNothing);
}

void _expectOnlyCurrentMarked(WidgetTester tester) {
  expect(_card(tester, 'Current song').isCurrent, isTrue);
  expect(_card(tester, 'Other song').isCurrent, isFalse);
  expect(_card(tester, 'Same id song').isCurrent, isFalse);
  expect(_hasGlyph(TrackCard, 'Current song'), isTrue);
  expect(_hasGlyph(TrackCard, 'Other song'), isFalse);
  expect(_hasGlyph(TrackCard, 'Same id song'), isFalse);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  group('TrackListTile', () {
    Widget list() => Scaffold(
      body: ListView(
        children: [
          for (final track in _tracks)
            TrackListTile(
              track: track,
              isInHistory: true,
              onDownload: ({bool forceQualityPicker = false}) {},
              leading: Text('${track.trackNumber}'),
            ),
        ],
      ),
    );

    testWidgets('marks only the playing track (Material)', (tester) async {
      await tester.pumpWidget(_app(list()));
      await _pumpFor(tester);
      _expectOnlyCurrentMarked(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('marks nothing when no file is identified', (tester) async {
      await tester.pumpWidget(_app(list(), identified: false));
      await _pumpFor(tester);
      expect(find.byType(NowPlayingIndicator), findsNothing);
    });

    testWidgets('Mornye rows show only the current title in the accent', (
      tester,
    ) async {
      await tester.pumpWidget(_app(list(), mornye: true));
      await _pumpFor(tester);
      _expectOnlyCurrentAccented(tester);
    });
  });

  group('TrackListTable', () {
    Widget table() => Scaffold(
      body: CustomScrollView(
        slivers: [
          TrackListTable(
            tracks: _tracks,
            ids: [for (var i = 0; i < _tracks.length; i++) 'row-$i'],
            isInHistory: const [true, true, true],
            selectedIds: const {},
            onSelect: (_, _, _) {},
            onActivate: (_) {},
          ),
        ],
      ),
    );

    testWidgets('marks only the playing track (Material)', (tester) async {
      debugDesktopPlatformOverride = true;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(table()));
      await _pumpFor(tester);
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(_hasGlyph(Consumer, 'Current song'), isTrue);
      expect(_hasGlyph(Consumer, 'Other song'), isFalse);
      expect(_hasGlyph(Consumer, 'Same id song'), isFalse);
      // The glyph takes the current row's track number.
      expect(find.text('1'), findsNothing);
      expect(find.text('3'), findsOneWidget);
      final surface = tester
          .widgetList<Material>(
            find.ancestor(
              of: find.text('Current song'),
              matching: find.byType(Material),
            ),
          )
          .first;
      final scheme = Theme.of(
        tester.element(find.text('Current song')),
      ).colorScheme;
      expect(surface.color, scheme.primaryContainer);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Mornye rows show no current-track state', (tester) async {
      debugDesktopPlatformOverride = true;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(table(), mornye: true));
      await _pumpFor(tester);
      expect(find.byType(NowPlayingIndicator), findsNothing);
    });
  });

  group('Library folder', () {
    Widget folder() => const LibraryTracksFolderScreen(
      mode: LibraryTracksFolderMode.playlist,
      playlistId: 'playlist',
    );

    testWidgets('phone rows mark only the playing track', (tester) async {
      debugDesktopPlatformOverride = false;
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(folder()));
      await _pumpFor(tester);
      _expectOnlyCurrentMarked(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop rows mark only the playing track', (tester) async {
      debugDesktopPlatformOverride = true;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(folder()));
      await _pumpFor(tester);
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(_hasGlyph(Consumer, 'Current song'), isTrue);
      expect(_hasGlyph(Consumer, 'Same id song'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('Library search', () {
    // Downloaded and local rows number their records independently, so the
    // same id can name two files.
    const hits = [
      LibrarySearchHit(
        kind: LibrarySearchKind.songs,
        id: '7',
        title: 'Current song',
        source: 'downloaded',
        samplePath: '/music/current.flac',
      ),
      LibrarySearchHit(
        kind: LibrarySearchKind.songs,
        id: '8',
        title: 'Other song',
        source: 'downloaded',
        samplePath: '/music/other.flac',
      ),
      LibrarySearchHit(
        kind: LibrarySearchKind.songs,
        id: '7',
        title: 'Same id song',
        source: 'local',
        samplePath: '/music/same-id.flac',
      ),
    ];

    Widget results() => Scaffold(
      body: CustomScrollView(
        slivers: [LibrarySearchResults(query: 'Song', onOpenArtist: (_) {})],
      ),
    );

    const current = MediaItem(
      id: '7',
      title: 'Current song',
      extras: {'source': '/music/current.flac'},
    );
    final searchOverrides = [
      librarySearchProvider.overrideWith(
        (ref, request) async =>
            request.kind == LibrarySearchKind.songs ? hits : [],
      ),
    ];

    for (final desktop in [false, true]) {
      testWidgets('rows mark only the playing file (desktop: $desktop)', (
        tester,
      ) async {
        debugDesktopPlatformOverride = desktop;
        await tester.pumpWidget(
          _app(
            results(),
            current: current,
            overrides: [
              ...searchOverrides,
              // The rows keep their Play buttons while a tap opens details.
              librarySongTapPlaysProvider.overrideWithValue(false),
            ],
          ),
        );
        await _pumpFor(tester);
        _expectOnlyCurrentMarked(tester);
        // The current row's button pauses rather than restarting.
        expect(findByTooltip('Pause'), findsOneWidget);
        expect(findByTooltip('Play'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Mornye rows show only the current title in the accent', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          results(),
          mornye: true,
          current: current,
          overrides: searchOverrides,
        ),
      );
      await _pumpFor(tester);
      _expectOnlyCurrentAccented(tester);
    });
  });
}
