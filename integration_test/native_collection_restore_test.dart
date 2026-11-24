import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/collection_restore_codec.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/platform_bridge.dart';

const _date = '2026-10-07T05:00:00.000';
const _tables = {
  'wishlist': 'wishlist_tracks',
  'loved': 'loved_tracks',
  'artist': 'favorite_artists',
  'playlist': 'playlists',
  'playlist_track': 'playlist_tracks',
};

Future<Database> _database(String path) => openDatabase(
  path,
  version: 2,
  onConfigure: (db) async {
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.execute('PRAGMA synchronous=NORMAL');
    await db.rawQuery('PRAGMA busy_timeout=5000');
  },
  onCreate: (db, _) async {
    for (final sql in [
      'CREATE TABLE wishlist_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
      'CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
      'CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY,artist_json TEXT NOT NULL,added_at TEXT NOT NULL)',
      'CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)',
      'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key),FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE)',
      for (final table in [
        'wishlist_tracks',
        'loved_tracks',
        'favorite_artists',
        'playlist_tracks',
      ])
        'CREATE INDEX idx_${table}_added_at ON $table(added_at DESC)',
      'CREATE INDEX idx_playlists_created_at ON playlists(created_at DESC)',
      'CREATE INDEX idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id)',
    ]) {
      await db.execute(sql);
    }
  },
);

Future<Map<String, dynamic>> _fixture(int count) => Isolate.run(() {
  final entries = [
    for (var i = 0; i < count; i++)
      {
        'key': 'example:$i',
        'track': {
          'id': '$i',
          'name': '音楽 🎵 Track $i',
          'artistName': 'Artist ${i % 127}',
          'albumName': 'Album ${i ~/ 12}',
          'coverUrl': 'https://example.test/${i ~/ 12}.jpg',
          'source': 'example',
          'duration': 180,
        },
        'addedAt': _date,
      },
  ];
  return {
    'wishlist': entries.take(count ~/ 10).toList(),
    'loved': entries.take(count ~/ 10).toList(),
    'favoriteArtists': [
      {'key': 'example:artist', 'name': 'İstanbul', 'addedAt': _date},
    ],
    'playlists': [
      {
        'id': 'p',
        'name': 'old',
        'tracks': [entries.first],
        'createdAt': _date,
      },
      {
        'id': 'p',
        'name': '最新',
        'coverImagePath': '/covers/a.jpg',
        'createdAt': _date,
        'tracks': entries,
      },
      {'id': 'empty', 'name': '', 'createdAt': _date},
    ],
  };
});

