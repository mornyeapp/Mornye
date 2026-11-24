import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_history.dart';
import 'package:mornye/services/playable_media.dart';

PlayableMedia _song(int id, {String? source}) => PlayableMedia(
  id: '$id',
  source: source ?? '/library/$id.flac',
  title: 'Song $id',
  artist: 'Artist $id',
);

void main() {
  test(
    'rotation survives restart independently of preference learning',
    () async {
      String? stored;
      AutoplayHistory open() => AutoplayHistory(
        read: () async => stored,
        write: (value) async => stored = value,
      );
      final history = open();
      for (var i = 0; i < 300; i++) {
        history.remember(_song(i));
      }
      history.remember(_song(0));
      await history.flush();
      final restored = open();
      await restored.load();
      final snapshot = restored.snapshot();
      expect(snapshot, history.snapshot());
      expect(snapshot[AutoplayHistory.sourceKey(_song(1))], 0);
      expect(snapshot[AutoplayHistory.sourceKey(_song(0))], 299);
      expect(
        snapshot[AutoplayHistory.songKey(_song(0, source: '/copy.flac'))],
        299,
      );
      expect(stored, isNot(contains('/library/')));
      expect(stored, isNot(contains('Song')));
    },
  );

  test('a play during restore remains newest, including copies', () async {
    String? stored;
    final original = AutoplayHistory(
      read: () async => null,
      write: (value) async => stored = value,
    );
    original.remember(_song(1));
    original.remember(_song(2));
    await original.flush();
    final pending = Completer<String?>();
    final restored = AutoplayHistory(
      read: () => pending.future,
      write: (value) async => stored = value,
    );
    final loading = restored.load();
    restored.remember(_song(1, source: '/copy.flac'));
    final saving = restored.flush();
    pending.complete(stored);
    await loading;
    await saving;
    final snapshot = restored.snapshot();
    expect(snapshot[AutoplayHistory.songKey(_song(1))], 2);
    expect(snapshot[AutoplayHistory.songKey(_song(2))], 1);
  });

  test('a play during a write is included before flushing finishes', () async {
    final pending = Completer<void>();
    final writes = <String>[];
    final history = AutoplayHistory(
      read: () async => null,
      write: (value) async {
        writes.add(value);
        if (writes.length == 1) await pending.future;
      },
    );
    history.remember(_song(1));
    final saving = history.flush();
    await Future<void>.delayed(Duration.zero);
    history.remember(_song(2));
    pending.complete();
    await saving;
    expect(writes, hasLength(2));
    expect(jsonDecode(writes.last) as Map, hasLength(2));
  });

  test(
    'corrupt history and failed writes preserve in-memory rotation',
    () async {
      var fail = true;
      String? stored;
      final history = AutoplayHistory(
        read: () async => '{broken',
        write: (value) async {
          if (fail) throw StateError('disk unavailable');
          stored = value;
        },
      );
      history.remember(_song(1));
      await history.flush();
      expect(history.snapshot()[AutoplayHistory.sourceKey(_song(1))], 0);
      fail = false;
      await history.flush();
      expect(stored, isNotNull);
    },
  );

  test('rotation is bounded and evicts only the oldest sources', () async {
    final history = AutoplayHistory(
      read: () async => null,
      write: (_) async {},
    );
    for (var i = 0; i <= AutoplayHistory.limit; i++) {
      history.remember(_song(i));
    }
    final snapshot = history.snapshot();
    expect(snapshot, hasLength(AutoplayHistory.limit * 2));
    expect(snapshot.containsKey(AutoplayHistory.sourceKey(_song(0))), isFalse);
    expect(snapshot.containsKey(AutoplayHistory.sourceKey(_song(1))), isTrue);
  });
}
