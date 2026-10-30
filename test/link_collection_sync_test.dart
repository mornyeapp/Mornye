import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/sync/link_collection_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/link_sync_support.dart';

Future<List<Map<String, Object?>>> _changes(Database db) => db.rawQuery(
  'SELECT kind, scope, key, seq, updated_ms, deleted, origin '
  'FROM link_sync_changes ORDER BY seq',
);

Future<Map<String, Object?>?> _change(
  Database db,
  String kind,
  String key, {
  String scope = '',
}) async {
  final rows = await db.rawQuery(
    'SELECT * FROM link_sync_changes WHERE kind = ? AND scope = ? AND key = ?',
    [kind, scope, key],
  );
  return rows.isEmpty ? null : rows.first;
}

LinkSyncChange _loved(
  String key,
  int updatedMs,
  String origin, {
  bool deleted = false,
  String name = 'Song',
}) => LinkSyncChange(
  kind: LinkSyncKinds.loved,
  key: key,
  updatedMs: updatedMs,
  origin: origin,
  deleted: deleted,
  data: deleted
      ? null
      : {
          'track': {...linkTestTrack(key).toJson(), 'name': name},
          'addedMs': 1000,
        },
);

LinkSyncChange _playlist(
  String id,
  int updatedMs,
  String origin, {
  String name = 'Mix',
  bool deleted = false,
}) => LinkSyncChange(
  kind: LinkSyncKinds.playlist,
  key: id,
  updatedMs: updatedMs,
  origin: origin,
  deleted: deleted,
  data: deleted
      ? null
      : {'name': name, 'createdMs': 500, 'updatedMs': updatedMs},
);

LinkSyncChange _member(
  String playlistId,
  String key,
  int updatedMs,
  String origin, {
  bool deleted = false,
}) => LinkSyncChange(
  kind: LinkSyncKinds.playlistTrack,
  playlistId: playlistId,
  key: key,
  updatedMs: updatedMs,
  origin: origin,
  deleted: deleted,
  data: deleted
      ? null
      : {'track': linkTestTrack(key).toJson(), 'addedMs': updatedMs},
);

