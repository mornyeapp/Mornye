import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_web_covers.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/sqlite_helpers.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:path_provider/path_provider.dart';

/// The catalog format the exporter writes (contract section 5).
const linkCatalogVersion = 1;

/// The header is written first as a placeholder and rewritten in place once
/// the row count is known, so it is padded to a fixed width. JSON readers
/// ignore the trailing spaces.
const _headerWidth = 96;

/// One page of Library Songs rows, as `LibraryDatabase` pages them.
typedef LinkCatalogPageLoader =
    Future<QueueLibraryDbPage> Function(QueueLibraryDbQuery query);

/// Maps one page of rows to NDJSON lines with the web covers held
/// ([LinkWebCovers.held]) and the files known to embed a picture
/// ([LinkWebCovers.pictures]); the default runs in an isolate.
typedef LinkCatalogPageMapper =
    Future<LinkCatalogPage> Function(
      List<Map<String, dynamic>> rows,
      Map<String, String> webCovers,
      Map<String, bool> pictures,
    );

/// One page of exported songs.
class LinkCatalogPage {
  const LinkCatalogPage({
    required this.bytes,
    required this.songs,
    required this.covers,
    this.webCoverSongs = const [],
  });

  /// UTF-8 NDJSON, one line per song.
  final Uint8List bytes;
  final List<LinkCatalogSong> songs;

  /// The cover the desktop player shows for each song in [songs]: its
  /// local cover file, else its web cover URL, or null.
  final List<String?> covers;

  /// The songs in [songs] without a local cover file but with a web cover.
  final List<LinkWebCoverSong> webCoverSongs;
}

/// A finished export.
class LinkCatalogExport {
  const LinkCatalogExport({
    required this.path,
    required this.count,
    required this.index,
    this.webCoverSongs = const [],
  });

  final String path;
  final int count;
  final DesktopLinkCatalogIndex index;

  /// The exported songs without a local cover file but with a web cover,
  /// for [LinkWebCovers].
  final List<LinkWebCoverSong> webCoverSongs;
}

final _uriScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
final _year = RegExp(r'^\s*(\d{4})');

