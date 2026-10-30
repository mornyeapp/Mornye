import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/link_sync_support.dart';
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

  test(
    'older loopback and temporary covers read as none, references stay',
    () async {
      const kept = {
        'network': 'network://nas/Album/cover.jpg',
        'tags': 'network://nas/Album/song.flac#cover',
        'web': 'https://example.com/cover.jpg',
        'file': '/data/user/0/app/files/covers/a.image',
      };
      final dropped = [
        'http://127.0.0.1:41234/7f3a',
        'http://localhost:8080/cover',
        '/data/user/0/app/cache/network_metadata/a1.jpg',
        '/var/mobile/Containers/Data/Application/X/tmp/'
            'download_cover_preview_x1/cover_preview.jpg',
        '${Directory.systemTemp.path}/cover.jpg',
      ];
      final rows = [
        for (final (key, artwork) in [
          ...kept.entries.map((entry) => (entry.key, entry.value)),
          ...dropped.indexed.map((entry) => ('old${entry.$1}', entry.$2)),
        ])
          {
            'day': '2026-10-20',
            'track_key': key,
            'title': key,
            'artist': key,
            'album': 'Album',
            'artwork': artwork,
            'milliseconds': 60000,
            'plays': 1,
          },
      ];
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await db.execute('''
        CREATE TABLE listening (
          day TEXT, track_key TEXT, title TEXT, artist TEXT, album TEXT,
          artwork TEXT, milliseconds INTEGER, plays INTEGER,
          PRIMARY KEY(day, track_key)
        )
      ''');
      for (final row in rows) {
        await db.insert('listening', row);
      }
      for (final summary in [
        ListeningSummary.fromRows(rows),
        await readListeningSummary(db, DateTime(2026), DateTime(2027)),
      ]) {
        expect(
          {
            for (final total in summary.tracks)
              total.track.key: total.track.artwork,
          },
          {...kept, for (var i = 0; i < dropped.length; i++) 'old$i': null},
        );
        expect(summary.artistArtwork, kept);
      }
    },
  );

  test('a later play replaces a broken cover; one without keeps it', () async {
    final db = await openLinkListeningDatabase(
      await linkSyncTempDirectory(),
      'covers',
    );
    const reference = 'network://nas/Album/cover.jpg';
    ListeningDelta play(String? artwork, {String day = '2026-10-20'}) =>
        ListeningDelta(
          day,
          ListeningTrack(
            key: 'network://nas/Album/song.flac',
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            artwork: artwork,
          ),
          5000,
          0,
        );
    Future<Map<String, Object?>> stored(String day) async => (await db.query(
      'listening',
      where: 'day = ?',
      whereArgs: [day],
    )).single;
    Future<String?> shown() async => (await readListeningSummary(
      db,
      DateTime(2026, 10, 20),
      DateTime(2026, 10, 22),
    )).tracks.single.track.artwork;

    // Recorded by an older build.
    await db.insert('listening', {
      'day': '2026-10-20',
      'track_key': 'network://nas/Album/song.flac',
      'title': 'Song',
      'artist': 'Artist',
      'album': 'Album',
      'artwork': 'http://127.0.0.1:41234/7f3a',
      'milliseconds': 5000,
      'plays': 0,
    });
    expect(await shown(), isNull);
    await writeListeningDeltas(db, [play(null)]);
    expect(await shown(), isNull);
    await writeListeningDeltas(db, [play(reference)]);
    expect(await shown(), reference);
    for (final artwork in [
      null,
      'http://127.0.0.1:41234/8b2c',
      '/data/user/0/app/cache/network_metadata/a1.jpg',
    ]) {
      await writeListeningDeltas(db, [play(artwork)]);
      expect((await stored('2026-10-20'))['artwork'], reference);
    }
    expect((await stored('2026-10-20'))['milliseconds'], 30000);
    await writeListeningDeltas(db, [
      play('http://127.0.0.1:41234/8b2c', day: '2026-10-21'),
    ]);
    expect((await stored('2026-10-21'))['artwork'], isNull);
  });

  test('a recorded cover reference replays as the stored cover', () async {
    final directory = await Directory.systemTemp.createTemp('replay-cover-');
    addTearDown(() => directory.delete(recursive: true));
    final covers = CoverStore(
      directory: () async => Directory('${directory.path}/covers'),
      fetch: (_, output) => output.writeAsBytes([0xFF, 0xD8, 0xFF, 0]),
    );
    addTearDown(covers.dispose);
    const source = 'network://nas/Album/song.flac';
    const folder = 'network://nas/Album/cover.jpg';
    final tags = CoverStore.songCoverReference(source);
    final tagFile = File('${directory.path}/tags.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 1]);
    final folderFile = await covers.file(folder);
    final tagCover = await covers.adopt(tags, tagFile.path);
    expect(folderFile, isNotNull);
    expect(tagCover, isNot(folderFile));
    // As Home On repeat plays a statistics track.
    MediaItem replay(String artwork) => PlayableMedia(
      id: source,
      source: source,
      title: 'Song',
      artist: 'Artist',
      artUri: artwork,
    ).toMediaItem(covers: covers);
    expect(replay(tags).artUri, Uri.file(tagCover!));
    expect(replay(tags).extras!['artworkRef'], tags);
    final other = PlayableMedia(
      id: 'other',
      source: 'network://nas/Other/song.flac',
      title: 'Other',
      artist: 'Artist',
      artUri: folder,
    ).toMediaItem(covers: covers);
    expect(other.artUri, Uri.file(folderFile!));
    expect(other.extras!['artworkRef'], folder);
  });
}
