import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_collections_database.dart';

const _workerRowThreshold = 64;
const _workerJsonThreshold = 64 * 1024;

/// Small collections avoid isolate startup. Large snapshots leave JSON parsing,
/// model construction and all membership indices on the worker together.
Future<LibraryCollectionsState> hydrateLibraryCollectionsSnapshot(
  LibraryCollectionsSnapshot snapshot,
) async {
  if (snapshot.nativeRowsPath != null) {
    try {
      return await _hydrateRowsInWorker<LibraryCollectionsState>(
        rows: const {},
        nativeRowsPath: snapshot.nativeRowsPath,
        nativeRowCount: snapshot.nativeRowCount,
      );
    } finally {
      await cleanupCollectionRows(
        nativeRowsPath: snapshot.nativeRowsPath,
        nativeRowsDirectory: snapshot.nativeRowsDirectory,
      );
    }
  }
  final rows =
      snapshot.wishlistRows.length +
      snapshot.lovedRows.length +
      snapshot.favoriteArtistRows.length +
      snapshot.playlistRows.length +
      snapshot.playlistTrackRows.length;
  if (rows < _workerRowThreshold &&
      !_hasLargeJson([
        ...snapshot.wishlistRows,
        ...snapshot.lovedRows,
        ...snapshot.favoriteArtistRows,
        ...snapshot.playlistRows,
      ])) {
    return decodeLibraryCollectionsSnapshot(snapshot);
  }
  return _hydrateRowsInWorker<LibraryCollectionsState>(
    rows: {
      _CollectionRows.wishlist: snapshot.wishlistRows,
      _CollectionRows.loved: snapshot.lovedRows,
      _CollectionRows.artists: snapshot.favoriteArtistRows,
      _CollectionRows.membership: snapshot.playlistTrackRows,
      _CollectionRows.playlists: snapshot.playlistRows,
    },
  );
}

LibraryCollectionsState decodeLibraryCollectionsSnapshot(
  LibraryCollectionsSnapshot snapshot,
) {
  final accumulator = _CollectionHydrationAccumulator()
    ..add(_CollectionRows.wishlist, snapshot.wishlistRows)
    ..add(_CollectionRows.loved, snapshot.lovedRows)
    ..add(_CollectionRows.artists, snapshot.favoriteArtistRows)
    ..add(_CollectionRows.membership, snapshot.playlistTrackRows)
    ..add(_CollectionRows.playlists, snapshot.playlistRows);
  return accumulator.finish();
}

List<UserPlaylistCollection> _decodePlaylistRows(
  List<Map<String, dynamic>> rows,
  Map<String, Set<String>> trackKeysByPlaylist,
) {
  final playlists = <UserPlaylistCollection>[];
  for (final row in rows) {
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) continue;
    final createdAtRaw = row['created_at'] as String?;
    final updatedAtRaw = row['updated_at'] as String?;
    final createdAt = DateTime.tryParse(createdAtRaw ?? '') ?? DateTime.now();
    final updatedAt = DateTime.tryParse(updatedAtRaw ?? '') ?? createdAt;
    String? previewCover;
    final previewTrackJson = row['preview_track_json'] as String?;
    if (previewTrackJson != null && previewTrackJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(previewTrackJson);
        if (decoded is Map) previewCover = decoded['coverUrl']?.toString();
      } catch (_) {}
    }
    playlists.add(
      UserPlaylistCollection(
        id: id,
        name: row['name'] as String? ?? '',
        coverImagePath: row['cover_image_path'] as String?,
        createdAt: createdAt,
        updatedAt: updatedAt,
        tracks: const [],
        previewCover: previewCover,
        tracksLoaded: false,
        trackKeys: trackKeysByPlaylist[id],
      ),
    );
  }

  return playlists;
}

class HydratedPlaylistTracks {
  const HydratedPlaylistTracks({
    required this.tracks,
    required this.trackKeys,
    required this.membershipUnchanged,
  });

