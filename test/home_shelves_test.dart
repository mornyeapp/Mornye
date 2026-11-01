import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/file_access.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:sqflite/sqflite.dart';
// The app reaches sqflite_common through sqflite and sqflite_common_ffi.
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import 'support/fixed_settings.dart';

/// Every read the databases ran, in order.
final _statements = <String>[];

int _ran(String fragment) =>
    _statements.where((sql) => sql.contains(fragment)).length;

/// Statistics reads, one per On Repeat load.
const _statisticsRead = 'FROM listening WHERE day >= ?';

/// The one-by-one Library lookups of a played file.
const _lookups = [
  'JOIN history_path_keys hpk',
  'SELECT DISTINCT item.id, item.file_path',
  'FROM library_visible WHERE id',
];

int _lookupsRan() => _lookups.fold(0, (sum, sql) => sum + _ran(sql));

/// The unfiltered Library count.
const _countRead = 'SUM(track_count)';

late Directory _root;

String _path(String name) => '${_root.path}/music/$name';

Map<String, dynamic> _download(String id, String path, {int number = 1}) => {
  'id': id,
  'trackName': 'Download $id',
  'artistName': 'Artist',
  'albumName': 'Album $id',
  'filePath': path,
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(2026, 9, number + 1).toIso8601String(),
  'isrc': 'ISRC-$id',
};

Future<void> _addScanned(String id, String path, {String? source}) async {
  final db = await LibraryDatabase.instance.database;
  await db.insert(
    'library',
    LibraryRowMapper.encode(
      LocalLibraryItem(
        id: id,
        sourceId: source ?? LibraryDatabase.legacySourceId,
        trackName: 'Scanned $id',
        artistName: 'Artist',
        albumName: 'Album $id',
        filePath: path,
        scannedAt: DateTime.utc(2026, 10, 1),
      ).toJson(),
    ),
  );
  final batch = db.batch();
  sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, path);
  await batch.commit(noResult: true);
}

/// [plays] plays of [key] for [milliseconds] in total, [daysAgo] days ago.
Future<void> _played(
  String key,
  int milliseconds, {
  int plays = 1,
  int daysAgo = 1,
  String? artwork,
}) async {
  final now = DateTime.now();
  await writeListeningDeltas(await ListeningStatisticsStore.instance.database, [
    ListeningDelta(
      listeningDay(DateTime(now.year, now.month, now.day - daysAgo)),
      ListeningTrack(
        key: key,
        title: 'Title of $key',
        artist: 'Artist',
        album: 'Album',
        artwork: artwork,
      ),
      milliseconds,
      plays,
    ),
  ]);
}

class _History extends DownloadHistoryNotifier {
  _History(this.initial);

  final DownloadHistoryState initial;

  @override
  DownloadHistoryState build() => initial;

  void set(DownloadHistoryState next) => state = next;

  void bump() =>
      state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
}

class _Revision extends LocalLibraryIndexRevision {
  void bumpForTest() => state++;
}

final _media = StreamController<MediaItem?>.broadcast();

