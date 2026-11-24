import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_context_provider.dart';
import 'package:mornye/providers/home_recommendations_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/services/suggestion_outcomes.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import 'support/fixed_settings.dart';

const _hiResTitle = 'Hi-Res in your Library';

LibraryBrowseEntry _album(int index) => LibraryBrowseEntry(
  source: 'downloaded',
  key: 'album-$index',
  name: 'Album $index',
  artist: 'Artist',
  samplePath: '',
  trackCount: 2,
);

class _Output extends HomeHiResOutput {
  _Output(this.on);

  final bool on;

  @override
  bool build() => on;
}

class _Server implements LinkClientApi {
  _Server(this.server);

  @override
  final LinkServerRecord server;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LinkServerRecord _record(String name, {String platform = 'macos'}) =>
    LinkServerRecord(
      serverId: 'server',
      name: name,
      connectionId: 'connection',
      address: 'https://192.0.2.10:4533',
      fingerprint: 'fingerprint',
      platform: platform,
    );

/// Home without extensions, a feed or a played song, in the situation the
/// arguments describe.
Widget _home({
  required bool mornye,
  bool hiResOutput = false,
  List<LibraryBrowseEntry> hiResAlbums = const [],
  void Function()? onHiResRead,
  HomeLinkDevice? linkDevice,
  bool offline = false,
  List<Track> recommended = const [],
  List<WeeklyRelease> releases = const [],
  MusicPlayerRuntime? runtime,
  List<String> genres = const [],
  Map<String, List<Track>> genreSongs = const {},
}) => ProviderScope(
  overrides: [
    if (runtime != null) musicPlayerRuntimeProvider.overrideWithValue(runtime),
    homeGenreRecommendationsProvider.overrideWith(
      (ref, genre) async => genreSongs[genre] ?? const [],
    ),
    homeHiResOutputProvider.overrideWith(() => _Output(hiResOutput)),
    homeHiResAlbumsProvider.overrideWith((ref) async {
      onHiResRead?.call();
      return hiResAlbums;
    }),
    homeLinkDeviceProvider.overrideWithValue(linkDevice),
    homeOfflineProvider.overrideWith((ref) => Stream.value(offline)),
    homeRecommendationsProvider.overrideWith((ref) async => recommended),
    homeNewReleasesProvider.overrideWith((ref) => Stream.value(releases)),
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
      (ref) async => [
        for (final genre in genres)
          LibraryMixView(
            mix: LibraryMix(
              kind: LibraryMixKind.genre,
              key: genre.toLowerCase(),
              label: genre,
              artists: const ['Someone'],
              songIds: const [],
            ),
            items: const [],
          ),
      ],
    ),
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
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const HomeTab(mode: HomeTabMode.browse),
  ),
);

Future<void> _open(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(home);
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _addScanned(
  Database db,
  String id, {
  required String album,
  required int? bitDepth,
  required String format,
}) async {
  final path = '/music/$album/$id.$format';
  final json = LocalLibraryItem(
    id: id,
    trackName: 'Song $id',
    artistName: 'Artist',
    albumName: album,
    albumArtist: 'Artist',
    filePath: path,
    scannedAt: DateTime.utc(2026, 11, 1),
    bitDepth: bitDepth,
    sampleRate: bitDepth == null ? null : 96000,
    format: format,
  ).toJson();
  await db.insert('library', LibraryRowMapper.encode(json));
  final batch = db.batch();
  sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, path);
  await batch.commit(noResult: true);
}

