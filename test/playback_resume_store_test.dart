import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_resume_store.dart';

import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SqliteProcessDatabase db;
  late PlaybackResumeStore store;
  const media = {'id': 'second', 'source': '/second.flac', 'title': 'Second'};
  final queue = [
    {'id': 'first', 'source': '/first.flac', 'queueOriginalIndex': 1},
    {...media, 'queueOriginalIndex': 0},
  ];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('playback-resume-');
    db = await SqliteProcessDatabase.open(path: '${directory.path}/state.db');
    await db.execute('''CREATE TABLE playback_session (
      id INTEGER PRIMARY KEY, media_json TEXT NOT NULL,
      current_index INTEGER, position_ms INTEGER, shuffle INTEGER,
      repeat_mode TEXT, updated_at TEXT
    )''');
    await PlaybackResumeStore.createSchema(db);
    store = PlaybackResumeStore(db);
    await db.insert('playback_session', {
      'id': 1,
      'media_json': jsonEncode(queue),
      'current_index': 1,
      'position_ms': 23000,
      'shuffle': 1,
      'repeat_mode': 'all',
    });
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'dismiss archives the full session without keeping an active player',
    () async {
      await store.archive(media);
      expect(await db.query('playback_session'), isEmpty);
      expect(await store.preview(), {'media': media, 'positionMs': 23000});
      expect(await store.session(), {
        'version': 2,
        'media': queue,
        'index': 1,
        'positionMs': 23000,
        'shuffle': true,
        'repeat': 'all',
      });
      await db.close();
      db = await SqliteProcessDatabase.open(path: '${directory.path}/state.db');
      store = PlaybackResumeStore(db);
      expect((await store.session())?['media'], queue);
      expect(await db.query('playback_session'), isEmpty);
    },
  );

  test('another empty dismiss retains the previous checkpoint', () async {
    await store.archive(media);
    await store.archive({'id': 'unrelated'});
    expect((await store.preview())?['media'], media);
    expect((await store.session())?['media'], queue);
  });

  test(
    'Home reads only the preview, even when a queue cannot be decoded',
    () async {
      await store.archive(media);
      await db.update('playback_resume', {'media_json': 'invalid json'});
      expect(await store.preview(), {'media': media, 'positionMs': 23000});
    },
  );

  test(
    'failed archival leaves the active session and old checkpoint intact',
    () async {
      await db.execute(
        '''CREATE TRIGGER fail_resume BEFORE INSERT ON playback_resume
      BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END''',
      );
      await expectLater(store.archive(media), throwsStateError);
      expect(await db.query('playback_session'), hasLength(1));
      expect(await store.preview(), isNull);
    },
  );

  test('installation reset can clear a dismissed session', () async {
    await store.archive(media);
    await store.clear();
    expect(await store.preview(), isNull);
    expect(await store.session(), isNull);
  });
}
