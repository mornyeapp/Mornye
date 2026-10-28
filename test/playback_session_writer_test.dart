import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/playback_session_writer.dart';

class _Database extends Fake implements AppStateDatabase {
  Map<String, dynamic>? row;
  final writes = <Map<String, dynamic>>[];
  final operations = <String>[];
  Future<void> Function()? beforeSave;
  Future<void> Function()? beforeUpdate;
  int failures = 0;

  @override
  Future<void> savePlaybackSession(Map<String, dynamic> session) async {
    operations.add('save');
    await beforeSave?.call();
    if (failures > 0) {
      failures--;
      throw StateError('Storage unavailable');
    }
    writes.add(session);
    row = session;
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    operations.add('update');
    await beforeUpdate?.call();
    if (row == null) return false;
    row = {
      ...row!,
      'index': index,
      'positionMs': positionMs,
      'shuffle': shuffle,
      'repeat': repeatMode,
    };
    return true;
  }

  @override
  Future<void> clearPlaybackSession() async {
    operations.add('clear');
    row = null;
  }

  Map<String, dynamic>? archived;
  Map<String, dynamic>? preview;

  @override
  Future<void> archivePlaybackSession(Map<String, dynamic> media) async {
    operations.add('archive');
    archived = row;
    preview = media;
    row = null;
  }
}

Future<void> _persist(
  PlaybackSessionWriter writer,
  List<Map<String, dynamic>> Function() queue, {
  int index = 0,
  int seconds = 0,
}) => writer.persist(
  serializeQueue: queue,
  index: index,
  position: Duration(seconds: seconds),
  shuffle: false,
  repeatMode: 'none',
);

void main() {
  late _Database database;
  late PlaybackSessionWriter writer;
  late List<Object> errors;
  setUp(() {
    database = _Database();
    errors = [];
    writer = PlaybackSessionWriter(database: database, onError: errors.add);
  });

  test(
    'unchanged queue updates scalars without serializing it again',
    () async {
      var serialized = 0;
      List<Map<String, dynamic>> queue() {
        serialized++;
        return [
          {'id': 'track'},
        ];
      }

      for (var i = 0; i < 25; i++) {
        await _persist(writer, queue, seconds: i);
      }
      expect(serialized, 1);
      expect(database.writes, hasLength(1));
      expect(database.row?['positionMs'], 24000);
      expect(errors, isEmpty);
    },
  );

  test('failed queue write is reported and the next write retries', () async {
    database.failures = 1;
    List<Map<String, dynamic>> queue() => [
      {'id': 'track'},
    ];
    await _persist(writer, queue);
    expect(errors.single, isA<StateError>());
    expect(database.row, isNull);

    await _persist(writer, queue, seconds: 3);
    expect(database.operations, ['save', 'save']);
    expect(database.row?['positionMs'], 3000);
  });

  test(
    'dismiss archives after pending writes and recreates active state on resume',
    () async {
      final ready = Completer<void>();
      database.beforeSave = () => ready.future;
      final save = _persist(
        writer,
        () => [
          {'id': 'track'},
        ],
        seconds: 23,
      );
      final dismiss = writer.clear(resumeMedia: {'id': 'track'});
      ready.complete();
      await Future.wait([save, dismiss]);
      expect(database.operations, ['save', 'archive']);
      expect(database.row, isNull);
      expect(database.archived?['positionMs'], 23000);
      expect(database.preview?['id'], 'track');
      await _persist(
        writer,
        () => [
          {'id': 'track'},
        ],
        seconds: 24,
      );
      expect(database.operations, ['save', 'archive', 'save']);
      expect(database.row?['positionMs'], 24000);
    },
  );

  test('missing row is recreated from the matching live queue', () async {
    var serialized = 0;
    List<Map<String, dynamic>> queue() {
      serialized++;
      return [
        {'id': 'track'},
      ];
    }

    await _persist(writer, queue);
    database.row = null;
    await _persist(writer, queue, seconds: 4);
    expect(serialized, 2);
    expect(database.operations, ['save', 'update', 'save']);
    expect(database.row?['positionMs'], 4000);
  });

  test('an older missing-row update cannot recreate a newer queue', () async {
    var queue = <Map<String, dynamic>>[
      {'id': 'first'},
    ];
    var serialized = 0;
    List<Map<String, dynamic>> snapshot() {
      serialized++;
      return List.of(queue);
    }

    await _persist(writer, snapshot);
    database.row = null;
    final entered = Completer<void>();
    final release = Completer<void>();
    database.beforeUpdate = () {
      entered.complete();
      return release.future;
    };
    final oldUpdate = _persist(writer, snapshot, seconds: 5);
    await entered.future;
    writer.queueChanged();
    queue = [
      {'id': 'first'},
      {'id': 'second'},
    ];
    final newWrite = _persist(writer, snapshot, index: 1, seconds: 2);
    release.complete();
    await Future.wait([oldUpdate, newWrite]);
    expect(serialized, 2);
    expect(database.operations, ['save', 'update', 'save']);
    expect(database.row?['media'], queue);
    expect(database.row?['index'], 1);
    expect(database.row?['positionMs'], 2000);
  });

  test(
    'queued snapshots retain their queue and index before storage waits',
    () async {
      final release = Completer<void>();
      database.beforeSave = () => release.future;
      var queue = <Map<String, dynamic>>[
        {'id': 'first'},
      ];
      final oldWrite = _persist(writer, () => List.of(queue));
      writer.queueChanged();
      queue = [
        {'id': 'first'},
        {'id': 'second'},
      ];
      final newWrite = _persist(writer, () => List.of(queue), index: 1);
      release.complete();
      await Future.wait([oldWrite, newWrite]);
      expect(database.writes.first['media'], [
        {'id': 'first'},
      ]);
      expect(database.writes.first['index'], 0);
      expect(database.writes.last['media'], queue);
      expect(database.writes.last['index'], 1);
    },
  );

  test('restored queues rewrite only when requested', () async {
    database.row = {'media': <Object>[]};
    writer.queueRestored(needsRewrite: false);
    await _persist(writer, () => throw StateError('Unexpected serialization'));
    expect(database.operations, ['update']);

    writer.queueRestored(needsRewrite: true);
    await _persist(
      writer,
      () => [
        {'id': 'restored'},
      ],
    );
    expect(database.operations, ['update', 'save']);
  });

  test('clear stays ordered between old and replacement writes', () async {
    final release = Completer<void>();
    database.beforeSave = () => release.future;
    final oldWrite = _persist(
      writer,
      () => [
        {'id': 'old'},
      ],
    );
    final clear = writer.clear();
    writer.queueChanged();
    final replacement = _persist(
      writer,
      () => [
        {'id': 'new'},
      ],
    );
    release.complete();
    await Future.wait([oldWrite, clear, replacement]);
    expect(database.operations, ['save', 'clear', 'save']);
    expect(database.row?['media'], [
      {'id': 'new'},
    ]);
  });
}
