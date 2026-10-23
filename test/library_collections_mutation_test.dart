import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';

class _CollectionsDatabase implements LibraryCollectionsDatabase {
  final wishlist = <String, Map<String, dynamic>>{};
  final loved = <String, Map<String, dynamic>>{};
  final artists = <String, Map<String, dynamic>>{};
  final playlists = <String, Map<String, dynamic>>{};
  final playlistTracks = <String, List<Map<String, dynamic>>>{};
  final playlistReadStarted = Completer<void>();
  final releasePlaylistRead = Completer<void>();
  int playlistReads = 0;
  LibraryPlaylistTracksSnapshot? stagedPlaylistRows;
  Future<LibraryCollectionsSnapshot>? pendingSnapshot;
  final snapshotReadStarted = Completer<void>();
  final events = <String>[];
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  bool failNextWrite = false;

  Future<void> _write(String event, void Function() persist) async {
    events.add(event);
    final fail = failNextWrite;
    failNextWrite = false;
    // Only the first write waits, so an unserialized later write can overtake it.
    if (!writeStarted.isCompleted) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    if (fail) throw StateError('database write failed');
    persist();
  }

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async {
    if (!snapshotReadStarted.isCompleted) snapshotReadStarted.complete();
    return pendingSnapshot ??
        Future.value(
          LibraryCollectionsSnapshot(
            wishlistRows: wishlist.values.toList(),
            lovedRows: loved.values.toList(),
            playlistRows: playlists.values.toList(),
            playlistTrackRows: [
              for (final entry in playlistTracks.entries)
                for (final row in entry.value)
                  {'playlist_id': entry.key, 'track_key': row['track_key']},
            ],
            favoriteArtistRows: artists.values.toList(),
          ),
        );
  }

  Future<List<Map<String, dynamic>>> loadPlaylistTracks(
    String playlistId,
  ) async {
    playlistReads++;
    if (!playlistReadStarted.isCompleted) {
      playlistReadStarted.complete();
      await releasePlaylistRead.future;
    }
    return playlistTracks[playlistId] ?? const [];
  }

  @override
  Future<LibraryPlaylistTracksSnapshot> loadPlaylistTracksSnapshot(
    String playlistId,
  ) async {
    final rows = await loadPlaylistTracks(playlistId);
    return stagedPlaylistRows ?? LibraryPlaylistTracksSnapshot(rows: rows);
  }

  @override
  Future<void> renamePlaylist({
    required String playlistId,
    required String name,
    required String updatedAt,
  }) => _write('rename:$playlistId', () {
    playlists[playlistId] = {
      ...playlists[playlistId]!,
      'name': name,
      'updated_at': updatedAt,
    };
  });

  Future<void> _upsertTrack(
    Map<String, Map<String, dynamic>> rows,
    String collection,
    String key,
    String json,
    String date,
  ) => _write('insert:$collection:$key', () {
    rows[key] = {'track_key': key, 'track_json': json, 'added_at': date};
  });

  @override
  Future<void> upsertWishlistEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertTrack(wishlist, 'wishlist', trackKey, trackJson, addedAt);

  @override
  Future<void> deleteWishlistEntry(String trackKey) =>
      _write('delete:wishlist:$trackKey', () => wishlist.remove(trackKey));

  @override
  Future<void> deleteWishlistTracks(List<String> keys) =>
      _write('bulk-wishlist:remove', () {
        for (final key in keys) {
          wishlist.remove(key);
        }
      });

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertTrack(loved, 'loved', trackKey, trackJson, addedAt);

  @override
  Future<void> deleteLovedEntry(String trackKey) =>
      _write('delete:loved:$trackKey', () => loved.remove(trackKey));

  @override
  Future<void> upsertFavoriteArtistEntry({
    required String artistKey,
    required String artistJson,
    required String addedAt,
  }) => _write('insert:artists:$artistKey', () {
    artists[artistKey] = {
      'artist_key': artistKey,
      'artist_json': artistJson,
      'added_at': addedAt,
    };
  });

