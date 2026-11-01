import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/link/sync/link_collection_sync_store.dart';
import 'package:mornye/services/link/sync/link_history_sync_schema.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

/// Old Android SQLite allows 999 bound parameters per statement.
const _chunkSize = 400;

/// Songs looked up by title and artist per statement, two parameters each.
const _songChunkSize = _chunkSize ~/ 2;

typedef _EventIdentity = (String origin, String day, String trackKey);

/// Reads and writes listening totals for Mornye Link history sync.
class LinkHistorySyncStore {
  LinkHistorySyncStore(this._open);

  final Future<Database> Function() _open;
  String? _deviceId;

  Future<Database> get database => _open();

  /// This database's sync device id (the `origin` of local listening).
  Future<String> deviceId() async {
    final cached = _deviceId;
    if (cached != null) return cached;
    final rows = await (await _open()).rawQuery(
      'SELECT device_id FROM $listeningSyncStateTable WHERE id = 1',
    );
    return _deviceId = rows.first['device_id']! as String;
  }

  Future<int> latestSeq() async {
    final rows = await (await _open()).rawQuery(
      'SELECT seq FROM $listeningSyncStateTable WHERE id = 1',
    );
    return rows.first['seq']! as int;
  }

  /// Adds listening time as this device's own playback (a Subsonic
  /// scrobble on the desktop).
  Future<void> record(List<ListeningDelta> deltas) async {
    if (deltas.isEmpty) return;
    await writeListeningDeltas(await _open(), deltas);
  }

  /// Totals that changed after [since], oldest first. [excludeOrigin] skips
  /// that device's own totals; [localOnly] keeps only this device's.
  Future<LinkSyncPage<LinkHistoryEvent>> eventsSince(
    int since, {
    String? excludeOrigin,
    bool localOnly = false,
    int limit = linkSyncPageSize,
  }) async {
    final pageSize = limit.clamp(1, linkSyncPageSize);
    final db = await _open();
    return db.transaction((txn) async {
      final state = (await txn.rawQuery(
        'SELECT device_id, seq FROM $listeningSyncStateTable WHERE id = 1',
      )).first;
      final device = state['device_id']! as String;
      final latest = state['seq']! as int;
      final filters = <String>['seq > ?'];
      final arguments = <Object?>[since];
      if (localOnly) {
        filters.add('origin = ?');
        arguments.add(device);
      }
      if (excludeOrigin != null) {
        filters.add('origin != ?');
        arguments.add(excludeOrigin);
      }
      final rows = await txn.rawQuery(
        'SELECT origin, day, track_key, title, artist, album, artwork, '
        'milliseconds, plays, seq FROM $listeningSyncTable '
        'WHERE ${filters.join(' AND ')} ORDER BY seq LIMIT ?',
        [...arguments, pageSize],
      );
      final more = rows.length >= pageSize;
      return LinkSyncPage(
        device: device,
        cursor: more ? rows.last['seq']! as int : latest,
        latest: latest,
        more: more,
        items: [
          for (final row in rows)
            LinkHistoryEvent(
              origin: row['origin']! as String,
              day: row['day']! as String,
              trackKey: row['track_key']! as String,
              title: row['title']! as String,
              artist: row['artist']! as String,
              album: row['album']! as String,
              artwork: linkSyncRemoteArtwork(row['artwork']),
              milliseconds: row['milliseconds']! as int,
              plays: row['plays']! as int,
            ),
        ],
      );
    });
  }