/// Matches the old per-row transaction, including inline JSON encoding, and
/// uses the same database/schema/indexes as the production native route.
Future<void> _legacyRestore(Database db, Map<String, dynamic> input) =>
    db.transaction((txn) async {
      for (final table in [
        'playlist_tracks',
        'playlists',
        'wishlist_tracks',
        'loved_tracks',
        'favorite_artists',
      ]) {
        await txn.delete(table);
      }
      for (final command in collectionRestoreCommands(input, _date)) {
        await txn.insert(
          _tables[command['kind']]!,
          command['values'] as Map<String, dynamic>,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });

Future<String> _digest(Database db) async {
  final rows = <String, Object?>{};
  for (final table in _tables.values) {
    rows[table] = await db.rawQuery('SELECT * FROM $table ORDER BY rowid');
  }
  return Isolate.run(
    () => sha256.convert(utf8.encode(jsonEncode(rows))).toString(),
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-collections-');
    db = await _database('${root.path}/library_collections.db');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  testWidgets(
    'production restore preserves exact rows and rejects incomplete input atomically',
    (tester) async {
      final input = await _fixture(20);
      await _legacyRestore(db, input);
      final oldDigest = await _digest(db);
      await LibraryCollectionsDatabase.replaceDatabaseFromBackup(
        db,
        input,
        nowIso: _date,
      );
      expect(await _digest(db), oldDigest);
      final changed = await _fixture(21);
      await LibraryCollectionsDatabase.replaceDatabaseFromBackup(
        db,
        changed,
        nowIso: _date,
      );
      final changedDigest = await _digest(db);
      expect(changedDigest, isNot(oldDigest));
      expect(await db.rawQuery('PRAGMA quick_check'), [
        {'quick_check': 'ok'},
      ]);
      await _legacyRestore(db, input);
      expect(await _digest(db), oldDigest);
      final spool = '${root.path}/commands.ndjson';
      final count = await writeCollectionRestoreCommands(spool, input, _date);
      final isolated = await Directory('${root.path}/rejected').create();
      final isolatedPath = '${isolated.path}/library_collections.db';
      final isolatedDatabase = await _database(isolatedPath);
      await _legacyRestore(isolatedDatabase, input);
      await isolatedDatabase.close();
      await expectLater(
        PlatformBridge.runNativeDataJob({
          'operation': 'backup_collections_import',
          'collections_path': isolatedPath,
          'ndjson_path': spool,
          'expected_count': count + 1,
        }),
        throwsA(isA<Exception>()),
      );
      final rejectedDatabase = await _database(isolatedPath);
      try {
        expect(await _digest(rejectedDatabase), oldDigest);
      } finally {
        await rejectedDatabase.close();
      }
      expect(await _digest(db), oldDigest);
      await LibraryCollectionsDatabase.replaceDatabaseFromBackup(
        db,
        {},
        nowIso: _date,
      );
      for (final table in _tables.values) {
        expect(await db.query(table), isEmpty);
      }
      expect(await db.rawQuery('PRAGMA quick_check'), [
        {'quick_check': 'ok'},
      ]);
    },
  );

  testWidgets(
    'paired large collection restore records total latency and UI heartbeat',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
      );
      final input = await _fixture(10000);
      await LibraryCollectionsDatabase.replaceDatabaseFromBackup(
        db,
        await _fixture(20),
        nowIso: _date,
      );
      final timings = <String, List<int>>{'dart': [], 'native': []};
      final heartbeats = <String, List<Map<String, int>>>{
        'dart': [],
        'native': [],
      };
      String? expected;
      for (var sample = 0; sample < 5; sample++) {
        for (final native in sample.isEven ? [false, true] : [true, false]) {
          final label = native ? 'native' : 'dart';
          final elapsed = Stopwatch()..start();
          var lastBeat = 0;
          var maximumGap = 0;
          var beats = 0;
          final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
            final now = elapsed.elapsedMicroseconds;
            final gap = now - lastBeat;
            if (gap > maximumGap) maximumGap = gap;
            lastBeat = now;
            beats++;
          });
          try {
            if (native) {
              await LibraryCollectionsDatabase.replaceDatabaseFromBackup(
                db,
                input,
                nowIso: _date,
              );
            } else {
              await _legacyRestore(db, input);
            }
          } finally {
            elapsed.stop();
            timer.cancel();
          }
          timings[label]!.add(elapsed.elapsedMicroseconds);
          heartbeats[label]!.add({
            'count': beats,
            'maximum_gap_us': maximumGap,
          });
          final digest = await _digest(db);
          expected ??= digest;
          expect(digest, expected);
          expect(beats, greaterThan(0));
        }
      }
      final report = {
        'platform': Platform.operatingSystem,
        'persisted_rows': 12003,
        'input_commands': 12005,
        'input_tracks': 10000,
        'mode':
            'five alternating paired samples; original per-row sqflite versus complete production worker+spool+native transaction',
        'times_us': timings,
        'heartbeat': heartbeats,
        'sha256_rows': expected,
        'scope':
            'Collection restore latency; unchanged UI; no claim of whole-app FPS or device RAM.',
      };
      binding.reportData ??= {};
      binding.reportData!['collection_restore'] = report;
      final output = File(
        '${(await getApplicationSupportDirectory()).path}/collection-restore-benchmark.json',
      );
      await output.writeAsString(jsonEncode(report));
      debugPrint('COLLECTION_RESTORE_REPORT: ${output.path}');
      debugPrint('COLLECTION_RESTORE_BENCHMARK: ${jsonEncode(report)}');
    },
  );
}
