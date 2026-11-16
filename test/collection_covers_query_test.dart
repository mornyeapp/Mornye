import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
// The app reaches sqflite_common through sqflite and sqflite_common_ffi.
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

/// Every read the databases ran, with the rows it returned.
final _reads = <({String sql, Object? arguments, int rows})>[];

/// Rows of playlist songs read.
int _playlistRowsRead() => _reads
    .where((read) => read.sql.contains('SELECT track_json FROM'))
    .fold(0, (sum, read) => sum + read.rows);

/// Library keys sent to the cover lookups.
int _libraryKeysAsked() => _reads
    .where((read) => read.sql.contains('FROM library_visible WHERE'))
    .fold(0, (sum, read) => sum + (read.arguments as List).length);

int _readCount() => _reads
    .where(
      (read) =>
          read.sql.contains('SELECT track_json FROM') ||
          read.sql.contains('FROM library_visible WHERE'),
    )
    .length;

late Directory _root;
late String _loadable;

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();

  void bump() =>
      state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
}

Track _track(int index, {String? cover}) => Track(
  id: 'track-$index',
  name: 'Song $index',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  coverUrl: cover,
);

Future<void> _addLibrarySong(int index, String cover) async {
  final db = await LibraryDatabase.instance.database;
  await db.insert(
    'library',
    LibraryRowMapper.encode(
      LocalLibraryItem(
        id: 'library-$index',
        sourceId: LibraryDatabase.legacySourceId,
        trackName: 'Song $index',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '${_root.path}/music/$index.flac',
        coverPath: cover,
        scannedAt: DateTime.utc(2026, 10, 1),
      ).toJson(),
    ),
  );
}

Future<void> _addPlaylist(String id, List<Track> tracks) async {
  final collections = LibraryCollectionsDatabase.instance;
  const at = '2026-11-01T00:00:00.000Z';
  await collections.upsertPlaylist(
    id: id,
    name: id,
    createdAt: at,
    updatedAt: at,
  );
  await collections.upsertPlaylistTracksBatch(
    playlistId: id,
    playlistUpdatedAt: at,
    tracks: [
      for (var i = 0; i < tracks.length; i++)
        {
          'track_key': tracks[i].id,
          'track_json': jsonEncode(tracks[i].toJson()),
          'added_at': DateTime.utc(
            2026,
            1,
            1,
          ).add(Duration(seconds: i)).toIso8601String(),
        },
    ],
  );
}

({ProviderContainer container, _Library library}) _container() {
  final library = _Library();
  final container = ProviderContainer(
    overrides: [localLibraryProvider.overrideWith(() => library)],
  );
  addTearDown(container.dispose);
  return (container: container, library: library);
}