  final List<CollectionTrackEntry> tracks;
  final Set<String> trackKeys;
  final bool membershipUnchanged;
}

typedef _PlaylistHydrationRequest = ({
  List<Map<String, dynamic>> rows,
  Set<String> knownKeys,
});

Future<HydratedPlaylistTracks> hydratePlaylistTracks(
  List<Map<String, dynamic>> rows, {
  required Set<String> knownKeys,
}) async {
  final request = (rows: rows, knownKeys: knownKeys);
  if (rows.length < _workerRowThreshold && !_hasLargeJson(rows)) {
    return _decodePlaylistTracks(request);
  }
  return _hydrateRowsInWorker<HydratedPlaylistTracks>(
    rows: {_CollectionRows.wishlist: rows},
    knownKeys: knownKeys,
  );
}

Future<HydratedPlaylistTracks> hydratePlaylistTracksSnapshot(
  LibraryPlaylistTracksSnapshot snapshot, {
  required Set<String> knownKeys,
}) async {
  if (snapshot.nativeRowsPath == null) {
    return hydratePlaylistTracks(snapshot.rows, knownKeys: knownKeys);
  }
  try {
    return await _hydrateRowsInWorker<HydratedPlaylistTracks>(
      rows: const {},
      knownKeys: knownKeys,
      nativeRowsPath: snapshot.nativeRowsPath,
      nativeRowCount: snapshot.nativeRowCount,
    );
  } finally {
    await cleanupCollectionRows(
      nativeRowsPath: snapshot.nativeRowsPath,
      nativeRowsDirectory: snapshot.nativeRowsDirectory,
    );
  }
}

Future<void> cleanupCollectionRows({
  String? nativeRowsPath,
  String? nativeRowsDirectory,
}) async {
  try {
    if (nativeRowsDirectory != null) {
      await Directory(nativeRowsDirectory).delete(recursive: true);
    } else if (nativeRowsPath != null) {
      await File(nativeRowsPath).delete();
    }
  } on FileSystemException {
    // The consuming worker may already have removed its row file.
  }
}

HydratedPlaylistTracks _decodePlaylistTracks(
  _PlaylistHydrationRequest request,
) {
  final tracks = _decodeTrackRows(request.rows).toList(growable: false);
  final keys = tracks.map((entry) => entry.key).toSet();
  return HydratedPlaylistTracks(
    tracks: tracks,
    trackKeys: keys,
    membershipUnchanged:
        keys.length == request.knownKeys.length &&
        keys.every(request.knownKeys.contains),
  );
}

List<CollectionTrackEntry> _decodeTrackRows(List<Map<String, dynamic>> rows) =>
    [for (final row in rows) ?_parseTrackRow(row)];

CollectionTrackEntry? _parseTrackRow(Map<String, dynamic> row) {
  final key = row['track_key'] as String?;
  final trackJson = row['track_json'] as String?;
  if (key == null || key.isEmpty || trackJson == null || trackJson.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(trackJson);
    if (decoded is! Map) return null;
    return CollectionTrackEntry(
      key: key,
      track: Track.fromJson(Map<String, dynamic>.from(decoded)),
      addedAt:
          DateTime.tryParse(row['added_at'] as String? ?? '') ?? DateTime.now(),
    );
  } catch (_) {
    return null;
  }
}

CollectionArtistEntry? _parseArtistRow(Map<String, dynamic> row) {
  final key = row['artist_key'] as String?;
  final artistJson = row['artist_json'] as String?;
  if (key == null || key.isEmpty || artistJson == null || artistJson.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(artistJson);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    return CollectionArtistEntry.fromJson({
      ...map,
      'key': key,
      'addedAt': map['addedAt'] ?? row['added_at'],
    });
  } catch (_) {
    return null;
  }
}

bool _hasLargeJson(List<Map<String, dynamic>> rows) {
  var length = 0;
  for (final row in rows) {
    for (final column in ['track_json', 'artist_json', 'preview_track_json']) {
      final value = row[column];
      if (value is String) length += value.length;
    }
    if (length >= _workerJsonThreshold) return true;
  }
  return false;
}

