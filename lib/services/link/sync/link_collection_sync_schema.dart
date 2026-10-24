import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';

/// Change tracking for the collections database (Mornye Link sync).
///
/// `link_sync_state` holds this database's random sync device id, the
/// sequence counter, and, only inside a transaction that applies peer
/// changes, the author and timestamp of the change being written.
/// `link_sync_changes` keeps one row per collection key: its latest
/// sequence, timestamp, author and whether it is a tombstone.
///
/// SQLite triggers on the collection tables record every writer (Dart,
/// native publication, backup restore) without Dart bookkeeping. They only
/// use SQL that the oldest supported Android SQLite understands (no UPSERT).
const linkSyncStateTable = 'link_sync_state';
const linkSyncChangesTable = 'link_sync_changes';

/// Unix milliseconds in SQL.
const _nowMs = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

String _isoToMs(String column) =>
    'COALESCE(CAST((julianday($column) - 2440587.5) * 86400000 AS INTEGER), 0)';

typedef _TrackedTable = ({
  String table,
  String kind,
  String? scopeColumn,
  String keyColumn,
  String seedTimeColumn,

  /// When set, an update records a change only if one of these columns
  /// changed (playlists: the name, not the timestamps or device cover).
  List<String>? updateColumns,
});

const List<_TrackedTable> _trackedTables = [
  (
    table: 'playlists',
    kind: LinkSyncKinds.playlist,
    scopeColumn: null,
    keyColumn: 'id',
    seedTimeColumn: 'updated_at',
    updateColumns: ['name', 'id'],
  ),
  (
    table: 'playlist_tracks',
    kind: LinkSyncKinds.playlistTrack,
    scopeColumn: 'playlist_id',
    keyColumn: 'track_key',
    seedTimeColumn: 'added_at',
    updateColumns: null,
  ),
  (
    table: 'loved_tracks',
    kind: LinkSyncKinds.loved,
    scopeColumn: null,
    keyColumn: 'track_key',
    seedTimeColumn: 'added_at',
    updateColumns: null,
  ),
  (
    table: 'wishlist_tracks',
    kind: LinkSyncKinds.wishlist,
    scopeColumn: null,
    keyColumn: 'track_key',
    seedTimeColumn: 'added_at',
    updateColumns: null,
  ),
  (
    table: 'favorite_artists',
    kind: LinkSyncKinds.favoriteArtist,
    scopeColumn: null,
    keyColumn: 'artist_key',
    seedTimeColumn: 'added_at',
    updateColumns: null,
  ),
];

/// Records one change for the row alias [row] (`NEW` or `OLD`). A local
/// edit is stamped at least one millisecond after the version it replaces;
/// a peer change keeps the author and timestamp set in the state row.
String _recordChange(
  _TrackedTable tracked,
  String row, {
  required bool deleted,
}) {
  final scope = tracked.scopeColumn == null
      ? "''"
      : '$row.${tracked.scopeColumn}';
  final key = '$row.${tracked.keyColumn}';
  return '''
    UPDATE $linkSyncStateTable SET seq = seq + 1 WHERE id = 1;
    INSERT OR REPLACE INTO $linkSyncChangesTable
      (kind, scope, key, seq, updated_ms, deleted, origin)
    SELECT '${tracked.kind}', $scope, $key, s.seq,
      CASE WHEN s.apply_origin IS NULL THEN MAX($_nowMs, COALESCE((
        SELECT c.updated_ms + 1 FROM $linkSyncChangesTable c
        WHERE c.kind = '${tracked.kind}' AND c.scope = $scope AND c.key = $key
      ), 0)) ELSE s.apply_updated_ms END,
      ${deleted ? 1 : 0}, COALESCE(s.apply_origin, s.device_id)
    FROM $linkSyncStateTable s WHERE s.id = 1;''';
}

List<String> _triggers(_TrackedTable tracked) {
  final name = 'link_sync_${tracked.table}';
  final keyColumns = [?tracked.scopeColumn, tracked.keyColumn];
  final rekeyed = keyColumns
      .map((column) => 'OLD.$column IS NOT NEW.$column')
      .join(' OR ');
  final updateColumns = tracked.updateColumns;
  final updateCondition = updateColumns == null
      ? ''
      : 'OF ${updateColumns.join(', ')} ON ${tracked.table} WHEN '
            '${updateColumns.map((column) => 'OLD.$column IS NOT NEW.$column').join(' OR ')}';
  return [
    'CREATE TRIGGER IF NOT EXISTS ${name}_insert AFTER INSERT ON ${tracked.table} '
        'BEGIN ${_recordChange(tracked, 'NEW', deleted: false)} END',
    'CREATE TRIGGER IF NOT EXISTS ${name}_delete AFTER DELETE ON ${tracked.table} '
        'BEGIN ${_recordChange(tracked, 'OLD', deleted: true)} END',
    'CREATE TRIGGER IF NOT EXISTS ${name}_rekey AFTER UPDATE ON ${tracked.table} '
        'WHEN $rekeyed '
        'BEGIN ${_recordChange(tracked, 'OLD', deleted: true)} END',
    'CREATE TRIGGER IF NOT EXISTS ${name}_update AFTER UPDATE '
        '${updateCondition.isEmpty ? 'ON ${tracked.table}' : updateCondition} '
        'BEGIN ${_recordChange(tracked, 'NEW', deleted: false)} END',
  ];
}

/// Creates the change tables and triggers and records every existing row as
/// a change by this device (seeded once, timestamped from the row's own
/// date), so the first sync merges both devices' collections. Idempotent.
Future<void> createLinkCollectionSyncSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $linkSyncStateTable (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      device_id TEXT NOT NULL,
      seq INTEGER NOT NULL DEFAULT 0,
      apply_origin TEXT,
      apply_updated_ms INTEGER
    )
  ''');
  await db.execute(
    'INSERT OR IGNORE INTO $linkSyncStateTable (id, device_id, seq) '
    'VALUES (1, lower(hex(randomblob(16))), 0)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $linkSyncChangesTable (
      kind TEXT NOT NULL,
      scope TEXT NOT NULL,
      key TEXT NOT NULL,
      seq INTEGER NOT NULL,
      updated_ms INTEGER NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      origin TEXT NOT NULL,
      PRIMARY KEY (kind, scope, key)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_${linkSyncChangesTable}_seq '
    'ON $linkSyncChangesTable(seq)',
  );
  for (final tracked in _trackedTables) {
    await db.execute('''
      INSERT OR IGNORE INTO $linkSyncChangesTable
        (kind, scope, key, seq, updated_ms, deleted, origin)
      SELECT '${tracked.kind}', ${tracked.scopeColumn ?? "''"},
        ${tracked.keyColumn}, 0, ${_isoToMs(tracked.seedTimeColumn)}, 0,
        (SELECT device_id FROM $linkSyncStateTable WHERE id = 1)
      FROM ${tracked.table} ORDER BY rowid
    ''');
  }
  await db.execute('''
    UPDATE $linkSyncChangesTable
    SET seq = (SELECT seq FROM $linkSyncStateTable WHERE id = 1) + rowid
    WHERE seq = 0
  ''');
  await db.execute('''
    UPDATE $linkSyncStateTable
    SET seq = MAX(seq, COALESCE((SELECT MAX(seq) FROM $linkSyncChangesTable), 0))
    WHERE id = 1
  ''');
  for (final tracked in _trackedTables) {
    for (final trigger in _triggers(tracked)) {
      await db.execute(trigger);
    }
  }
}