ProviderContainer _container({
  required bool includeLocal,
  List<DownloadHistoryItem> inMemory = const [],
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(
        () => FixedSettingsNotifier(
          AppSettings(localLibraryEnabled: includeLocal),
        ),
      ),
      downloadHistoryProvider.overrideWith(
        () => _History(DownloadHistoryState(items: inMemory)),
      ),
      localLibraryIndexRevisionProvider.overrideWith(_Revision.new),
      currentMediaItemProvider.overrideWithBuild(
        (ref, notifier) => _media.stream,
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets a provider rerun after a change.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// Reruns of [provider] after its first load.
ProviderSubscription<AsyncValue<T>> _countReloads<T>(
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> provider,
  void Function() onReload,
) => container.listen(provider, (previous, next) {
  if (next.isLoading) onReload();
});

/// The shelf as the old provider made it: each statistics track in turn,
/// matched one lookup at a time.
Future<List<Object?>> _oneByOne(
  ProviderContainer container, {
  required bool includeLocal,
}) async {
  final now = DateTime.now();
  final summary = await ListeningStatisticsStore.instance.load(
    DateTime(now.year, now.month, now.day - 27),
    DateTime(now.year, now.month, now.day + 1),
  );
  final history = container.read(downloadHistoryProvider.notifier);
  final database = LibraryDatabase.instance;
  final tracks = <Object?>[];
  for (final total in summary.tracks) {
    if (tracks.length == 10) break;
    final key = total.track.key;
    if (total.plays <= 0 ||
        key.startsWith('http://') ||
        key.startsWith('https://')) {
      continue;
    }
    final track = [key, total.track.title, total.track.artwork];
    final downloaded = await history.getByFilePathAsync(key);
    if (downloaded != null) {
      tracks.add([...track, 'dl:${downloaded.id}']);
      continue;
    }
    final ids = await database.getPhysicalFileIds([key]);
    if (ids.isNotEmpty && !includeLocal) continue;
    final row = ids.isEmpty ? null : await database.getById(ids.first);
    if (row != null) {
      tracks.add([...track, 'local:${row['id']}']);
      continue;
    }
    if (await fileExists(key)) tracks.add([...track, null]);
  }
  return tracks;
}

List<Object?> _describe(List<HomeRepeatTrack> tracks) => [
  for (final (:track, :item) in tracks)
    [
      track.key,
      track.title,
      track.artwork,
      switch (item) {
        null => null,
        UnifiedLibraryItem(:final historyItem?) => 'dl:${historyItem.id}',
        UnifiedLibraryItem(:final localItem?) => 'local:${localItem.id}',
        _ => 'other',
      },
    ],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    _root = await Directory.systemTemp.createTemp('home-shelves-');
    await Directory('${_root.path}/music').create();
    sqfliteFfiInit();
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (event) {
          if (event is SqfliteLoggerSqlEvent) _statements.add(event.sql);
        },
      ),
    );
    messenger.setMockMethodCallHandler(paths, (_) async => _root.path);
  });

  tearDownAll(() async {
    await LibraryDatabase.instance.close();
    await HistoryDatabase.instance.close();
    messenger.setMockMethodCallHandler(paths, null);
    await _root.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryDatabase.instance.clearAll();
    await HistoryDatabase.instance.clearAll();
    await ListeningStatisticsStore.instance.clear();
    _statements.clear();
  });

  group('Recently added', () {
    for (final includeLocal in [true, false]) {
      test('reloads per Library revision, not per History change '
          '(Local Library ${includeLocal ? 'on' : 'off'})', () async {
        await HistoryDatabase.instance.upsertBatch([
          for (var index = 0; index < 4; index++)
            _download('d$index', _path('d$index.flac'), number: index),
        ]);
        await _addScanned('s0', _path('s0.flac'));
        final container = _container(includeLocal: includeLocal);
        var reloads = 0;
        _countReloads<HomeRecentlyAdded>(
          container,
          homeRecentlyAddedProvider,
          () => reloads++,
        );
        final first = await container.read(homeRecentlyAddedProvider.future);
        expect(first.items, hasLength(includeLocal ? 5 : 4));
        expect(first.trackCount, includeLocal ? 5 : 4);

        // Each completed download lands in memory first; the coalesced
        // revision follows.
        final history =
            container.read(downloadHistoryProvider.notifier) as _History;
        for (var index = 0; index < 5; index++) {
          history.set(
            history.state.copyWith(
              items: [
                DownloadHistoryItem.fromJson(
                  _download('m$index', _path('m$index.flac')),
                ),
                ...history.state.items,
              ],
            ),
          );
          await _settle();
        }
        expect(reloads, 0);

        history.bump();
        final same = await container.read(homeRecentlyAddedProvider.future);
        expect(reloads, 1);
        // Nothing changed in the Library: the same songs, so Home does not
        // rebuild.
        expect(same, first);
        expect(identical(same.items, first.items), isTrue);

        (container.read(localLibraryIndexRevisionProvider.notifier)
                as _Revision)
            .bumpForTest();
        await _settle();
        expect(reloads, includeLocal ? 2 : 1);

        await HistoryDatabase.instance.upsertBatch([
          // Added after the scanned song.
          _download('d9', _path('d9.flac'), number: 40),
        ]);
        history.bump();
        final added = await container.read(homeRecentlyAddedProvider.future);
        expect(added.items.first.historyItem?.id, 'd9');
        expect(added.trackCount, includeLocal ? 6 : 5);
        // The Library index loads with its own startup warmup.
        expect(container.exists(localLibraryProvider), isFalse);
      });
    }

    test('shares one count with the Library badges per revision', () async {
      await HistoryDatabase.instance.upsertBatch([
        _download('d0', _path('d0.flac')),
      ]);
      final container = _container(includeLocal: true);
      container.listen(homeRecentlyAddedProvider, (_, _) {});
      final badges = libraryCountsProvider(
        const LibraryCountsRequest(
          searchQuery: '',
          filterSource: null,
          filterQuality: null,
          filterFormat: null,
          filterMetadata: null,
          localLibraryEnabled: true,
        ),
      );
      container.listen(badges, (_, _) {});
      await container.read(homeRecentlyAddedProvider.future);
      await container.read(badges.future);
      expect(_ran(_countRead), 1);

      (container.read(downloadHistoryProvider.notifier) as _History).bump();
      await container.read(homeRecentlyAddedProvider.future);
      await container.read(badges.future);
      expect(_ran(_countRead), 2);
    });
  });

  group('On Repeat', () {
    /// Downloads, scanned files (one on an offline source), files outside
    /// the Library that exist or are gone, streams, songs never counted as
    /// played and equal listening times; more matches than the shelf holds.
    Future<List<DownloadHistoryItem>> seed() async {
      final library = await LibraryDatabase.instance.database;
      await library.insert('library_sources', {
        'id': 'offline',
        'path': _path('offline'),
        'display_name': 'Offline',
        'enabled': 1,
        'available': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final downloads = [
        for (var index = 0; index < 8; index++)
          _download('d$index', _path('d$index.flac'), number: index),
        // Another format of a scanned file: the download wins.
        _download('dcopy', _path('s0.opus'), number: 9),
      ];
      await HistoryDatabase.instance.upsertBatch(downloads);
      for (var index = 0; index < 7; index++) {
        await _addScanned('s$index', _path('s$index.flac'));
      }
      await _addScanned('off', _path('off.flac'), source: 'offline');
      await _addScanned('offgone', _path('offgone.flac'), source: 'offline');
      for (final name in ['outside0.flac', 'outside1.flac', 'off.flac']) {
        await File(_path(name)).writeAsString('audio');
      }
      final played = <(String, int)>[
        ('https://stream.example/a', 900000),
        (_path('d0.flac'), 800000),
        (_path('s0.flac'), 700000),
        (_path('gone0.flac'), 650000),
        (_path('s1.flac'), 600000),
        (_path('outside0.flac'), 600000),
        (_path('d1.flac'), 600000),
        ('http://stream.example/b', 550000),
        (_path('off.flac'), 500000),
        (_path('offgone.flac'), 480000),
        (_path('s2.flac'), 450000),
        (_path('d2.flac'), 400000),
        (_path('gone1.flac'), 380000),
        (_path('s3.flac'), 350000),
        (_path('outside1.flac'), 300000),
        (_path('d3.flac'), 300000),
        (_path('s4.flac'), 250000),
        (_path('d4.flac'), 200000),
        (_path('s5.flac'), 150000),
        (_path('d5.flac'), 120000),
        (_path('d6.flac'), 100000),
        (_path('d7.flac'), 90000),
      ];
      for (final (index, (key, milliseconds)) in played.indexed) {
        await _played(
          key,
          milliseconds,
          artwork: index.isEven ? 'https://covers.example/$index.jpg' : null,
        );
      }
      // Listened to, never for 30 seconds in one go.
      await _played(_path('s6.flac'), 990000, plays: 0, daysAgo: 2);
      // Days add up.
      await _played(_path('d4.flac'), 5000, plays: 0, daysAgo: 3);
      // Older than four weeks.
      await _played(_path('d3.flac'), 2000000, daysAgo: 40);
      return [
        for (final json in downloads.take(2))
          DownloadHistoryItem.fromJson(json),
      ];
    }

    for (final includeLocal in [true, false]) {
      test('matches the one-by-one shelf '
          '(Local Library ${includeLocal ? 'on' : 'off'})', () async {
        final inMemory = await seed();
        final container = _container(
          includeLocal: includeLocal,
          inMemory: inMemory,
        );
        container.listen(homeOnRepeatProvider, (_, _) {});
        final shelf = await container.read(homeOnRepeatProvider.future);
        final expected = await _oneByOne(container, includeLocal: includeLocal);
        expect(expected, hasLength(10));
        expect(_describe(shelf), expected);
      });
    }

    test('a song after none follows no play; one after another may', () async {
      await seed();
      final container = _container(includeLocal: true);
      var reloads = 0;
      _countReloads<List<HomeRepeatTrack>>(
        container,
        homeOnRepeatProvider,
        () => reloads++,
      );
      await container.read(homeOnRepeatProvider.future);

      // The restored session's song, then the next one after it plays.
      _media.add(const MediaItem(id: 'a', title: 'A'));
      await _settle();
      expect(reloads, 0);
      _media.add(const MediaItem(id: 'b', title: 'B'));
      await _settle();
      expect(reloads, 1);
      _media.add(null);
      await _settle();
      expect(reloads, 2);
      _media.add(const MediaItem(id: 'c', title: 'C'));
      await _settle();
      expect(reloads, 2);
    });

    test('continues past missing candidates to fill the shelf', () async {
      for (var index = 0; index < 55; index++) {
        final path = _path('candidate-$index.flac');
        await _played(path, 1000000 - index * 1000);
        if (index >= 45) await File(path).writeAsString('audio');
      }
      final container = _container(includeLocal: false);
      container.listen(homeOnRepeatProvider, (_, _) {});
      final tracks = await container.read(homeOnRepeatProvider.future);
      expect(tracks.map((entry) => entry.track.key), [
        for (var index = 45; index < 55; index++)
          _path('candidate-$index.flac'),
      ]);
      expect(_ran(_statisticsRead), 2);
    });

    test(
      'rechecks memoized files outside the Library after deletion',
      () async {
        final path = _path('outside.flac');
        await File(path).writeAsString('audio');
        await _played(path, 100000);
        final container = _container(includeLocal: false);
        container.listen(homeOnRepeatProvider, (_, _) {});
        expect(await container.read(homeOnRepeatProvider.future), hasLength(1));

        await File(path).delete();
        container.invalidate(homeOnRepeatProvider);
        expect(await container.read(homeOnRepeatProvider.future), isEmpty);
      },
    );

    test(
      'a new song reads the statistics again and looks nothing up',
      () async {
        await seed();
        final container = _container(includeLocal: true);
        container.listen(homeOnRepeatProvider, (_, _) {});
        _media.add(const MediaItem(id: 'a', title: 'A'));
        final first = await container.read(homeOnRepeatProvider.future);
        final lookups = _lookupsRan();
        expect(lookups, greaterThan(10));
        expect(_ran(_statisticsRead), 1);

        _media.add(const MediaItem(id: 'b', title: 'B'));
        await _settle();
        final next = await container.read(homeOnRepeatProvider.future);
        expect(_ran(_statisticsRead), 2);
        expect(_lookupsRan(), lookups);
        expect(identical(next, first), isTrue);

        // A play that moves a song up changes the shelf.
        await _played(_path('s3.flac'), 5000000);
        _media.add(const MediaItem(id: 'c', title: 'C'));
        await _settle();
        final moved = await container.read(homeOnRepeatProvider.future);
        expect(_lookupsRan(), lookups);
        expect(moved.first.track.key, _path('s3.flac'));

        // A Library change looks the songs up again; the same matches keep
        // the shelf as it was.
        final before = _lookupsRan();
        (container.read(downloadHistoryProvider.notifier) as _History).bump();
        await _settle();
        final again = await container.read(homeOnRepeatProvider.future);
        expect(_lookupsRan(), greaterThan(before));
        expect(identical(again, moved), isTrue);
      },
    );
  });

  group('Mixes', () {
    test(
      'keep their views while a Library change leaves their songs',
      () async {
        final downloads = [
          for (var index = 0; index < 30; index++)
            _download('d$index', _path('d$index.flac'), number: index % 25),
        ];
        await HistoryDatabase.instance.upsertBatch(downloads);
        final mix = LibraryMix(
          kind: LibraryMixKind.artist,
          key: 'artist',
          label: 'Artist',
          artists: const ['Artist'],
          songIds: [for (var index = 0; index < 12; index++) 'dl_d$index'],
        );
        SharedPreferences.setMockInitialValues({
          'home_library_mixes_v2': jsonEncode({
            'day': listeningDay(DateTime.now()),
            'includeLocal': false,
            'count': 30,
            'mixes': [mix.toJson()],
          }),
        });
        final runtime = MusicPlayerRuntime();
        addTearDown(runtime.dispose);
        final container = _container(
          includeLocal: false,
          overrides: [
            libraryMixesStartupProvider.overrideWithBuild(
              (ref, notifier) => true,
            ),
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
          ],
        );
        var reloads = 0;
        _countReloads<List<LibraryMixView>>(
          container,
          libraryMixesProvider,
          () => reloads++,
        );
        final first = await container.read(libraryMixesProvider.future);
        expect(first.single.items, hasLength(12));

        final history =
            container.read(downloadHistoryProvider.notifier) as _History;
        // A download outside the mixes, in memory before its revision.
        await HistoryDatabase.instance.upsertBatch([
          _download('d30', _path('d30.flac')),
        ]);
        history.set(
          history.state.copyWith(
            items: [
              DownloadHistoryItem.fromJson(_download('d30', _path('d30.flac'))),
            ],
          ),
        );
        await _settle();
        expect(reloads, 0);
        history.bump();
        await _settle();
        final kept = await container.read(libraryMixesProvider.future);
        expect(reloads, 1);
        expect(identical(kept, first), isTrue);

        // A mix song renamed.
        await HistoryDatabase.instance.upsertBatch([
          {...downloads[3], 'trackName': 'Renamed'},
        ]);
        history.bump();
        await _settle();
        final renamed = await container.read(libraryMixesProvider.future);
        expect(identical(renamed, first), isFalse);
        expect(renamed.single.items[3].trackName, 'Renamed');
      },
    );
  });
}