enum _CollectionRows { wishlist, loved, artists, membership, playlists }

class _CollectionHydrationAccumulator {
  final wishlist = <CollectionTrackEntry>[];
  final loved = <CollectionTrackEntry>[];
  final artists = <CollectionArtistEntry>[];
  final playlistRows = <Map<String, dynamic>>[];
  final trackKeysByPlaylist = <String, Set<String>>{};

  void add(_CollectionRows kind, List<Map<String, dynamic>> rows) {
    switch (kind) {
      case _CollectionRows.wishlist:
        wishlist.addAll(_decodeTrackRows(rows));
      case _CollectionRows.loved:
        loved.addAll(_decodeTrackRows(rows));
      case _CollectionRows.artists:
        for (final row in rows) {
          final artist = _parseArtistRow(row);
          if (artist != null) artists.add(artist);
        }
      case _CollectionRows.playlists:
        playlistRows.addAll(rows);
      case _CollectionRows.membership:
        for (final row in rows) {
          final id = row['playlist_id'] as String?;
          final key = row['track_key'] as String?;
          if (id == null || id.isEmpty || key == null || key.isEmpty) continue;
          trackKeysByPlaylist.putIfAbsent(id, () => {}).add(key);
        }
    }
  }

  LibraryCollectionsState finish() => LibraryCollectionsState(
    wishlist: wishlist,
    loved: loved,
    favoriteArtists: artists,
    playlists: _decodePlaylistRows(playlistRows, trackKeysByPlaylist),
    isLoaded: true,
  );
}

enum _CollectionWorkerMode { snapshot, playlist, exportJson }

typedef _CollectionWorkerRequest = ({
  SendPort result,
  _CollectionWorkerMode mode,
});
typedef _CollectionRowBatch = ({
  _CollectionRows kind,
  List<Map<String, dynamic>> rows,
});

typedef _NativeCollectionRows = ({String path, int? count});

/// A single giant compute argument copies every row map before the isolate
/// starts, still blocking the caller. Stream bounded batches instead. The
/// worker consumes JSON as it arrives; Isolate.exit transfers the final model
/// graph without another full copy on the UI isolate.
Future<T> _hydrateRowsInWorker<T>({
  required Map<_CollectionRows, List<Map<String, dynamic>>> rows,
  Set<String>? knownKeys,
  String? nativeRowsPath,
  int? nativeRowCount,
}) => _runCollectionWorker<T>(
  mode: knownKeys == null
      ? _CollectionWorkerMode.snapshot
      : _CollectionWorkerMode.playlist,
  feed: (sendBatch) async {
    for (final entry in rows.entries) {
      for (var offset = 0; offset < entry.value.length; offset += 256) {
        final end = (offset + 256).clamp(0, entry.value.length);
        await sendBatch((
          kind: entry.key,
          rows: entry.value.sublist(offset, end),
        ));
      }
    }
    if (knownKeys != null) {
      var batch = <String>[];
      for (final key in knownKeys) {
        batch.add(key);
        if (batch.length < 256) continue;
        await sendBatch(batch);
        batch = <String>[];
      }
      if (batch.isNotEmpty) await sendBatch(batch);
    }
    if (nativeRowsPath != null) {
      await sendBatch((path: nativeRowsPath, count: nativeRowCount));
    }
  },
);

typedef _SendCollectionBatch = Future<void> Function(Object batch);

