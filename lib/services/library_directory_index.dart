import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/saf_display_path.dart';

/// One Library song as the folder index reads it: its record and file.
class LibraryDirectoryEntry {
  const LibraryDirectoryEntry({
    required this.source,
    required this.id,
    required this.path,
    this.cover,
    this.discNumber,
    this.trackNumber,
    this.safTreeUri,
    this.safRelativeDir,
    this.safFileName,
  });

  factory LibraryDirectoryEntry.fromRow(Map<String, Object?> row) =>
      LibraryDirectoryEntry(
        source: row['source'] as String? ?? 'downloaded',
        id: row['id'].toString(),
        path: row['file_path'] as String? ?? '',
        cover: row['cover'] as String?,
        discNumber: (row['disc_number'] as num?)?.toInt(),
        trackNumber: (row['track_number'] as num?)?.toInt(),
        safTreeUri: row['download_tree_uri'] as String?,
        safRelativeDir: row['saf_relative_dir'] as String?,
        safFileName: row['saf_file_name'] as String?,
      );

  /// `downloaded` for a download, `local` for a scanned file.
  final String source;
  final String id;
  final String path;
  final String? cover;
  final int? discNumber;
  final int? trackNumber;

  /// Where a download saved into a SAF tree, which names its folder even
  /// when the document URI is opaque.
  final String? safTreeUri;
  final String? safRelativeDir;
  final String? safFileName;
}

/// Where a Library file sits: the volume, SAF tree or network connection it
/// is on, the folders below that, and its file name.
class LibraryFileLocation {
  const LibraryFileLocation({
    required this.root,
    required this.rootLabel,
    required this.folders,
    required this.fileName,
    this.separator = '/',
  });

  /// Identifies the volume, tree or connection.
  final String root;

  /// The root as a path starts with it: `/`, `C:\`, `SD Card` or the name
  /// of a network connection.
  final String rootLabel;
  final List<String> folders;
  final String fileName;

  /// Joins folder names in paths shown to people.
  final String separator;
}

final _drivePath = RegExp(r'^[A-Za-z]:(/|$)');

List<String> _segments(String path) =>
    path.split('/').where((segment) => segment.isNotEmpty).toList();

/// The location of a stored Library path, or null when it names no file.
///
/// Handles plain paths on every platform, SAF `content://` documents (shown
/// as the storage path they map to when the provider allows), CUE virtual
/// tracks and `network://` files, whose root reads as the connection name
/// from [networkNames].
LibraryFileLocation? libraryFileLocation(
  String path, {
  String? safTreeUri,
  String? safRelativeDir,
  String? safFileName,
  Map<String, String> networkNames = const {},
}) {
  final file = (isCueVirtualPath(path) ? stripCueTrackSuffix(path) : path)
      .trim();
  if (file.isEmpty) return null;
  if (file.startsWith('network://')) {
    final uri = Uri.tryParse(file);
    final parts = uri?.pathSegments.where((part) => part.isNotEmpty).toList();
    if (uri == null || uri.host.isEmpty || parts == null || parts.isEmpty) {
      return null;
    }
    return LibraryFileLocation(
      root: 'network://${uri.host}',
      rootLabel: networkNames[uri.host] ?? uri.host,
      folders: parts.sublist(0, parts.length - 1),
      fileName: parts.last,
    );
  }
  if (isContentUri(file)) {
    return _documentLocation(
      file,
      safTreeUri: safTreeUri,
      safRelativeDir: safRelativeDir,
      safFileName: safFileName,
    );
  }
  if (file.startsWith('file://')) {
    try {
      return _fileLocation(Uri.parse(file).toFilePath());
    } catch (_) {
      return null;
    }
  }
  return _fileLocation(file);
}

