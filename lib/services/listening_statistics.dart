import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/track_identity_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      final cover = normalizeCoverReference(total.track.artwork);
      if (cover == null) continue;
      final artist = total.track.artist;
      if (listeningTime.containsKey(artist) &&
          total.milliseconds <= listeningTime[artist]!) {
        continue;
      }
      artwork[artist] = cover;
      listeningTime[artist] = total.milliseconds;
    }
    return artwork;
  }

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
        ListeningTrack(
          key: key,
          title: row['title'] as String,
          artist: artist,
          album: row['album'] as String,
          artwork: row['artwork'] as String?,
        ),
        (tracks[key]?.milliseconds ?? 0) + time,
        (tracks[key]?.plays ?? 0) + count,
      );
      artists[artist] = (artists[artist] ?? 0) + time;
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
  ListeningTrack? _track;
  Duration? _lastElapsed;
  DateTime? _lastDate;
  bool _playing = false;
  bool _enabled = true;
  bool _clearing = false;
  int _sessionMilliseconds = 0;
  bool _counted = false;

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
  String? _cachedDeviceId;

  static String _generateDeviceId() {
    final platform = Platform.operatingSystem.toLowerCase();
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'dev_${platform}_$hex';
  }

  static Future<void> _createTablesAndTriggers(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS listening_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS listening_device_records (
        device_id TEXT NOT NULL,
        day TEXT NOT NULL,
        track_key TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT NOT NULL,
        artwork TEXT,
        milliseconds INTEGER NOT NULL DEFAULT 0,
        plays INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        is_legacy INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (device_id, day, track_key)
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ldr_day ON listening_device_records(day);',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ldr_device ON listening_device_records(device_id);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS listening (
        day TEXT NOT NULL,
        track_key TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT NOT NULL,
        artwork TEXT,
        milliseconds INTEGER NOT NULL DEFAULT 0,
        plays INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, track_key)
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        month TEXT PRIMARY KEY,
        dirty INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_ldr_insert AFTER INSERT ON listening_device_records
      BEGIN
        INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
        VALUES (new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0);
        UPDATE listening SET
          title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
          milliseconds = milliseconds + new.milliseconds,
          plays = plays + new.plays
        WHERE day = new.day AND track_key = new.track_key;
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_ldr_update AFTER UPDATE ON listening_device_records
      BEGIN
        -- Branch 1: Same grouping key
        UPDATE listening SET
          title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
          milliseconds = milliseconds + (new.milliseconds - old.milliseconds),
          plays = plays + (new.plays - old.plays)
        WHERE day = new.day AND track_key = new.track_key
          AND (old.day = new.day AND old.track_key = new.track_key);

        -- Branch 2: Grouping key changed
        UPDATE listening SET
          milliseconds = milliseconds - old.milliseconds,
          plays = plays - old.plays
        WHERE day = old.day AND track_key = old.track_key
          AND (old.day != new.day OR old.track_key != new.track_key);

        DELETE FROM listening
        WHERE day = old.day AND track_key = old.track_key
          AND (old.day != new.day OR old.track_key != new.track_key)
          AND milliseconds <= 0 AND plays <= 0;

        INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
        SELECT new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0
        WHERE (old.day != new.day OR old.track_key != new.track_key);

        UPDATE listening SET
          title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
          milliseconds = milliseconds + new.milliseconds,
          plays = plays + new.plays
        WHERE day = new.day AND track_key = new.track_key
          AND (old.day != new.day OR old.track_key != new.track_key);
      END;
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_ldr_delete AFTER DELETE ON listening_device_records
      BEGIN
        UPDATE listening SET
          milliseconds = milliseconds - old.milliseconds,
          plays = plays - old.plays
        WHERE day = old.day AND track_key = old.track_key;

        DELETE FROM listening
        WHERE day = old.day AND track_key = old.track_key
          AND milliseconds <= 0 AND plays <= 0;
      END;
    ''');
  }

  Future<Database> _open() => _database.getOrCreate(
    () => sqlite.openAppDatabase(
      'listening_statistics.db',
      version: 2,
      onCreate: (db, _) async {
        await _createTablesAndTriggers(db);
        String? devId;
        try {
          final prefs = await SharedPreferences.getInstance();
          devId = prefs.getString('mornye_sync_device_id');
        } catch (_) {}
        devId ??= _generateDeviceId();
        _cachedDeviceId = devId;

        await db.insert('listening_metadata', {
          'key': 'local_device_id',
          'value': devId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        await db.insert('listening_metadata', {
          'key': 'schema_version',
          'value': '2',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await db.insert('listening_metadata', {
          'key': 'sync_epoch',
          'value': '1',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createTablesAndTriggers(db);

          // Preserve existing local_device_id if already present
          final existingRows = await db.query(
            'listening_metadata',
            where: 'key = ?',
            whereArgs: ['local_device_id'],
            limit: 1,
          );
          String? devId;
          if (existingRows.isNotEmpty) {
            devId = existingRows.first['value'] as String?;
          }
          if (devId == null || devId.isEmpty) {
            try {
              final prefs = await SharedPreferences.getInstance();
              devId = prefs.getString('mornye_sync_device_id');
            } catch (_) {}
          }
          devId ??= _generateDeviceId();
          _cachedDeviceId = devId;

          await db.insert('listening_metadata', {
            'key': 'local_device_id',
            'value': devId,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          await db.insert('listening_metadata', {
            'key': 'schema_version',
            'value': '2',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await db.insert('listening_metadata', {
            'key': 'sync_epoch',
            'value': '1',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);

          // Migrate legacy listening records safely (idempotent)
          await migrateLegacyHistory(dbOverride: db, targetDeviceId: devId);
        }
      },
    ),
  );

  /// Migrates legacy v1 `listening` records into `listening_device_records`
  /// keyed under the target device ID with canonicalized track keys,
  /// marks affected months dirty in `sync_outbox`, and rebuilds the summary table.
  ///
  /// Can be called during [onUpgrade] or manually on an arbitrary [DatabaseExecutor].
  Future<void> migrateLegacyHistory({
    DatabaseExecutor? dbOverride,
    String? targetDeviceId,
  }) async {
    final db = dbOverride ?? (await _open());
    final devId = targetDeviceId ?? (await deviceId());

    // Never duplicate legacy records if already migrated
    final legacyCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM listening_device_records WHERE is_legacy = 1',
          ),
        ) ??
        0;
    if (legacyCount > 0) return;

    final existingForDev =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM listening_device_records WHERE device_id = ?',
            [devId],
          ),
        ) ??
        0;
    if (existingForDev > 0) return;

    final legacyRows = await db.query('listening');
    if (legacyRows.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final monthsToDirty = <String>{};

    for (final row in legacyRows) {
      final rawKey = row['track_key'] as String;
      final title = row['title'] as String;
      final artist = row['artist'] as String;
      final day = row['day'] as String;
      final canonical = TrackIdentityUtils.canonicalKey(
        title: title,
        artist: artist,
        source: rawKey,
      );
      await db.rawInsert(
        '''
        INSERT INTO listening_device_records
          (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(device_id, day, track_key) DO UPDATE SET
          title = excluded.title,
          artist = excluded.artist,
          album = excluded.album,
          artwork = COALESCE(excluded.artwork, listening_device_records.artwork),
          milliseconds = listening_device_records.milliseconds + excluded.milliseconds,
          plays = listening_device_records.plays + excluded.plays
      ''',
        [
          devId,
          day,
          canonical,
          title,
          artist,
          row['album'] as String,
          row['artwork'] as String?,
          row['milliseconds'] as int,
          row['plays'] as int,
          nowMs,
        ],
      );
      if (day.length >= 7) {
        monthsToDirty.add(day.substring(0, 7));
      }
    }

    // Mark historical months dirty in sync outbox so baseline will sync
    for (final month in monthsToDirty) {
      await db.rawInsert(
        '''
        INSERT OR REPLACE INTO sync_outbox (month, dirty, updated_at)
        VALUES (?, 1, ?)
      ''',
        [month, nowMs],
      );
    }

    // Self-healing rebuild of physical summary table
    await db.execute('DELETE FROM listening;');
    await db.execute('''
      INSERT INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
      SELECT day, track_key, MAX(title), MAX(artist), MAX(album), MAX(artwork),
             SUM(milliseconds), SUM(plays)
      FROM listening_device_records
      GROUP BY day, track_key
      HAVING SUM(milliseconds) > 0 OR SUM(plays) > 0;
    ''');
  }

  /// Returns the persistent unique identifier for this local device installation.
  Future<String> deviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;

    // 1. Check SharedPreferences first (durable anchor across DB upgrades/rebuilds)
    String? devId;
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 300),
      );
      devId = prefs.getString('mornye_sync_device_id');
    } catch (_) {}

    if (devId != null && devId.isNotEmpty) {
      _cachedDeviceId = devId;
      return devId;
    }

    // 2. Generate once and persist in SharedPreferences
    final generated = _generateDeviceId();
    _cachedDeviceId = generated;
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 300),
      );
      await prefs.setString('mornye_sync_device_id', generated);
    } catch (_) {}
    return generated;
  }

  /// Reconciles device records by removing orphaned or superseded device IDs
  /// that are no longer part of the valid device set. Native triggers ensure
  /// the materialized summary table immediately decrements accordingly.
  Future<void> pruneObsoleteDeviceRecords({
    required String localDeviceId,
    required Set<String> activePeerDeviceIds,
  }) async {
    final db = await _open();
    final allAllowedIds = {localDeviceId, ...activePeerDeviceIds};
    final placeholders = List.filled(allAllowedIds.length, '?').join(', ');

    final obsoleteRows = await db.rawQuery(
      'SELECT DISTINCT device_id FROM listening_device_records WHERE device_id NOT IN ($placeholders)',
      allAllowedIds.toList(),
    );
    if (obsoleteRows.isEmpty) return;

    await db.transaction((txn) async {
      for (final row in obsoleteRows) {
        final obsoleteId = row['device_id'] as String;
        _log.i('Pruning obsolete/superseded device records for $obsoleteId');
        await txn.delete(
          'listening_device_records',
          where: 'device_id = ?',
          whereArgs: [obsoleteId],
        );
      }
    });
  }

  /// Safely cleans up foreign peer records from listening_device_records
  /// whose device registration was superseded or pruned from manifest.json.
  /// Strictly NEVER modifies local device records (device_id == localDeviceId).
  Future<void> pruneObsoletePeerRecords({
    required String localDeviceId,
    required Set<String> validPeerDeviceIds,
  }) async {
    final db = await _open();
    final allPeerRows = await db.rawQuery(
      'SELECT DISTINCT device_id FROM listening_device_records WHERE device_id != ?',
      [localDeviceId],
    );
    if (allPeerRows.isEmpty) return;

    final obsoletePeerIds = <String>[];
    for (final row in allPeerRows) {
      final peerId = row['device_id'] as String;
      if (!validPeerDeviceIds.contains(peerId)) {
        obsoletePeerIds.add(peerId);
      }
    }
    if (obsoletePeerIds.isEmpty) return;

    await db.transaction((txn) async {
      for (final obsoleteId in obsoletePeerIds) {
        _log.i('Pruning superseded foreign peer records for $obsoleteId');
        await txn.delete(
          'listening_device_records',
          where: 'device_id = ?',
          whereArgs: [obsoleteId],
        );
      }
    });
  }

  /// Returns all unique device IDs currently present in listening_device_records.
  Future<Set<String>> knownDeviceIds() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT DISTINCT device_id FROM listening_device_records',
    );
    return {
      for (final r in rows)
        if (r['device_id'] is String && (r['device_id'] as String).isNotEmpty)
          r['device_id'] as String,
    };
  }

  /// Reads a value from listening_metadata.
  Future<String?> readMetadata(String key) async {
    final db = await _open();
    final rows = await db.query(
      'listening_metadata',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.first['value'] as String?;
    }
    return null;
  }

  /// Writes a key-value pair to listening_metadata.
  Future<void> writeMetadata(String key, String value) async {
    final db = await _open();
    await db.insert('listening_metadata', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Returns the current sync epoch from metadata.
  Future<int> currentSyncEpoch() async {
    final val = await readMetadata('sync_epoch');
    if (val != null) {
      return int.tryParse(val) ?? 1;
    }
    return 1;
  }

  /// Sets the sync epoch in metadata.
  Future<void> updateSyncEpoch(int epoch) async {
    await writeMetadata('sync_epoch', epoch.toString());
  }

  /// Returns the set of months (YYYY-MM) with pending dirty changes to upload.
  Future<List<String>> dirtyMonths() async {
    final db = await _open();
    final rows = await db.query(
      'sync_outbox',
      where: 'dirty = 1',
      orderBy: 'month ASC',
    );
    return [for (final row in rows) row['month'] as String];
  }

  /// Marks a month clean in the sync outbox once successfully uploaded.
  Future<void> markMonthClean(String month) async {
    final db = await _open();
    await db.delete('sync_outbox', where: 'month = ?', whereArgs: [month]);
  }

  /// Marks a month dirty in the sync outbox.
  Future<void> markMonthDirty(String month) async {
    final db = await _open();
    await db.insert('sync_outbox', {
      'month': month,
      'dirty': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Reads all device records for a specific device and calendar month (YYYY-MM).
  Future<List<Map<String, dynamic>>> getRecordsForMonth(
    String deviceId,
    String month,
  ) async {
    final db = await _open();
    final rows = await db.rawQuery(
      '''
      SELECT day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at
      FROM listening_device_records
      WHERE device_id = ? AND day >= ? AND day <= ?
      ORDER BY day ASC, milliseconds DESC
    ''',
      [deviceId, '$month-01', '$month-31'],
    );
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  /// Atomically replaces an entire month partition for a given peer device.
  /// Native triggers automatically update the physical summary table.
  Future<void> replaceDeviceMonthRecords(
    String remoteDeviceId,
    String month,
    List<Map<String, dynamic>> records,
  ) async {
    final localId = await deviceId();
    if (remoteDeviceId == localId) {
      _log.w(
        'Refusing to replace partition for local device ID: $remoteDeviceId',
      );
      return;
    }

    final db = await _open();
    await db.transaction((transaction) async {
      await transaction.delete(
        'listening_device_records',
        where: 'device_id = ? AND day >= ? AND day <= ?',
        whereArgs: [remoteDeviceId, '$month-01', '$month-31'],
      );
      final batch = transaction.batch();
      for (final record in records) {
        batch.rawInsert(
          '''
          INSERT INTO listening_device_records
            (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
          ON CONFLICT(device_id, day, track_key) DO UPDATE SET
            title = excluded.title,
            artist = excluded.artist,
            album = excluded.album,
            artwork = COALESCE(excluded.artwork, listening_device_records.artwork),
            milliseconds = excluded.milliseconds,
            plays = excluded.plays,
            updated_at = excluded.updated_at
        ''',
          [
            remoteDeviceId,
            record['day'],
            record['track_key'] ?? record['canonicalKey'],
            record['title'] ?? '',
            record['artist'] ?? '',
            record['album'] ?? '',
            record['artwork'],
            record['milliseconds'] ?? 0,
            record['plays'] ?? 0,
            record['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Rebuilds the physical summary table from all device records.
  Future<void> rebuildSummaryTable() async {
    final db = await _open();
    await db.transaction((transaction) async {
      await transaction.execute('DELETE FROM listening;');
      await transaction.execute('''
        INSERT INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
        SELECT day, track_key, MAX(title), MAX(artist), MAX(album), MAX(artwork),
               SUM(milliseconds), SUM(plays)
        FROM listening_device_records
        GROUP BY day, track_key
        HAVING SUM(milliseconds) > 0 OR SUM(plays) > 0;
      ''');
    });
  }

  /// Clears listening records created by this device only.
  Future<void> clearThisDeviceHistory() async {
    final db = await _open();
    final devId = await deviceId();
    await db.transaction((transaction) async {
      // Find all months affected by this device
      final rows = await transaction.rawQuery(
        'SELECT DISTINCT substr(day, 1, 7) AS month FROM listening_device_records WHERE device_id = ?',
        [devId],
      );
      await transaction.delete(
        'listening_device_records',
        where: 'device_id = ?',
        whereArgs: [devId],
      );
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final r in rows) {
        final month = r['month'] as String?;
        if (month != null && month.isNotEmpty) {
          await transaction.insert('sync_outbox', {
            'month': month,
            'dirty': 1,
            'updated_at': nowMs,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  /// Clears history across all synced devices and advances to a new sync epoch.
  Future<void> clearAllHistory({required int newEpoch}) async {
    final db = await _open();
    await db.transaction((transaction) async {
      await transaction.delete('listening_device_records');
      await transaction.delete('listening');
      await transaction.delete('sync_outbox');
      await transaction.insert('listening_metadata', {
        'key': 'sync_epoch',
        'value': newEpoch.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> add(List<ListeningDelta> deltas) async {
    final db = await _open();
    final localDeviceId = await deviceId();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dirtyMonths = <String>{};

    await db.transaction((transaction) async {
      final batch = transaction.batch();
      for (final delta in deltas) {
        final canonicalKey = TrackIdentityUtils.canonicalKey(
          title: delta.track.title,
          artist: delta.track.artist,
          source: delta.track.key,
        );

        batch.rawInsert(
          '''
          INSERT OR IGNORE INTO listening_device_records
            (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
          VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, 0)
        ''',
          [
            localDeviceId,
            delta.day,
            canonicalKey,
            delta.track.title,
            delta.track.artist,
            delta.track.album,
            delta.track.artwork,
            nowMs,
          ],
        );

        batch.rawUpdate(
          '''
          UPDATE listening_device_records SET
            title = ?, artist = ?, album = ?, artwork = ?,
            milliseconds = milliseconds + ?, plays = plays + ?,
            updated_at = ?
          WHERE device_id = ? AND day = ? AND track_key = ?
        ''',
          [
            delta.track.title,
            delta.track.artist,
            delta.track.album,
            delta.track.artwork,
            delta.milliseconds,
            delta.plays,
            nowMs,
            localDeviceId,
            delta.day,
            canonicalKey,
          ],
        );

        if (delta.day.length >= 7) {
          dirtyMonths.add(delta.day.substring(0, 7));
        }
      }

      for (final month in dirtyMonths) {
        batch.rawInsert(
          '''
          INSERT OR REPLACE INTO sync_outbox (month, dirty, updated_at)
          VALUES (?, 1, ?)
        ''',
          [month, nowMs],
        );
      }

      await batch.commit(noResult: true);
    });
  }

  Future<ListeningSummary> load(DateTime start, DateTime end) async {
    final db = await _open();
    return readListeningSummary(db, start, end);
  }

  /// Runs a read-only aggregate against the statistics database.
  Future<T> read<T>(Future<T> Function(DatabaseExecutor db) query) async =>
      query(await _open());

  Future<void> clear() async => clearThisDeviceHistory();
}

/// Aggregate in SQLite so an annual recap transfers one row per song, artist
/// and day, rather than every daily song record into the Flutter heap.
Future<ListeningSummary> readListeningSummary(
  DatabaseExecutor db,
  DateTime start,
  DateTime end,
) async {
  final arguments = [listeningDay(start), listeningDay(end)];
  final rows = await db.rawQuery('''
    SELECT totals.track_key, details.title, details.artist, details.album,
      details.artwork, totals.milliseconds, totals.plays
    FROM (
      SELECT track_key, SUM(milliseconds) AS milliseconds, SUM(plays) AS plays,
        MAX(day) AS last_day
      FROM listening WHERE day >= ? AND day < ? GROUP BY track_key
    ) AS totals
    JOIN listening AS details ON details.track_key = totals.track_key
      AND details.day = totals.last_day
    ORDER BY totals.milliseconds DESC
  ''', arguments);
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
        ListeningTrack(
          key: row['track_key'] as String,
          title: row['title'] as String,
          artist: row['artist'] as String,
          album: row['album'] as String,
          artwork: row['artwork'] as String?,
        ),
        row['milliseconds'] as int,
        row['plays'] as int,
      ),
  ];
  return ListeningSummary(
    milliseconds: tracks.fold(0, (sum, track) => sum + track.milliseconds),
    plays: tracks.fold(0, (sum, track) => sum + track.plays),
    tracks: tracks,
    artists: {
      for (final row in artistRows)
        row['artist'] as String: row['milliseconds'] as int,
    },
    days: {
      for (final row in dayRows)
        row['day'] as String: row['milliseconds'] as int,
    },
  );
}

final _listeningClock = Stopwatch()..start();
final listeningRecorder = ListeningRecorder(
  write: ListeningStatisticsStore.instance.add,
  elapsed: () => _listeningClock.elapsed,
  now: DateTime.now,
);
