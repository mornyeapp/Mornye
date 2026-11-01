import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/link/sync/link_history_sync_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('ListeningStatistics');

String listeningDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

class ListeningTrack {
  const ListeningTrack({
    required this.key,
    required this.title,
    required this.artist,
    required this.album,
    this.artwork,
  });

  /// The track of a `listening` row, with [fallbackArtwork] when the row has
  /// no cover. Older builds recorded loopback URLs and temporary files,
  /// which read as no artwork, so the fallback shows instead of a broken
  /// image until the song plays again.
  factory ListeningTrack.fromRow(
    Map<String, Object?> row, {
    String? fallbackArtwork,
  }) => ListeningTrack(
    key: row['track_key'] as String,
    title: row['title'] as String,
    artist: row['artist'] as String,
    album: row['album'] as String,
    artwork:
        durableCoverReference(
          normalizeStoredCoverReference(row['artwork'] as String?),
        ) ??
        fallbackArtwork,
  );

  final String key;
  final String title;
  final String artist;
  final String album;
  final String? artwork;
}

class ListeningTotal {
  const ListeningTotal(this.track, this.milliseconds, this.plays);

  final ListeningTrack track;
  final int milliseconds;
  final int plays;
}

class ListeningSummary {
  const ListeningSummary({
    this.milliseconds = 0,
    this.plays = 0,
    this.tracks = const [],
    this.artists = const {},
    this.days = const {},
  });

  final int milliseconds;
  final int plays;
  final List<ListeningTotal> tracks;
  final Map<String, int> artists;
  final Map<String, int> days;

  Map<String, String> get artistArtwork {
    final artwork = <String, String>{};
    final listeningTime = <String, int>{};
    for (final total in tracks) {
      final cover = total.track.artwork;
      if (cover == null) continue;
      for (final artist in splitArtistTagValues(total.track.artist)) {
        if (listeningTime.containsKey(artist) &&
            total.milliseconds <= listeningTime[artist]!) {
          continue;
        }
        artwork[artist] = cover;
        listeningTime[artist] = total.milliseconds;
      }
    }
    return artwork;
  }

  /// A summary of daily [rows]; each song keeps its last row's details.
  /// [readListeningSummary] is the reader the app uses.
  @visibleForTesting
  factory ListeningSummary.fromRows(List<Map<String, Object?>> rows) {
    final tracks = <String, ListeningTotal>{};
    final artists = <String, int>{};
    final days = <String, int>{};
    var milliseconds = 0;
    var plays = 0;
    for (final row in rows) {
      final time = row['milliseconds'] as int;
      final count = row['plays'] as int;
      final key = row['track_key'] as String;
      final artist = row['artist'] as String;
      final day = row['day'] as String;
      milliseconds += time;
      plays += count;
      tracks[key] = ListeningTotal(
        ListeningTrack.fromRow(row),
        (tracks[key]?.milliseconds ?? 0) + time,
        (tracks[key]?.plays ?? 0) + count,
      );
      for (final name in splitArtistTagValues(artist)) {
        artists[name] = (artists[name] ?? 0) + time;
      }
      days[day] = (days[day] ?? 0) + time;
    }
    final ranked = tracks.values.toList()
      ..sort((a, b) => b.milliseconds.compareTo(a.milliseconds));
    return ListeningSummary(
      milliseconds: milliseconds,
      plays: plays,
      tracks: ranked,
      artists: artists,
      days: days,
    );
  }
}

class ListeningDelta {
  ListeningDelta(this.day, this.track, this.milliseconds, this.plays);

  final String day;
  final ListeningTrack track;
  int milliseconds;
  int plays;
}

/// Uses elapsed time, never a change in seek position. Pauses and buffering
/// stop accrual; a play is counted once after 30 seconds in that session.
class ListeningRecorder {
  ListeningRecorder({
    required this.write,
    required this.elapsed,
    required this.now,
  });

  final Future<void> Function(List<ListeningDelta>) write;
  final Duration Function() elapsed;
  final DateTime Function() now;
  final Map<(String, String), ListeningDelta> _pending = {};
  Future<void> _writeTail = Future<void>.value();
  int _writing = 0;
  ListeningTrack? _track;
  Duration? _lastElapsed;
  DateTime? _lastDate;
  bool _playing = false;
  bool _enabled = true;
  bool _clearing = false;
  int _sessionMilliseconds = 0;
  bool _counted = false;

  /// Nothing plays, nothing waits to be written and no write can still fail
  /// and return its time: [flush] has no work.
  bool get idle => !_playing && _pending.isEmpty && _writing == 0;

  void update(
    ListeningTrack? track, {
    required bool playing,
    bool ended = false,
  }) {
    checkpoint();
    if (_track?.key != track?.key || ended) {
      _sessionMilliseconds = 0;
      _counted = false;
    }
    _track = track;
    _playing = playing && !ended;
    _lastElapsed = elapsed();
    _lastDate = now();
  }

  void setEnabled(bool enabled) {
    checkpoint();
    _enabled = enabled;
    _lastElapsed = elapsed();
    _lastDate = now();
  }