  @override
  Future<void> deleteFavoriteArtistEntry(String artistKey) =>
      _write('delete:artists:$artistKey', () => artists.remove(artistKey));

  @override
  Future<void> upsertPlaylist({
    required String id,
    required String name,
    required String createdAt,
    required String updatedAt,
    String? coverImagePath,
  }) => _write('insert:playlist:$id', () {
    playlists[id] = {
      'id': id,
      'name': name,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'cover_image_path': coverImagePath,
    };
  });

  @override
  Future<void> deletePlaylist(String playlistId) =>
      _write('delete:playlist:$playlistId', () => playlists.remove(playlistId));

  @override
  Future<void> deletePlaylists(List<String> ids) =>
      _write('bulk-playlists:remove', () {
        for (final id in ids) {
          playlists.remove(id);
          playlistTracks.remove(id);
        }
      });

  @override
  Future<void> upsertPlaylistTracksBatch({
    required String playlistId,
    required String playlistUpdatedAt,
    required List<Map<String, String>> tracks,
  }) => _write('batch:$playlistId', () {
    final rows = playlistTracks.putIfAbsent(playlistId, () => []);
    for (final track in tracks) {
      rows.removeWhere((row) => row['track_key'] == track['track_key']);
      rows.add({...track, 'playlist_id': playlistId});
    }
    playlists[playlistId]!['updated_at'] = playlistUpdatedAt;
  });

  @override
  Future<void> upsertLovedTracksBatch(List<Map<String, String>> tracks) =>
      _write('bulk-loved:add', () {
        for (final row in tracks) {
          loved[row['track_key']!] = Map<String, dynamic>.from(row);
        }
      });

  @override
  Future<void> deleteLovedTracks(List<String> keys) =>
      _write('bulk-loved:remove', () {
        for (final key in keys) {
          loved.remove(key);
        }
      });