Future<T> _runCollectionWorker<T>({
  required _CollectionWorkerMode mode,
  required Future<void> Function(_SendCollectionBatch sendBatch) feed,
}) async {
  final replies = ReceivePort();
  final ready = Completer<SendPort>();
  final result = Completer<T>();
  Completer<void>? acknowledgement;
  // An error can arrive while batches are being sent, before the final await.
  result.future.ignore();
  final subscription = replies.listen((Object? message) {
    if (message is SendPort) {
      ready.complete(message);
    } else if (message == true) {
      acknowledgement?.complete();
    } else if (message is List<Object?> && message.length == 1) {
      result.complete(message.single as T);
    } else {
      final error = message is List<Object?> && message.length == 2
          ? RemoteError(message[0].toString(), message[1].toString())
          : StateError('Collections hydration worker exited without a result');
      if (!ready.isCompleted) ready.completeError(error);
      if (!result.isCompleted) result.completeError(error);
      if (acknowledgement case final pending? when !pending.isCompleted) {
        pending.completeError(error);
      }
    }
  });
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _collectionHydrationWorker,
      (result: replies.sendPort, mode: mode),
      onError: replies.sendPort,
      onExit: replies.sendPort,
      debugName: 'library collections hydration',
    );
    final commands = await ready.future;
    Future<void> sendBatch(Object batch) async {
      final received = Completer<void>();
      acknowledgement = received;
      commands.send(batch);
      await received.future;
    }

    await feed(sendBatch);
    commands.send(null);
    return await result.future;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    replies.close();
  }
}

void _collectionHydrationWorker(_CollectionWorkerRequest request) async {
  final commands = ReceivePort();
  final accumulator = _CollectionHydrationAccumulator();
  final exporter = _CollectionExportAccumulator();
  final knownKeys = <String>{};
  request.result.send(commands.sendPort);
  await for (final Object? message in commands) {
    if (message case _CollectionRowBatch batch) {
      accumulator.add(batch.kind, batch.rows);
      request.result.send(true);
    } else if (message is List<String>) {
      knownKeys.addAll(message);
      request.result.send(true);
    } else if (message case _NativeCollectionRows input) {
      await _readNativeCollectionRows(input, accumulator);
      request.result.send(true);
    } else if (message case _CollectionExportBatch batch) {
      exporter.add(batch);
      request.result.send(true);
    } else if (message case _PlaylistExportHeader header) {
      exporter.startPlaylist(header);
      request.result.send(true);
    } else if (message == null) {
      commands.close();
      if (request.mode == _CollectionWorkerMode.exportJson) {
        Isolate.exit(request.result, [jsonEncode(exporter.finish())]);
      }
      if (request.mode == _CollectionWorkerMode.snapshot) {
        Isolate.exit(request.result, [accumulator.finish()]);
      }
      final tracks = accumulator.wishlist.toList(growable: false);
      final keys = tracks.map((entry) => entry.key).toSet();
      Isolate.exit(request.result, [
        HydratedPlaylistTracks(
          tracks: tracks,
          trackKeys: keys,
          membershipUnchanged:
              keys.length == knownKeys.length && keys.every(knownKeys.contains),
        ),
      ]);
    }
  }
}

Future<void> _readNativeCollectionRows(
  _NativeCollectionRows input,
  _CollectionHydrationAccumulator accumulator,
) async {
  var count = 0;
  _CollectionRows? previousKind;
  var batch = <Map<String, dynamic>>[];
  final lines = const LineSplitter().startChunkedConversion(
    _CollectionLineSink((line) {
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      final kind = switch (decoded['kind']) {
        'wishlist' || 'playlist_track' => _CollectionRows.wishlist,
        'loved' => _CollectionRows.loved,
        'artist' => _CollectionRows.artists,
        'membership' => _CollectionRows.membership,
        'playlist' => _CollectionRows.playlists,
        _ => throw const FormatException(
          'Unknown collection snapshot row kind',
        ),
      };
      if (previousKind != null &&
          (kind != previousKind || batch.length == 256)) {
        accumulator.add(previousKind!, batch);
        batch = <Map<String, dynamic>>[];
      }
      previousKind = kind;
      batch.add(Map<String, dynamic>.from(decoded['row'] as Map));
      count++;
    }),
  );
  try {
    // Decode file chunks asynchronously, then split and consume their lines
    // synchronously on this worker. A stream event per row adds avoidable
    // scheduling overhead to large snapshots.
    await for (final chunk in File(
      input.path,
    ).openRead().transform(utf8.decoder)) {
      lines.add(chunk);
    }
    lines.close();
    if (previousKind != null && batch.isNotEmpty) {
      accumulator.add(previousKind!, batch);
    }
    if (input.count != null && count != input.count) {
      throw const FormatException('Incomplete native collection snapshot');
    }
  } finally {
    await File(input.path).delete();
  }
}

