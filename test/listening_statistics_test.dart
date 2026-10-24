import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

import 'support/sqlite_process_database.dart';

const _one = ListeningTrack(
  key: 'one',
  title: 'One',
  artist: 'Artist',
  album: 'Album',
);
const _two = ListeningTrack(
  key: 'two',
  title: 'Two',
  artist: 'Artist',
  album: 'Album',
);

void main() {
  test(
    'counts elapsed playback once, excluding pauses and seek-like updates',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2).add(elapsed),
      );
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 20);
      recorder.update(_one, playing: false);
      elapsed += const Duration(minutes: 10);
      recorder.update(_one, playing: true);
      // A seek can cause a state update but cannot create elapsed listening.
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 20);
      await recorder.flush();
      expect(writes.single.milliseconds, 40000);
      expect(writes.single.plays, 1);
      elapsed += const Duration(seconds: 40);
      await recorder.flush();
      expect(writes.last.milliseconds, 40000);
      expect(writes.last.plays, 0);
    },
  );

  test(
    'track changes and repeat completion start a new counted play',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2),
      );
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 35);
      recorder.update(_one, playing: false, ended: true);
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 35);
      recorder.update(_two, playing: true);
      elapsed += const Duration(seconds: 10);
      await recorder.flush();
      expect(writes.first.plays, 2);
      expect(writes.first.milliseconds, 70000);
      expect(writes.last.plays, 0);
      expect(writes.last.milliseconds, 10000);
    },
  );

  test('splits midnight and excludes disabled collection', () async {
    var elapsed = Duration.zero;
    final start = DateTime(2026, 10, 1, 23, 59, 50);
    final writes = <ListeningDelta>[];
    final recorder = ListeningRecorder(
      write: (batch) async => writes.addAll(batch),
      elapsed: () => elapsed,
      now: () => start.add(elapsed),
    );
    recorder.update(_one, playing: true);
    elapsed += const Duration(seconds: 20);
    recorder.setEnabled(false);
    elapsed += const Duration(hours: 1);
    await recorder.flush();
    expect(writes.map((e) => e.day), ['2026-10-01', '2026-10-02']);
    expect(writes.map((e) => e.milliseconds), [10000, 10000]);
  });

  test(
    'retries failed writes without dropping or double-counting deltas',
    () async {
      var elapsed = Duration.zero;
      var fail = true;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async {
          if (fail) throw StateError('temporary database error');
          writes.addAll(batch);
        },
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2),
      );
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 30);
      await recorder.flush();
      fail = false;
      elapsed += const Duration(seconds: 10);
      await recorder.flush();
      expect(writes.single.milliseconds, 40000);
      expect(writes.single.plays, 1);
    },
  );

  test('clear waits for in-flight writes and drops failed retries', () async {
    var elapsed = Duration.zero;
    final blockedWrite = Completer<void>();
    final started = Completer<void>();
    final writes = <ListeningDelta>[];
    var firstWrite = true;
    var cleared = false;
    final recorder = ListeningRecorder(
      write: (batch) async {
        if (firstWrite) {
          firstWrite = false;
          started.complete();
          await blockedWrite.future;
          throw StateError('write interrupted');
        }
        writes.addAll(batch);
      },
      elapsed: () => elapsed,
      now: () => DateTime(2026, 10, 2),
    );
    recorder.update(_one, playing: true);
    elapsed += const Duration(seconds: 35);
    final flushing = recorder.flush();
    await started.future;
    final clearing = recorder.clear(() async => cleared = true);
    expect(cleared, isFalse);
    elapsed += const Duration(seconds: 20);
    final duringClear = recorder.flush();
    blockedWrite.complete();
    await flushing;
    await clearing;
    await duringClear;
    expect(cleared, isTrue);
    elapsed += const Duration(seconds: 30);
    await recorder.flush();
    expect(writes.single.milliseconds, 30000);
    expect(writes.single.plays, 1);
  });

  test('summary merges days for the same track and credits artists once', () {
    final summary = ListeningSummary.fromRows([
      for (final day in ['2026-10-01', '2026-10-02'])
        {
          'day': day,
          'track_key': 'one',
          'title': 'One',
          'artist': 'Artist',
          'album': 'Album',
          'artwork': null,
          'milliseconds': 60000,
          'plays': 1,
        },
    ]);
    expect(summary.milliseconds, 120000);
    expect(summary.plays, 2);
    expect(summary.tracks.single.milliseconds, 120000);
    expect(summary.artists, {'Artist': 120000});
    expect(summary.days.length, 2);
  });

  test(
    'stored collaborations credit each artist without inflating totals',
    () async {
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await db.execute('''
        CREATE TABLE listening (
          day TEXT, track_key TEXT, title TEXT, artist TEXT, album TEXT,
          artwork TEXT, milliseconds INTEGER, plays INTEGER,
          PRIMARY KEY(day, track_key)
        )
      ''');
      final rows = <Map<String, Object?>>[
        {
          'day': '2026-10-01',
          'track_key': 'collaboration',
          'title': 'Collaboration',
          'artist': 'Artist A, Artist B; artist a',
          'album': 'Album',
          'artwork': 'https://example.com/collaboration.jpg',
          'milliseconds': 180000,
          'plays': 1,
        },
        {
          'day': '2026-10-02',
          'track_key': 'solo',
          'title': 'Solo',
          'artist': 'Artist A',
          'album': 'Solo Album',
          'artwork': null,
          'milliseconds': 120000,
          'plays': 1,
        },
      ];
      for (final row in rows) {
        await db.insert('listening', row);
      }
      final summaries = [
        ListeningSummary.fromRows(rows),
        await readListeningSummary(db, DateTime(2026), DateTime(2027)),
      ];
      for (final summary in summaries) {
        expect(summary.artists, {'Artist A': 300000, 'Artist B': 180000});
        expect(summary.milliseconds, 300000);
        expect(summary.plays, 2);
        expect(summary.days, {'2026-10-01': 180000, '2026-10-02': 120000});
        expect(summary.tracks.length, 2);
        expect(
          summary.tracks.first.track.artist,
          'Artist A, Artist B; artist a',
        );
        expect(summary.tracks.first.milliseconds, 180000);
        expect(summary.artistArtwork, {
          'Artist A': 'https://example.com/collaboration.jpg',
          'Artist B': 'https://example.com/collaboration.jpg',
        });
      }
      // Reading old credits corrects the presentation without rewriting history.
      final stored = await db.query(
        'listening',
        where: 'track_key = ?',
        whereArgs: ['collaboration'],
      );
      expect(stored.single['artist'], 'Artist A, Artist B; artist a');
    },
  );

  test(
    'artist artwork uses the most listened track with an available cover',
    () {
      final summary = ListeningSummary(
        tracks: [
          ListeningTotal(_one, 180000, 3),
          ListeningTotal(
            const ListeningTrack(
              key: 'other',
              title: 'Other',
              artist: 'Other Artist',
              album: 'Other Album',
              artwork: 'https://example.com/other.jpg',
            ),
            60000,
            1,
          ),
          ListeningTotal(
            const ListeningTrack(
              key: 'less',
              title: 'Less',
              artist: 'Artist',
              album: 'Another Album',
              artwork: 'https://example.com/less.jpg',
            ),
            30000,
            1,
          ),
          ListeningTotal(
            const ListeningTrack(
              key: 'more',
              title: 'More',
              artist: 'Artist, Collaborator',
              album: 'Album',
              artwork: ' file:///covers/album.jpg ',
            ),
            120000,
            2,
          ),
        ],
      );
      expect(summary.artistArtwork, {
        'Artist': 'file:///covers/album.jpg',
        'Collaborator': 'file:///covers/album.jpg',
        'Other Artist': 'https://example.com/other.jpg',
      });
      expect(
        ListeningSummary(
          tracks: [ListeningTotal(_one, 60000, 1)],
        ).artistArtwork,
        isEmpty,
      );
    },
  );
}