/// Reads [provider] the way a tile does: listened while shown, then disposed.
Future<T> _readOnce<T>(
  ProviderContainer container,
  FutureProvider<T> provider,
) async {
  final subscription = container.listen(provider, (_, _) {});
  try {
    return await container.read(provider.future);
  } finally {
    subscription.close();
    await container.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    _root = await Directory.systemTemp.createTemp('collection-covers-');
    await Directory('${_root.path}/music').create();
    _loadable = '${_root.path}/cover.jpg';
    await File(_loadable).writeAsBytes(const [0]);
    sqfliteFfiInit();
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (event) {
          if (event is SqfliteLoggerSqlEvent) {
            final result = event.result;
            _reads.add((
              sql: event.sql,
              arguments: event.arguments,
              rows: result is List ? result.length : 0,
            ));
          }
        },
      ),
    );
    messenger.setMockMethodCallHandler(paths, (_) async => _root.path);
  });

  tearDownAll(() async {
    await LibraryDatabase.instance.close();
    messenger.setMockMethodCallHandler(paths, null);
    await _root.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryDatabase.instance.clearAll();
    await (await LibraryCollectionsDatabase.instance.database).delete(
      'playlists',
    );
    _reads.clear();
  });

  test('a long playlist whose first song has no cover reads one small page '
      'and looks up only that page', () async {
    await _addPlaylist('long', [for (var i = 0; i < 500; i++) _track(i)]);
    await _addLibrarySong(0, _loadable);
    final (:container, library: _) = _container();
    _reads.clear();

    final cover = await _readOnce<String?>(
      container,
      playlistCoverProvider((id: 'long', cover: null, updatedAt: null)),
    );

    expect(cover, _loadable);
    expect(_playlistRowsRead(), lessThanOrEqualTo(16));
    expect(_libraryKeysAsked(), lessThanOrEqualTo(2 * 16));
  });

  test('a playlist tile that comes back into view asks again only after the '
      'Library or the playlist changed', () async {
    await _addPlaylist('kept', [for (var i = 0; i < 40; i++) _track(i)]);
    await _addLibrarySong(30, _loadable);
    final (:container, :library) = _container();
    const request = (id: 'kept', cover: null, updatedAt: null);
    _reads.clear();

    expect(
      await _readOnce<String?>(container, playlistCoverProvider(request)),
      _loadable,
    );
    final firstReads = _readCount();
    expect(firstReads, greaterThan(0));

    for (var i = 0; i < 3; i++) {
      expect(
        await _readOnce<String?>(container, playlistCoverProvider(request)),
        _loadable,
      );
    }
    expect(_readCount(), firstReads);

    final changed = (
      id: 'kept',
      cover: null,
      updatedAt: DateTime.utc(2026, 11, 2),
    );
    expect(
      await _readOnce<String?>(container, playlistCoverProvider(changed)),
      _loadable,
    );
    expect(_readCount(), 2 * firstReads);

    library.bump();
    expect(
      await _readOnce<String?>(container, playlistCoverProvider(request)),
      _loadable,
    );
    expect(_readCount(), 3 * firstReads);
  });

  test('the first loadable cover is the same for a playlist and a collection '
      'header, in song order', () async {
    final missing = '${_root.path}/missing.jpg';
    final cases = <String, ({List<Track> tracks, String? expected})>{
      'stored cover of a later page': (
        tracks: [
          _track(100, cover: missing),
          for (var i = 101; i < 121; i++) _track(i),
          _track(121, cover: 'https://example.com/121.jpg'),
          for (var i = 122; i < 160; i++) _track(i),
        ],
        expected: 'https://example.com/121.jpg',
      ),
      'Library cover before a later stored cover': (
        tracks: [
          _track(2),
          _track(3, cover: missing),
          _track(5, cover: missing),
          _track(6, cover: _loadable),
        ],
        expected: '$_loadable-library-5',
      ),
      'empty Library cover is skipped': (
        tracks: [
          _track(4),
          _track(6, cover: _loadable),
        ],
        expected: _loadable,
      ),
      'stored cover before its own Library cover': (
        tracks: [
          _track(0),
          _track(1, cover: 'https://example.com/1.jpg'),
        ],
        expected: 'https://example.com/1.jpg',
      ),
      'Library cover deep in a long collection': (
        tracks: [for (var i = 400; i < 700; i++) _track(i)],
        expected: '$_loadable-library-650',
      ),
      'no cover at all': (
        tracks: [for (var i = 800; i < 870; i++) _track(i, cover: missing)],
        expected: null,
      ),
    };
    await _addLibrarySong(1, '$_loadable-library-1');
    await _addLibrarySong(4, '');
    await _addLibrarySong(5, '$_loadable-library-5');
    await _addLibrarySong(650, '$_loadable-library-650');
    await _addLibrarySong(651, '$_loadable-library-651');

    for (final MapEntry(key: name, value: (:tracks, :expected))
        in cases.entries) {
      await _addPlaylist(name, tracks);
      final (:container, library: _) = _container();
      expect(
        await _readOnce<String?>(
          container,
          playlistCoverProvider((id: name, cover: null, updatedAt: null)),
        ),
        expected,
        reason: 'playlist: $name',
      );
      expect(
        await _readOnce<String?>(
          container,
          localLibraryFirstCoverProvider(
            LocalLibraryCoverBatchRequest([
              for (final track in tracks) LocalLibraryCoverRequest.of(track),
            ]),
          ),
        ),
        expected,
        reason: 'collection: $name',
      );
    }
  });

  test(
    'collection covers look up only the songs whose own cover fails',
    () async {
      await _addLibrarySong(7, _loadable);
      final tracks = [
        for (var i = 0; i < 200; i++)
          i == 7 ? _track(i) : _track(i, cover: 'https://example.com/$i.jpg'),
      ];
      final (:container, library: _) = _container();
      _reads.clear();

      final covers = await _readOnce<List<String?>>(
        container,
        localLibraryCoversProvider(
          LocalLibraryCoverBatchRequest([
            for (final track in tracks) LocalLibraryCoverRequest.of(track),
          ]),
        ),
      );

      expect(covers, [
        for (var i = 0; i < 200; i++)
          i == 7 ? _loadable : 'https://example.com/$i.jpg',
      ]);
      expect(_libraryKeysAsked(), lessThanOrEqualTo(2));
    },
  );

  test(
    'the first cover of a large collection header looks up a small page',
    () async {
      await _addLibrarySong(0, _loadable);
      final (:container, library: _) = _container();
      _reads.clear();

      final cover = await _readOnce<String?>(
        container,
        localLibraryFirstCoverProvider(
          LocalLibraryCoverBatchRequest([
            for (var i = 0; i < 2000; i++)
              LocalLibraryCoverRequest.of(_track(i)),
          ]),
        ),
      );

      expect(cover, _loadable);
      expect(_libraryKeysAsked(), lessThanOrEqualTo(2 * 16));
    },
  );
}
