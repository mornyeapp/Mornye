import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_session_restore.dart';
import 'package:mornye/services/playback_session_writer.dart';

PlayableMedia _song(int i) => PlayableMedia(
  id: 'song-$i',
  source: '/Music/Artist $i/Song $i.flac',
  title: i.isEven ? 'Song "$i" \\ tab\t' : 'Chanson n°$i 坂本 🎧',
  artist: 'Artist $i',
  album: 'Album ${i ~/ 10}',
  artUri: 'file:///covers/$i.jpg',
  duration: Duration(seconds: 180 + i),
  sampleRate: 44100,
  format: 'FLAC',
  explicit: i % 7 == 0,
  autoplay: i % 11 == 0,
);

/// The `media_json` text earlier builds wrote for [media].
String _legacyJson(List<PlayableMedia> media, [List<int>? originalIndices]) =>
    jsonEncode([
      for (var i = 0; i < media.length; i++)
        {...media[i].toJson(), 'queueOriginalIndex': originalIndices?[i] ?? i},
    ]);

/// The session as earlier builds read it back.
Future<Map<String, Object?>> _storedRow(Database db) async =>
    (await db.rawQuery(
      'SELECT typeof(media_json) AS type, media_json, current_index, '
      'position_ms, shuffle, repeat_mode FROM playback_session',
    )).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Database db;
  late AppStateDatabase store;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('playback-session-');
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    store = AppStateDatabase.instance;
    db = await store.database;
  });
  tearDownAll(() async {
    await db.close();
    messenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });
  setUp(() async {
    await store.clearPlaybackSession();
    await store.clearPlaybackResume();
  });

  test('a session this build saves is the text earlier builds read', () async {
    final songs = [for (var i = 0; i < 300; i++) _song(i)];
    final order = [for (var i = 0; i < songs.length; i++) (i * 7) % 300];
    final errors = <Object>[];
    final writer = PlaybackSessionWriter(database: store, onError: errors.add);
    await writer.persist(
      queue: () => (media: List.of(songs), originalIndices: order),
      index: 7,
      position: const Duration(seconds: 42),
      shuffle: true,
      repeatMode: 'all',
    );
    expect(errors, isEmpty);

    final row = await _storedRow(db);
    expect(row['type'], 'text');
    expect(row['media_json'], _legacyJson(songs, order));
    expect(row['current_index'], 7);
    expect(row['position_ms'], 42000);
    expect(row['shuffle'], 1);
    expect(row['repeat_mode'], 'all');
    final legacy = (jsonDecode(row['media_json'] as String) as List)
        .cast<Map<String, dynamic>>();
    expect([for (final item in legacy) item['queueOriginalIndex']], order);
    expect(
      [for (final item in legacy) PlayableMedia.fromJson(item)!.toJson()],
      [for (final song in songs) song.toJson()],
    );

    final session = await store.getPlaybackSession();
    final restored = await prepareRestoredPlaybackMedia(
      session!['media'] as List<Object?>,
      fileExists: (_) async => true,
      loadLibraryCoverPath: (_) async => null,
    );
    expect(
      [for (final item in restored.items) item.toJson()],
      [for (final song in songs) song.toJson()],
    );
    expect(restored.artworkRelocated, isFalse);
    expect(session['index'], 7);
    expect(session['shuffle'], isTrue);
  });

  test(
    'a session an earlier build saved restores, updates and resumes',
    () async {
      final songs = [for (var i = 0; i < 80; i++) _song(i)];
      // As earlier builds wrote it: the encoded list as a string column.
      await db.insert('playback_session', {
        'id': 1,
        'media_json': _legacyJson(songs),
        'current_index': 3,
        'position_ms': 9000,
        'shuffle': 0,
        'repeat_mode': 'none',
        'updated_at': '2026-10-30T00:00:00.000',
      });
      final session = await store.getPlaybackSession();
      expect(session?['media'], jsonDecode(_legacyJson(songs)));

      final restored = [
        for (final item in session!['media'] as List)
          PlayableMedia.fromJson(Map<String, dynamic>.from(item as Map))!,
      ];
      final errors = <Object>[];
      final writer = PlaybackSessionWriter(database: store, onError: errors.add)
        ..queueRestored(needsRewrite: false);
      Future<void> persist(int index, int seconds) => writer.persist(
        queue: () => (media: List.of(restored), originalIndices: null),
        index: index,
        position: Duration(seconds: seconds),
        shuffle: false,
        repeatMode: 'none',
      );

      await persist(3, 12);
      var row = await _storedRow(db);
      expect(row['media_json'], _legacyJson(songs));
      expect(row['position_ms'], 12000);

      restored.insert(4, _song(500));
      writer.queueChanged();
      await persist(3, 13);
      row = await _storedRow(db);
      expect(row['type'], 'text');
      expect(row['media_json'], _legacyJson([...songs]..insert(4, _song(500))));

      await store.archivePlaybackSession(restored[3].toJson());
      final resumed = await store.getPlaybackResumeSession();
      expect(resumed?['media'], jsonDecode(row['media_json'] as String));
      expect(resumed?['positionMs'], 13000);
      expect(await store.getPlaybackSession(), isNull);
      expect(errors, isEmpty);
    },
  );

  test('a database in another encoding stores the same text', () async {
    final other = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(other.close);
    await other.execute("PRAGMA encoding = 'UTF-16le'");
    await other.execute('''
      CREATE TABLE playback_session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        media_json TEXT NOT NULL,
        current_index INTEGER NOT NULL DEFAULT 0,
        position_ms INTEGER NOT NULL DEFAULT 0,
        shuffle INTEGER NOT NULL DEFAULT 0,
        repeat_mode TEXT NOT NULL DEFAULT 'none',
        updated_at TEXT NOT NULL
      )
    ''');
    expect(
      (await other.rawQuery('PRAGMA encoding')).single.values.single,
      'UTF-16le',
    );
    final songs = [for (var i = 0; i < 5; i++) _song(i)];
    await AppStateDatabase.writePlaybackSession(
      other,
      mediaJson: utf8.encode(_legacyJson(songs)),
      index: 1,
      positionMs: 500,
      shuffle: false,
      repeatMode: 'one',
    );
    final row = await _storedRow(other);
    expect(row['type'], 'text');
    expect(row['media_json'], _legacyJson(songs));
  });
}
