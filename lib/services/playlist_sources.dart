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
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PlaylistImport');

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

p.Context _folderContext(String path, bool tree) =>
    tree || path.startsWith('network://') ? p.posix : p.context;

/// [path] and the folders above it, up to [root]. [root] is the topmost
/// folder to offer; for a SAF [tree] the chain ends at the tree root, `''`.
Iterable<String> _folderChain(String path, bool tree, String? root) sync* {
  if (!tree && root == null) {
    yield path;
    return;
  }
  final context = _folderContext(path, tree);
  var current = path;
  while (true) {
    yield current;
    if (current.isEmpty || current == root) return;
    final parent = context.dirname(current);
    if (parent == current) return;
    if (parent == '.') {
      if (tree) yield '';
      return;
    }
    current = parent;
  }
}

/// The deepest folder that holds, or is above, every one of [folders].
String? _commonFolder(List<String> folders) {
  if (folders.isEmpty) return null;
  final context = _folderContext(folders.first, false);
  var candidate = folders.first;
  while (true) {
    final current = candidate;
    if (folders.every(
      (folder) => folder == current || context.isWithin(current, folder),
    )) {
      return current;
    }
    final parent = context.dirname(current);
    if (parent == current || parent == '.') return null;
    candidate = parent;
  }
}

/// Like [groupLibraryFolders], but every folder also holds the tracks of all
/// its subfolders, and the folders above the ones with tracks are offered
/// too, up to the top of their Library source. Picking a folder therefore
/// takes everything nested inside it, on plain paths and SAF trees alike.
List<LibraryFolder> groupLibraryFolderTree(
  List<LibraryFilePathRow> rows, {
  Map<String, String> sourceNames = const {},
}) {
  final direct =
      <String, ({String sourceId, String path, bool tree, List<String> ids})>{};
  for (final row in rows) {
    final folder = libraryFolderPath(row.filePath);
    if (folder == null) continue;
    direct
        .putIfAbsent(
          '${row.sourceId}\n$folder',
          () => (
            sourceId: row.sourceId,
            path: folder,
            tree: isContentUri(row.filePath.trim()),
            ids: <String>[],
          ),
        )
        .ids
        .add(row.id);
  }

  final plainFolders = <String, List<String>>{};
  for (final group in direct.values) {
    if (!group.tree) {
      plainFolders.putIfAbsent(group.sourceId, () => []).add(group.path);
    }
  }
  final roots = {
    for (final entry in plainFolders.entries)
      entry.key: _commonFolder(entry.value),
  };

  final totals = <String, ({String sourceId, String path, Set<String> ids})>{};
  for (final group in direct.values) {
    final root = group.tree ? '' : roots[group.sourceId];
    for (final folder in _folderChain(group.path, group.tree, root)) {
      totals
          .putIfAbsent(
            '${group.sourceId}\n$folder',
            () => (sourceId: group.sourceId, path: folder, ids: <String>{}),
          )
          .ids
          .addAll(group.ids);
    }
  }

  final folders = [
    for (final group in totals.values)
      LibraryFolder(
        name: group.path.isEmpty
            ? sourceNames[group.sourceId] ?? group.sourceId
            : p.basename(group.path),
        path: group.path,
        ids: group.ids.toList(growable: false),
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
) => groupLibraryFolderTree(request.rows, sourceNames: request.sourceNames);

/// Every Library track inside [root] and all of its subfolders, however
/// deep. Only files already in the Library are found.
Future<LibraryFolder> libraryFolderTree(
  String root,
  LibraryDatabase library,
) async {
  final rows = await library.getFilePathRows();
  return compute(_folderTree, (root: root, rows: rows));
}

LibraryFolder _folderTree(
  ({String root, List<LibraryFilePathRow> rows}) request,
) => folderTreeOfRows(request.root, request.rows);

/// The [rows] inside [root] and all of its subfolders, as one folder.
LibraryFolder folderTreeOfRows(String root, List<LibraryFilePathRow> rows) {
  final base = p.normalize(_visiblePath(root) ?? root);
  final ids = <String>[];
  for (final row in rows) {
    final folder = libraryFolderPath(row.filePath);
    if (folder == null) continue;
    final dir = p.normalize(folder);
    if (dir == base || p.isWithin(base, dir)) ids.add(row.id);
  }
  return LibraryFolder(name: p.basename(base), path: base, ids: ids);
}

/// The tracks of [folder] and its subfolders: subfolders in path order, each
/// one in [sortFolderItems] order.
Future<List<Track>> libraryFolderTreeTracks(
  LibraryFolder folder,
  LibraryDatabase library,
) async {
  final byDir = <String, List<LocalLibraryItem>>{};
  for (final row in await library.getByIds(folder.ids)) {
    final item = LocalLibraryItem.fromJson(row);
    byDir
        .putIfAbsent(libraryFolderPath(item.filePath) ?? '', () => [])
        .add(item);
  }
  final dirs = byDir.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final dir in dirs)
      for (final item in sortFolderItems(byDir[dir]!)) _localTrack(item),
  ];
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

final _percentEscape = RegExp('%[0-9A-Fa-f]{2}');

/// [_pathSegments] of a plain path line written percent-encoded, as some
/// players do ("My%20Song.flac"); empty for any other line.
List<String> _decodedPathSegments(String raw) {
  final path = raw.trim();
  if (!_percentEscape.hasMatch(path) ||
      isContentUri(path) ||
      path.toLowerCase().startsWith('file:')) {
    return const [];
  }
  try {
    return _pathSegments(Uri.decodeComponent(path));
  } on ArgumentError {
    return const [];
  } on FormatException {
    return const [];
  }
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
  /// A percent-encoded line is tried again decoded.
  String? match(String path) =>
      _matchSegments(_pathSegments(path)) ??
      _matchSegments(_decodedPathSegments(path));

  String? _matchSegments(List<String> segments) {
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
  final byPath = entries.length - pending.length;
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
  // A title numbered to keep the playlist's order ("001 - Song") is looked
  // up again without its number.
  final numbered = [
    for (final i in pending)
      if (rows[i] == null &&
          _withoutPosition(entries[i].track.name) != entries[i].track.name)
        i,
  ];
  if (numbered.isNotEmpty) {
    final retried = await library.findExistingBatch([
      for (final i in numbered)
        LocalLibraryBatchLookupRequest(
          trackName: _withoutPosition(entries[i].track.name),
          artistName: entries[i].track.artistName,
        ),
    ]);
    for (var j = 0; j < numbered.length; j++) {
      rows[numbered[j]] = retried[j];
    }
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
  _log.i(
    'Matched $matched of ${entries.length} playlist entries '
    '($byPath by path, ${matched - byPath} by title and artist)',
  );
  final unmatchedPaths = [
    for (var i = 0; i < entries.length; i++)
      if (rows[i] == null && entries[i].path != null) entries[i].path!,
  ];
  if (unmatchedPaths.isNotEmpty) {
    _log.i(
      'Unmatched path lines, first: ${unmatchedPaths.take(3).join(' | ')}',
    );
  }
  return (tracks: tracks, matched: matched);
}

final _positionPrefix = RegExp(r'^\d{1,4}\s*[-.)]\s+');

/// [title] without a leading playlist position such as "001 - " or "01. ",
/// which some exports write into the display text to keep their order.
String _withoutPosition(String title) {
  final match = _positionPrefix.firstMatch(title);
  return match == null || match.end >= title.length
      ? title
      : title.substring(match.end);
}
