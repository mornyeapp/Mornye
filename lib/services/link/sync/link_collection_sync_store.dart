import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/sync/link_collection_sync_schema.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkCollectionSync');

/// Old Android SQLite allows 999 bound parameters per statement.
const _chunkSize = 400;

const _trackTables = {
  LinkSyncKinds.loved: 'loved_tracks',
  LinkSyncKinds.wishlist: 'wishlist_tracks',
};

typedef _Identity = (String kind, String scope, String key);

class _Record {
  const _Record(
    this.kind,
    this.scope,
    this.key,
    this.updatedMs,
    this.deleted,
    this.origin,
  );

  factory _Record.fromRow(Map<String, Object?> row) => _Record(
    row['kind']! as String,
    row['scope']! as String,
    row['key']! as String,
    row['updated_ms']! as int,
    row['deleted'] == 1,
    row['origin']! as String,
  );

  final String kind;
  final String scope;
  final String key;
  final int updatedMs;
  final bool deleted;
  final String origin;

  _Identity get identity => (kind, scope, key);
}

/// The outcome of applying a batch of peer changes.
class LinkSyncApplyResult {
  const LinkSyncApplyResult({required this.applied, required this.latest});

  /// Changes that won last writer wins and were written.
  final int applied;

  /// The receiver's newest sequence afterwards.
  final int latest;
}

Iterable<List<T>> _chunks<T>(List<T> values) sync* {
  for (var start = 0; start < values.length; start += _chunkSize) {
    yield values.sublist(
      start,
      start + _chunkSize < values.length ? start + _chunkSize : values.length,
    );
  }
}

String _placeholders(int count) => List.filled(count, '?').join(',');

