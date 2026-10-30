import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/services/listening_statistics.dart';

import 'support/link_sync_support.dart';

ListeningDelta _delta(
  String key,
  int milliseconds, {
  int plays = 0,
  String day = '2026-10-20',
  String title = 'Song',
  String? artwork,
}) => ListeningDelta(
  day,
  ListeningTrack(
    key: key,
    title: title,
    artist: 'Artist',
    album: 'Album',
    artwork: artwork,
  ),
  milliseconds,
  plays,
);

LinkHistoryEvent _event(
  String origin,
  String key,
  int milliseconds, {
  int plays = 1,
  String day = '2026-10-20',
  String title = 'Song',
}) => LinkHistoryEvent(
  origin: origin,
  day: day,
  trackKey: key,
  title: title,
  artist: 'Artist',
  album: 'Album',
  milliseconds: milliseconds,
  plays: plays,
);

Future<List<Map<String, Object?>>> _listening(Database db) =>
    db.rawQuery('SELECT * FROM listening ORDER BY day, track_key');

void main() {
  test('v1 statistics migrate to v2 and seed this device totals', () async {
    final directory = await linkSyncTempDirectory();
    final path = '${directory.path}/listening_statistics.db';
    sqfliteFfiInit();
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE listening (
            day TEXT NOT NULL, track_key TEXT NOT NULL, title TEXT NOT NULL,
            artist TEXT NOT NULL, album TEXT NOT NULL, artwork TEXT,
            milliseconds INTEGER NOT NULL DEFAULT 0,
            plays INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, track_key))
        '''),
      ),
    );
    await writeListeningDeltas(legacy, [
      _delta('/a.flac', 60000, plays: 1),
      _delta('/b.flac', 0),
    ]);
    await legacy.close();

    final db = await ListeningStatisticsStore.openWithFactory(
      databaseFactoryFfi,
      path,
    );
    addTearDown(db.close);
    expect((await db.rawQuery('PRAGMA user_version')).first.values.first, 2);
    final store = LinkHistorySyncStore(() async => db);
    final page = await store.eventsSince(0);
    expect(page.items.map((event) => event.trackKey), ['/a.flac']);
    expect(page.items.single.origin, await store.deviceId());
    expect(page.items.single.milliseconds, 60000);
    expect(page.cursor, await store.latestSeq());
    expect(await _listening(db), hasLength(2));
  });

  test('local playback grows this device totals; peer writes do not', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkListeningDatabase(directory, 'phone');
    final store = LinkHistorySyncStore(() async => db);
    await writeListeningDeltas(db, [_delta('/a.flac', 1000)]);
    await writeListeningDeltas(db, [_delta('/a.flac', 30000, plays: 1)]);
    final mine = await store.eventsSince(0, localOnly: true);
    expect(mine.items.single.milliseconds, 31000);
    expect(mine.items.single.plays, 1);

    await store.apply([_event('desk', '/desk/a.flac', 5000)]);
    final local = await store.eventsSince(0, localOnly: true);
    expect(local.items.single.milliseconds, 31000);
    // The peer's total is kept for relaying to other devices.
    final relay = await store.eventsSince(0, excludeOrigin: 'phone2');
    expect(relay.items.map((event) => event.origin).toSet(), hasLength(2));
    final forDesk = await store.eventsSince(0, excludeOrigin: 'desk');
    expect(forDesk.items.map((event) => event.origin), [
      await store.deviceId(),
    ]);
  });

  test('peer totals add only their growth, under the local song key', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkListeningDatabase(directory, 'desk');
    final store = LinkHistorySyncStore(() async => db);
    await writeListeningDeltas(db, [
      _delta('/desk/song.flac', 10000, plays: 1, day: '2026-10-19'),
    ]);

    // Same title and artist: counted under the desktop's key.
    var result = await store.apply([
      _event('phone', '/phone/song.flac', 40000),
    ]);
    expect(result.applied, 1);
    var rows = await _listening(db);
    expect(rows.map((row) => row['track_key']).toSet(), {'/desk/song.flac'});
    expect(rows.last['milliseconds'], 40000);
    expect(rows.last['plays'], 1);

    // Re-sending is harmless; growth adds the difference only.
    result = await store.apply([_event('phone', '/phone/song.flac', 40000)]);
    expect(result.applied, 0);
    await store.apply([
      _event('phone', '/phone/song.flac', 70000, plays: 2),
      _event('phone', '/phone/song.flac', 50000),
    ]);
    rows = await _listening(db);
    expect(rows.last['milliseconds'], 70000);
    expect(rows.last['plays'], 2);
    // A smaller total never subtracts.
    await store.apply([_event('phone', '/phone/song.flac', 1000)]);
    expect((await _listening(db)).last['milliseconds'], 70000);

    // A song new to this device keeps the author's key; own totals echoed
    // back by a peer are ignored.
    await store.apply([
      _event('phone', '/phone/other.flac', 2000, title: 'Other'),
      _event(await store.deviceId(), '/desk/song.flac', 999999),
    ]);
    rows = await _listening(db);
    expect(rows.map((row) => row['track_key']).toSet(), {
      '/desk/song.flac',
      '/phone/other.flac',
    });
    expect(rows.first['milliseconds'], 10000);
    // Local playback after the merge still counts only this device's time.
    await writeListeningDeltas(db, [_delta('/desk/song.flac', 500)]);
    final mine = await store.eventsSince(0, localOnly: true);
    expect(mine.items.map((event) => (event.day, event.milliseconds)).toSet(), {
      ('2026-10-19', 10000),
      ('2026-10-20', 500),
    });
  });

  test('events round-trip the wire and drop device-local artwork', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkListeningDatabase(directory, 'phone');
    final store = LinkHistorySyncStore(() async => db);
    await writeListeningDeltas(db, [
      _delta('/a.flac', 1000, artwork: '/data/cover.jpg'),
      _delta('/b.flac', 1000, artwork: 'https://example.com/b.jpg'),
    ]);
    final page = await store.eventsSince(0, limit: 1);
    expect(page.more, isTrue);
    final rest = await store.eventsSince(page.cursor);
    expect(rest.more, isFalse);
    final wire = linkJsonRoundTrip(rest.toJson('events', (e) => e.toJson()));
    final decoded = LinkSyncPage.fromJson<LinkHistoryEvent>(
      wire,
      'events',
      (item, origin) => LinkHistoryEvent.fromJson(item, fallbackOrigin: origin),
    );
    expect(decoded!.items.single.artwork, 'https://example.com/b.jpg');
    expect(page.items.single.artwork, isNull);
    expect(
      LinkHistoryEvent.fromJson({'origin': 'x', 'day': 'bad', 'trackKey': 'k'}),
      isNull,
    );
  });

  test('loopback artwork an older build recorded is never synced', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkListeningDatabase(directory, 'phone');
    final store = LinkHistorySyncStore(() async => db);
    const loopback = 'http://127.0.0.1:41234/7f3a';
    await db.insert('listening', {
      'day': '2026-10-20',
      'track_key': '/a.flac',
      'title': 'Song',
      'artist': 'Artist',
      'album': 'Album',
      'artwork': loopback,
      'milliseconds': 1000,
      'plays': 0,
    });
    final page = await store.eventsSince(0);
    expect(page.items.single.trackKey, '/a.flac');
    expect(page.items.single.artwork, isNull);
    final event = LinkHistoryEvent.fromJson({
      'origin': 'peer',
      'day': '2026-10-20',
      'trackKey': '/b.flac',
      'artwork': loopback,
      'ms': 1000,
      'plays': 0,
    });
    expect(event!.artwork, isNull);
  });
}