LibraryFileLocation? _fileLocation(String path) {
  final normalized = path.replaceAll('\\', '/');
  final String root;
  final String rootLabel;
  var separator = '/';
  final String rest;
  if (normalized.startsWith('//')) {
    // A Windows network share.
    root = '//';
    rootLabel = r'\\';
    separator = r'\';
    rest = normalized.substring(2);
  } else if (normalized.startsWith('/')) {
    root = '/';
    rootLabel = '/';
    rest = normalized.substring(1);
  } else if (_drivePath.hasMatch(normalized)) {
    root = normalized.substring(0, 2).toUpperCase();
    rootLabel = '$root\\';
    separator = r'\';
    rest = normalized.substring(2);
  } else {
    // A display path such as "SD Card/Music/song.flac" starts at its volume.
    final parts = _segments(normalized);
    if (parts.length < 2) return null;
    return LibraryFileLocation(
      root: 'volume:${parts.first}',
      rootLabel: parts.first,
      folders: parts.sublist(1, parts.length - 1),
      fileName: parts.last,
    );
  }
  final parts = _segments(rest);
  if (parts.isEmpty) return null;
  return LibraryFileLocation(
    root: root,
    rootLabel: rootLabel,
    folders: parts.sublist(0, parts.length - 1),
    fileName: parts.last,
    separator: separator,
  );
}

LibraryFileLocation? _documentLocation(
  String uri, {
  String? safTreeUri,
  String? safRelativeDir,
  String? safFileName,
}) {
  if (safTreeUri != null &&
      safTreeUri.isNotEmpty &&
      safFileName != null &&
      safFileName.trim().isNotEmpty) {
    final display = buildSafFileDisplayPath(
      pathOrUri: uri,
      treeUri: safTreeUri,
      relativeDir: safRelativeDir,
      fileName: safFileName,
    );
    if (!isContentUri(display)) return _fileLocation(display);
  }
  final display = formatSafUriForDisplay(uri);
  if (!isContentUri(display)) return _fileLocation(display);
  final document = resolveSafDocumentLocation(uri);
  if (document != null) {
    final treeDisplay = formatSafUriForDisplay(document.treeUri);
    final treeSegments = Uri.parse(document.treeUri).pathSegments;
    return LibraryFileLocation(
      root: document.treeUri,
      rootLabel: isContentUri(treeDisplay)
          ? treeSegments.isEmpty
                ? document.treeUri
                : treeSegments.last
          : treeDisplay,
      folders: _segments(document.relativeDir),
      fileName: document.fileName,
    );
  }
  // A provider document outside a tree has no folders to show.
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.authority.isEmpty) return null;
  final parts = parsed.pathSegments.where((part) => part.isNotEmpty);
  return LibraryFileLocation(
    root: 'content://${parsed.authority}',
    rootLabel: parsed.authority,
    folders: const [],
    fileName: parts.isEmpty ? uri : parts.last,
  );
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

/// Orders names as a file manager does: case-insensitive, digit runs by
/// their value, so "Disc 2" comes before "Disc 10".
int compareNaturally(String a, String b) {
  final left = a.toLowerCase();
  final right = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < left.length && j < right.length) {
    final x = left.codeUnitAt(i);
    final y = right.codeUnitAt(j);
    if (_isDigit(x) && _isDigit(y)) {
      while (i < left.length - 1 &&
          left.codeUnitAt(i) == 0x30 &&
          _isDigit(left.codeUnitAt(i + 1))) {
        i++;
      }
      while (j < right.length - 1 &&
          right.codeUnitAt(j) == 0x30 &&
          _isDigit(right.codeUnitAt(j + 1))) {
        j++;
      }
      var iEnd = i;
      while (iEnd < left.length && _isDigit(left.codeUnitAt(iEnd))) {
        iEnd++;
      }
      var jEnd = j;
      while (jEnd < right.length && _isDigit(right.codeUnitAt(jEnd))) {
        jEnd++;
      }
      final length = (iEnd - i) - (jEnd - j);
      if (length != 0) return length;
      final digits = left
          .substring(i, iEnd)
          .compareTo(right.substring(j, jEnd));
      if (digits != 0) return digits;
      i = iEnd;
      j = jEnd;
      continue;
    }
    if (x != y) return x - y;
    i++;
    j++;
  }
  final rest = (left.length - i) - (right.length - j);
  return rest != 0 ? rest : a.compareTo(b);
}

/// A song in a [LibraryDirectory].
class LibraryDirectoryTrack {
  const LibraryDirectoryTrack({
    required this.source,
    required this.id,
    required this.fileName,
    this.cover,
    this.discNumber,
    this.trackNumber,
  });

  /// `downloaded` for a download, `local` for a scanned file.
  final String source;
  final String id;
  final String fileName;
  final String? cover;
  final int? discNumber;
  final int? trackNumber;

  /// The [UnifiedLibraryItem] id of the song.
  String get itemId => source == 'local' ? 'local_$id' : 'dl_$id';
}