  /// Adds the growth of each peer total since the last value seen. A song
  /// is counted under the key this device already uses for it: the key an
  /// earlier day of the same total mapped to, else a song with the same
  /// title and artist, else the author's key.
  Future<LinkSyncApplyResult> apply(Iterable<LinkHistoryEvent> events) async {
    final own = await deviceId();
    final incoming = <_EventIdentity, LinkHistoryEvent>{};
    for (final event in events) {
      if (event.origin == own) continue;
      final identity = (event.origin, event.day, event.trackKey);
      final previous = incoming[identity];
      if (previous == null ||
          event.milliseconds > previous.milliseconds ||
          event.plays > previous.plays) {
        incoming[identity] = previous == null
            ? event
            : LinkHistoryEvent(
                origin: event.origin,
                day: event.day,
                trackKey: event.trackKey,
                title: event.title,
                artist: event.artist,
                album: event.album,
                artwork: event.artwork ?? previous.artwork,
                milliseconds: event.milliseconds > previous.milliseconds
                    ? event.milliseconds
                    : previous.milliseconds,
                plays: event.plays > previous.plays
                    ? event.plays
                    : previous.plays,
              );
      }
    }
    final db = await _open();
    return sqlite.transactionWithBusyRetry(db, (txn) async {
      final seen = <_EventIdentity, (String, int, int)>{};
      final mapped = <(String, String), String>{};
      final keysByOrigin = <String, Set<String>>{};
      for (final (origin, _, trackKey) in incoming.keys) {
        keysByOrigin.putIfAbsent(origin, () => {}).add(trackKey);
      }
      for (final MapEntry(key: origin, value: keys) in keysByOrigin.entries) {
        final list = keys.toList();
        for (var start = 0; start < list.length; start += _chunkSize) {
          final chunk = list.sublist(
            start,
            start + _chunkSize < list.length ? start + _chunkSize : list.length,
          );
          final rows = await txn.rawQuery(
            'SELECT day, track_key, local_key, milliseconds, plays '
            'FROM $listeningSyncTable WHERE origin = ? AND track_key IN '
            '(${List.filled(chunk.length, '?').join(',')})',
            [origin, ...chunk],
          );
          for (final row in rows) {
            final trackKey = row['track_key']! as String;
            final localKey = row['local_key']! as String;
            seen[(origin, row['day']! as String, trackKey)] = (
              localKey,
              row['milliseconds']! as int,
              row['plays']! as int,
            );
            mapped[(origin, trackKey)] = localKey;
          }
        }
      }
      // The batch below writes at the end, so songs are matched against the
      // totals as they were before these events.
      final matches = await _songKeys(txn, {
        for (final MapEntry(key: identity, value: event) in incoming.entries)
          if (event.title.isNotEmpty &&
              seen[identity] == null &&
              !mapped.containsKey((event.origin, event.trackKey)) &&
              (event.milliseconds > 0 || event.plays > 0))
            (event.title, event.artist),
      });
      final batch = txn.batch();
      var applied = 0;
      for (final MapEntry(key: identity, value: event) in incoming.entries) {
        final previous = seen[identity];
        final milliseconds = event.milliseconds - (previous?.$2 ?? 0);
        final plays = event.plays - (previous?.$3 ?? 0);
        if (milliseconds <= 0 && plays <= 0) continue;
        var localKey = previous?.$1 ?? mapped[(event.origin, event.trackKey)];
        if (localKey == null) {
          localKey = event.title.isEmpty
              ? event.trackKey
              : matches[(event.title, event.artist)] ?? event.trackKey;
          mapped[(event.origin, event.trackKey)] = localKey;
        }
        if (applied++ == 0) {
          batch.rawUpdate(
            'UPDATE $listeningSyncStateTable SET applying = 1 WHERE id = 1',
          );
        }
        final growth = (
          milliseconds < 0 ? 0 : milliseconds,
          plays < 0 ? 0 : plays,
        );
        batch.rawInsert(
          'INSERT OR IGNORE INTO listening '
          '(day, track_key, title, artist, album, artwork, milliseconds, plays) '
          'VALUES (?, ?, ?, ?, ?, ?, 0, 0)',
          [
            event.day,
            localKey,
            event.title,
            event.artist,
            event.album,
            event.artwork,
          ],
        );
        batch.rawUpdate(
          'UPDATE listening SET milliseconds = milliseconds + ?, '
          'plays = plays + ?, artwork = COALESCE(artwork, ?) '
          'WHERE day = ? AND track_key = ?',
          [growth.$1, growth.$2, event.artwork, event.day, localKey],
        );
        batch.rawUpdate(
          'UPDATE $listeningSyncStateTable SET seq = seq + 1 WHERE id = 1',
        );
        batch.rawInsert(
          'INSERT OR REPLACE INTO $listeningSyncTable '
          '(origin, day, track_key, local_key, title, artist, album, artwork, '
          'milliseconds, plays, seq) '
          'SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, seq '
          'FROM $listeningSyncStateTable WHERE id = 1',
          [
            event.origin,
            event.day,
            event.trackKey,
            localKey,
            event.title,
            event.artist,
            event.album,
            event.artwork,
            (previous?.$2 ?? 0) + growth.$1,
            (previous?.$3 ?? 0) + growth.$2,
          ],
        );
      }
      if (applied > 0) {
        batch.rawUpdate(
          'UPDATE $listeningSyncStateTable SET applying = 0 WHERE id = 1',
        );
        await batch.commit(noResult: true);
      }
      final latest = await txn.rawQuery(
        'SELECT seq FROM $listeningSyncStateTable WHERE id = 1',
      );
      return LinkSyncApplyResult(
        applied: applied,
        latest: latest.first['seq']! as int,
      );
    });
  }

  /// The key of each of [songs] (title and artist, either case) on its
  /// newest listening day, for those this device has heard.
  static Future<Map<(String, String), String>> _songKeys(
    Transaction txn,
    Set<(String, String)> songs,
  ) async {
    final keys = <(String, String), String>{};
    final list = songs.toList();
    for (var start = 0; start < list.length; start += _songChunkSize) {
      final chunk = list.sublist(
        start,
        start + _songChunkSize < list.length
            ? start + _songChunkSize
            : list.length,
      );
      final rows = await txn.rawQuery(
        'WITH wanted(title, artist) AS '
        '(VALUES ${List.filled(chunk.length, '(?, ?)').join(', ')}) '
        'SELECT title, artist, (SELECT l.track_key FROM listening l '
        'WHERE l.title = wanted.title COLLATE NOCASE '
        'AND l.artist = wanted.artist COLLATE NOCASE '
        'ORDER BY l.day DESC LIMIT 1) AS track_key FROM wanted',
        [
          for (final (title, artist) in chunk) ...[title, artist],
        ],
      );
      for (final row in rows) {
        if (row['track_key'] case final String key) {
          keys[(row['title']! as String, row['artist']! as String)] = key;
        }
      }
    }
    return keys;
  }
}

/// The listening statistics store of this app. Tests override it.
final linkHistorySyncStoreProvider = Provider<LinkHistorySyncStore>(
  (ref) =>
      LinkHistorySyncStore(() => ListeningStatisticsStore.instance.database),
);
