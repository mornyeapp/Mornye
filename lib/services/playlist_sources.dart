import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/csv_import_service.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/m3u_playlist_service.dart';
import 'package:mornye/utils/file_access.dart';

/// One Library folder offered as a playlist source.
class LibraryFolder {
  const LibraryFolder({
    required this.name,
    required this.path,
    required this.ids,
  });

  final String name;

  /// The folder as the user knows it: relative to its storage tree for SAF
  /// documents, otherwise the stored path. Empty for a tree's root.
  final String path;

  /// Library row ids of the folder's tracks.
  final List<String> ids;
}

/// One entry of an imported playlist file. M3U entries keep their path line,
/// which identifies a local file better than the display text does.
class PlaylistImportEntry {
  const PlaylistImportEntry(this.track, [this.path]);

  final Track track;
  final String? path;
}

/// A Library path as the user sees it, without a CUE track suffix: SAF
/// documents relative to their tree, other paths unchanged.
String? _visiblePath(String filePath) {
  final path = stripCueTrackSuffix(filePath.trim());
  if (path.isEmpty) return null;
  return isContentUri(path) ? M3uPlaylistService.exportPathFor(path) : path;
}

/// The folder holding a Library file, or null without a usable path.
String? libraryFolderPath(String filePath) {
  final path = _visiblePath(filePath);
  if (path == null) return null;
  if (isContentUri(filePath.trim()) || path.startsWith('network://')) {
    final folder = p.posix.dirname(path);
    return folder == '.' ? '' : folder;
  }
  return p.dirname(path);
}

/// Groups [rows] by folder, sorted by name. A tree root is named after its
/// Library source in [sourceNames].
List<LibraryFolder> groupLibraryFolders(
  List<LibraryFilePathRow> rows, {
  Map<String, String> sourceNames = const {},
}) {
  final groups = <String, ({String sourceId, String path, List<String> ids})>{};
  for (final row in rows) {
    final folder = libraryFolderPath(row.filePath);
    if (folder == null) continue;
    groups
        .putIfAbsent(
          '${row.sourceId}\n$folder',
          () => (sourceId: row.sourceId, path: folder, ids: <String>[]),
        )
        .ids
        .add(row.id);
  }
  final folders = [
    for (final group in groups.values)
      LibraryFolder(
        name: group.path.isEmpty
            ? sourceNames[group.sourceId] ?? group.sourceId
            : p.basename(group.path),
        path: group.path,
        ids: group.ids,
      ),
  ];
  folders.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.path.compareTo(b.path);
  });
  return folders;
}

/// A folder in playback order: by disc and track number when it holds one
/// album that numbers every track, otherwise by file name, as a file browser
/// lists it.
List<LocalLibraryItem> sortFolderItems(List<LocalLibraryItem> items) {
  String fileName(LocalLibraryItem item) =>
      p.basename(_visiblePath(item.filePath) ?? item.filePath).toLowerCase();
  int byFileName(LocalLibraryItem a, LocalLibraryItem b) =>
      fileName(a).compareTo(fileName(b));

  final albums = {
    for (final item in items) item.albumName.trim().toLowerCase(),
  };
  final numbered =
      albums.length == 1 && items.every((item) => item.trackNumber != null);
  return [...items]..sort(
    numbered
        ? (a, b) {
            final disc = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
            if (disc != 0) return disc;
            final track = a.trackNumber!.compareTo(b.trackNumber!);
            return track != 0 ? track : byFileName(a, b);
          }
        : byFileName,
  );
}

Track _localTrack(LocalLibraryItem item) =>
    UnifiedLibraryItem.fromLocalLibrary(item).toTrack();

/// The Library's folders with at least one visible track.
Future<List<LibraryFolder>> loadLibraryFolders(LibraryDatabase library) async {
  final rows = await library.getFilePathRows();
  final sourceNames = {
    for (final source in await library.getSources())
      source.id: source.displayName,
  };
  return compute(_groupFolders, (rows: rows, sourceNames: sourceNames));
}

List<LibraryFolder> _groupFolders(
  ({List<LibraryFilePathRow> rows, Map<String, String> sourceNames}) request,
) => groupLibraryFolders(request.rows, sourceNames: request.sourceNames);

/// The tracks of [folder] in [sortFolderItems] order.
Future<List<Track>> libraryFolderTracks(
  LibraryFolder folder,
  LibraryDatabase library,
) async {
  final rows = await library.getByIds(folder.ids);
  final items = sortFolderItems([
    for (final row in rows) LocalLibraryItem.fromJson(row),
  ]);
  return [for (final item in items) _localTrack(item)];
}

