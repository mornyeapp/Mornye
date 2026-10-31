import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_session_writer.dart';

class _Database extends Fake implements AppStateDatabase {
  Map<String, dynamic>? row;
  final writes = <Map<String, dynamic>>[];
  final operations = <String>[];

  /// The row after each storage operation, as a kill right then leaves it.
  final states = <Map<String, dynamic>?>[];
  Future<void> Function()? beforeSave;
  Future<void> Function()? beforeUpdate;
  int failures = 0;

  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    operations.add('save');
    await beforeSave?.call();
    if (failures > 0) {
      failures--;
      states.add(row);
      throw StateError('Storage unavailable');
    }
    final json = utf8.decode(mediaJson);
    final session = {
      'json': json,
      'media': jsonDecode(json),
      'index': index,
      'positionMs': positionMs,
      'shuffle': shuffle,
      'repeat': repeatMode,
    };
    writes.add(session);
    states.add(row = session);
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
    states.add(
      row = {
        ...row!,
        'index': index,
        'positionMs': positionMs,
        'shuffle': shuffle,
        'repeat': repeatMode,
      },
    );
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

/// Counts the songs encoded on this isolate, as one JSON object each.
class _CountedSong extends PlayableMedia {
  _CountedSong(int i)
    : super(
        id: 'local:${i.toRadixString(16).padLeft(40, '0')}',
        source: '/storage/Music/Artist $i/Album ${i ~/ 12}/$i - Song $i.flac',
        title: 'Song $i',
        artist: 'Artist $i',
        album: 'Album ${i ~/ 12}',
        artUri: 'file:///covers/cover_${i.toRadixString(16)}.jpg',
        duration: Duration(milliseconds: 180000 + i),
        bitDepth: 24,
        sampleRate: 96000,
        format: 'FLAC',
      );

  static int encodes = 0;
  static int encodedBytes = 0;

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    encodes++;
    encodedBytes += utf8.encode(jsonEncode(json)).length;
    return json;
  }
}

PlayableMedia _song(String id) =>
    PlayableMedia(id: id, source: '/music/$id.flac', title: id, artist: 'A');

PlaybackSessionQueue _queue(
  List<PlayableMedia> media, [
  List<int>? originalIndices,
]) => (media: List.of(media), originalIndices: originalIndices);

/// The media list the saved session has always stored for [media].
String _legacyJson(List<PlayableMedia> media, [List<int>? originalIndices]) =>
    jsonEncode([
      for (var i = 0; i < media.length; i++)
        {...media[i].toJson(), 'queueOriginalIndex': originalIndices?[i] ?? i},
    ]);