  @override
  Future<void> deletePlaylistTracks({
    required String playlistId,
    required List<String> trackKeys,
    required String playlistUpdatedAt,
  }) => _write('bulk-playlist:remove', () {
    final keys = trackKeys.toSet();
    playlistTracks[playlistId]!.removeWhere(
      (row) => keys.contains(row['track_key']),
    );
    playlists[playlistId]!['updated_at'] = playlistUpdatedAt;
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Track _track(String id) => Track(
  id: id,
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  source: 'example',
);

ProviderContainer _container(_CollectionsDatabase db) {
  final container = ProviderContainer(
    overrides: [
      libraryCollectionsProvider.overrideWith(
        () => LibraryCollectionsNotifier(database: db),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'playlist import retains all 202 positions and re-import is idempotent',
    () async {
      final db = _CollectionsDatabase();
      db.playlists['playlist'] = {
        'id': 'playlist',
        'name': 'Playlist',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };
      db.releasePlaylistRead.complete();
      db.releaseWrite.complete();
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      final tracks = [
        for (var i = 0; i < 202; i++)
          _track('$i').copyWith(isrc: 'RECORDING${i % 198}'),
      ];
      final first = await notifier.addTracksToPlaylist(
        'playlist',
        tracks,
        preserveOccurrences: true,
      );
      expect(first.addedCount, 202);
      final imported = container
          .read(libraryCollectionsProvider)
          .playlists
          .single;
      expect(imported.trackCount, 202);
      expect(
        imported.tracks.map((entry) => entry.track.id),
        tracks.map((track) => track.id),
      );
      expect(db.playlistTracks['playlist'], hasLength(202));
      final request = PlaylistPickerSummaryRequest.fromTracks(
        tracks,
        preserveOccurrences: true,
      );
      expect(request.trackKeys.toSet(), imported.trackKeys);
      final second = await notifier.addTracksToPlaylist(
        'playlist',
        tracks,
        preserveOccurrences: true,
      );
      expect(second.addedCount, 0);
      expect(second.alreadyInPlaylistCount, 202);
      // Legacy playlists with the original 198 keys receive the four missing entries.
      final legacyKeys = tracks.map(trackCollectionKey).toSet();
      expect(
        request.trackKeys.where((key) => !legacyKeys.contains(key)),
        hasLength(4),
      );
    },
  );

  for (final failFirst in [false, true]) {
    test(
      'playlist bulk deletion snapshots IDs and serializes retries (fail: $failFirst)',
      () async {
        final db = _CollectionsDatabase()..failNextWrite = failFirst;
        for (final id in ['a', 'b', 'keep']) {
          db.playlists[id] = {
            'id': id,
            'name': 'Playlist $id',
            'cover_image_path': 'cover-$id',
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-02T00:00:00Z',
          };
          db.playlistTracks[id] = [
            {
              'track_key': 'example:shared',
              'track_json': jsonEncode(_track('shared').toJson()),
              'added_at': '2026-01-01T00:00:00Z',
            },
          ];
        }
        final container = _container(db);
        final notifier = container.read(libraryCollectionsProvider.notifier);
        final ids = ['a', 'b', 'missing', 'a'];
        final first = notifier.deletePlaylists(ids);
        ids
          ..clear()
          ..add('keep');
        final failure = failFirst ? expectLater(first, throwsStateError) : null;
        await db.writeStarted.future;
        final before = container.read(libraryCollectionsProvider);
        expect(before.playlists.every((p) => !p.tracksLoaded), true);
        var publications = 0;
        container.listen(libraryCollectionsProvider, (_, _) => publications++);
        final second = notifier.deletePlaylists(['a', 'b']);
        expect(db.events, ['bulk-playlists:remove']);
        expect(container.read(libraryCollectionsProvider), same(before));
        db.releaseWrite.complete();
        if (failure != null) {
          await failure;
        } else {
          expect(await first, 2);
        }
        expect(await second, failFirst ? 2 : 0);
        final after = container.read(libraryCollectionsProvider);
        expect(after.playlists.single, same(before.playlistById('keep')));
        expect(after.playlists.single.coverImagePath, 'cover-keep');
        expect(after.playlists.single.trackKeys, {'example:shared'});
        expect(db.playlists.keys, ['keep']);
        expect(db.playlistTracks.keys, ['keep']);
        expect(db.playlistReads, 0);
        expect(publications, 1);
        expect(await notifier.deletePlaylists([]), 0);
        expect(await notifier.deletePlaylists(['missing', 'a']), 0);
        expect(db.events.length, failFirst ? 2 : 1);
        expect(publications, 1);
      },
    );
  }

  test('late hydration cannot resurrect a bulk-deleted playlist', () async {
    final db = _CollectionsDatabase();
    db.playlists['p'] = {
      'id': 'p',
      'name': 'Playlist',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };
    final rows = [
      {
        'track_key': 'example:shared',
        'track_json': jsonEncode(_track('shared').toJson()),
        'added_at': '2026-01-01T00:00:00Z',
      },
    ];
    db.playlistTracks['p'] = rows;
    db.stagedPlaylistRows = LibraryPlaylistTracksSnapshot(rows: rows);
    final container = _container(db);
    final notifier = container.read(libraryCollectionsProvider.notifier);
    final load = notifier.ensurePlaylistLoaded('p');
    await db.playlistReadStarted.future;
    db.releaseWrite.complete();
    expect(await notifier.deletePlaylists(['p']), 1);
    expect(container.read(libraryCollectionsProvider).playlists, isEmpty);
    db.releasePlaylistRead.complete();
    await load;
    expect(container.read(libraryCollectionsProvider).playlists, isEmpty);
    expect(db.playlistReads, 1);
  });

  for (final kind in ['wishlist', 'loved', 'playlist']) {
    for (final failFirst in [false, true]) {
      test(
        'bulk $kind removal is atomic and serializes repeated clicks (fail: $failFirst)',
        () async {
          final db = _CollectionsDatabase()..failNextWrite = failFirst;
          final tracks = [
            for (final id in ['a', 'b', 'keep']) _track(id),
          ];
          final rows = [
            for (final track in tracks)
              <String, dynamic>{
                'track_key': trackCollectionKey(track),
                'track_json': jsonEncode(track.toJson()),
                'added_at': '2026-01-01T00:00:00Z',
              },
          ];
          for (final row in rows) {
            db.wishlist[row['track_key'] as String] = {...row};
            db.loved[row['track_key'] as String] = {...row};
          }
          for (final id in ['p', 'other']) {
            db.playlists[id] = {
              'id': id,
              'name': id,
              'cover_image_path': 'cover',
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-01T00:00:00Z',
            };
            db.playlistTracks[id] = [
              for (final row in rows) {...row},
            ];
          }
          db.releasePlaylistRead.complete();
          final container = _container(db);
          final notifier = container.read(libraryCollectionsProvider.notifier);
          Future<int> remove(Iterable<String> keys) => switch (kind) {
            'wishlist' => notifier.removeWishlistTracks(keys),
            'loved' => notifier.removeLovedTracks(keys),
            _ => notifier.removeTracksFromPlaylist('p', keys),
          };
          final selected = ['example:a', 'example:b', 'example:a', 'missing'];
          final first = remove(selected);
          selected
            ..clear()
            ..add('example:keep');
          final failure = failFirst
              ? expectLater(first, throwsStateError)
              : null;
          await db.writeStarted.future;
          final before = container.read(libraryCollectionsProvider);
          var publications = 0;
          container.listen(
            libraryCollectionsProvider,
            (_, _) => publications++,
          );
          final second = remove(['example:a', 'example:b']);
          expect(db.events, ['bulk-$kind:remove']);
          expect(container.read(libraryCollectionsProvider), same(before));
          db.releaseWrite.complete();
          if (failure != null) {
            await failure;
          } else {
            expect(await first, 2);
          }
          expect(await second, failFirst ? 2 : 0);
          expect(publications, 1);
          final after = container.read(libraryCollectionsProvider);
          final remaining = switch (kind) {
            'wishlist' => after.wishlist,
            'loved' => after.loved,
            _ => after.playlistById('p')!.tracks,
          };
          expect(remaining.map((entry) => entry.track.id), ['keep']);
          expect(remaining.single.addedAt, DateTime.utc(2026));
          expect(
            after.playlistById('other'),
            same(before.playlistById('other')),
          );
          expect(db.playlistTracks['other'], rows);
          expect(db.wishlist.length, kind == 'wishlist' ? 1 : 3);
          expect(db.loved.length, kind == 'loved' ? 1 : 3);
          expect(db.playlistTracks['p']!.length, kind == 'playlist' ? 1 : 3);
          expect(db.events.length, failFirst ? 2 : 1);
          expect(db.playlistReads, kind == 'playlist' ? 1 : 0);
          if (kind == 'playlist') {
            final playlist = after.playlistById('p')!;
            expect(playlist.coverImagePath, 'cover');
            expect(playlist.createdAt, DateTime.utc(2026));
            expect(playlist.trackKeys, {'example:keep'});
            expect(playlist.updatedAt.isAfter(DateTime.utc(2026)), isTrue);
            expect(
              db.playlists['p']!['updated_at'],
              playlist.updatedAt.toIso8601String(),
            );
          }
          expect(await remove(const []), 0);
          expect(await remove(['missing']), 0);
          expect(
            await notifier.removeTracksFromPlaylist('missing', [
              'example:keep',
            ]),
            0,
          );
          expect(container.read(libraryCollectionsProvider), same(after));
          expect(publications, 1);
        },
      );
    }
  }

  for (final failFirst in [false, true]) {
    test(
      'Love All is atomic and serializes repeated clicks (failure: $failFirst)',
      () async {
        final db = _CollectionsDatabase()..failNextWrite = failFirst;
        final container = _container(db);
        final notifier = container.read(libraryCollectionsProvider.notifier);
        var publications = 0;
        container.listen(libraryCollectionsProvider, (_, _) => publications++);
        final selected = [_track('1'), _track('1'), _track('2')];
        final first = notifier.toggleLovedTracks(selected);
        final failure = failFirst ? expectLater(first, throwsStateError) : null;
        await db.writeStarted.future;
        publications = 0;
        expect(container.read(libraryCollectionsProvider).loved, isEmpty);
        final second = notifier.toggleLovedTracks(selected);
        expect(db.events, ['bulk-loved:add']);
        db.releaseWrite.complete();
        if (failure != null) {
          await failure;
        } else {
          expect(await first, (removed: false, count: 2));
        }
        expect(await second, (removed: !failFirst, count: 2));
        expect(publications, failFirst ? 1 : 2);
        expect(
          container
              .read(libraryCollectionsProvider)
              .loved
              .map((entry) => entry.track.id),
          failFirst ? ['2', '1'] : isEmpty,
        );
        expect(db.loved.length, failFirst ? 2 : 0);
        expect(db.events, [
          'bulk-loved:add',
          failFirst ? 'bulk-loved:add' : 'bulk-loved:remove',
        ]);
      },
    );
  }

  test(
    'mixed Love All preserves existing metadata and unrelated loved tracks',
    () async {
      final db = _CollectionsDatabase();
      for (final id in ['existing', 'unrelated']) {
        db.loved[trackCollectionKey(_track(id))] = {
          'track_key': trackCollectionKey(_track(id)),
          'track_json': jsonEncode(_track(id).toJson()),
          'added_at': '2026-01-01T00:00:00Z',
        };
      }
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      final selected = [_track('existing'), _track('new'), _track('new')];
      final add = notifier.toggleLovedTracks(selected);
      await db.writeStarted.future;
      db.releaseWrite.complete();
      expect(await add, (removed: false, count: 1));
      expect(
        container
            .read(libraryCollectionsProvider)
            .loved
            .map((entry) => entry.track.id),
        ['new', 'existing', 'unrelated'],
      );
      expect(
        db.loved[trackCollectionKey(_track('existing'))]!['added_at'],
        '2026-01-01T00:00:00Z',
      );
      expect(await notifier.toggleLovedTracks(selected), (
        removed: true,
        count: 2,
      ));
      expect(
        container.read(libraryCollectionsProvider).loved.single.track.id,
        'unrelated',
      );
      final before = db.events.length;
      expect(await notifier.toggleLovedTracks(const []), (
        removed: false,
        count: 0,
      ));
      expect(db.events.length, before);
    },
  );

  for (final failFirst in [false, true]) {
    test(
      'bulk additions publish after persistence and serialize duplicates (failure: $failFirst)',
      () async {
        final db = _CollectionsDatabase();
        db.playlists['playlist'] = {
          'id': 'playlist',
          'name': 'Playlist',
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        };
        db.releasePlaylistRead.complete();
        db.failNextWrite = failFirst;
        final container = _container(db);
        final notifier = container.read(libraryCollectionsProvider.notifier);
        final first = notifier.addTracksToPlaylist('playlist', [
          _track('1'),
          _track('1'),
          _track('2'),
        ]);
        final failure = failFirst ? expectLater(first, throwsStateError) : null;
        await db.writeStarted.future;
        expect(
          container
              .read(libraryCollectionsProvider)
              .playlistById('playlist')!
              .trackCount,
          0,
        );
        final second = notifier.addTracksToPlaylist('playlist', [
          _track('2'),
          _track('3'),
        ]);
        expect(db.events, ['batch:playlist']);
        db.releaseWrite.complete();
        if (failure != null) {
          await failure;
        } else {
          final result = await first;
          expect(result.addedCount, 2);
          expect(result.alreadyInPlaylistCount, 1);
        }
        final result = await second;
        expect(result.addedCount, failFirst ? 2 : 1);
        expect(result.alreadyInPlaylistCount, failFirst ? 0 : 1);
        final playlist = container
            .read(libraryCollectionsProvider)
            .playlistById('playlist')!;
        expect(
          playlist.tracks.map((entry) => entry.track.id),
          failFirst ? ['2', '3'] : ['1', '2', '3'],
        );
        expect(playlist.trackCount, failFirst ? 2 : 3);
        expect(db.events, ['batch:playlist', 'batch:playlist']);
      },
    );
  }

  test('disposed snapshot read removes native rows before returning', () async {
    final directory = await Directory.systemTemp.createTemp(
      'collection-read-disposed-',
    );
    final path = '${directory.path}/rows.ndjson';
    await File(path).writeAsString('must never be parsed');
    final reply = Completer<LibraryCollectionsSnapshot>();
    final db = _CollectionsDatabase()..pendingSnapshot = reply.future;
    final container = _container(db);
    final notifier = container.read(libraryCollectionsProvider.notifier);
    final done = notifier.ensurePlaylistLoaded('missing');
    await db.snapshotReadStarted.future;
    container.dispose();
    reply.complete(
      LibraryCollectionsSnapshot(
        wishlistRows: const [],
        lovedRows: const [],
        playlistRows: const [],
        playlistTrackRows: const [],
        favoriteArtistRows: const [],
        nativeRowsPath: path,
        nativeRowsDirectory: directory.path,
        nativeRowCount: 1,
      ),
    );
    await done;
    expect(await directory.exists(), isFalse);
  });

  test(
    'playlist worker load is single-flight and retains intervening rename',
    () async {
      final db = _CollectionsDatabase();
      db.playlists['playlist'] = {
        'id': 'playlist',
        'name': 'Original',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };
      db.playlistTracks['playlist'] = List.generate(
        100,
        (index) => {
          'track_key': 'example:$index',
          'track_json': jsonEncode(_track('$index')),
          'added_at': '2026-01-01T00:00:00Z',
        },
      );
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final first = notifier.ensurePlaylistLoaded('playlist');
      await db.playlistReadStarted.future;
      final second = notifier.ensurePlaylistLoaded('playlist');
      final rename = notifier.renamePlaylist('playlist', 'Renamed');
      await db.writeStarted.future;
      db.releaseWrite.complete();
      await rename;
      db.releasePlaylistRead.complete();
      await Future.wait([first, second]);
      final playlist = container
          .read(libraryCollectionsProvider)
          .playlistById('playlist')!;
      expect(db.playlistReads, 1);
      expect(playlist.name, 'Renamed');
      expect(playlist.tracksLoaded, isTrue);
      expect(playlist.trackCount, 100);
      expect(
        playlist.tracks.map((entry) => entry.track.id),
        List.generate(100, (index) => '$index'),
      );
    },
  );

  test('disposed playlist read cannot publish a worker result', () async {
    final db = _CollectionsDatabase();
    final directory = await Directory.systemTemp.createTemp(
      'collection-read-disposed-',
    );
    final path = '${directory.path}/rows.ndjson';
    await File(path).writeAsString('must never be parsed');
    db.stagedPlaylistRows = LibraryPlaylistTracksSnapshot(
      nativeRowsPath: path,
      nativeRowsDirectory: directory.path,
      nativeRowCount: 1,
    );
    db.playlists['playlist'] = {
      'id': 'playlist',
      'name': 'Playlist',
      'created_at': '2026-01-01T00:00:00Z',
    };
    final container = _container(db);
    final notifier = container.read(libraryCollectionsProvider.notifier);
    await notifier.ensurePlaylistsLoaded(const []);
    final loading = notifier.ensurePlaylistLoaded('playlist');
    await db.playlistReadStarted.future;
    container.dispose();
    db.releasePlaylistRead.complete();
    await loading;
    expect(db.playlistReads, 1);
    expect(await directory.exists(), isFalse);
  });

  test(
    'late write completion does not publish or start a disposed mutation',
    () async {
      final db = _CollectionsDatabase();
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final active = notifier.toggleWishlist(_track('active'));
      await db.writeStarted.future;
      final queued = notifier.toggleWishlist(_track('queued'));
      final cancelled = expectLater(queued, throwsStateError);
      container.dispose();
      db.releaseWrite.complete();
      expect(await active, isTrue);
      await cancelled;
      expect(db.events, ['insert:wishlist:example:active']);
      expect(db.wishlist.keys, ['example:active']);
    },
  );

  for (final kind in ['wishlist', 'loved', 'artists']) {
    test('two overlapping $kind toggles persist insert then delete', () async {
      final db = _CollectionsDatabase();
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      Future<bool> toggle() => switch (kind) {
        'wishlist' => notifier.toggleWishlist(_track('song')),
        'loved' => notifier.toggleLoved(_track('song')),
        _ => notifier.toggleFavoriteArtist(
          artistId: 'artist',
          providerId: 'example',
          name: 'Artist',
        ),
      };
      final key = kind == 'artists' ? 'example:artist' : 'example:song';
      final first = toggle();
      await db.writeStarted.future;
      final second = toggle();
      await Future<void>.delayed(Duration.zero);
      expect(db.events, ['insert:$kind:$key']);
      final pending = container.read(libraryCollectionsProvider);
      expect(pending.wishlist, isEmpty);
      expect(pending.loved, isEmpty);
      expect(pending.favoriteArtists, isEmpty);
      db.releaseWrite.complete();
      expect(await Future.wait([first, second]), [true, false]);
      expect(db.events, ['insert:$kind:$key', 'delete:$kind:$key']);
      expect(db.wishlist, isEmpty);
      expect(db.loved, isEmpty);
      expect(db.artists, isEmpty);
      final state = container.read(libraryCollectionsProvider);
      expect(state.wishlist, isEmpty);
      expect(state.loved, isEmpty);
      expect(state.favoriteArtists, isEmpty);
    });
  }

  test(
    'playlist deletion cannot remove a concurrently created playlist',
    () async {
      final db = _CollectionsDatabase();
      for (final id in ['target', 'keep']) {
        db.playlists[id] = {
          'id': id,
          'name': id,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        };
      }
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final deletion = notifier.deletePlaylists(['target']);
      await db.writeStarted.future;
      final creation = notifier.createPlaylist('New');
      await Future<void>.delayed(Duration.zero);
      expect(db.events, ['bulk-playlists:remove']);
      expect(
        container.read(libraryCollectionsProvider).playlists.map((p) => p.id),
        ['target', 'keep'],
      );
      db.releaseWrite.complete();
      await deletion;
      final createdId = await creation;
      expect(db.events, [
        'bulk-playlists:remove',
        'insert:playlist:$createdId',
      ]);
      expect(db.playlists.keys.toSet(), {'keep', createdId});
      expect(
        container.read(libraryCollectionsProvider).playlists.map((p) => p.id),
        [createdId, 'keep'],
      );
    },
  );

  test(
    'failed writes retain published state and release the next mutation',
    () async {
      final db = _CollectionsDatabase()..failNextWrite = true;
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final failed = notifier.toggleWishlist(_track('failed'));
      final failure = expectLater(failed, throwsStateError);
      await db.writeStarted.future;
      final successful = notifier.toggleWishlist(_track('successful'));
      await Future<void>.delayed(Duration.zero);
      expect(db.events, ['insert:wishlist:example:failed']);
      expect(container.read(libraryCollectionsProvider).wishlist, isEmpty);
      db.releaseWrite.complete();
      await failure;
      expect(await successful, isTrue);
      expect(db.wishlist.keys, ['example:successful']);
      expect(
        container.read(libraryCollectionsProvider).wishlist.map((e) => e.key),
        ['example:successful'],
      );
    },
  );
}