/// Parses an M3U, M3U8 or CSV playlist file named [fileName].
Future<List<PlaylistImportEntry>> parsePlaylistImportFile(
  Uint8List bytes,
  String fileName,
) async {
  final extension = p.extension(fileName).toLowerCase();
  if (extension == '.m3u' || extension == '.m3u8') {
    return compute(_parseM3uImport, bytes);
  }
  final tracks = await CsvImportService.parsePlaylistInBackground(
    bytes,
    format: 'csv',
  );
  return [for (final track in tracks) PlaylistImportEntry(track)];
}

List<PlaylistImportEntry> _parseM3uImport(Uint8List bytes) {
  var content = utf8.decode(bytes, allowMalformed: true);
  if (content.startsWith('﻿')) content = content.substring(1);
  return [
    for (final entry in M3uPlaylistService.parseM3uEntries(content))
      PlaylistImportEntry(entry.track, entry.path),
  ];
}

/// Lowercase path segments without empty, `.` or `..` parts. `file:` URIs
/// are decoded and SAF documents are taken relative to their tree.
List<String> _pathSegments(String raw) {
  var path = stripCueTrackSuffix(raw.trim());
  if (isContentUri(path)) {
    path = M3uPlaylistService.exportPathFor(path) ?? '';
  } else if (path.toLowerCase().startsWith('file:')) {
    try {
      path = Uri.parse(path).pathSegments.join('/');
    } on FormatException {
      // Keep the raw text; its file name may still match.
    }
  }
  return path
      .replaceAll('\\', '/')
      .toLowerCase()
      .split('/')
      .where(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      )
      .toList(growable: false);
}

/// Matches playlist paths to Library files by their last one to three
/// segments, so an export from another device or player still resolves.
class PlaylistPathIndex {
  PlaylistPathIndex(Iterable<LibraryFilePathRow> rows) {
    for (final row in rows) {
      final segments = _pathSegments(row.filePath);
      for (var count = 1; count <= math.min(_depth, segments.length); count++) {
        _ids.update(
          segments.sublist(segments.length - count).join('/'),
          (id) => id == row.id ? id : '',
          ifAbsent: () => row.id,
        );
      }
    }
  }

  static const _depth = 3;

  /// Library id per path tail; empty when several files share the tail.
  final Map<String, String> _ids = {};

  /// The Library id at [path], or null when no single file matches. The
  /// longest tail present decides; a shared one is not narrowed further.
  String? match(String path) {
    final segments = _pathSegments(path);
    for (var count = math.min(_depth, segments.length); count > 0; count--) {
      final id = _ids[segments.sublist(segments.length - count).join('/')];
      if (id != null) return id.isEmpty ? null : id;
    }
    return null;
  }
}

List<String?> _matchPaths(
  ({List<LibraryFilePathRow> rows, List<String?> paths}) request,
) {
  final index = PlaylistPathIndex(request.rows);
  return [
    for (final path in request.paths) path == null ? null : index.match(path),
  ];
}

/// The playlist for [entries]: each entry's Library file by path, else by
/// ISRC or title and artist. Entries without a local file keep the file's
/// own metadata, so they can still be downloaded.
Future<({List<Track> tracks, int matched})> matchPlaylistImport(
  List<PlaylistImportEntry> entries,
  LibraryDatabase library,
) async {
  final ids = List<String?>.filled(entries.length, null);
  if (entries.any((entry) => entry.path != null)) {
    final rows = await library.getFilePathRows();
    final paths = [for (final entry in entries) entry.path];
    ids.setAll(0, await compute(_matchPaths, (rows: rows, paths: paths)));
  }
  final byId = {
    for (final row in await library.getByIds(ids.nonNulls.toSet().toList()))
      row['id'] as String: row,
  };
  final rows = [for (final id in ids) id == null ? null : byId[id]];
  final pending = [
    for (var i = 0; i < entries.length; i++)
      if (rows[i] == null) i,
  ];
  final found = await library.findExistingBatch([
    for (final i in pending)
      LocalLibraryBatchLookupRequest(
        isrc: entries[i].track.isrc,
        trackName: entries[i].track.name,
        artistName: entries[i].track.artistName,
      ),
  ]);
  for (var j = 0; j < pending.length; j++) {
    rows[pending[j]] = found[j];
  }
  var matched = 0;
  final tracks = <Track>[];
  for (var i = 0; i < entries.length; i++) {
    final row = rows[i];
    if (row == null) {
      tracks.add(entries[i].track);
    } else {
      matched++;
      tracks.add(_localTrack(LocalLibraryItem.fromJson(row)));
    }
  }
  return (tracks: tracks, matched: matched);
}