Future<void> _persist(
  PlaybackSessionWriter writer,
  PlaybackSessionQueue Function() queue, {
  int index = 0,
  int seconds = 0,
}) => writer.persist(
  queue: queue,
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
      PlaybackSessionQueue queue() {
        serialized++;
        return _queue([_song('track')]);
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
    PlaybackSessionQueue queue() => _queue([_song('track')]);
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
        () => _queue([_song('track')]),
        seconds: 23,
      );
      final dismiss = writer.clear(resumeMedia: {'id': 'track'});
      ready.complete();
      await Future.wait([save, dismiss]);
      expect(database.operations, ['save', 'archive']);
      expect(database.row, isNull);
      expect(database.archived?['positionMs'], 23000);
      expect(database.preview?['id'], 'track');
      await _persist(writer, () => _queue([_song('track')]), seconds: 24);
      expect(database.operations, ['save', 'archive', 'save']);
      expect(database.row?['positionMs'], 24000);
    },
  );

  test('missing row is recreated from the matching live queue', () async {
    var serialized = 0;
    PlaybackSessionQueue queue() {
      serialized++;
      return _queue([_song('track')]);
    }

    await _persist(writer, queue);
    database.row = null;
    await _persist(writer, queue, seconds: 4);
    expect(serialized, 2);
    expect(database.operations, ['save', 'update', 'save']);
    expect(database.row?['positionMs'], 4000);
  });

  test('an older missing-row update cannot recreate a newer queue', () async {
    var queue = [_song('first')];
    var serialized = 0;
    PlaybackSessionQueue snapshot() {
      serialized++;
      return _queue(queue);
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
    queue = [queue.single, _song('second')];
    final newWrite = _persist(writer, snapshot, index: 1, seconds: 2);
    release.complete();
    await Future.wait([oldUpdate, newWrite]);
    expect(serialized, 2);
    expect(database.operations, ['save', 'update', 'save']);
    expect(database.row?['json'], _legacyJson(queue));
    expect(database.row?['index'], 1);
    expect(database.row?['positionMs'], 2000);
  });

  test(
    'a started write keeps the queue and index it was called with',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      database.beforeSave = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      final first = [_song('first')];
      var snapshots = 0;
      final oldWrite = _persist(writer, () {
        snapshots++;
        return _queue(first);
      });
      expect(snapshots, 1);
      await entered.future;
      writer.queueChanged();
      final queue = [...first, _song('second')];
      final newWrite = _persist(writer, () => _queue(queue), index: 1);
      release.complete();
      await Future.wait([oldWrite, newWrite]);
      expect(database.writes.first['json'], _legacyJson(first));
      expect(database.writes.first['index'], 0);
      expect(database.writes.last['json'], _legacyJson(queue));
      expect(database.writes.last['index'], 1);
    },
  );

  test('queue writes that have not started store only the newest', () async {
    final release = Completer<void>();
    database.beforeSave = () => release.future;
    var live = [_song('a')];
    final writes = [_persist(writer, () => _queue(live))];
    await pumpEventQueue();
    expect(database.operations, ['save']);
    for (final id in ['b', 'c', 'd']) {
      writer.queueChanged();
      live = [...live, _song(id)];
      final queue = live;
      writes.add(
        _persist(writer, () => _queue(queue), index: queue.length - 1)
        // Each caller learns of the write once a newer queue is stored.
        .then((_) => expect(database.writes, hasLength(2))),
      );
    }
    release.complete();
    await Future.wait(writes);
    expect(database.operations, ['save', 'save']);
    expect(database.writes.last['json'], _legacyJson(live));
    expect(database.writes.last['index'], 3);
    expect(errors, isEmpty);
  });

  test('a large write encodes here when no isolate can start', () async {
    writer = PlaybackSessionWriter(
      database: database,
      onError: errors.add,
      encodeInBackground: (_) =>
          throw IsolateSpawnException('Isolates unavailable'),
    );
    final songs = [for (var i = 0; i < 100; i++) _CountedSong(i)];
    _CountedSong.encodes = 0;
    await _persist(writer, () => _queue(songs));
    expect(_CountedSong.encodes, 100);
    expect(database.row?['json'], _legacyJson(songs));
    expect(errors, isEmpty);
  });

  test('a position save queued before a dismissal updates its row', () async {
    final release = Completer<void>();
    database.beforeSave = () => release.future;
    PlaybackSessionQueue queue() => _queue([_song('track')]);
    final save = _persist(writer, queue, seconds: 1);
    final position = _persist(writer, queue, seconds: 9);
    final dismiss = writer.clear(resumeMedia: {'id': 'track'});
    release.complete();
    await Future.wait([save, position, dismiss]);
    expect(database.operations, ['save', 'update', 'archive']);
    expect(database.archived?['positionMs'], 9000);
    expect(errors, isEmpty);
  });

  test('restored queues rewrite only when requested', () async {
    database.row = {'media': <Object>[]};
    writer.queueRestored(needsRewrite: false);
    await _persist(writer, () => throw StateError('Unexpected serialization'));
    expect(database.operations, ['update']);

    writer.queueRestored(needsRewrite: true);
    await _persist(writer, () => _queue([_song('restored')]));
    expect(database.operations, ['update', 'save']);
  });

  test('clear stays ordered between old and replacement writes', () async {
    final release = Completer<void>();
    database.beforeSave = () => release.future;
    final oldWrite = _persist(writer, () => _queue([_song('old')]));
    final clear = writer.clear();
    writer.queueChanged();
    final replacement = _persist(writer, () => _queue([_song('new')]));
    release.complete();
    await Future.wait([oldWrite, clear, replacement]);
    expect(database.operations, ['save', 'clear', 'save']);
    expect(database.row?['json'], _legacyJson([_song('new')]));
  });

  test('stored media is the earlier encoding byte for byte', () async {
    const fixed = PlayableMedia(
      id: 'const',
      source: '/c.flac',
      title: 'C',
      artist: 'A',
    );
    final songs = [
      fixed,
      const PlayableMedia(
        id: 'quote "and" \\ slash',
        source: 'content://media/external/audio/media/42',
        title: 'Tab\tnew\nline \u0007 bell',
        artist: 'Beyoncé, 坂本龍一, 🎧',
        album: 'Lone \uD800 surrogate',
        artUri: 'https://example.com/cover.jpg',
        duration: Duration(minutes: 3),
        bitDepth: 0,
        sampleRate: 44100,
        bitrate: 320,
        format: ' ',
        explicit: true,
        genre: '',
        autoplay: true,
      ),
      const PlayableMedia(
        id: 'network',
        source: 'network://nas/a.flac',
        title: 'N',
        artist: 'A',
        artUri: 'network://nas/cover.jpg',
        networkArtworkSource: 'network://nas/folder.jpg',
      ),
      fixed,
      for (var i = 0; i < 100; i++) _CountedSong(i),
    ];
    final shuffled = [for (var i = songs.length - 1; i >= 0; i--) i];
    await _persist(writer, () => _queue(songs));
    expect(database.row?['json'], _legacyJson(songs));
    writer.queueChanged();
    await _persist(writer, () => _queue(songs, shuffled));
    expect(database.row?['json'], _legacyJson(songs, shuffled));
    writer.queueChanged();
    await _persist(writer, () => _queue(const []));
    expect(database.row?['json'], '[]');
    expect(errors, isEmpty);
  });

  test(
    'one song changed in a 5,000-song queue encodes that song alone',
    () async {
      final songs = [for (var i = 0; i < 5000; i++) _CountedSong(i)];
      var next = songs.length;
      final steps = <String, ({int songs, int bytes, int legacyBytes})>{};
      Future<void> step(String name, [List<int>? originalIndices]) async {
        _CountedSong.encodes = _CountedSong.encodedBytes = 0;
        writer.queueChanged();
        await _persist(writer, () => _queue(songs, originalIndices));
        final encoded = (
          songs: _CountedSong.encodes,
          bytes: _CountedSong.encodedBytes,
        );
        // What the earlier writer encoded for every change: the whole queue.
        final legacy = _legacyJson(songs, originalIndices);
        expect(database.row?['json'], legacy, reason: name);
        steps[name] = (
          songs: encoded.songs,
          bytes: encoded.bytes,
          legacyBytes: utf8.encode(legacy).length,
        );
      }

      await step('start');
      songs.insert(2500, _CountedSong(next++));
      await step('insert');
      songs.removeAt(10);
      await step('remove');
      songs.insert(4000, songs.removeAt(20));
      await step('move');
      songs[3000] = _CountedSong(next++);
      await step('replace');
      await step('shuffle', [for (var i = songs.length - 1; i >= 0; i--) i]);

      // A new queue of this size encodes on another isolate.
      expect(steps['start']!.songs, 0);
      expect(
        [
          for (final name in ['insert', 'replace']) steps[name]!.songs,
        ],
        [1, 1],
      );
      expect(
        [
          for (final name in ['remove', 'move', 'shuffle']) steps[name]!.songs,
        ],
        [0, 0, 0],
      );
      for (final name in ['insert', 'replace']) {
        final step = steps[name]!;
        expect(step.legacyBytes, greaterThan(1500000), reason: name);
        expect(step.bytes * 4000, lessThan(step.legacyBytes), reason: name);
      }
      expect(errors, isEmpty);
    },
  );

  test('a kill after any storage operation leaves one whole queue', () async {
    final saved = <(String, int)>{};
    Future<void> persist(List<PlayableMedia> queue, int index, int seconds) {
      saved.add((_legacyJson(queue), index));
      return _persist(
        writer,
        () => _queue(queue),
        index: index,
        seconds: seconds,
      );
    }

    final songs = [for (var i = 0; i < 6; i++) _song('$i')];
    final release = Completer<void>();
    database.beforeSave = () => release.future;
    final writes = [persist(songs.sublist(0, 2), 0, 0)];
    await pumpEventQueue();
    writer.queueChanged();
    writes
      ..add(persist(songs.sublist(0, 3), 2, 5))
      ..add(persist(songs.sublist(0, 3), 2, 6));
    writer.queueChanged();
    writes
      ..add(persist(songs.sublist(1, 3), 1, 7))
      ..add(persist(songs.sublist(1, 3), 0, 8));
    release.complete();
    await Future.wait(writes);

    database.beforeSave = null;
    database.failures = 1;
    writer.queueChanged();
    await Future.wait([
      persist(songs.sublist(2, 5), 2, 0),
      persist(songs.sublist(2, 5), 2, 3),
    ]);
    await persist(songs.sublist(2, 5), 1, 4);

    expect(database.states, isNotEmpty);
    for (final state in database.states) {
      expect(state, isNotNull);
      expect(saved, contains((state!['json'], state['index'])));
    }
    expect(database.row?['json'], _legacyJson(songs.sublist(2, 5)));
    expect(database.row?['index'], 1);
    expect(database.row?['positionMs'], 4000);
    expect(errors, hasLength(1));
  });
}
