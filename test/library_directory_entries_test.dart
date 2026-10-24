import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';

import 'support/sqlite_process_database.dart';

void main() {
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await LibrarySchema.create(db, LibrarySchema.version);
    await db.execute("ATTACH DATABASE ':memory:' AS history_db");
    await db.execute('''
      CREATE TABLE history_db.history (
        id TEXT PRIMARY KEY, file_path TEXT, cover_url TEXT,
        disc_number INTEGER, track_number INTEGER, download_tree_uri TEXT,
        saf_relative_dir TEXT, saf_file_name TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE history_db.history_path_keys (
        item_id TEXT NOT NULL, path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )
    ''');
    await db.insert('history_db.history', {
      'id': 'download',
      'file_path': 'content://tree/document/1',
      'cover_url': 'https://covers.example/1.jpg',
      'disc_number': 1,
      'track_number': 2,
      'download_tree_uri': 'content://tree',
      'saf_relative_dir': 'Artist/Album',
      'saf_file_name': '02 Song.flac',
    });
    await db.insert('history_db.history', {'id': 'pending', 'file_path': ''});
    await db.insert('history_db.history_path_keys', {
      'item_id': 'download',
      'path_key': 'shared',
    });
    for (final (id, key) in [('copy', 'shared'), ('scanned', 'own')]) {
      await db.insert('library', {
        'id': id,
        'source_id': 'legacy',
        'track_name': id,
        'artist_name': 'Artist',
        'album_name': 'Album',
        'album_key': 'album|artist',
        'file_path': '/music/$id.flac',
        'cover_path': '/covers/$id.jpg',
        'scanned_at': '2026-10-24T00:00:00Z',
        'track_number': 3,
      });
      await db.insert('library_path_keys', {'item_id': id, 'path_key': key});
    }
    store = LibraryQueueStore(db, historyFts: false, localFts: false);
  });
  tearDown(() => db.close());

  test('reads downloads and the scanned files they do not shadow', () async {
    final rows = await store.directoryEntries(includeLocal: true);
    expect(rows, [
      {
        'source': 'downloaded',
        'id': 'download',
        'file_path': 'content://tree/document/1',
        'cover': 'https://covers.example/1.jpg',
        'disc_number': 1,
        'track_number': 2,
        'download_tree_uri': 'content://tree',
        'saf_relative_dir': 'Artist/Album',
        'saf_file_name': '02 Song.flac',
      },
      {
        'source': 'local',
        'id': 'scanned',
        'file_path': '/music/scanned.flac',
        'cover': '/covers/scanned.jpg',
        'disc_number': null,
        'track_number': 3,
        'download_tree_uri': null,
        'saf_relative_dir': null,
        'saf_file_name': null,
      },
    ]);
  });

  test('leaves scanned files out while the local Library is off', () async {
    final rows = await store.directoryEntries(includeLocal: false);
    expect([for (final row in rows) row['id']], ['download']);
  });
}
