import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/isrc_utils.dart';

/// The largest cover file sent with `phone/covers`; songs with a larger one
/// go without a cover.
const linkPhoneCoverMaxBytes = 1024 * 1024;

/// One page of Library Songs rows, as `LibraryDatabase` pages them.
typedef LinkPhoneRowLoader =
    Future<QueueLibraryDbPage> Function(QueueLibraryDbQuery query);

/// Maps one page of rows to songs; the default runs in an isolate.
typedef LinkPhoneRowMapper =
    Future<LinkPhoneSongPage> Function(List<Map<String, dynamic>> rows);

/// A cover of the phone's songs, sent once with `phone/covers`.
class LinkPhoneCover {
  const LinkPhoneCover({
    required this.id,
    required this.path,
    required this.size,
    required this.ext,
  });

  /// [linkFileIdFor] of [path] and [size].
  final String id;
  final String path;
  final int size;

  /// `jpg`, `png` or `webp`, from the file's first bytes.
  final String ext;
}

/// One page of Library rows mapped for the desktop.
class LinkPhoneSongPage {
  const LinkPhoneSongPage({
    required this.songs,
    required this.files,
    required this.covers,
    required this.lines,
  });

  final List<LinkPhoneSong> songs;

  /// The file behind each song in [songs].
  final List<LinkPhoneFile> files;

  /// The cover of each song in [songs], or null.
  final List<LinkPhoneCover?> covers;

  /// The UTF-8 JSON of each song in [songs].
  final List<Uint8List> lines;
}

/// The phone's songs as the desktop lists them, with the file behind each
/// and their covers.
class LinkPhoneCatalog {
  const LinkPhoneCatalog({
    required this.version,
    required this.songs,
    required this.files,
    required this.covers,
  });

  /// SHA-256 hex of the songs' JSON lines in order.
  final String version;
  final List<LinkPhoneSong> songs;

  /// The file of each song, by [LinkPhoneSong.fileId].
  final Map<String, LinkPhoneFile> files;

  /// The songs' covers, each once.
  final List<LinkPhoneCover> covers;

  /// The file the desktop asks for as `<fileId>.<suffix>`, or null.
  LinkPhoneFile? fileNamed(String name) {
    final dot = name.indexOf('.');
    return files[dot < 0 ? name : name.substring(0, dot)];
  }
}

final _year = RegExp(r'^\s*(\d{4})');

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
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

String _lastSegment(String path) => path.split(RegExp(r'[\\/]')).last;

String _withoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// The file name a content URI ends with, such as a document's path.
String _contentName(Map<dynamic, dynamic> item, String uri) {
  if (_text(item['safFileName']) case final name?) return name;
  try {
    return _lastSegment(Uri.decodeComponent(uri));
  } on Object {
    return _lastSegment(uri);
  }
}

/// The upload extension of a content URI row: its file name's, else its
/// format's.
String? _contentSuffix(Map<dynamic, dynamic> item, String name) {
  if (linkUploadExtensionOf(name) case final extension?) return extension;
  final format = switch (_text(item['format'])?.toLowerCase()) {
    'adts' => 'aac',
    final format => format,
  };
  return linkUploadExtensions.contains(format) ? format : null;
}

/// [raw] as a local file path, or null for URLs and content URIs.
String? _localPath(Object? raw) {
  final value = _text(raw);
  if (value == null) return null;
  if (value.startsWith('/')) return value;
  if (!value.startsWith('file://')) return null;
  try {
    return Uri.parse(value).toFilePath();
  } on Object {
    return null;
  }
}