/// A folder of the Library and what it holds.
class LibraryDirectory {
  LibraryDirectory._(this.key, this.name, this.path);

  /// Identifies the folder across index rebuilds.
  final String key;

  /// The folder name. A top-level entry of several roots reads as its path.
  String name;

  /// The folder's path as people read it.
  final String path;

  /// Folders inside this one, by name.
  final List<LibraryDirectory> folders = [];

  /// Songs directly in this folder: by file name, then disc and track
  /// number, so the songs of one CUE sheet keep their order.
  final List<LibraryDirectoryTrack> tracks = [];

  /// Songs in this folder and every folder below it.
  int trackCount = 0;

  /// Artwork of the first song directly in this folder that has any.
  String? cover;

  /// The songs of this folder, then of each folder below it, in order.
  Iterable<LibraryDirectoryTrack> get allTracks sync* {
    yield* tracks;
    for (final folder in folders) {
      yield* folder.allTracks;
    }
  }
}

/// The Library's songs arranged by the folders their files are in.
class LibraryDirectoryIndex {
  LibraryDirectoryIndex._(this.root, this._byKey);

  /// Arranges [entries]. The folders above the first one that holds songs
  /// or several folders collapse, so [root] opens where the music starts.
  /// When the songs sit on several volumes or connections, [root] lists
  /// each of them by its collapsed path instead.
  factory LibraryDirectoryIndex.build(
    Iterable<LibraryDirectoryEntry> entries, {
    Map<String, String> networkNames = const {},
  }) {
    final top = LibraryDirectory._('', '', '');
    final byKey = <String, LibraryDirectory>{'': top};
    for (final entry in entries) {
      final location = libraryFileLocation(
        entry.path,
        safTreeUri: entry.safTreeUri,
        safRelativeDir: entry.safRelativeDir,
        safFileName: entry.safFileName,
        networkNames: networkNames,
      );
      if (location == null) continue;
      var folder = byKey.putIfAbsent(location.root, () {
        final root = LibraryDirectory._(
          location.root,
          location.rootLabel,
          location.rootLabel,
        );
        top.folders.add(root);
        return root;
      });
      for (final name in location.folders) {
        final parent = folder;
        final key = '${parent.key}\u0000$name';
        folder = byKey.putIfAbsent(key, () {
          final path = parent.path.endsWith(location.separator)
              ? '${parent.path}$name'
              : '${parent.path}${location.separator}$name';
          final child = LibraryDirectory._(key, name, path);
          parent.folders.add(child);
          return child;
        });
      }
      folder.tracks.add(
        LibraryDirectoryTrack(
          source: entry.source,
          id: entry.id,
          fileName: location.fileName,
          cover: entry.cover?.isNotEmpty == true ? entry.cover : null,
          discNumber: entry.discNumber,
          trackNumber: entry.trackNumber,
        ),
      );
    }
    for (var i = 0; i < top.folders.length; i++) {
      var root = top.folders[i];
      while (root.tracks.isEmpty && root.folders.length == 1) {
        root = root.folders.single;
      }
      root.name = root.path;
      top.folders[i] = root;
    }
    _arrange(top);
    return LibraryDirectoryIndex._(
      top.folders.length == 1 ? top.folders.single : top,
      byKey,
    );
  }

  /// The folder the Folders page opens on. Its key is empty when it lists
  /// several volumes or connections.
  final LibraryDirectory root;
  final Map<String, LibraryDirectory> _byKey;

  /// The folder with [key], or null when it no longer holds songs.
  LibraryDirectory? operator [](String key) => _byKey[key];

  static int _compareTracks(LibraryDirectoryTrack a, LibraryDirectoryTrack b) {
    final byName = compareNaturally(a.fileName, b.fileName);
    if (byName != 0) return byName;
    final byDisc = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
    if (byDisc != 0) return byDisc;
    final byNumber = (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
    return byNumber != 0 ? byNumber : a.itemId.compareTo(b.itemId);
  }

  static void _arrange(LibraryDirectory folder) {
    folder.folders.sort((a, b) => compareNaturally(a.name, b.name));
    folder.tracks.sort(_compareTracks);
    folder.cover = folder.tracks
        .map((track) => track.cover)
        .firstWhere((cover) => cover != null, orElse: () => null);
    var count = folder.tracks.length;
    for (final child in folder.folders) {
      _arrange(child);
      count += child.trackCount;
    }
    folder.trackCount = count;
  }
}