class _CollectionLineSink implements Sink<String> {
  const _CollectionLineSink(this.onLine);
  final void Function(String) onLine;

  @override
  void add(String line) => onLine(line);

  @override
  void close() {}
}

enum _CollectionExportRows { wishlist, loved, artist, playlistTrack }

typedef _CollectionExportBatch = ({
  _CollectionExportRows kind,
  List<Object> entries,
});
typedef _PlaylistExportHeader = ({
  String id,
  String name,
  String? cover,
  DateTime createdAt,
  DateTime updatedAt,
});

/// Converts the stable published model snapshot to JSON on a worker without
/// cloning the whole graph in a single send. Playlist headers exclude
/// membership sets and their tracks are submitted separately in bounded
/// ordered batches. Backup writers embed this trusted fragment directly.
Future<String> exportLibraryCollectionsJson(LibraryCollectionsState state) =>
    _runCollectionWorker<String>(
      mode: _CollectionWorkerMode.exportJson,
      feed: (sendBatch) async {
        Future<void> entries(
          _CollectionExportRows kind,
          List<Object> values,
        ) async {
          for (var offset = 0; offset < values.length; offset += 256) {
            await sendBatch((
              kind: kind,
              entries: values.sublist(
                offset,
                (offset + 256).clamp(0, values.length),
              ),
            ));
          }
        }

        await entries(_CollectionExportRows.wishlist, state.wishlist);
        await entries(_CollectionExportRows.loved, state.loved);
        for (final playlist in state.playlists) {
          await sendBatch((
            id: playlist.id,
            name: playlist.name,
            cover: playlist.coverImagePath,
            createdAt: playlist.createdAt,
            updatedAt: playlist.updatedAt,
          ));
          await entries(_CollectionExportRows.playlistTrack, playlist.tracks);
        }
        await entries(_CollectionExportRows.artist, state.favoriteArtists);
      },
    );

class _CollectionExportAccumulator {
  final wishlist = <Map<String, dynamic>>[];
  final loved = <Map<String, dynamic>>[];
  final artists = <Map<String, dynamic>>[];
  final playlists = <Map<String, dynamic>>[];
  List<Map<String, dynamic>>? playlistTracks;

  void startPlaylist(_PlaylistExportHeader header) {
    playlistTracks = <Map<String, dynamic>>[];
    playlists.add({
      'id': header.id,
      'name': header.name,
      if (header.cover != null) 'coverImagePath': header.cover,
      'createdAt': header.createdAt.toIso8601String(),
      'updatedAt': header.updatedAt.toIso8601String(),
      'tracks': playlistTracks,
    });
  }

  void add(_CollectionExportBatch batch) {
    if (batch.kind == _CollectionExportRows.artist) {
      artists.addAll(
        batch.entries.map((entry) => (entry as CollectionArtistEntry).toJson()),
      );
      return;
    }
    final target = switch (batch.kind) {
      _CollectionExportRows.wishlist => wishlist,
      _CollectionExportRows.loved => loved,
      _CollectionExportRows.playlistTrack =>
        playlistTracks ??
            (throw const FormatException('Playlist tracks require a header')),
      _CollectionExportRows.artist => throw StateError(
        'Artist target is handled above',
      ),
    };
    target.addAll(
      batch.entries.map((entry) => (entry as CollectionTrackEntry).toJson()),
    );
  }

  Map<String, dynamic> finish() => {
    'wishlist': wishlist,
    'loved': loved,
    'playlists': playlists,
    'favoriteArtists': artists,
  };
}