void main() {
  group('a DAC as the output', () {
    test('starts with direct USB playback and lasts through song changes', () {
      var on = false;
      for (final (reason, expected) in [
        ('preparing', false),
        ('active', true),
        ('idle', true),
        ('preparing', true),
        ('ready', true),
        ('format_unsupported', true),
        ('active', true),
        ('route_changed', false),
        ('ready', false),
      ]) {
        on = homeUsbHiResOutput(
          on,
          UsbAudioStatus(reason: reason),
          enabled: true,
        );
        expect(on, expected, reason: reason);
      }
      expect(
        homeUsbHiResOutput(
          true,
          const UsbAudioStatus(reason: 'active'),
          enabled: false,
        ),
        isFalse,
      );
      expect(
        homeUsbHiResOutput(
          true,
          const UsbAudioStatus(reason: 'no_usb'),
          enabled: true,
        ),
        isFalse,
      );
    });

    test('is the desktop exclusive output while it holds the device', () {
      var on = false;
      for (final (status, expected) in [
        (ExclusiveOutputStatus.pending, false),
        (ExclusiveOutputStatus.active, true),
        (ExclusiveOutputStatus.pending, true),
        (ExclusiveOutputStatus.unavailable, false),
      ]) {
        on = homeExclusiveHiResOutput(on, status, enabled: true);
        expect(on, expected, reason: status.name);
      }
      expect(
        homeExclusiveHiResOutput(
          true,
          ExclusiveOutputStatus.active,
          enabled: false,
        ),
        isFalse,
      );
    });

    test('follows the player\'s USB status', () {
      addTearDown(() => usbAudioStatus.value = const UsbAudioStatus());
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(const AppSettings(usbBitPerfect: true)),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(homeHiResOutputProvider), isFalse);
      usbAudioStatus.value = const UsbAudioStatus(
        reason: 'active',
        driver: 'usb_direct',
      );
      expect(container.read(homeHiResOutputProvider), isTrue);
      usbAudioStatus.value = const UsbAudioStatus();
      expect(container.read(homeHiResOutputProvider), isTrue);
      usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
      expect(container.read(homeHiResOutputProvider), isFalse);
    });
  });

  group('a Link device', () {
    test('is the host this phone is connected to', () {
      final client = _Server(_record(' Studio PC '));
      expect(
        homeLinkDevice(
          client: client,
          connection: LinkConnectionState.connected,
        ),
        (name: 'Studio PC', count: 1, phone: false, hosting: false),
      );
      expect(
        homeLinkDevice(
          client: client,
          connection: LinkConnectionState.connecting,
        ),
        isNull,
      );
      expect(
        homeLinkDevice(
          client: _Server(_record('Pocket', platform: 'android')),
          connection: LinkConnectionState.connected,
        )?.phone,
        isTrue,
      );
    });

    test('is the phones connected to this host', () {
      const phones = [
        LinkClientInfo(deviceId: 'a', name: 'Pocket', platform: 'android'),
        LinkClientInfo(deviceId: 'b', name: 'Tablet', platform: 'ios'),
      ];
      expect(homeLinkDevice(hostRunning: true, hostClients: phones), (
        name: 'Pocket',
        count: 2,
        phone: true,
        hosting: true,
      ));
      expect(homeLinkDevice(hostRunning: false, hostClients: phones), isNull);
      expect(homeLinkDevice(hostRunning: true), isNull);
    });
  });

  test('no network is offline, an unknown one is not', () {
    expect(homeIsOffline([ConnectivityResult.none]), isTrue);
    expect(homeIsOffline([ConnectivityResult.wifi]), isFalse);
    expect(
      homeIsOffline([ConnectivityResult.none, ConnectivityResult.vpn]),
      isFalse,
    );
    expect(homeIsOffline(const []), isFalse);
  });

  group('the Hi-Res albums', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() async {
      final root = await Directory.systemTemp.createTemp('home-hi-res-');
      sqfliteFfiInit();
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactoryFfi;
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      addTearDown(() async {
        await LibraryDatabase.instance.close();
        await HistoryDatabase.instance.close();
        messenger.setMockMethodCallHandler(paths, null);
        databaseFactory = previousFactory;
        await root.delete(recursive: true);
      });
    });

    test('are the albums the Library\'s Hi-Res filter keeps', () async {
      final db = await LibraryDatabase.instance.database;
      for (final (album, bitDepth, format) in [
        ('Studio', 24, 'flac'),
        ('Compact', 16, 'flac'),
        ('Lossy', null, 'mp3'),
      ]) {
        for (final number in [1, 2]) {
          await _addScanned(
            db,
            '$album-$number',
            album: album,
            bitDepth: bitDepth,
            format: format,
          );
        }
      }
      final page = await LibraryDatabase.instance.getQueueAlbumPageResult(
        homeHiResAlbumQuery(includeLocal: true, limit: 300),
      );
      expect([for (final row in page.rows) row['album_name']], ['Studio']);
      final counts = await LibraryDatabase.instance.getQueueCounts(
        homeHiResCountsRequest(includeLocal: true).toDbQuery(),
      );
      expect(counts.albumCount, 1);
    });
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('the $style Home shows Hi-Res albums while a DAC plays', (
      tester,
    ) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          hiResOutput: true,
          hiResAlbums: [_album(0), _album(1)],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text(_hiResTitle), findsOneWidget);
      expect(find.text('Album 1'), findsOneWidget);
    });

    testWidgets('the $style Home reads no Hi-Res albums without a DAC', (
      tester,
    ) async {
      var reads = 0;
      await _open(
        tester,
        _home(
          mornye: mornye,
          hiResAlbums: [_album(0)],
          onHiResRead: () => reads++,
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text(_hiResTitle), findsNothing);
      expect(reads, 0);
    });

    testWidgets('the $style Home names the attached Link device', (
      tester,
    ) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          linkDevice: (
            name: 'Studio PC',
            count: 1,
            phone: false,
            hosting: false,
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Connected to Studio PC'), findsOneWidget);
      await tester.tap(find.text('Connected to Studio PC'));
      await tester.pumpAndSettle();
      expect(find.text('Devices'), findsOneWidget);
    });

    testWidgets('the $style Home counts several connected phones', (
      tester,
    ) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          linkDevice: (name: 'Pocket', count: 3, phone: true, hosting: true),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Connected to 3 devices'), findsOneWidget);
    });

    testWidgets('the $style Home has no Link row without a device', (
      tester,
    ) async {
      await _open(tester, _home(mornye: mornye));
      expect(tester.takeException(), isNull);

      expect(find.byKey(const ValueKey('home-link-device')), findsNothing);
      expect(find.textContaining('Connected to'), findsNothing);
    });

    for (final offline in [false, true]) {
      testWidgets('the $style Home ${offline ? 'hides' : 'shows'} the '
          'online shelves ${offline ? 'offline' : 'online'}', (tester) async {
        await _open(
          tester,
          _home(
            mornye: mornye,
            offline: offline,
            recommended: const [
              Track(
                id: 'song',
                name: 'Suggested song',
                artistName: 'Someone',
                albumName: 'Album',
                duration: 200,
              ),
            ],
            releases: [
              WeeklyRelease(
                id: 'release',
                name: 'New album',
                artist: 'Someone',
                providerId: 'example-provider',
                date: DateTime(2026, 11, 20),
              ),
            ],
          ),
        );
        expect(tester.takeException(), isNull);

        final matcher = offline ? findsNothing : findsOneWidget;
        expect(find.text('Recommended for you'), matcher);
        expect(find.text('Suggested song'), matcher);
        // Mornye shows a new release among its Top Picks as well.
        expect(find.text('New album'), offline ? findsNothing : findsWidgets);
      });
    }

    testWidgets('the $style Home logs each recommended song it shows '
        'with its place', (tester) async {
      final outcomes = _Outcomes();
      await _open(
        tester,
        _home(
          mornye: mornye,
          recommended: const [
            Track(
              id: 'first',
              name: 'First song',
              artistName: 'Someone',
              albumName: 'Album',
              duration: 200,
            ),
            Track(
              id: 'second',
              name: 'Second song',
              artistName: 'Someone else',
              albumName: 'Album',
              duration: 200,
            ),
          ],
          runtime: MusicPlayerRuntime(
            dependencies: PlaybackDependencies(
              createSuggestionOutcomes: () => outcomes,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(outcomes.shown, [
        ('Someone', 'First song', 0),
        ('Someone else', 'Second song', 1),
      ]);
    });

    testWidgets('the $style Recommended page adds a shelf for each Library '
        'genre, each song once', (tester) async {
      Track song(String name) => Track(
        id: name,
        name: name,
        artistName: 'Someone',
        albumName: 'Album',
        duration: 200,
      );
      final outcomes = _Outcomes();
      await _open(
        tester,
        _home(
          mornye: mornye,
          recommended: [song('Daily song')],
          genres: const ['Rock', 'Jazz', 'Folk'],
          genreSongs: {
            'rock': [song('Daily song'), song('Rock song')],
            // Only songs another shelf has: no shelf of its own.
            'jazz': [song('Rock song')],
            'folk': [song('Folk song')],
          },
          runtime: MusicPlayerRuntime(
            dependencies: PlaybackDependencies(
              createSuggestionOutcomes: () => outcomes,
            ),
          ),
        ),
      );
      final title = find.text('Recommended for you');
      await tester.ensureVisible(title);
      await tester.tap(title);
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);

      expect(find.text('Based on your Library'), findsOneWidget);
      expect(find.text('Rock'), findsOneWidget);
      expect(find.text('Jazz'), findsNothing);
      expect(find.text('Folk'), findsOneWidget);
      expect(find.text('Daily song'), findsOneWidget);
      expect(find.text('Rock song'), findsOneWidget);
      expect(find.text('Folk song'), findsOneWidget);
      // Learning hears of the day's songs only.
      expect(
        {for (final (_, title, _) in outcomes.shown) title},
        {'Daily song'},
      );
    });
  }
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

/// Keeps what the shelf logs instead of writing it.
class _Outcomes extends SuggestionOutcomes {
  final shown = <(String, String, int)>[];

  @override
  void recommendationShown({
    required String artist,
    required String title,
    required int rank,
    int? sourceRank,
    double? fit,
  }) => shown.add((artist, title, rank));
}