/// The cover type of the image at [path] from its first bytes.
String? _imageType(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final head = file.readSync(12);
    bool starts(int offset, List<int> bytes) {
      if (head.length < offset + bytes.length) return false;
      for (var i = 0; i < bytes.length; i++) {
        if (head[offset + i] != bytes[i]) return false;
      }
      return true;
    }

    if (starts(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
    if (starts(0, const [0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (starts(0, ascii.encode('RIFF')) && starts(8, ascii.encode('WEBP'))) {
      return 'webp';
    }
    return null;
  } on FileSystemException {
    return null;
  } finally {
    file?.closeSync();
  }
}

/// The cover the desktop can take at [path]: an image file of at most
/// [linkPhoneCoverMaxBytes].
LinkPhoneCover? _cover(String path) {
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file ||
      stat.size <= 0 ||
      stat.size > linkPhoneCoverMaxBytes) {
    return null;
  }
  final ext = _imageType(path);
  if (ext == null) return null;
  return LinkPhoneCover(
    id: linkFileIdFor(path, stat.size),
    path: path,
    size: stat.size,
    ext: ext,
  );
}

/// Maps Library Songs rows (`{'source', 'item'}`) to the songs the desktop
/// can play: local files and content URIs in a format it takes, with file
/// ids as [LinkPhoneFiles.fileFor] names them. Streams, network sources and
/// missing files are left out. Runs in an isolate: it reads every file's
/// size.
LinkPhoneSongPage mapLinkPhoneRows(List<Map<String, dynamic>> rows) {
  final songs = <LinkPhoneSong>[];
  final files = <LinkPhoneFile>[];
  final covers = <LinkPhoneCover?>[];
  final lines = <Uint8List>[];
  final coverChecks = <String, LinkPhoneCover?>{};

  for (final row in rows) {
    final item = row['item'];
    if (item is! Map) continue;
    final source = item['filePath'];
    if (source is! String) continue;
    final LinkPhoneFile file;
    final String suffix;
    final String name;
    final int size;
    if (isContentUri(source)) {
      name = _contentName(item, source);
      final extension = _contentSuffix(item, name);
      if (extension == null) continue;
      // Its copy names the upload, so the file keeps no extension.
      file = LinkPhoneFile(fileId: linkFileIdFor(source, 0), source: source);
      suffix = extension;
      size = _positiveInt(item['fileSize']) ?? 0;
    } else if (source.startsWith('/')) {
      final extension = linkUploadExtensionOf(source);
      if (extension == null) continue;
      final stat = FileStat.statSync(source);
      if (stat.type != FileSystemEntityType.file) continue;
      name = _lastSegment(source);
      file = LinkPhoneFile(
        fileId: linkFileIdFor(source, stat.size),
        source: source,
        extension: extension,
      );
      suffix = extension;
      size = stat.size;
    } else {
      continue;
    }
    final title = _text(item['trackName']) ?? _text(_withoutExtension(name));
    if (title == null) continue;

    final local = row['source'] == 'local';
    final coverPath = _localPath(local ? item['coverPath'] : item['coverUrl']);
    final cover = coverPath == null
        ? null
        : coverChecks.putIfAbsent(coverPath, () => _cover(coverPath));
    final durationSeconds = _positiveInt(item['duration']);
    final isrc = normalizeIsrc(item['isrc']?.toString());
    final year = _year.firstMatch('${item['releaseDate'] ?? ''}')?.group(1);
    final song = LinkPhoneSong(
      fileId: file.fileId,
      suffix: suffix,
      title: title,
      artist: _text(item['artistName']) ?? '',
      size: size,
      album: _text(item['albumName']),
      albumArtist: _text(item['albumArtist']),
      track: _positiveInt(item['trackNumber']),
      disc: _positiveInt(item['discNumber']),
      year: year == null ? null : int.parse(year),
      genre: _text(item['genre']),
      durationMs: durationSeconds == null ? null : durationSeconds * 1000,
      isrc: isrc.isEmpty ? null : isrc,
      bitRate: _positiveInt(item['bitrate']),
      sampleRate: _positiveInt(item['sampleRate']),
      bitDepth: _positiveInt(item['bitDepth']),
      explicit: item['explicit'] == true || item['explicit'] == 1,
      coverId: cover?.id,
      addedMs: _epochMs(local ? item['scannedAt'] : item['downloadedAt']),
    );
    songs.add(song);
    files.add(file);
    covers.add(cover);
    lines.add(utf8.encode(jsonEncode(song.toJson())));
  }
  return LinkPhoneSongPage(
    songs: songs,
    files: files,
    covers: covers,
    lines: lines,
  );
}

Future<LinkPhoneSongPage> _mapInIsolate(List<Map<String, dynamic>> rows) =>
    compute(mapLinkPhoneRows, rows);

/// Builds the phone's [LinkPhoneCatalog] from what its Library Songs view
/// lists, and keeps the one built last for the desktop's file requests.
///
/// Rows are paged from SQLite and mapped off the UI isolate, page by page,
/// so only the songs themselves stay in memory.
class LinkPhoneLibrary {
  LinkPhoneLibrary({
    required bool Function() includeLocal,
    LinkPhoneRowLoader? loadPage,
    LinkPhoneRowMapper? mapPage,
    this.pageSize = 1000,
  }) : _includeLocal = includeLocal,
       _loadPage =
           loadPage ??
           ((query) => LibraryDatabase.instance.getQueueTrackPageResult(query)),
       _mapPage = mapPage ?? _mapInIsolate;

  /// Whether scanned sources show in the Library (the Local Library switch).
  final bool Function() _includeLocal;
  final LinkPhoneRowLoader _loadPage;
  final LinkPhoneRowMapper _mapPage;
  final int pageSize;

  /// Library changes seen so far, and how many of them [_last] and
  /// [_building] reflect.
  int _changes = 0;
  int _lastAt = -1;
  int _buildingAt = -1;
  LinkPhoneCatalog? _last;
  Future<LinkPhoneCatalog>? _building;

  /// The catalog built last, or null before the first build.
  LinkPhoneCatalog? get last => _last;

  /// The Library changed: the next [build] reads it again, and [fileNamed]
  /// builds again before it gives up on a name.
  void changed() => _changes++;

  /// Builds the catalog, or joins a build that started since the last
  /// [changed].
  Future<LinkPhoneCatalog> build() {
    final changes = _changes;
    if (_building case final running? when _buildingAt == changes) {
      return running;
    }
    late final Future<LinkPhoneCatalog> future;
    future = _build(changes).whenComplete(() {
      if (identical(_building, future)) _building = null;
    });
    _building = future;
    _buildingAt = changes;
    return future;
  }

  /// The file the desktop asks for as `<fileId>.<suffix>`: from [last], or
  /// from a new build when there is none or the Library changed since.
  Future<LinkPhoneFile?> fileNamed(String name) async {
    final last = _last;
    final file = last?.fileNamed(name);
    if (file != null || (last != null && _lastAt == _changes)) return file;
    return (await build()).fileNamed(name);
  }

  Future<LinkPhoneCatalog> _build(int changes) async {
    final includeLocal = _includeLocal();
    final songs = <LinkPhoneSong>[];
    final files = <String, LinkPhoneFile>{};
    final covers = <String, LinkPhoneCover>{};
    late final Digest digest;
    final hash = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
        (digests) => digest = digests.single,
      ),
    );
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
        final mapped = await _mapPage(page.rows);
        for (var i = 0; i < mapped.songs.length; i++) {
          final song = mapped.songs[i];
          // A file listed twice goes once.
          if (files.containsKey(song.fileId)) continue;
          files[song.fileId] = mapped.files[i];
          songs.add(song);
          hash
            ..add(mapped.lines[i])
            ..add(const [0x0A]);
          if (mapped.covers[i] case final cover?) {
            covers.putIfAbsent(cover.id, () => cover);
          }
        }
      }
      if (page.rows.length < pageSize) break;
      cursor = page.nextCursor;
    }
    hash.close();
    final catalog = LinkPhoneCatalog(
      version: digest.toString(),
      songs: songs,
      files: files,
      covers: [...covers.values],
    );
    if (changes >= _lastAt) {
      _last = catalog;
      _lastAt = changes;
    }
    return catalog;
  }
}