Map<String, dynamic>? _decodeMap(Object? json) {
  if (json is! String) return null;
  try {
    final decoded = jsonDecode(json);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

/// Reads and writes collection changes for Mornye Link sync. The desktop
/// serves pages from it and applies phone changes; the phone does the
/// reverse with its own database.
class LinkCollectionSyncStore {
  LinkCollectionSyncStore(this._open);

  final Future<Database> Function() _open;
  String? _deviceId;

  Future<Database> get database => _open();

  /// This database's sync device id (the `origin` of its local changes).
  Future<String> deviceId() async {
    final cached = _deviceId;
    if (cached != null) return cached;
    final rows = await (await _open()).rawQuery(
      'SELECT device_id FROM $linkSyncStateTable WHERE id = 1',
    );
    return _deviceId = rows.first['device_id']! as String;
  }

  /// The newest sequence number.
  Future<int> latestSeq() async {
    final rows = await (await _open()).rawQuery(
      'SELECT seq FROM $linkSyncStateTable WHERE id = 1',
    );
    return rows.first['seq']! as int;
  }

  /// The sequence of the newest change this device authored, or 0.
  Future<int> latestLocalSeq() async {
    final rows = await (await _open()).rawQuery('''
      SELECT c.seq FROM $linkSyncChangesTable c, $linkSyncStateTable s
      WHERE s.id = 1 AND c.origin = s.device_id
      ORDER BY c.seq DESC LIMIT 1
    ''');
    return rows.isEmpty ? 0 : rows.first['seq']! as int;
  }

  /// Changes after [since], oldest first. [excludeOrigin] skips changes that
  /// device authored (it already has them); [localOnly] keeps only changes
  /// this device authored. Live playlist members bring their playlist's
  /// record along so the receiver can create the playlist first.
  Future<LinkSyncPage<LinkSyncChange>> changesSince(
    int since, {
    String? excludeOrigin,
    bool localOnly = false,
    int limit = linkSyncPageSize,
  }) async {
    final pageSize = limit.clamp(1, linkSyncPageSize);
    final db = await _open();
    return db.transaction((txn) async {
      final state = (await txn.rawQuery(
        'SELECT device_id, seq FROM $linkSyncStateTable WHERE id = 1',
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
        'SELECT kind, scope, key, seq, updated_ms, deleted, origin '
        'FROM $linkSyncChangesTable WHERE ${filters.join(' AND ')} '
        'ORDER BY seq LIMIT ?',
        [...arguments, pageSize],
      );
      final more = rows.length >= pageSize;
      final cursor = more ? rows.last['seq']! as int : latest;
      final records = rows.map(_Record.fromRow).toList();
      final pagePlaylists = {
        for (final record in records)
          if (record.kind == LinkSyncKinds.playlist) record.key,
      };
      final parents = {
        for (final record in records)
          if (record.kind == LinkSyncKinds.playlistTrack &&
              !record.deleted &&
              !pagePlaylists.contains(record.scope))
            record.scope,
      }.toList();
      final related = <_Record>[];
      for (final chunk in _chunks(parents)) {
        final parentRows = await txn.rawQuery(
          'SELECT kind, scope, key, seq, updated_ms, deleted, origin '
          'FROM $linkSyncChangesTable '
          "WHERE kind = ? AND scope = '' AND key IN (${_placeholders(chunk.length)})",
          [LinkSyncKinds.playlist, ...chunk],
        );
        related.addAll(parentRows.map(_Record.fromRow));
      }
      final changes = await _withData(txn, [...related, ...records]);
      return LinkSyncPage(
        device: device,
        cursor: cursor,
        latest: latest,
        more: more,
        items: changes,
      );
    });
  }

  Future<List<LinkSyncChange>> _withData(
    DatabaseExecutor db,
    List<_Record> records,
  ) async {
    final data = <_Identity, Map<String, dynamic>>{};
    final live = records.where((record) => !record.deleted).toList();
    for (final MapEntry(key: kind, value: table) in _trackTables.entries) {
      final keys = [
        for (final record in live)
          if (record.kind == kind) record.key,
      ];
      for (final chunk in _chunks(keys)) {
        final rows = await db.rawQuery(
          'SELECT track_key, track_json, added_at FROM $table '
          'WHERE track_key IN (${_placeholders(chunk.length)})',
          chunk,
        );
        for (final row in rows) {
          final track = _decodeMap(row['track_json']);
          if (track == null) continue;
          data[(kind, '', row['track_key']! as String)] = {
            'track': track,
            'addedMs': ?linkSyncIsoToMs(row['added_at']),
          };
        }
      }
    }
    final artistKeys = [
      for (final record in live)
        if (record.kind == LinkSyncKinds.favoriteArtist) record.key,
    ];
    for (final chunk in _chunks(artistKeys)) {
      final rows = await db.rawQuery(
        'SELECT artist_key, artist_json, added_at FROM favorite_artists '
        'WHERE artist_key IN (${_placeholders(chunk.length)})',
        chunk,
      );
      for (final row in rows) {
        final artist = _decodeMap(row['artist_json']);
        if (artist == null) continue;
        data[(LinkSyncKinds.favoriteArtist, '', row['artist_key']! as String)] =
            {'artist': artist, 'addedMs': ?linkSyncIsoToMs(row['added_at'])};
      }
    }
    final playlistIds = [
      for (final record in live)
        if (record.kind == LinkSyncKinds.playlist) record.key,
    ];
    for (final chunk in _chunks(playlistIds)) {
      final rows = await db.rawQuery(
        'SELECT id, name, created_at, updated_at FROM playlists '
        'WHERE id IN (${_placeholders(chunk.length)})',
        chunk,
      );
      for (final row in rows) {
        data[(LinkSyncKinds.playlist, '', row['id']! as String)] = {
          'name': row['name'] as String? ?? '',
          'createdMs': ?linkSyncIsoToMs(row['created_at']),
          'updatedMs': ?linkSyncIsoToMs(row['updated_at']),
        };
      }
    }
    final members = <String, List<String>>{};
    for (final record in live) {
      if (record.kind != LinkSyncKinds.playlistTrack) continue;
      members.putIfAbsent(record.scope, () => []).add(record.key);
    }
    for (final MapEntry(key: playlistId, value: keys) in members.entries) {
      for (final chunk in _chunks(keys)) {
        final rows = await db.rawQuery(
          'SELECT track_key, track_json, added_at FROM playlist_tracks '
          'WHERE playlist_id = ? AND track_key IN (${_placeholders(chunk.length)})',
          [playlistId, ...chunk],
        );
        for (final row in rows) {
          final track = _decodeMap(row['track_json']);
          if (track == null) continue;
          data[(
            LinkSyncKinds.playlistTrack,
            playlistId,
            row['track_key']! as String,
          )] = {
            'track': track,
            'addedMs': ?linkSyncIsoToMs(row['added_at']),
          };
        }
      }
    }
    final changes = <LinkSyncChange>[];
    var missing = 0;
    for (final record in records) {
      final payload = record.deleted ? null : data[record.identity];
      if (!record.deleted && payload == null) {
        missing++;
        continue;
      }
      changes.add(
        LinkSyncChange(
          kind: record.kind,
          playlistId: record.scope,
          key: record.key,
          deleted: record.deleted,
          updatedMs: record.updatedMs,
          origin: record.origin,
          data: payload,
        ),
      );
    }
    if (missing > 0) {
      _log.w('Skipped $missing live changes without a readable row');
    }
    return changes;
  }

  /// Applies peer [changes] in one transaction by last writer wins. Rows are
  /// written with the author and timestamp set in the state row, so the
  /// triggers record them as the author's changes, not as local ones.
  Future<LinkSyncApplyResult> apply(Iterable<LinkSyncChange> changes) async {
    final incoming = <_Identity, LinkSyncChange>{};
    for (final change in changes) {
      final identity = (change.kind, change.playlistId, change.key);
      final previous = incoming[identity];
      if (previous == null ||
          change.winsOver(
            updatedMs: previous.updatedMs,
            origin: previous.origin,
          )) {
        incoming[identity] = change;
      }
    }
    final db = await _open();
    return sqlite.transactionWithBusyRetry(db, (txn) async {
      final local = <_Identity, (int, String)>{};
      final groups = <(String, String), List<String>>{};
      for (final (kind, scope, key) in incoming.keys) {
        groups.putIfAbsent((kind, scope), () => []).add(key);
      }
      for (final MapEntry(key: (kind, scope), value: keys) in groups.entries) {
        for (final chunk in _chunks(keys)) {
          final rows = await txn.rawQuery(
            'SELECT key, updated_ms, origin FROM $linkSyncChangesTable '
            'WHERE kind = ? AND scope = ? AND key IN (${_placeholders(chunk.length)})',
            [kind, scope, ...chunk],
          );
          for (final row in rows) {
            local[(kind, scope, row['key']! as String)] = (
              row['updated_ms']! as int,
              row['origin']! as String,
            );
          }
        }
      }
      final winners = <LinkSyncChange>[];
      for (final MapEntry(key: identity, value: change) in incoming.entries) {
        final version = local[identity];
        if (version == null ||
            change.winsOver(updatedMs: version.$1, origin: version.$2)) {
          winners.add(change);
        }
      }
      final playlistIds = {
        for (final change in winners)
          change.kind == LinkSyncKinds.playlist
              ? change.key
              : change.playlistId,
      }..remove('');
      final playlists = <String>{};
      for (final chunk in _chunks(playlistIds.toList())) {
        final rows = await txn.rawQuery(
          'SELECT id FROM playlists WHERE id IN (${_placeholders(chunk.length)})',
          chunk,
        );
        playlists.addAll(rows.map((row) => row['id']! as String));
      }
      final batch = txn.batch();
      var applied = 0;
      for (final change in [
        ...winners.where((change) => change.kind == LinkSyncKinds.playlist),
        ...winners.where((change) => change.kind != LinkSyncKinds.playlist),
      ]) {
        if (_write(batch, change, playlists)) applied++;
      }
      if (applied > 0) {
        batch.rawUpdate(
          'UPDATE $linkSyncStateTable '
          'SET apply_origin = NULL, apply_updated_ms = NULL WHERE id = 1',
        );
        await batch.commit(noResult: true);
      }
      final latest = await txn.rawQuery(
        'SELECT seq FROM $linkSyncStateTable WHERE id = 1',
      );
      return LinkSyncApplyResult(
        applied: applied,
        latest: latest.first['seq']! as int,
      );
    });
  }

  /// Queues the writes for one winning change. Returns false when the change
  /// cannot be applied (malformed data, or a member of a missing playlist).
  bool _write(Batch batch, LinkSyncChange change, Set<String> playlists) {
    final data = change.data ?? const <String, dynamic>{};
    final addedAt = linkSyncMsToIso(
      linkSyncInt(data['addedMs']) ?? change.updatedMs,
    );
    final changeAt = linkSyncMsToIso(change.updatedMs);
    final writes = <void Function()>[];
    switch (change.kind) {
      case LinkSyncKinds.loved || LinkSyncKinds.wishlist:
        final table = _trackTables[change.kind]!;
        if (change.deleted) {
          writes.add(
            () => batch.delete(
              table,
              where: 'track_key = ?',
              whereArgs: [change.key],
            ),
          );
        } else {
          final track = data['track'];
          if (track is! Map) return false;
          writes.add(
            () => batch.insert(table, {
              'track_key': change.key,
              'track_json': jsonEncode(track),
              'added_at': addedAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace),
          );
        }
      case LinkSyncKinds.favoriteArtist:
        if (change.deleted) {
          writes.add(
            () => batch.delete(
              'favorite_artists',
              where: 'artist_key = ?',
              whereArgs: [change.key],
            ),
          );
        } else {
          final artist = data['artist'];
          if (artist is! Map) return false;
          writes.add(
            () => batch.insert('favorite_artists', {
              'artist_key': change.key,
              'artist_json': jsonEncode(artist),
              'added_at': addedAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace),
          );
        }
      case LinkSyncKinds.playlist:
        if (change.deleted) {
          // The foreign key cascade removes (and records) its members.
          playlists.remove(change.key);
          writes.add(
            () => batch.delete(
              'playlists',
              where: 'id = ?',
              whereArgs: [change.key],
            ),
          );
        } else {
          final name = data['name'];
          if (name is! String) return false;
          final updatedAt = linkSyncMsToIso(
            linkSyncInt(data['updatedMs']) ?? change.updatedMs,
          );
          if (playlists.contains(change.key)) {
            // Never REPLACE a playlist: that would cascade its members.
            writes.add(
              () => batch.rawUpdate(
                'UPDATE playlists SET name = ?, updated_at = CASE '
                'WHEN updated_at < ? THEN ? ELSE updated_at END WHERE id = ?',
                [name, updatedAt, updatedAt, change.key],
              ),
            );
          } else {
            playlists.add(change.key);
            writes.add(
              () => batch.insert('playlists', {
                'id': change.key,
                'name': name,
                'cover_image_path': null,
                'created_at': linkSyncMsToIso(
                  linkSyncInt(data['createdMs']) ?? change.updatedMs,
                ),
                'updated_at': updatedAt,
              }),
            );
          }
        }
      case LinkSyncKinds.playlistTrack:
        if (change.deleted) {
          writes.add(
            () => batch.delete(
              'playlist_tracks',
              where: 'playlist_id = ? AND track_key = ?',
              whereArgs: [change.playlistId, change.key],
            ),
          );
        } else {
          final track = data['track'];
          if (track is! Map || !playlists.contains(change.playlistId)) {
            return false;
          }
          writes.add(
            () => batch.insert('playlist_tracks', {
              'playlist_id': change.playlistId,
              'track_key': change.key,
              'track_json': jsonEncode(track),
              'added_at': addedAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace),
          );
        }
        writes.add(
          () => batch.rawUpdate(
            'UPDATE playlists SET updated_at = ? '
            'WHERE id = ? AND updated_at < ?',
            [changeAt, change.playlistId, changeAt],
          ),
        );
      default:
        return false;
    }
    batch.rawUpdate(
      'UPDATE $linkSyncStateTable '
      'SET apply_origin = ?, apply_updated_ms = ? WHERE id = 1',
      [change.origin, change.updatedMs],
    );
    for (final write in writes) {
      write();
    }
    // The triggers skip writes that changed nothing (deleting a missing row,
    // renaming to the same name); record the winning version explicitly.
    batch.rawUpdate(
      'UPDATE $linkSyncStateTable SET seq = seq + 1 WHERE id = 1',
    );
    batch.rawInsert(
      'INSERT OR REPLACE INTO $linkSyncChangesTable '
      '(kind, scope, key, seq, updated_ms, deleted, origin) '
      'SELECT ?, ?, ?, seq, ?, ?, ? FROM $linkSyncStateTable WHERE id = 1',
      [
        change.kind,
        change.playlistId,
        change.key,
        change.updatedMs,
        change.deleted ? 1 : 0,
        change.origin,
      ],
    );
    return true;
  }
}

/// The collections change store of this app's database. Tests override it.
final linkCollectionSyncStoreProvider = Provider<LinkCollectionSyncStore>(
  (ref) => LinkCollectionSyncStore(
    () => LibraryCollectionsDatabase.instance.database,
  ),
);