  void checkpoint() {
    final end = elapsed();
    final date = now();
    final previous = _lastElapsed;
    final startDate = _lastDate;
    _lastElapsed = end;
    _lastDate = date;
    final track = _track;
    if (!_enabled ||
        _clearing ||
        !_playing ||
        track == null ||
        previous == null) {
      return;
    }
    var time = (end - previous).inMilliseconds;
    if (time <= 0) return;
    // Keep a midnight boundary in the correct day without letting wall-clock
    // adjustments manufacture extra listening time.
    var cursor = startDate ?? date;
    while (time > 0) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final remaining = midnight.difference(cursor).inMilliseconds;
      final chunk = remaining > 0 && remaining < time ? remaining : time;
      final day = listeningDay(cursor);
      final delta = _pending.putIfAbsent((
        day,
        track.key,
      ), () => ListeningDelta(day, track, 0, 0));
      delta.milliseconds += chunk;
      _sessionMilliseconds += chunk;
      if (!_counted && _sessionMilliseconds >= 30000) {
        delta.plays++;
        _counted = true;
      }
      time -= chunk;
      cursor = midnight;
    }
  }

  Future<void> flush() {
    if (_clearing) return _writeTail;
    checkpoint();
    final batch = _pending.values.toList(growable: false);
    _pending.clear();
    if (batch.isNotEmpty) _writing++;
    _writeTail = _writeTail.then((_) async {
      if (batch.isEmpty) return;
      try {
        await write(batch);
      } catch (error) {
        // A transient database failure must neither crash playback nor lose
        // the buffered time. Retry with the next normal checkpoint.
        for (final delta in _clearing ? <ListeningDelta>[] : batch) {
          final existing = _pending[(delta.day, delta.track.key)];
          if (existing == null) {
            _pending[(delta.day, delta.track.key)] = delta;
          } else {
            existing.milliseconds += delta.milliseconds;
            existing.plays += delta.plays;
          }
        }
        _log.w('Could not persist listening statistics: $error');
      } finally {
        _writing--;
      }
    });
    return _writeTail;
  }

  Future<void> clear(Future<void> Function() clearStore) async {
    if (_clearing) return;
    _clearing = true;
    _pending.clear();
    final operation = _writeTail.then((_) => clearStore());
    _writeTail = operation.catchError((Object error) {
      _log.w('Could not clear listening statistics: $error');
    });
    try {
      await operation;
      _sessionMilliseconds = 0;
      _counted = false;
    } finally {
      _lastElapsed = elapsed();
      _lastDate = now();
      _clearing = false;
    }
  }
}

class ListeningStatisticsStore {
  static final instance = ListeningStatisticsStore._();
  ListeningStatisticsStore._();

  final _database = sqlite.SingleFlightInitializer<Database>();

  /// v2 adds Mornye Link change tracking beside the `listening` table.
  static const _version = 2;

