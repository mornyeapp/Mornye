import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/home_layout.dart';
import 'package:mornye/models/recognized_song.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/home_unfinished_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/music_recognition_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/music_recognition_screen.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/music_recognition.dart';
import 'package:mornye/services/music_recognition_library.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

const _title = 'Finish your collection';

const _track = Track(
  id: 'example-provider:song',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

CollectionTrackEntry _wish(int index) => CollectionTrackEntry(
  key: 'example-provider:song-$index',
  track: _track,
  addedAt: DateTime.utc(2026),
);

DownloadItem _failed(int index) => DownloadItem(
  id: 'download-$index',
  track: _track,
  service: 'example-provider',
  status: DownloadStatus.failed,
  createdAt: DateTime.utc(2026),
  error: 'failed',
);

RecognizedSong _recognized(String title, {String? isrc}) => RecognizedSong(
  title: title,
  artist: 'Artist',
  isrc: isrc,
  recognizedAt: DateTime.utc(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the counts', () {
    test('list only rows with something, in order', () {
      expect(const HomeUnfinished().isEmpty, isTrue);
      expect(const HomeUnfinished(failedDownloads: 2, wishlist: 1).rows, [
        HomeUnfinishedRow.wishlist,
        HomeUnfinishedRow.failedDownloads,
      ]);
      expect(
        const HomeUnfinished(
          wishlist: 1,
          incompleteAlbums: 2,
          recognized: 3,
          failedDownloads: 4,
        ).rows,
        HomeUnfinishedRow.values,
      );
      expect(
        const HomeUnfinished(recognized: 1),
        const HomeUnfinished(recognized: 1),
      );
    });

    test('take incomplete albums from the Library filter', () {
      final request = incompleteAlbumsCountRequest(localLibraryEnabled: true);
      expect(request.filterMetadata, incompleteAlbumFilter);
      expect(request.searchQuery, isEmpty);
      expect(request.localLibraryEnabled, isTrue);
    });

    test('count recognized songs the Library has no entry for', () async {
      final library = _Lookup(isrcs: {'ISRC1'}, songs: {'Kept|Artist'});
      final missing = await countRecognizedNotInLibrary([
        _recognized('By code', isrc: 'isrc1'),
        // Matched once the featured artist is dropped, as the screen does.
        _recognized('Kept (feat. Guest)'),
        _recognized('Not kept'),
      ], library);
      expect(missing, 1);
    });

    test('combine every source', () async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          downloadHistoryProvider.overrideWith(_History.new),
          libraryCollectionsProvider.overrideWith(
            () => _Collections([_wish(0), _wish(1)]),
          ),
          downloadQueueProvider.overrideWith(() => _Queue([_failed(0)])),
          libraryMixesStartupProvider.overrideWithBuild(
            (ref, notifier) => true,
          ),
          homeIncompleteAlbumCountProvider.overrideWith((ref) async => 3),
          recognitionHistoryProvider.overrideWith(
            () => _RecognitionHistory([
              _recognized('Kept'),
              _recognized('Not kept'),
            ]),
          ),
          homeRecognitionLookupProvider.overrideWithValue(
            _Lookup(songs: {'Kept|Artist'}),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(homeUnfinishedProvider, (_, _) {});
      await container.read(homeIncompleteAlbumCountProvider.future);
      await container.read(homeRecognizedMissingProvider.future);
      expect(
        container.read(homeUnfinishedProvider),
        const HomeUnfinished(
          wishlist: 2,
          incompleteAlbums: 3,
          recognized: 1,
          failedDownloads: 1,
        ),
      );
    });

    for (final (name, history, settled) in [
      ('without recognized songs', const <RecognizedSong>[], true),
      ('before startup settles', [_recognized('Not kept')], false),
    ]) {
      test('skip lookups $name', () async {
        final lookup = _Lookup();
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            downloadHistoryProvider.overrideWith(_History.new),
            libraryMixesStartupProvider.overrideWithBuild(
              (ref, notifier) => settled,
            ),
            recognitionHistoryProvider.overrideWith(
              () => _RecognitionHistory(history),
            ),
            homeRecognitionLookupProvider.overrideWithValue(lookup),
          ],
        );
        addTearDown(container.dispose);
        expect(await container.read(homeRecognizedMissingProvider.future), 0);
        expect(lookup.lookups, 0);
        if (!settled) {
          // Returns before the Library count is asked for.
          expect(
            await container.read(homeIncompleteAlbumCountProvider.future),
            0,
          );
        }
      });
    }
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('the $style Home leaves the section out with nothing '
        'unfinished', (tester) async {
      await _open(tester, _Harness(mornye: mornye));
      expect(tester.takeException(), isNull);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('the $style Home leaves the section out until Edit Home '
        'turns it on', (tester) async {
      await _open(
        tester,
        _Harness(mornye: mornye, wishlist: [_wish(0)], turnedOn: false),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('the $style Home shows only rows with something', (
      tester,
    ) async {
      final harness = _Harness(
        mornye: mornye,
        wishlist: [_wish(0), _wish(1)],
        failed: [_failed(0)],
      );
      await _open(tester, harness);
      expect(tester.takeException(), isNull);

      expect(find.text(_title), findsOneWidget);
      expect(find.text('2 songs on your wishlist'), findsOneWidget);
      expect(find.text('1 download failed'), findsOneWidget);
      expect(find.textContaining('missing songs'), findsNothing);
      expect(find.textContaining('recognized'), findsNothing);

      // Retry all empties the failed row; the Wishlist row stays.
      await tester.tap(find.byKey(const ValueKey('home-unfinished-retry')));
      await _settle(tester);
      expect(harness.queue.retries, [false]);
      expect(find.text('1 download failed'), findsNothing);
      expect(find.text('2 songs on your wishlist'), findsOneWidget);

      harness.collections.setWishlist(const []);
      await _settle(tester);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('the $style Home rows open their pages', (tester) async {
      final harness = _Harness(
        mornye: mornye,
        wishlist: [_wish(0)],
        failed: [_failed(0), _failed(1)],
        incompleteAlbums: 1,
        recognized: 2,
        albums: [
          const LibraryBrowseEntry(
            source: 'downloaded',
            key: 'album-key',
            name: 'Gapped Album',
            artist: 'Artist',
            samplePath: '',
            trackCount: 7,
            completeness: AlbumCompleteness(
              status: 'incomplete',
              present: 7,
              expected: 12,
            ),
          ),
        ],
      );
      await _open(tester, harness);
      expect(tester.takeException(), isNull);

      Future<void> back() async {
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await _settle(tester);
      }

      await tester.tap(find.text('1 song on your wishlist'));
      await _settle(tester);
      expect(
        tester
            .widget<LibraryTracksFolderScreen>(
              find.byType(LibraryTracksFolderScreen),
            )
            .mode,
        LibraryTracksFolderMode.wishlist,
      );
      await back();

      await tester.tap(find.text('1 album is missing songs'));
      await _settle(tester);
      expect(find.text('Incomplete albums'), findsWidgets);
      expect(find.text('Gapped Album'), findsOneWidget);
      expect(find.text('Artist · 7 of 12 songs'), findsOneWidget);
      await back();

      await tester.tap(find.text('2 recognized songs are not in your Library'));
      await _settle(tester);
      expect(find.byType(MusicRecognitionScreen), findsOneWidget);
      await back();

      await tester.tap(find.text('2 downloads failed'));
      await _settle(tester);
      expect(
        tester.widget<QueueTab>(find.byType(QueueTab)).librarySection,
        'downloads',
      );
      await back();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the $style Home keeps the rows readable on a wide pane', (
      tester,
    ) async {
      await _open(
        tester,
        _Harness(mornye: mornye, wishlist: [_wish(0)]),
        size: const Size(1600, 1000),
      );
      expect(tester.takeException(), isNull);
      final row = tester.getSize(
        find.ancestor(
          of: find.text('1 song on your wishlist'),
          matching: find.byType(InkWell),
        ),
      );
      expect(row.width, lessThanOrEqualTo(720));
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(
  WidgetTester tester,
  _Harness harness, {
  Size size = const Size(400, 900),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(harness.build());
  await _settle(tester);
}

/// Home without extensions, a feed, Library shelves or a played song, with
/// the given loose ends.
class _Harness {
  _Harness({
    required this.mornye,
    List<CollectionTrackEntry> wishlist = const [],
    List<DownloadItem> failed = const [],
    this.incompleteAlbums = 0,
    this.recognized = 0,
    this.albums = const [],
    this.turnedOn = true,
  }) : collections = _Collections(wishlist),
       queue = _Queue(failed);

  final bool mornye;

  /// The section ships turned off; Edit Home turns it on.
  final bool turnedOn;
  final _Collections collections;
  final _Queue queue;
  final int incompleteAlbums;
  final int recognized;
  final List<LibraryBrowseEntry> albums;

  Widget build() => ProviderScope(
    overrides: [
      homeNewReleasesProvider.overrideWith(
        (ref) => Stream.value(const <WeeklyRelease>[]),
      ),
      settingsProvider.overrideWith(
        () => FixedSettingsNotifier(
          AppSettings(
            homeFeedProvider: AppSettings.homeFeedProviderOff,
            homeLayout: const HomeLayout().withVisible(
              HomeSection.unfinished,
              turnedOn,
            ),
          ),
        ),
      ),
      extensionProvider.overrideWith(_Extensions.new),
      exploreProvider.overrideWith(_Explore.new),
      downloadHistoryProvider.overrideWith(_History.new),
      localLibraryProvider.overrideWith(_Local.new),
      recentAccessProvider.overrideWith(_Recent.new),
      libraryMixesProvider.overrideWith((ref) async => const []),
      homeTopPicksProvider.overrideWith((ref) async => const <ExploreItem>[]),
      homeRecentlyAddedProvider.overrideWith(
        (ref) async => (items: const <UnifiedLibraryItem>[], trackCount: 0),
      ),
      homeRecentlyPlayedProvider.overrideWith((ref) async => const []),
      homeOnRepeatProvider.overrideWith((ref) async => const []),
      homeQuickSongsProvider.overrideWith((ref) async => const []),
      homeLibraryAlbumsProvider.overrideWith((ref) async => const []),
      playerUiEnabledProvider.overrideWithValue(true),
      currentMediaItemProvider.overrideWithBuild(
        (ref, notifier) => Stream<MediaItem?>.value(null),
      ),
      playbackResumeProvider.overrideWith((ref) async => null),
      libraryCollectionsProvider.overrideWith(() => collections),
      downloadQueueProvider.overrideWith(() => queue),
      homeIncompleteAlbumCountProvider.overrideWith(
        (ref) async => incompleteAlbums,
      ),
      homeRecognizedMissingProvider.overrideWith((ref) async => recognized),
      libraryBrowsePageLoaderProvider.overrideWithValue(
        (request) async => LibraryBrowsePage(albums),
      ),
      recognitionHistoryProvider.overrideWith(
        () => _RecognitionHistory(const []),
      ),
      recognitionMicrophoneProvider.overrideWithValue(_Microphone()),
      musicRecognizerProvider.overrideWithValue(_Recognizer()),
      playbackPlayingProvider.overrideWith((ref) => false),
    ],
    child: MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeTab(mode: HomeTabMode.browse),
    ),
  );
}

class _Lookup implements RecognitionLibrary {
  _Lookup({this.isrcs = const {}, this.songs = const {}});

  final Set<String> isrcs;

  /// "title|artist" pairs.
  final Set<String> songs;
  int lookups = 0;

  static const _match = RecognitionLibraryMatch(
    path: '/music/song.flac',
    title: '',
    artist: '',
  );

  @override
  Future<RecognitionLibraryMatch?> byIsrc(String isrc) async {
    lookups++;
    return isrcs.contains(isrc) ? _match : null;
  }

  @override
  Future<RecognitionLibraryMatch?> byTitleArtist(
    String title,
    String artist,
  ) async {
    lookups++;
    return songs.contains('$title|$artist') ? _match : null;
  }
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections(this.initial);

  final List<CollectionTrackEntry> initial;

  @override
  LibraryCollectionsState build() =>
      LibraryCollectionsState(wishlist: initial, isLoaded: true);

  void setWishlist(List<CollectionTrackEntry> wishlist) =>
      state = LibraryCollectionsState(wishlist: wishlist, isLoaded: true);
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this.initial);

  final List<DownloadItem> initial;

  /// One entry per Retry all.
  final retries = <bool>[];

  @override
  DownloadQueueState build() =>
      const DownloadQueueState().copyWith(items: initial, isPaused: true);

  @override
  Future<void> retryAllFailed({bool networkOnly = false}) async {
    retries.add(networkOnly);
    state = state.copyWith(items: const []);
  }
}

class _RecognitionHistory extends RecognitionHistoryNotifier {
  _RecognitionHistory(this.initial);

  final List<RecognizedSong> initial;

  @override
  List<RecognizedSong> build() => initial;
}

class _Microphone implements RecognitionMicrophone {
  @override
  Future<MicrophoneAccess> requestAccess() async => MicrophoneAccess.granted;

  @override
  Future<Stream<Uint8List>> start() async => const Stream.empty();

  @override
  Future<void> stop() async {}

  @override
  bool get canOpenSettings => false;

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> dispose() async {}
}

class _Recognizer implements MusicRecognizer {
  @override
  Future<RecognitionResponse> recognize(
    Uint8List pcm, {
    required String requestId,
  }) async => const RecognitionCancelled();

  @override
  Future<void> cancel(String requestId) async {}
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

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}
