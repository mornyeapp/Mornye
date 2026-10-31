import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Repairs missing statistics covers independently of listening counters and
/// their cursors. Only requested covers travel, and each receiver keeps its
/// own thumbnail so it also works while the other device is disconnected.
class LinkHistoryArtwork {
  LinkHistoryArtwork(
    this._store, {
    Future<Directory> Function()? directory,
    Future<String?> Function(String)? localFile,
  }) : _directory = directory ?? _defaultDirectory,
       _localFile = localFile ?? _cachedFile;

  static const pageSize = 100;
  static const batchSize = 4;
  static const maxCoverBytes = 512 * 1024;
  static const maxSourceBytes = 24 * 1024 * 1024;
  static const maxStoreBytes = 128 * 1024 * 1024;
  static const _maxEncodedBytes = ((maxCoverBytes + 2) ~/ 3) * 4;

  final LinkHistorySyncStore _store;
  final Future<Directory> Function() _directory;
  final Future<String?> Function(String) _localFile;
  List<_ArtworkTrack>? _tracks;
  List<_ArtworkTrack>? _indexedRows;
  final _bySong = <(String, String), List<_ArtworkTrack>>{};
  DateTime? _readAt;
  final _files = <String, Future<String?>>{};
  final _exports = <String, Future<Map<String, String>?>>{};
  Future<void> _writes = Future.value();
  int? _storedBytes;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'listening_covers'),
  );

  static Future<String?> _cachedFile(String reference) async {
    final value = normalizeStoredCoverReference(reference);
    if (value == null) return null;
    String? path;
    if (CoverStore.fetches(value)) {
      await CoverStore.instance.warmUp();
      path = CoverStore.instance.indexedFile(value);
    } else if (File(value).isAbsolute) {
      path = value;
    } else {
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.isScheme('file')) return null;
      try {
        path = uri.toFilePath();
      } on UnsupportedError {
        return null;
      }
    }
    return path != null && await File(path).exists() ? path : null;
  }

  Future<List<_ArtworkTrack>> _snapshot({bool refresh = false}) async {
    if (!refresh &&
        _tracks != null &&
        DateTime.now().difference(_readAt!) < const Duration(seconds: 30)) {
      return _tracks!;
    }
    final rows = await (await _store.database).rawQuery('''
      SELECT details.track_key, details.title, details.artist, details.album,
        covered.artwork
      FROM (
        SELECT track_key, MAX(day) AS last_day,
          MAX(CASE WHEN LENGTH(TRIM(artwork)) > 0 THEN day END) AS cover_day
        FROM listening GROUP BY track_key
        HAVING SUM(milliseconds) > 0 OR SUM(plays) > 0
      ) AS totals
      JOIN listening AS details ON details.track_key = totals.track_key
        AND details.day = totals.last_day
      LEFT JOIN listening AS covered ON covered.track_key = totals.track_key
        AND covered.day = totals.cover_day
      ORDER BY details.track_key
    ''');
    _files.clear();
    _exports.clear();
    _storedBytes = null;
    _readAt = DateTime.now();
    return _tracks = [
      for (final row in rows)
        _ArtworkTrack(
          row['track_key']! as String,
          row['title']! as String,
          row['artist']! as String,
          row['album']! as String,
          row['artwork'] as String?,
        ),
    ]..sort((a, b) => a.key.compareTo(b.key));
  }

  Future<String?> _file(String reference) =>
      _files.putIfAbsent(reference, () async {
        try {
          return await _localFile(reference);
        } on FileSystemException {
          return null;
        }
      });

  Future<bool> _available(_ArtworkTrack track) async {
    final artwork = track.artwork;
    return artwork != null &&
        (linkSyncRemoteArtwork(artwork) != null ||
            await _file(artwork) != null);
  }

  List<_ArtworkTrack> _matches(_ArtworkTrack wanted, List<_ArtworkTrack> rows) {
    if (!identical(_indexedRows, rows)) {
      _bySong.clear();
      for (final row in rows) {
        _bySong.putIfAbsent((row.titleKey, row.artistKey), () => []).add(row);
      }
      _indexedRows = rows;
    }
    final songs = _bySong[(wanted.titleKey, wanted.artistKey)] ?? const [];
    final exact = songs
        .where((row) => row.albumKey == wanted.albumKey)
        .toList();
    if (exact.isNotEmpty) return exact;
    // Missing album tags may match only one release, never an ambiguous one.
    final candidates = songs.toList();
    if (candidates.map((row) => row.albumKey).toSet().length == 1 &&
        (wanted.albumKey.isEmpty ||
            candidates.every((row) => row.albumKey.isEmpty))) {
      return candidates;
    }
    return const [];
  }

  Future<Map<String, dynamic>?> _cover(
    _ArtworkTrack wanted,
    List<_ArtworkTrack> rows,
  ) async {
    for (final track in _matches(wanted, rows)) {
      final reference = track.artwork;
      if (reference == null) continue;
      final url = linkSyncRemoteArtwork(reference);
      if (url != null) return {'track': wanted.toJson(), 'url': url};
      final path = await _file(reference);
      if (path == null) continue;
      // A first sync may repair thousands of songs. Retain only a few
      // encoded thumbnails, rather than their combined payload in memory.
      if (!_exports.containsKey(path) && _exports.length >= 8) {
        _exports.remove(_exports.keys.first);
      }
      final exported = await _exports.putIfAbsent(path, () async {
        try {
          final source = File(path);
          if (await source.length() > maxSourceBytes) return null;
          final builder = BytesBuilder(copy: false);
          await for (final chunk in source.openRead(0, maxSourceBytes + 1)) {
            builder.add(chunk);
          }
          if (builder.length > maxSourceBytes) return null;
          final bytes = await shrinkLinkCover(
            builder.takeBytes(),
            maxSize: 256,
          );
          if (bytes == null || bytes.length > maxCoverBytes) return null;
          return {'data': base64Encode(bytes)};
        } on FileSystemException {
          return null;
        }
      });
      if (exported != null) return {'track': wanted.toJson(), ...exported};
    }
    return null;
  }

  Future<String?> _save(Uint8List bytes) async {
    final root = await _directory();
    await root.create(recursive: true);
    final name = sha256.convert(bytes).toString();
    final target = File(p.join(root.path, '$name.png'));
    if (await target.exists()) return target.path;
    if (_storedBytes == null) {
      var total = 0;
      await for (final entry in root.list()) {
        if (entry is File) total += await entry.length();
      }
      _storedBytes = total;
    }
    if (_storedBytes! + bytes.length > maxStoreBytes) return null;
    final staged = File('${target.path}.part');
    try {
      await staged.writeAsBytes(bytes, flush: true);
      await staged.rename(target.path);
      _storedBytes = _storedBytes! + bytes.length;
      return target.path;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<int> _apply(List<dynamic> covers) {
    final result = _writes.then((_) async {
      final rows = await _snapshot();
      var changed = 0;
      for (final cover in covers) {
        if (cover is! Map) continue;
        final wanted = _ArtworkTrack.fromJson(cover['track']);
        if (wanted == null) continue;
        final missing = <_ArtworkTrack>[];
        for (final track in _matches(wanted, rows)) {
          if (!await _available(track)) missing.add(track);
        }
        if (missing.isEmpty) continue;
        String? artwork = linkSyncRemoteArtwork(cover['url']);
        if (artwork == null) {
          final data = cover['data'];
          if (data is! String || data.length > _maxEncodedBytes) continue;
          final Uint8List input;
          try {
            input = base64Decode(data);
          } on FormatException {
            continue;
          }
          if (input.isEmpty || input.length > maxCoverBytes) continue;
          // Validate and bound decoded dimensions before persisting peer bytes.
          final bytes = await shrinkLinkCover(input, maxSize: 256);
          if (bytes == null || bytes.length > maxCoverBytes) continue;
          try {
            artwork = await _save(bytes);
          } on FileSystemException {
            // A full or unavailable cache must not interrupt history sync.
            continue;
          }
        }
        if (artwork == null) continue;
        final db = await _store.database;
        for (final track in missing) {
          changed += await db.rawUpdate(
            'UPDATE listening SET artwork = ? WHERE track_key = ? '
            "AND (artwork IS NULL OR TRIM(artwork) = '' OR artwork = ?)",
            [artwork, track.key, track.artwork],
          );
          track.artwork = artwork;
        }
      }
      return changed;
    });
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Authenticated history/artwork requests forwarded by the Link host.
  Future<Map<String, dynamic>> handle(LinkRequest request) async {
    final args = request.args;
    if (request.method == 'GET') {
      final after = args['after'] as String? ?? '';
      final rows = await _snapshot(refresh: after.isEmpty);
      final page = rows
          .where((row) => row.key.compareTo(after) > 0)
          .take(pageSize)
          .toList();
      final missing = <Map<String, dynamic>>[];
      final available = <String>{};
      for (final track in page) {
        if (!await _available(track)) {
          missing.add(track.toJson());
        } else {
          available.add(track.identity);
          // An album-less tag can use a cover only for an unambiguous release.
          _matches(track, rows);
          final songs = _bySong[(track.titleKey, track.artistKey)]!;
          if (songs.map((song) => song.albumKey).toSet().length == 1) {
            available.add(track.withoutAlbum);
          }
        }
      }
      return {
        'tracks': missing,
        'available': available.toList(),
        'cursor': page.lastOrNull?.key ?? after,
        'more': page.length == pageSize,
      };
    }
    final want = args['want'];
    final covers = args['covers'];
    if (want is List && want.length <= batchSize) {
      final rows = await _snapshot();
      return {
        'covers': [
          for (final item in want)
            if (_ArtworkTrack.fromJson(item) case final track?)
              ?await _cover(track, rows),
        ],
      };
    }
    if (covers is List && covers.length <= batchSize) {
      return {'applied': await _apply(covers)};
    }
    throw const LinkException('invalid', 'Invalid history artwork batch');
  }

  /// Repairs both directions, including entries whose time never changed
  /// since the original history sync. Old peers simply lack this endpoint.
  Future<int> sync(LinkClientApi client) async {
    final rows = await _snapshot(refresh: true);
    final available = <String>{};
    var after = '';
    while (true) {
      final reply = await client.get(LinkOps.historyArtwork, {'after': after});
      if (reply is! Map || reply['tracks'] is! List) {
        throw const LinkException('invalid', 'Malformed history artwork page');
      }
      final tracks = reply['tracks'] as List;
      final held = reply['available'];
      if (held is! List || held.length > pageSize * 2) {
        throw const LinkException(
          'invalid',
          'Malformed history artwork inventory',
        );
      }
      for (final id in held) {
        if (id is String && id.length == 64) available.add(id);
      }
      if (tracks.length > pageSize) {
        throw const LinkException('invalid', 'History artwork page too large');
      }
      for (var start = 0; start < tracks.length; start += batchSize) {
        final covers = <Map<String, dynamic>>[];
        for (final item in tracks.skip(start).take(batchSize)) {
          final track = _ArtworkTrack.fromJson(item);
          if (track == null) continue;
          final cover = await _cover(track, rows);
          if (cover != null) covers.add(cover);
        }
        if (covers.isNotEmpty) {
          await client.post(LinkOps.historyArtwork, {'covers': covers});
        }
      }
      if (reply['more'] != true) break;
      final next = reply['cursor'];
      if (next is! String || next.compareTo(after) <= 0) {
        throw const LinkException(
          'invalid',
          'History artwork cursor did not advance',
        );
      }
      after = next;
    }
    final missing = <_ArtworkTrack>[];
    for (final track in rows) {
      if ((available.contains(track.identity) ||
              available.contains(track.withoutAlbum)) &&
          !await _available(track)) {
        missing.add(track);
      }
    }
    var changed = 0;
    for (var start = 0; start < missing.length; start += batchSize) {
      final reply = await client.post(LinkOps.historyArtwork, {
        'want': [
          for (final track in missing.skip(start).take(batchSize))
            track.toJson(),
        ],
      });
      if (reply is! Map ||
          reply['covers'] is! List ||
          (reply['covers'] as List).length > batchSize) {
        throw const LinkException('invalid', 'Malformed history artwork batch');
      }
      changed += await _apply(reply['covers'] as List);
    }
    return changed;
  }
}

class _ArtworkTrack {
  _ArtworkTrack(this.key, this.title, this.artist, this.album, [this.artwork]);

  final String key, title, artist, album;
  String? artwork;
  late final titleKey = _normalize(title);
  late final artistKey = _normalize(artist);
  late final albumKey = _normalize(album);
  late final identity = sha256
      .convert(utf8.encode(jsonEncode([titleKey, artistKey, albumKey])))
      .toString();
  late final withoutAlbum = sha256
      .convert(utf8.encode(jsonEncode([titleKey, artistKey, ''])))
      .toString();

  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Map<String, dynamic> toJson() => {
    'key': key,
    'title': title,
    'artist': artist,
    'album': album,
  };

  static _ArtworkTrack? fromJson(Object? value) {
    if (value is! Map) return null;
    final parts = [
      value['key'],
      value['title'],
      value['artist'],
      value['album'],
    ];
    if (parts.any((part) => part is! String || part.length > 4096)) return null;
    if ((parts[0] as String).isEmpty || (parts[1] as String).trim().isEmpty) {
      return null;
    }
    return _ArtworkTrack(
      parts[0] as String,
      parts[1] as String,
      parts[2] as String,
      parts[3] as String,
    );
  }
}

final linkHistoryArtworkProvider = Provider<LinkHistoryArtwork>(
  (ref) => LinkHistoryArtwork(ref.watch(linkHistorySyncStoreProvider)),
);