  Future<Database> _open() => _database.getOrCreate(
    () => sqlite.openAppDatabase(
      'listening_statistics.db',
      version: _version,
      onCreate: _create,
      onUpgrade: _upgrade,
    ),
  );

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE listening (
        day TEXT NOT NULL,
        track_key TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT NOT NULL,
        artwork TEXT,
        milliseconds INTEGER NOT NULL DEFAULT 0,
        plays INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, track_key)
      )
    ''');
    await createLinkHistorySyncSchema(db);
  }

  static Future<void> _upgrade(Database db, int oldVersion, int _) async {
    if (oldVersion < 2) await createLinkHistorySyncSchema(db);
  }

  /// Opens [path] with the statistics schema through [factory], for host
  /// tests that use FFI.
  @visibleForTesting
  static Future<Database> openWithFactory(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: _version,
      onCreate: _create,
      onUpgrade: _upgrade,
    ),
  );

  /// The statistics database (Mornye Link history sync).
  Future<Database> get database => _open();

  Future<void> add(List<ListeningDelta> deltas) async =>
      writeListeningDeltas(await _open(), deltas);

  Future<ListeningSummary> load(DateTime start, DateTime end) async {
    final db = await _open();
    return readListeningSummary(db, start, end);
  }

  Future<List<ListeningTotal>> loadReplayableTracks(
    DateTime start,
    DateTime end, {
    required int limit,
    int offset = 0,
  }) async => readReplayableListeningTracks(
    await _open(),
    start,
    end,
    limit: limit,
    offset: offset,
  );

  /// Runs a read-only aggregate against the statistics database.
  Future<T> read<T>(Future<T> Function(DatabaseExecutor db) query) async =>
      query(await _open());

  Future<void> clear() async => (await _open()).delete('listening');
}

/// Adds [deltas] to the per-day totals in one transaction.
Future<void> writeListeningDeltas(
  Database db,
  List<ListeningDelta> deltas,
) async {
  await db.transaction((transaction) async {
    final batch = transaction.batch();
    for (final delta in deltas) {
      final artwork = durableCoverReference(delta.track.artwork);
      batch.rawInsert(
        '''
        INSERT OR IGNORE INTO listening
          (day, track_key, title, artist, album, artwork, milliseconds, plays)
        VALUES (?, ?, ?, ?, ?, ?, 0, 0)
      ''',
        [
          delta.day,
          delta.track.key,
          delta.track.title,
          delta.track.artist,
          delta.track.album,
          artwork,
        ],
      );
      // Avoid UPSERT syntax unavailable in older Android SQLite versions.
      // A play whose cover is not known yet keeps the one stored.
      batch.rawUpdate(
        '''
        UPDATE listening SET title = ?, artist = ?, album = ?,
          artwork = COALESCE(?, artwork),
          milliseconds = milliseconds + ?, plays = plays + ?
        WHERE day = ? AND track_key = ?
      ''',
        [
          delta.track.title,
          delta.track.artist,
          delta.track.album,
          artwork,
          delta.milliseconds,
          delta.plays,
          delta.day,
          delta.track.key,
        ],
      );
    }
    await batch.commit(noResult: true);
  });
}

/// One row per song of the window, most listened first. A song shows its
/// latest day's details, and the latest cover recorded in the window when
/// that day has none.
String _listeningTracksSql({
  String where = '',
  String having = '',
  String tail = '',
}) =>
    '''
    SELECT totals.track_key, details.title, details.artist, details.album,
      COALESCE(details.artwork, covered.artwork) AS artwork,
      totals.milliseconds, totals.plays
    FROM (
      SELECT track_key, SUM(milliseconds) AS milliseconds, SUM(plays) AS plays,
        MAX(day) AS last_day,
        MAX(CASE WHEN artwork IS NOT NULL THEN day END) AS cover_day
      FROM listening WHERE day >= ? AND day < ?$where GROUP BY track_key$having
    ) AS totals
    JOIN listening AS details ON details.track_key = totals.track_key
      AND details.day = totals.last_day
    LEFT JOIN listening AS covered ON covered.track_key = totals.track_key
      AND covered.day = totals.cover_day
    ORDER BY totals.milliseconds DESC$tail
  ''';

/// Aggregate in SQLite so an annual recap transfers one row per song, artist
/// and day, rather than every daily song record into the Flutter heap.
/// A song shows its latest day's details, and the latest cover recorded in
/// the window when that day has none.
Future<ListeningSummary> readListeningSummary(
  DatabaseExecutor db,
  DateTime start,
  DateTime end,
) async {
  final arguments = [listeningDay(start), listeningDay(end)];
  final rows = await db.rawQuery(_listeningTracksSql(), arguments);
  final artistRows = await db.rawQuery('''
    SELECT artist, SUM(milliseconds) AS milliseconds
    FROM listening WHERE day >= ? AND day < ? GROUP BY artist
  ''', arguments);
  final dayRows = await db.rawQuery('''
    SELECT day, SUM(milliseconds) AS milliseconds
    FROM listening WHERE day >= ? AND day < ? GROUP BY day ORDER BY day
  ''', arguments);
  final tracks = [
    for (final row in rows)
      ListeningTotal(
        ListeningTrack.fromRow(row),
        row['milliseconds'] as int,
        row['plays'] as int,
      ),
  ];
  // Split stored credits on read so existing history also credits each artist.
  // Each collaborator gets the track's time; overall totals still count once.
  final artists = <String, int>{};
  for (final row in artistRows) {
    for (final artist in splitArtistTagValues(row['artist'] as String)) {
      artists[artist] = (artists[artist] ?? 0) + (row['milliseconds'] as int);
    }
  }
  return ListeningSummary(
    milliseconds: tracks.fold(0, (sum, track) => sum + track.milliseconds),
    plays: tracks.fold(0, (sum, track) => sum + track.plays),
    tracks: tracks,
    artists: artists,
    days: {
      for (final row in dayRows)
        row['day'] as String: row['milliseconds'] as int,
    },
  );
}

/// The tracks of [readListeningSummary] in its order, [limit] from
/// [offset], that can be played again from their key: played at least once
/// and not recorded under a stream URL. Equal listening times keep the
/// summary's order, by key.
Future<List<ListeningTotal>> readReplayableListeningTracks(
  DatabaseExecutor db,
  DateTime start,
  DateTime end, {
  required int limit,
  int offset = 0,
}) async {
  final rows = await db.rawQuery(
    _listeningTracksSql(
      where:
          " AND track_key NOT GLOB 'http://*'"
          " AND track_key NOT GLOB 'https://*'",
      having: ' HAVING SUM(plays) > 0',
      tail: ', totals.track_key LIMIT ? OFFSET ?',
    ),
    [listeningDay(start), listeningDay(end), limit, offset],
  );
  return [
    for (final row in rows)
      ListeningTotal(
        ListeningTrack.fromRow(row),
        row['milliseconds'] as int,
        row['plays'] as int,
      ),
  ];
}

final _listeningClock = Stopwatch()..start();
final listeningRecorder = ListeningRecorder(
  write: ListeningStatisticsStore.instance.add,
  elapsed: () => _listeningClock.elapsed,
  now: DateTime.now,
);