/// [raw] as an absolute local file path, or null for content URIs, network
/// sources and relative paths.
String? linkLocalFilePath(Object? raw) {
  var path = linkCleanPath(raw is String ? raw.trim() : '');
  if (path.isEmpty) return null;
  if (path.startsWith('file://')) {
    try {
      path = Uri.parse(path).toFilePath();
    } on Object {
      return null;
    }
  } else if (_uriScheme.hasMatch(path)) {
    return null;
  }
  return File(path).isAbsolute ? path : null;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// [value] when it is a web URL.
String? _webUrl(Object? value) {
  final text = _text(value);
  return text != null &&
          (text.startsWith('https://') || text.startsWith('http://'))
      ? text
      : null;
}

int? _positiveInt(Object? value) {
  final number = value is num ? value.toInt() : int.tryParse('$value');
  return number != null && number > 0 ? number : null;
}

int? _epochMs(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return DateTime.tryParse(value)?.millisecondsSinceEpoch;
  return null;
}

String? _suffix(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

String _basenameWithoutExtension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// [value] when the desktop fetches it as a web cover.
String? _webCoverUrl(Object? value) {
  final url = linkCoverUrl(value);
  return url != null && isLinkWebCoverUrl(Uri.parse(url)) ? url : null;
}

/// Maps Library Songs rows (`{'source', 'item'}`) to catalog lines. Rows
/// whose file is not a readable local file are left out. A song without a
/// local cover file whose audio file is known to embed no picture
/// ([pictures] by [linkPictureStamp]) names its web cover's copy in
/// [webCovers] (by [linkCoverUrlId]) when held. Runs in an isolate: it
/// checks every file on disk.
LinkCatalogPage mapLinkCatalogRows(
  List<Map<String, dynamic>> rows, {
  Map<String, String> webCovers = const {},
  Map<String, bool> pictures = const {},
}) {
  final bytes = BytesBuilder(copy: false);
  final songs = <LinkCatalogSong>[];
  final covers = <String?>[];
  final webCoverSongs = <LinkWebCoverSong>[];
  final coverChecks = <String, bool>{};
  final webCoverPaths = <String, String?>{};
  bool isFile(String path) =>
      FileSystemEntity.typeSync(path) == FileSystemEntityType.file;

  for (final row in rows) {
    final source = row['source'];
    final item = row['item'];
    if (item is! Map) continue;
    final prefix = switch (source) {
      'local' => linkLocalSongId,
      'downloaded' => linkDownloadSongId,
      _ => null,
    };
    final recordId = _text(item['id']?.toString());
    final path = linkLocalFilePath(item['filePath']);
    if (prefix == null || recordId == null || path == null) continue;
    final FileStat stat;
    try {
      stat = FileStat.statSync(path);
    } on Object {
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;

    final title = _text(item['trackName']) ?? _basenameWithoutExtension(path);
    final artist = _text(item['artistName']) ?? '';
    final album = _text(item['albumName']);
    final albumArtist = _text(item['albumArtist']);
    final durationSeconds = _positiveInt(item['duration']);
    final isrc = normalizeIsrc(item['isrc']?.toString());
    final matchKey = linkMatchKey(title, artist);
    final coverCandidate = linkLocalFilePath(
      source == 'local' ? item['coverPath'] : item['coverUrl'],
    );
    final coverPath =
        coverCandidate != null &&
            coverChecks.putIfAbsent(
              coverCandidate,
              () => isFile(coverCandidate),
            )
        ? coverCandidate
        : null;
    final webCover = coverPath == null ? _webCoverUrl(item['coverUrl']) : null;
    String? webCoverPath;
    if (webCover != null) {
      final stamp = linkPictureStamp(path, stat);
      webCoverSongs.add((path: path, stamp: stamp, url: webCover));
      // A picture in the file comes first; the web copy only stands in.
      if (pictures[stamp] == false) {
        webCoverPath = webCoverPaths.putIfAbsent(
          webCover,
          () => webCovers[linkCoverUrlId(webCover)],
        );
      }
    }
    final year = _year.firstMatch('${item['releaseDate'] ?? ''}')?.group(1);
    final song = LinkCatalogSong(
      id: prefix(recordId),
      title: title,
      artist: artist,
      path: path,
      album: album,
      albumArtist: albumArtist,
      durationMs: durationSeconds == null ? null : durationSeconds * 1000,
      isrc: isrc.isEmpty ? null : isrc,
      matchKey: matchKey.isEmpty ? null : matchKey,
    );
    final line = <String, Object?>{
      'id': song.id,
      'title': title,
      'artist': artist,
      'albumArtist': albumArtist,
      'album': album,
      'albumKey': album == null
          ? null
          : '${normalizeLookupText(albumArtist ?? artist)}|'
                '${normalizeLookupText(album)}',
      'track': _positiveInt(item['trackNumber']),
      'disc': _positiveInt(item['discNumber']),
      'year': year == null ? null : int.parse(year),
      'genre': _text(item['genre']),
      'durationMs': song.durationMs,
      'path': path,
      'size': _positiveInt(item['fileSize']) ?? stat.size,
      'suffix': _suffix(path) ?? _text(item['format'])?.toLowerCase(),
      'bitRate': _positiveInt(item['bitrate']),
      'sampleRate': _positiveInt(item['sampleRate']),
      'bitDepth': _positiveInt(item['bitDepth']),
      'channels': null,
      'isrc': song.isrc,
      'matchKey': song.matchKey,
      'coverPath': coverPath ?? webCoverPath,
      'addedMs': _epochMs(
        source == 'local' ? item['scannedAt'] : item['downloadedAt'],
      ),
      // The Library rows keep whether a file has ReplayGain, not the values.
      'trackGain': null,
      'albumGain': null,
      'trackPeak': null,
      'albumPeak': null,
      'explicit': item['explicit'] == true || item['explicit'] == 1,
    };
    bytes
      ..add(utf8.encode(jsonEncode(line)))
      ..addByte(0x0A);
    songs.add(song);
    // The desktop player shows the web cover itself, not the Link copy.
    covers.add(coverPath ?? _webUrl(item['coverUrl']));
  }
  return LinkCatalogPage(
    bytes: bytes.takeBytes(),
    songs: songs,
    covers: covers,
    webCoverSongs: webCoverSongs,
  );
}

LinkCatalogPage _mapMessage(
  (List<Map<String, dynamic>>, Map<String, String>, Map<String, bool>) page,
) => mapLinkCatalogRows(page.$1, webCovers: page.$2, pictures: page.$3);

Future<LinkCatalogPage> _mapInIsolate(
  List<Map<String, dynamic>> rows,
  Map<String, String> webCovers,
  Map<String, bool> pictures,
) => compute(_mapMessage, (rows, webCovers, pictures));

Future<Directory> _defaultDirectory() async =>
    Directory('${(await getTemporaryDirectory()).path}/mornye-link');

/// Writes what the Library Songs view shows (downloads plus enabled scanned
/// sources, deduplicated by the queue store) as the NDJSON catalog the
/// server reads, and builds the identity index from the same rows.
///
/// Rows are paged from SQLite and mapped off the UI isolate, and lines are
/// appended to the file page by page, so a large Library never sits in
/// memory as JSON.
class LinkCatalogExporter {
  LinkCatalogExporter({
    LinkCatalogPageLoader? loadPage,
    LinkCatalogPageMapper? mapPage,
    Future<Directory> Function()? directory,
    int Function()? nowMs,
    Future<Map<String, String>> Function()? webCovers,
    Future<Map<String, bool>> Function()? pictures,
    this.pageSize = 1000,
  }) : _loadPage =
           loadPage ??
           ((query) => LibraryDatabase.instance.getQueueTrackPageResult(query)),
       _mapPage = mapPage ?? _mapInIsolate,
       _directory = directory ?? _defaultDirectory,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _webCovers = webCovers ?? (() async => const {}),
       _pictures = pictures ?? (() async => const {});

  final LinkCatalogPageLoader _loadPage;
  final LinkCatalogPageMapper _mapPage;
  final Future<Directory> Function() _directory;
  final int Function() _nowMs;
  final Future<Map<String, String>> Function() _webCovers;
  final Future<Map<String, bool>> Function() _pictures;
  final int pageSize;

  static Uint8List _header(int generatedMs, int count) {
    final json = jsonEncode({
      'catalogVersion': linkCatalogVersion,
      'generatedMs': generatedMs,
      'count': count,
    });
    assert(json.length < _headerWidth, 'Catalog header outgrew its width');
    return utf8.encode('${json.padRight(_headerWidth - 1)}\n');
  }

  Future<LinkCatalogExport> export({
    required bool includeLocal,
    required String serverId,
  }) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final target = File('${directory.path}/catalog.ndjson');
    final part = File('${target.path}.part');
    final builder = LinkCatalogIndexBuilder();
    final generatedMs = _nowMs();
    final webCovers = await _webCovers();
    final pictures = await _pictures();
    final webCoverSongs = <LinkWebCoverSong>[];
    final file = await part.open(mode: FileMode.write);
    try {
      await file.writeFrom(_header(generatedMs, 0));
      QueueLibraryDbCursor? cursor;
      for (var offset = 0; ; offset += pageSize) {
        final page = await _loadPage(
          QueueLibraryDbQuery(
            includeLocal: includeLocal,
            limit: pageSize,
            offset: offset,
            cursor: cursor,
          ),
        );
        if (page.rows.isNotEmpty) {
          final mapped = await _mapPage(page.rows, webCovers, pictures);
          if (mapped.bytes.isNotEmpty) await file.writeFrom(mapped.bytes);
          for (var i = 0; i < mapped.songs.length; i++) {
            builder.add(mapped.songs[i], cover: mapped.covers[i]);
          }
          webCoverSongs.addAll(mapped.webCoverSongs);
        }
        if (page.rows.length < pageSize) break;
        cursor = page.nextCursor;
      }
      await file.setPosition(0);
      await file.writeFrom(_header(generatedMs, builder.length));
    } finally {
      await file.close();
    }
    await part.rename(target.path);
    return LinkCatalogExport(
      path: target.path,
      count: builder.length,
      index: builder.build(serverId),
      webCoverSongs: webCoverSongs,
    );
  }
}

/// The catalog exporter the desktop host uses. Tests override it.
final linkCatalogExporterProvider = Provider<LinkCatalogExporter>((ref) {
  final webCovers = ref.read(linkWebCoversProvider);
  return LinkCatalogExporter(
    webCovers: webCovers.held,
    pictures: webCovers.pictures,
  );
});