Future<List<String>> _keys(Database db, String table) async => [
  for (final row in await db.rawQuery(
    'SELECT track_key FROM $table ORDER BY rowid',
  ))
    row['track_key']! as String,
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = false;
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  test(
    'v2 databases with data migrate to v3 and seed one change per row',
    () async {
      final directory = await linkSyncTempDirectory();
      final path = '${directory.path}/library_collections.db';
      sqfliteFfiInit();
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, _) async {
            for (final table in ['wishlist_tracks', 'loved_tracks']) {
              await db.execute(
                'CREATE TABLE $table(track_key TEXT PRIMARY KEY, '
                'track_json TEXT NOT NULL, added_at TEXT NOT NULL)',
              );
            }
            await db.execute(
              'CREATE TABLE playlists(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
              'cover_image_path TEXT, created_at TEXT NOT NULL, '
              'updated_at TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL, '
              'track_key TEXT NOT NULL, track_json TEXT NOT NULL, '
              'added_at TEXT NOT NULL, PRIMARY KEY (playlist_id, track_key), '
              'FOREIGN KEY (playlist_id) REFERENCES playlists(id) '
              'ON DELETE CASCADE)',
            );
            await db.execute(
              'CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY, '
              'artist_json TEXT NOT NULL, added_at TEXT NOT NULL)',
            );
          },
        ),
      );
      await legacy.insert('loved_tracks', {
        'track_key': 'example:1',
        'track_json': linkTestTrackJson('1'),
        'added_at': '2026-01-02T03:04:05.678901',
      });
      for (var i = 0; i < 70; i++) {
        await legacy.insert('wishlist_tracks', {
          'track_key': 'example:w$i',
          'track_json': linkTestTrackJson('w$i'),
          'added_at': '2026-01-0${i % 9 + 1}T00:00:00.000',
        });
      }
      await legacy.insert('playlists', {
        'id': 'pl_1',
        'name': 'Road',
        'cover_image_path': '/covers/pl_1.jpg',
        'created_at': '2026-01-01T00:00:00.000',
        'updated_at': '2026-01-03T00:00:00.000',
      });
      await legacy.insert('playlist_tracks', {
        'playlist_id': 'pl_1',
        'track_key': 'example:2',
        'track_json': linkTestTrackJson('2'),
        'added_at': '2026-01-03T00:00:00.000',
      });
      await legacy.insert('favorite_artists', {
        'artist_key': 'example:a1',
        'artist_json': jsonEncode({'key': 'example:a1', 'name': 'Band'}),
        'added_at': 'not a date',
      });
      await legacy.close();

      final db = await LibraryCollectionsDatabase.openWithFactory(
        databaseFactoryFfi,
        path,
      );
      addTearDown(db.close);
      expect((await db.rawQuery('PRAGMA user_version')).first.values.first, 3);
      final store = LinkCollectionSyncStore(() async => db);
      final device = await store.deviceId();
      expect(device, hasLength(32));
      final changes = await _changes(db);
      expect(changes, hasLength(74));
      expect(
        [for (final row in changes) row['seq']],
        [for (var i = 1; i <= 74; i++) i],
      );
      expect(changes.every((row) => row['origin'] == device), isTrue);
      expect(changes.every((row) => row['deleted'] == 0), isTrue);
      expect(await store.latestSeq(), 74);
      // Seeded from the row's own date (read as UTC; julianday rounding).
      expect(
        (await _change(db, LinkSyncKinds.loved, 'example:1'))!['updated_ms'],
        closeTo(
          DateTime.utc(2026, 1, 2, 3, 4, 5, 678).millisecondsSinceEpoch,
          1,
        ),
      );
      expect(
        (await _change(
          db,
          LinkSyncKinds.favoriteArtist,
          'example:a1',
        ))!['updated_ms'],
        0,
      );
      expect(
        await _change(
          db,
          LinkSyncKinds.playlistTrack,
          'example:2',
          scope: 'pl_1',
        ),
        isNotNull,
      );
      // Collection rows are unchanged.
      expect(await _keys(db, 'loved_tracks'), ['example:1']);
      expect(
        (await db.query('playlists')).single['cover_image_path'],
        '/covers/pl_1.jpg',
      );

      // Native reads still receive the v2 schema they validate.
      final temporary = await linkSyncTempDirectory();
      final snapshot = await LibraryCollectionsDatabase.readDatabaseSnapshot(
        db,
        temporaryDirectory: temporary,
        nativeJobRunner: (request) async {
          final projected = await databaseFactoryFfi.openDatabase(
            request['collections_path'] as String,
          );
          try {
            expect(
              (await projected.rawQuery(
                'PRAGMA user_version',
              )).first.values.first,
              2,
            );
            final tables = await projected.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table'",
            );
            expect(
              tables.map((row) => row['name']),
              isNot(contains('link_sync_changes')),
            );
          } finally {
            await projected.close();
          }
          return {
            'published': true,
            'rows_path': request['output_path'],
            'counts': {'wishlist': 70},
          };
        },
      );
      expect(snapshot.nativeRowCount, 70);
    },
  );

  test(
    'triggers record Dart writes, raw SQL and cascades, coalesced per key',
    () async {
      final directory = await linkSyncTempDirectory();
      final db = await openLinkCollectionsDatabase(directory, 'phone');
      final collections = LibraryCollectionsDatabase.withDatabase(db);
      final store = LinkCollectionSyncStore(() async => db);
      final device = await store.deviceId();

      await collections.upsertLovedEntry(
        trackKey: 'example:1',
        trackJson: linkTestTrackJson('1'),
        addedAt: DateTime.now().toIso8601String(),
      );
      final first = await _change(db, LinkSyncKinds.loved, 'example:1');
      // Re-saving the same key replaces its single record with a newer one.
      await collections.upsertLovedEntry(
        trackKey: 'example:1',
        trackJson: linkTestTrackJson('1'),
        addedAt: DateTime.now().toIso8601String(),
      );
      final second = await _change(db, LinkSyncKinds.loved, 'example:1');
      expect(second!['seq']! as int, greaterThan(first!['seq']! as int));
      expect(
        second['updated_ms']! as int,
        greaterThan(first['updated_ms']! as int),
      );
      expect(second['origin'], device);
      expect(
        (await _changes(db)).where((row) => row['key'] == 'example:1'),
        hasLength(1),
      );

      // A raw INSERT ... SELECT, as native batch publication writes.
      await db.execute(
        'INSERT OR REPLACE INTO wishlist_tracks (track_key, track_json, added_at) '
        "SELECT 'example:raw', ?, '2026-05-01T00:00:00.000'",
        [linkTestTrackJson('raw')],
      );
      expect(
        await _change(db, LinkSyncKinds.wishlist, 'example:raw'),
        isNotNull,
      );

      await collections.upsertPlaylist(
        id: 'pl_1',
        name: 'Road',
        createdAt: DateTime.now().toIso8601String(),
        updatedAt: DateTime.now().toIso8601String(),
      );
      await collections.upsertPlaylistTracksBatch(
        playlistId: 'pl_1',
        playlistUpdatedAt: DateTime.now().toIso8601String(),
        tracks: [
          for (final id in ['2', '3'])
            {
              'track_key': 'example:$id',
              'track_json': linkTestTrackJson(id),
              'added_at': DateTime.now().toIso8601String(),
            },
        ],
      );
      final named = await _change(db, LinkSyncKinds.playlist, 'pl_1');
      // Timestamp and cover updates are device-local, not playlist changes.
      await collections.updatePlaylistCover(
        playlistId: 'pl_1',
        coverImagePath: '/covers/x.jpg',
        updatedAt: DateTime.now().toIso8601String(),
      );
      expect(await _change(db, LinkSyncKinds.playlist, 'pl_1'), named);
      await collections.renamePlaylist(
        playlistId: 'pl_1',
        name: 'Coast',
        updatedAt: DateTime.now().toIso8601String(),
      );
      final renamed = await _change(db, LinkSyncKinds.playlist, 'pl_1');
      expect(renamed!['seq']! as int, greaterThan(named!['seq']! as int));

      await collections.deleteLovedEntry('example:1');
      expect(
        (await _change(db, LinkSyncKinds.loved, 'example:1'))!['deleted'],
        1,
      );

      await collections.deletePlaylists(['pl_1']);
      expect(
        (await _change(db, LinkSyncKinds.playlist, 'pl_1'))!['deleted'],
        1,
      );
      for (final key in ['example:2', 'example:3']) {
        final member = await _change(
          db,
          LinkSyncKinds.playlistTrack,
          key,
          scope: 'pl_1',
        );
        expect(member!['deleted'], 1);
      }
    },
  );

  test('a local edit is stamped after the peer version it replaces', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'phone');
    final store = LinkCollectionSyncStore(() async => db);
    final future = DateTime.now().millisecondsSinceEpoch + 3600000;
    await store.apply([_loved('example:1', future, 'desk')]);
    await LibraryCollectionsDatabase.withDatabase(
      db,
    ).deleteLovedEntry('example:1');
    final record = await _change(db, LinkSyncKinds.loved, 'example:1');
    expect(record!['updated_ms'], future + 1);
    expect(record['origin'], await store.deviceId());
  });

  test('peer changes keep their author and are not echoed back', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'phone');
    final store = LinkCollectionSyncStore(() async => db);
    final collections = LibraryCollectionsDatabase.withDatabase(db);
    await collections.upsertWishlistEntry(
      trackKey: 'example:mine',
      trackJson: linkTestTrackJson('mine'),
      addedAt: DateTime.now().toIso8601String(),
    );
    final result = await store.apply([
      _loved('example:peer', 5000, 'desk'),
      _playlist('pl_9', 5000, 'desk'),
      _member('pl_9', 'example:m', 5001, 'desk'),
    ]);
    expect(result.applied, 3);
    final record = await _change(db, LinkSyncKinds.loved, 'example:peer');
    expect(record!['origin'], 'desk');
    expect(record['updated_ms'], 5000);
    final state = (await db.query('link_sync_state')).single;
    expect(state['apply_origin'], isNull);
    expect(state['apply_updated_ms'], isNull);

    final local = await store.changesSince(0, localOnly: true);
    expect(local.items.map((change) => change.key), ['example:mine']);
    final forDesk = await store.changesSince(0, excludeOrigin: 'desk');
    expect(forDesk.items.map((change) => change.key), ['example:mine']);
    expect(forDesk.cursor, await store.latestSeq());

    // Re-applying the same versions is a no-op.
    final again = await store.apply([
      _loved('example:peer', 5000, 'desk'),
      _member('pl_9', 'example:m', 5001, 'desk'),
    ]);
    expect(again.applied, 0);

    // A local write after an apply is local again.
    await collections.deleteWishlistEntry('example:mine');
    final mine = await _change(db, LinkSyncKinds.wishlist, 'example:mine');
    expect(mine!['origin'], await store.deviceId());
  });

  test('last writer wins: edit against delete and concurrent edits', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'desk');
    final store = LinkCollectionSyncStore(() async => db);
    await store.apply([_loved('example:1', 1000, 'a')]);

    // An older delete loses, a newer one wins, an older re-add then loses.
    expect(
      (await store.apply([
        _loved('example:1', 900, 'b', deleted: true),
      ])).applied,
      0,
    );
    expect(await _keys(db, 'loved_tracks'), ['example:1']);
    expect(
      (await store.apply([
        _loved('example:1', 1100, 'b', deleted: true),
      ])).applied,
      1,
    );
    expect(await _keys(db, 'loved_tracks'), isEmpty);
    expect((await store.apply([_loved('example:1', 1050, 'a')])).applied, 0);
    expect(await _keys(db, 'loved_tracks'), isEmpty);
    final tombstone = await _change(db, LinkSyncKinds.loved, 'example:1');
    expect(tombstone!['deleted'], 1);
    expect(tombstone['origin'], 'b');

    // Equal timestamps: the greater origin wins, on every device.
    await store.apply([_loved('example:2', 2000, 'a', name: 'From A')]);
    await store.apply([_loved('example:2', 2000, 'b', name: 'From B')]);
    await store.apply([_loved('example:2', 2000, 'a', name: 'From A')]);
    final row = (await db.query(
      'loved_tracks',
      where: "track_key = 'example:2'",
    )).single;
    expect((jsonDecode(row['track_json']! as String) as Map)['name'], 'From B');

    // Within one batch the newest version of a key wins.
    await store.apply([
      _loved('example:3', 3000, 'a'),
      _loved('example:3', 3100, 'a', deleted: true),
    ]);
    expect(await _keys(db, 'loved_tracks'), ['example:2']);
  });

  test('playlist rename and membership never conflict', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'desk');
    final store = LinkCollectionSyncStore(() async => db);
    final collections = LibraryCollectionsDatabase.withDatabase(db);
    await store.apply([_playlist('pl_1', 1000, 'phone', name: 'Old')]);
    await collections.renamePlaylist(
      playlistId: 'pl_1',
      name: 'Mine',
      updatedAt: DateTime.now().toIso8601String(),
    );
    final localName = await _change(db, LinkSyncKinds.playlist, 'pl_1');

    // The phone adds a member later than its own (older) rename.
    final result = await store.apply([
      _playlist('pl_1', 1500, 'phone', name: 'Theirs'),
      _member('pl_1', 'example:9', 2000, 'phone'),
    ]);
    expect(result.applied, 1);
    expect((await db.query('playlists')).single['name'], 'Mine');
    expect(await _keys(db, 'playlist_tracks'), ['example:9']);
    expect(await _change(db, LinkSyncKinds.playlist, 'pl_1'), localName);
  });

  test('a deleted playlist stays deleted unless renamed later', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'desk');
    final store = LinkCollectionSyncStore(() async => db);
    await store.apply([
      _playlist('pl_1', 1000, 'a'),
      _member('pl_1', 'example:1', 1000, 'a'),
    ]);
    await store.apply([_playlist('pl_1', 2000, 'b', deleted: true)]);
    expect(await db.query('playlists'), isEmpty);
    expect(
      (await _change(
        db,
        LinkSyncKinds.playlistTrack,
        'example:1',
        scope: 'pl_1',
      ))!['deleted'],
      1,
    );

    // A later member add on a device that missed the delete does not
    // resurrect it (its playlist record is older than the tombstone).
    final add = await store.apply([
      _playlist('pl_1', 1000, 'a'),
      _member('pl_1', 'example:2', 3000, 'a'),
    ]);
    expect(add.applied, 0);
    expect(await db.query('playlists'), isEmpty);

    // A later rename recreates the playlist, empty.
    await store.apply([_playlist('pl_1', 4000, 'a', name: 'Back')]);
    expect((await db.query('playlists')).single['name'], 'Back');
    expect(await _keys(db, 'playlist_tracks'), isEmpty);
  });

  test('pages are bounded, resumable and carry member playlists', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'desk');
    final store = LinkCollectionSyncStore(() async => db);
    final collections = LibraryCollectionsDatabase.withDatabase(db);
    await collections.upsertPlaylist(
      id: 'pl_1',
      name: 'Long',
      createdAt: DateTime.now().toIso8601String(),
      updatedAt: DateTime.now().toIso8601String(),
    );
    await collections.upsertLovedTracksBatch([
      for (var i = 0; i < 1100; i++)
        {
          'track_key': 'example:$i',
          'track_json': linkTestTrackJson('$i'),
          'added_at': DateTime.now().toIso8601String(),
        },
    ]);
    await collections.upsertPlaylistTrack(
      playlistId: 'pl_1',
      trackKey: 'example:member',
      trackJson: linkTestTrackJson('member'),
      addedAt: DateTime.now().toIso8601String(),
      playlistUpdatedAt: DateTime.now().toIso8601String(),
    );

    final first = await store.changesSince(0);
    expect(first.items, hasLength(500));
    expect(first.more, isTrue);
    expect(first.items.first.kind, LinkSyncKinds.playlist);
    final second = await store.changesSince(first.cursor);
    expect(second.more, isTrue);
    final last = await store.changesSince(second.cursor);
    expect(last.more, isFalse);
    expect(last.cursor, await store.latestSeq());
    // The member's playlist record rides along even though it was in the
    // first page, so this page applies on its own.
    expect(last.items.first.kind, LinkSyncKinds.playlist);
    expect(last.items.last.kind, LinkSyncKinds.playlistTrack);
    expect({
      for (final page in [first, second, last]) ...page.items.map((c) => c.key),
    }, hasLength(1102));
    final small = await store.changesSince(0, limit: 10);
    expect(small.items, hasLength(10));

    // A second device converges from the pages, and the wire format holds.
    final peer = await openLinkCollectionsDatabase(directory, 'phone');
    final peerStore = LinkCollectionSyncStore(() async => peer);
    for (final page in [first, second, last]) {
      final wire = linkJsonRoundTrip(page.toJson('changes', (c) => c.toJson()));
      final decoded = LinkSyncPage.fromJson<LinkSyncChange>(
        wire,
        'changes',
        (item, origin) => LinkSyncChange.fromJson(item, fallbackOrigin: origin),
      );
      await peerStore.apply(decoded!.items);
    }
    expect(await _keys(peer, 'loved_tracks'), hasLength(1100));
    expect(await _keys(peer, 'playlist_tracks'), ['example:member']);
    expect((await peer.query('playlists')).single['cover_image_path'], isNull);
  });

  test('a network cover of a loved song stays on its device', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'phone');
    final store = LinkCollectionSyncStore(() async => db);
    final collections = LibraryCollectionsDatabase.withDatabase(db);
    const network = 'network://nas/Album/cover.jpg';
    const web = 'https://example.com/cover.jpg';
    String json(String id, String cover) =>
        jsonEncode({...linkTestTrack(id).toJson(), 'coverUrl': cover});
    final now = DateTime.now().toIso8601String();
    await collections.upsertLovedEntry(
      trackKey: 'example:network',
      trackJson: json('network', network),
      addedAt: now,
    );
    await collections.upsertLovedEntry(
      trackKey: 'example:web',
      trackJson: json('web', web),
      addedAt: now,
    );
    await collections.upsertPlaylist(
      id: 'pl_1',
      name: 'Mix',
      createdAt: now,
      updatedAt: now,
    );
    await collections.upsertPlaylistTrack(
      playlistId: 'pl_1',
      trackKey: 'example:member',
      trackJson: json('member', network),
      addedAt: now,
      playlistUpdatedAt: now,
    );

    final page = await store.changesSince(0);
    final sent = {
      for (final change in page.items)
        if (change.data?['track'] case final Map<String, dynamic> track)
          change.key: track['coverUrl'],
    };
    expect(sent, {
      'example:network': null,
      'example:web': web,
      'example:member': null,
    });
    // The device itself keeps the reference.
    expect(
      (await collections.loadLovedTracks()).map((track) => track.coverUrl),
      containsAll([network, web]),
    );

    final peer = await openLinkCollectionsDatabase(directory, 'desk');
    await LinkCollectionSyncStore(() async => peer).apply(page.items);
    expect(
      (await LibraryCollectionsDatabase.withDatabase(
        peer,
      ).loadLovedTracks()).map((track) => track.coverUrl),
      containsAll([null, web]),
    );
  });
}
