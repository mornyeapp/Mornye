import 'package:sqflite/sqflite.dart';

/// Change tracking for listening statistics (Mornye Link sync).
///
/// `listening` aggregates time per day and song. `listening_sync` keeps
/// every author's own running totals per (origin, day, author's track key),
/// plus `local_key`, the key those totals are counted under here (a peer's
/// file path differs from this device's path for the same song).
/// `listening_sync_state` holds the sync device id, the sequence counter and
/// the `applying` flag set while peer totals are written, so the triggers
/// only count growth from this device's own playback.
const listeningSyncStateTable = 'listening_sync_state';
const listeningSyncTable = 'listening_sync';

String _recordGrowth(String milliseconds, String plays) =>
    '''
    UPDATE $listeningSyncStateTable SET seq = seq + 1 WHERE id = 1;
    INSERT OR IGNORE INTO $listeningSyncTable
      (origin, day, track_key, local_key, title, artist, album, artwork,
       milliseconds, plays, seq)
    SELECT device_id, NEW.day, NEW.track_key, NEW.track_key, NEW.title,
      NEW.artist, NEW.album, NEW.artwork, 0, 0, seq
    FROM $listeningSyncStateTable WHERE id = 1;
    UPDATE $listeningSyncTable SET
      milliseconds = milliseconds + MAX($milliseconds, 0),
      plays = plays + MAX($plays, 0),
      title = NEW.title, artist = NEW.artist, album = NEW.album,
      artwork = NEW.artwork,
      seq = (SELECT seq FROM $listeningSyncStateTable WHERE id = 1)
    WHERE origin = (SELECT device_id FROM $listeningSyncStateTable WHERE id = 1)
      AND day = NEW.day AND track_key = NEW.track_key;''';

const _notApplying =
    '(SELECT applying FROM $listeningSyncStateTable WHERE id = 1) = 0';

/// Creates the sync tables, an index for matching songs by title and
/// artist, and the triggers, and seeds this device's existing totals so the
/// first sync merges both devices' statistics. Idempotent.
Future<void> createLinkHistorySyncSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $listeningSyncStateTable (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      device_id TEXT NOT NULL,
      seq INTEGER NOT NULL DEFAULT 0,
      applying INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute(
    'INSERT OR IGNORE INTO $listeningSyncStateTable (id, device_id) '
    'VALUES (1, lower(hex(randomblob(16))))',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $listeningSyncTable (
      origin TEXT NOT NULL,
      day TEXT NOT NULL,
      track_key TEXT NOT NULL,
      local_key TEXT NOT NULL,
      title TEXT NOT NULL,
      artist TEXT NOT NULL,
      album TEXT NOT NULL,
      artwork TEXT,
      milliseconds INTEGER NOT NULL DEFAULT 0,
      plays INTEGER NOT NULL DEFAULT 0,
      seq INTEGER NOT NULL,
      PRIMARY KEY (origin, day, track_key)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_${listeningSyncTable}_seq '
    'ON $listeningSyncTable(seq)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_${listeningSyncTable}_origin_key '
    'ON $listeningSyncTable(origin, track_key)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_listening_title_artist '
    'ON listening(title COLLATE NOCASE, artist COLLATE NOCASE)',
  );
  await db.execute('''
    INSERT OR IGNORE INTO $listeningSyncTable
      (origin, day, track_key, local_key, title, artist, album, artwork,
       milliseconds, plays, seq)
    SELECT s.device_id, l.day, l.track_key, l.track_key, l.title, l.artist,
      l.album, l.artwork, l.milliseconds, l.plays, 0
    FROM listening l, $listeningSyncStateTable s
    WHERE s.id = 1 AND (l.milliseconds > 0 OR l.plays > 0)
    ORDER BY l.rowid
  ''');
  await db.execute('''
    UPDATE $listeningSyncTable
    SET seq = (SELECT seq FROM $listeningSyncStateTable WHERE id = 1) + rowid
    WHERE seq = 0
  ''');
  await db.execute('''
    UPDATE $listeningSyncStateTable
    SET seq = MAX(seq, COALESCE((SELECT MAX(seq) FROM $listeningSyncTable), 0))
    WHERE id = 1
  ''');
  await db.execute(
    'CREATE TRIGGER IF NOT EXISTS listening_sync_insert AFTER INSERT ON listening '
    'WHEN $_notApplying AND (NEW.milliseconds > 0 OR NEW.plays > 0) '
    'BEGIN ${_recordGrowth('NEW.milliseconds', 'NEW.plays')} END',
  );
  await db.execute(
    'CREATE TRIGGER IF NOT EXISTS listening_sync_update AFTER UPDATE ON listening '
    'WHEN $_notApplying AND '
    '(NEW.milliseconds > OLD.milliseconds OR NEW.plays > OLD.plays) '
    'BEGIN ${_recordGrowth('NEW.milliseconds - OLD.milliseconds', 'NEW.plays - OLD.plays')} END',
  );
}
