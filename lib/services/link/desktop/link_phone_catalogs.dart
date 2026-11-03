import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart'
    show linkDurationToleranceMs, linkMatchKey;
import 'package:mornye/services/link/desktop/link_web_covers.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('LinkPhoneCatalogs');

const _coverExtensions = ['jpg', 'png', 'webp'];
final _coverName = RegExp(r'^([0-9a-f]{32})\.(jpg|png|webp)$');
const _catalogName = 'catalog.ndjson';
const _partName = 'catalog.ndjson.part';
const _librarySourceName = 'library_source';
const _newline = 10;

/// The folder that keeps paired phones' songs, one folder per phone
/// (`<app support>/link_phones`). Tests override it.
final linkPhoneFolderProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory(
        '${(await getApplicationSupportDirectory()).path}/link_phones',
      ),
);

LinkException _invalid(String message) => LinkException('invalid', message);

int? _intArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  return value is num ? value.toInt() : null;
}

/// The cover files the desktop's Library rows of the phone [sourceId] name
/// now; throws when they cannot be read.
typedef LinkLibraryCovers = Future<Set<String>> Function(String sourceId);

/// The song lists and covers paired phones send for the desktop's Library
/// (contract 12.2 and 12.3). Each phone has a folder named after its
/// [linkPhoneSourceId] under [root]: `catalog.ndjson` (a `{"version"}` line,
/// then one [LinkPhoneSong] per line) and `covers/<coverKey>.<ext>`.
class LinkPhoneCatalogs {
  LinkPhoneCatalogs({
    required Future<Directory> Function() root,
    required Future<bool> Function(String deviceId) paired,
    void Function(String deviceId)? onCommit,
    LinkCoverFetcher? fetchCover,
    LinkCoverShrinker? shrinkCover,
    LinkLibraryCovers? libraryCovers,
  }) : _root = root,
       _paired = paired,
       _onCommit = onCommit,
       _fetch = fetchCover ?? fetchLinkCover,
       _shrink = shrinkCover ?? shrinkLinkCover,
       _libraryCovers = libraryCovers ?? ((_) async => const {});

  /// The most songs a phone may list.
  static const maxSongs = 100000;

  /// The largest cover file. A phone sends larger covers shrunk, and a
  /// larger one fetched from the web is kept shrunk to [linkShrunkCoverSize].
  static const maxCoverBytes = 2 * 1024 * 1024;

  /// The most base64 characters of covers in one request.
  static const maxCoversRequest = 4 * 1024 * 1024;

  /// The most cover bytes kept for one phone; further covers are left out.
  static const maxCoverStore = 1024 * 1024 * 1024;

  /// The longest song line kept; longer songs are left out.
  static const maxSongLine = 4 * 1024;

  final Future<Directory> Function() _root;
  final Future<bool> Function(String deviceId) _paired;
  final void Function(String deviceId)? _onCommit;
  final LinkCoverFetcher _fetch;
  final LinkCoverShrinker _shrink;
  final LinkLibraryCovers _libraryCovers;
  final _uploads = <String, _Upload>{};
  final _versions = <String, String?>{};
  final _coverBytes = <String, int>{};
  final _queues = <String, Future<void>>{};
  final _deleted = <String, Future<Set<String>>>{};

  /// The last cover removal queued for each phone. `GET phone/covers` waits
  /// for it; the other readers look up covers of committed songs, which no
  /// removal takes away.
  final _pruning = <String, Future<void>>{};

  /// The cover ids of a list just committed, for the removal queued right
  /// behind its last page.
  final _committedCovers = <String, Set<String>>{};

  /// The web covers fetched or tried for each phone while the app runs.
  final _triedCovers = <String, Set<String>>{};

  /// Registers `phone/catalog` and `phone/covers` on [router].
  void register(LinkHostRouter router) {
    router
      ..register(LinkOps.phoneCatalog, _catalog)
      ..register(LinkOps.phoneCovers, _covers);
  }

  /// Completes when the writes and cover fetches queued so far for the
  /// phone [sourceId] are done.
  @visibleForTesting
  Future<void> idle(String sourceId) => _queues[sourceId] ?? Future.value();

  /// Runs the writes of one phone one after another.
  Future<T> _serial<T>(String sourceId, Future<T> Function() action) {
    final result = (_queues[sourceId] ?? Future<void>.value()).then(
      (_) => action(),
    );
    _queues[sourceId] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Queues [prune] among the writes of the phone [sourceId].
  void _queuePrune(String sourceId, Future<void> Function() prune) {
    _pruning[sourceId] = _serial(
      sourceId,
      prune,
    ).then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  Future<String> _sourceFor(LinkRequest request, {required bool write}) async {
    final deviceId = request.deviceId;
    if (deviceId.isEmpty) throw _invalid('Missing device');
    if (write && !await _paired(deviceId)) {
      throw _invalid('Only a paired phone can send its songs');
    }
    return linkPhoneSourceId(deviceId);
  }

  Future<String> _folder(String sourceId) async =>
      '${(await _root()).path}/$sourceId';

  Future<Object?> _catalog(LinkRequest request) async {
    if (request.method == 'GET') {
      final sourceId = await _sourceFor(request, write: false);
      final deviceId = request.deviceId;
      if (await _paired(deviceId)) {
        // A phone asks at the start of each sync: covers a commit kept only
        // for Library rows go once a rescan moved the rows, and covers a
        // failed fetch left out of its list get another try.
        _queuePrune(sourceId, () => _pruneDropped(sourceId));
        unawaited(
          _serial(sourceId, () => _fetchListedCovers(deviceId, sourceId)),
        );
      }
      return {'version': await version(sourceId)};
    }
    final sourceId = await _sourceFor(request, write: true);
    final reply = _serial(
      sourceId,
      () => _page(request.deviceId, sourceId, request.args),
    );
    // Right behind the page, so a commit's removal runs after its reply and
    // before anything the phone sends next.
    _queuePrune(sourceId, () async {
      if (_committedCovers.remove(sourceId) case final keep?) {
        await _pruneCovers(sourceId, keep);
      }
    });
    return reply;
  }

  /// One `POST phone/catalog` page; the last one commits the list.
  Future<Object?> _page(
    String deviceId,
    String sourceId,
    Map<String, dynamic> args,
  ) async {
    final version = args['version'];
    final offset = _intArg(args, 'offset');
    final total = _intArg(args, 'total');
    final songs = args['songs'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 128 ||
        offset == null ||
        total == null ||
        songs is! List) {
      throw _invalid('Malformed page');
    }
    if (total < 0 || total > maxSongs) throw _invalid('Too many songs');
    if (offset < 0 ||
        songs.length > linkPhoneCatalogPage ||
        offset + songs.length > total ||
        (songs.isEmpty && total > 0)) {
      throw _invalid('Malformed page');
    }
    final folder = await _folder(sourceId);
    var upload = _uploads[sourceId];
    if (offset == 0) {
      // Starts over, dropping an unfinished upload.
      await upload?.discard();
      await Directory(folder).create(recursive: true);
      upload = _uploads[sourceId] = await _Upload.start(
        File('$folder/$_partName'),
        version,
        total,
      );
    } else if (upload == null ||
        upload.version != version ||
        upload.total != total ||
        upload.next != offset) {
      _uploads.remove(sourceId);
      await upload?.discard();
      throw _invalid('Page out of order; start again from offset 0');
    }
    await upload.add(songs);
    if (upload.next < total) return const {'ok': true};
    _uploads.remove(sourceId);
    await upload.commit(File('$folder/$_catalogName'));
    await _pruneDeleted(sourceId);
    _versions[sourceId] = version;
    _committedCovers[sourceId] = upload.coverIds;
    _onCommit?.call(deviceId);
    final coverUrls = upload.coverUrls;
    if (coverUrls.isNotEmpty) {
      // The phone's request does not wait for them.
      unawaited(
        _serial(sourceId, () => _fetchCovers(deviceId, sourceId, coverUrls)),
      );
    }
    return const {'ok': true};
  }

  /// Fetches the web covers of the phone's committed songs.
  Future<void> _fetchListedCovers(String deviceId, String sourceId) async {
    final urls = <String, String>{};
    await for (final song in songs(sourceId)) {
      if (song.coverId == null && song.coverUrl != null) {
        urls[song.coverKey!] = song.coverUrl!;
      }
    }
    if (urls.isNotEmpty) await _fetchCovers(deviceId, sourceId, urls);
  }

  /// Removes the covers an earlier commit left out but kept while Library
  /// rows named them. Covers written since the commit wait for the commit
  /// they were sent for.
  Future<void> _pruneDropped(String sourceId) async {
    final DateTime committed;
    try {
      committed = await File(
        '${await _folder(sourceId)}/$_catalogName',
      ).lastModified();
    } on FileSystemException {
      // Nothing committed yet.
      return;
    }
    final keys = <String>{};
    await for (final song in songs(sourceId)) {
      if (song.coverKey case final key?) keys.add(key);
    }
    await _pruneCovers(sourceId, keys, writtenBefore: committed);
  }

  /// Fetches the covers of [urls] (by cover key) not held or tried yet,
  /// then shows the phone's songs again when any arrived.
  Future<void> _fetchCovers(
    String deviceId,
    String sourceId,
    Map<String, String> urls,
  ) async {
    final held = await coverPaths(sourceId);
    final tried = _triedCovers.putIfAbsent(sourceId, () => <String>{});
    final missing = [
      for (final MapEntry(:key, :value) in urls.entries)
        if (!held.containsKey(key) && tried.add(key))
          (id: key, url: Uri.parse(value)),
    ];
    if (missing.isEmpty) return;
    final folder = '${await _folder(sourceId)}/covers';
    await Directory(folder).create(recursive: true);
    var stored = await _storedBytes(sourceId, held);
    var added = 0;
    try {
      // A few at a time, so a large first list does not flood the network.
      fetching:
      for (var start = 0; start < missing.length; start += 4) {
        final batch = missing.skip(start).take(4).toList();
        final fetched = await Future.wait([
          for (final cover in batch)
            _fetch(
              cover.url,
            ).then<Uint8List?>((bytes) => bytes, onError: (Object _) => null),
        ]);
        for (var i = 0; i < batch.length; i++) {
          var bytes = fetched[i];
          // Stores often serve covers at full size, several megabytes.
          if (bytes != null && bytes.length > maxCoverBytes) {
            bytes = await _shrink(bytes);
          }
          final ext = bytes == null ? null : linkCoverExtension(bytes);
          if (ext == null) continue;
          if (stored + bytes!.length > maxCoverStore) {
            _log.w('Phone covers are over their limit; leaving the rest out');
            break fetching;
          }
          await writeLinkCover(folder, batch[i].id, ext, bytes);
          stored += bytes.length;
          added++;
        }
      }
    } on Object catch (error) {
      _log.w('Could not fetch the phone songs\' covers: $error');
    } finally {
      _coverBytes[sourceId] = stored;
    }
    if (added > 0) _onCommit?.call(deviceId);
  }

  /// The bytes of the covers held for the phone [sourceId].
  Future<int> _storedBytes(String sourceId, Map<String, String> held) async {
    if (_coverBytes[sourceId] case final bytes?) return bytes;
    var bytes = 0;
    for (final path in held.values) {
      try {
        bytes += await File(path).length();
      } on FileSystemException {
        // Removed meanwhile.
      }
    }
    return bytes;
  }

  Future<Object?> _covers(LinkRequest request) async {
    if (request.method == 'GET') {
      final sourceId = await _sourceFor(request, write: false);
      // The phone sends the covers left out, so the list must not name one
      // a queued removal takes away.
      await _pruning[sourceId];
      return {
        'ids': [...(await coverPaths(sourceId)).keys],
      };
    }
    final sourceId = await _sourceFor(request, write: true);
    return _serial(sourceId, () => _addCovers(sourceId, request.args));
  }

  /// Stores the valid covers of a `POST phone/covers`; a cover with a bad
  /// id, type or size is left out.
  Future<Object?> _addCovers(String sourceId, Map<String, dynamic> args) async {
    final covers = args['covers'];
    if (covers is! List) throw _invalid('Missing covers');
    var characters = 0;
    for (final cover in covers) {
      if (cover is Map && cover['data'] is String) {
        characters += (cover['data'] as String).length;
      }
    }
    if (characters > maxCoversRequest) throw _invalid('Too many covers');
    final folder = '${await _folder(sourceId)}/covers';
    await Directory(folder).create(recursive: true);
    final held = await coverPaths(sourceId);
    var stored = await _storedBytes(sourceId, held);
    try {
      for (final cover in covers) {
        if (cover is! Map) continue;
        final id = cover['id'];
        final ext = cover['ext'];
        final data = cover['data'];
        if (id is! String ||
            !isLinkFileId(id) ||
            !_coverExtensions.contains(ext) ||
            data is! String ||
            held.containsKey(id)) {
          continue;
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          continue;
        }
        if (bytes.isEmpty || bytes.length > maxCoverBytes) continue;
        if (stored + bytes.length > maxCoverStore) {
          _log.w('Phone covers are over their limit; leaving the rest out');
          break;
        }
        await writeLinkCover(folder, id, ext as String, bytes);
        held[id] = '$folder/$id.$ext';
        stored += bytes.length;
      }
    } finally {
      _coverBytes[sourceId] = stored;
    }
    return const {'ok': true};
  }

  /// Removes covers neither the committed list ([keep]) nor the Library
  /// names, with [writtenBefore] only those written before it. Library rows
  /// name the old covers until the rescan after a commit moves them, so
  /// those go at a later prune.
  Future<void> _pruneCovers(
    String sourceId,
    Set<String> keep, {
    DateTime? writtenBefore,
  }) async {
    final Set<String> shown;
    try {
      shown = {
        for (final path in await _libraryCovers(sourceId)) p.basename(path),
      };
    } on Object catch (error) {
      _log.w('Could not read which phone covers Library shows: $error');
      return;
    }
    final held = await coverPaths(sourceId);
    for (final MapEntry(:key, :value) in held.entries) {
      if (keep.contains(key) || shown.contains(p.basename(value))) continue;
      try {
        final file = File(value);
        if (writtenBefore != null &&
            !(await file.lastModified()).isBefore(writtenBefore)) {
          continue;
        }
        _coverBytes.remove(sourceId);
        await file.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }

  /// The version of the list the phone [sourceId] last committed, or null.
  Future<String?> version(String sourceId) async {
    if (_versions.containsKey(sourceId)) return _versions[sourceId];
    String? version;
    try {
      final file = await File(
        '${await _folder(sourceId)}/$_catalogName',
      ).open();
      try {
        final head = await file.read(1024);
        final end = head.indexOf(_newline);
        if (end > 0) {
          final header = jsonDecode(utf8.decode(head.sublist(0, end)));
          if (header is Map && header['version'] is String) {
            version = header['version'] as String;
          }
        }
      } finally {
        await file.close();
      }
    } on FileSystemException {
      // Nothing committed yet.
    } on FormatException {
      // A damaged list; the phone sends it again.
    }
    return _versions[sourceId] = version;
  }

  /// The songs of the list the phone [sourceId] committed. The file is read
  /// at once, so a commit meanwhile never waits for a slow reader.
  Stream<LinkPhoneSong> songs(String sourceId) async* {
    final deleted = await _deletedSongs(sourceId);
    await for (final song in _readSongs(sourceId)) {
      if (!deleted.contains(song.fileId)) yield song;
    }
  }

  Stream<LinkPhoneSong> _readSongs(String sourceId) async* {
    final Uint8List bytes;
    try {
      bytes = await File(
        '${await _folder(sourceId)}/$_catalogName',
      ).readAsBytes();
    } on FileSystemException {
      return;
    }
    // The first line is the version.
    var start = bytes.indexOf(_newline) + 1;
    if (start <= 0) return;
    while (start < bytes.length) {
      var end = bytes.indexOf(_newline, start);
      if (end < 0) end = bytes.length;
      final song = _decode(bytes, start, end);
      start = end + 1;
      if (song != null) yield song;
    }
  }

  /// The committed song of the phone [sourceId] with [fileId], or null.
  Future<LinkPhoneSong?> song(String sourceId, String fileId) async {
    if (!isLinkFileId(fileId)) return null;
    if ((await _deletedSongs(sourceId)).contains(fileId)) return null;
    final Uint8List bytes;
    try {
      bytes = await File(
        '${await _folder(sourceId)}/$_catalogName',
      ).readAsBytes();
    } on FileSystemException {
      return null;
    }
    // Lines are written by [LinkPhoneSong.toJson], which puts fileId first.
    final prefix = utf8.encode('{"fileId":"$fileId"');
    bool matches(int start, int end) {
      if (end - start < prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (bytes[start + i] != prefix[i]) return false;
      }
      return true;
    }

    var start = bytes.indexOf(_newline) + 1;
    if (start <= 0) return null;
    while (start < bytes.length) {
      var end = bytes.indexOf(_newline, start);
      if (end < 0) end = bytes.length;
      if (matches(start, end)) return _decode(bytes, start, end);
      start = end + 1;
    }
    return null;
  }

  Future<Set<String>> _deletedSongs(String sourceId) =>
      _deleted.putIfAbsent(sourceId, () async {
        final ids = <String>{};
        final folder = Directory('${await _folder(sourceId)}/deleted');
        if (await folder.exists()) {
          await for (final file in folder.list(followLinks: false)) {
            final id = p.basename(file.path);
            if (file is File && isLinkFileId(id)) ids.add(id);
          }
        }
        return ids;
      });

  /// Keep confirmed deletions out of stale or in-flight catalog snapshots,
  /// including after a desktop restart. The phone remains the file owner.
  Future<void> recordDeleted(String deviceId, String fileId) {
    final sourceId = linkPhoneSourceId(deviceId);
    return _serial(sourceId, () async {
      if (!isLinkFileId(fileId) || await song(sourceId, fileId) == null) return;
      final deleted = await _deletedSongs(sourceId);
      final folder = Directory('${await _folder(sourceId)}/deleted');
      await folder.create(recursive: true);
      await File('${folder.path}/$fileId').writeAsString('', flush: true);
      deleted.add(fileId);
      _onCommit?.call(deviceId);
    });
  }

  /// Once a full phone snapshot omits a deleted song, a later deliberate
  /// re-import of that file can appear normally again.
  Future<void> _pruneDeleted(String sourceId) async {
    final deleted = await _deletedSongs(sourceId);
    if (deleted.isEmpty) return;
    final absent = {...deleted};
    await for (final song in _readSongs(sourceId)) {
      absent.remove(song.fileId);
    }
    final folder = '${await _folder(sourceId)}/deleted';
    for (final fileId in absent) {
      await File('$folder/$fileId').delete();
      deleted.remove(fileId);
    }
  }

  static LinkPhoneSong? _decode(Uint8List bytes, int start, int end) {
    if (end <= start) return null;
    try {
      return LinkPhoneSong.fromJson(
        jsonDecode(utf8.decode(Uint8List.sublistView(bytes, start, end))),
      );
    } on FormatException {
      return null;
    }
  }

  /// A playing track in one phone's catalog. Older phones send no file id,
  /// so use the same recording identity as the desktop's own catalog.
  Future<LinkPhoneSong?> songForRef(String sourceId, TrackRef ref) async {
    if (ref.fileId case final fileId?) return song(sourceId, fileId);
    final isrc = normalizeIsrc(ref.isrc ?? '');
    final key = ref.matchKey ?? linkMatchKey(ref.title, ref.artist);
    final titleKey = linkMatchKey(ref.title, ref.artist);
    LinkPhoneSong? fallback;
    var bestDifference = 1 << 62;
    await for (final candidate in songs(sourceId)) {
      if (isrc.isNotEmpty && normalizeIsrc(candidate.isrc ?? '') == isrc) {
        return candidate;
      }
      final candidateKey = linkMatchKey(candidate.title, candidate.artist);
      if (candidateKey.isEmpty ||
          (candidateKey != key && candidateKey != titleKey)) {
        continue;
      }
      final duration = ref.durationMs;
      final actual = candidate.durationMs;
      final difference = duration == null || actual == null
          ? linkDurationToleranceMs
          : (duration - actual).abs();
      if (difference <= linkDurationToleranceMs &&
          difference < bestDifference) {
        fallback = candidate;
        bestDifference = difference;
      }
    }
    return fallback;
  }

  /// The covers held for the phone [sourceId] by cover id.
  Future<Map<String, String>> coverPaths(String sourceId) async {
    final folder = '${await _folder(sourceId)}/covers';
    final covers = <String, String>{};
    try {
      await for (final entry in Directory(folder).list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final match = _coverName.firstMatch(name);
        if (match != null) covers[match[1]!] = '$folder/$name';
      }
    } on FileSystemException {
      // No covers yet.
    }
    return covers;
  }

  /// The cover [coverId] held for the phone [sourceId], or null.
  Future<String?> coverPath(String sourceId, String coverId) async {
    if (!isLinkFileId(coverId)) return null;
    final folder = '${await _folder(sourceId)}/covers';
    for (final ext in _coverExtensions) {
      final path = '$folder/$coverId.$ext';
      if (await File(path).exists()) return path;
    }
    return null;
  }

  /// The covers of the songs [fileIds] across the phones here: the cover
  /// file held, else the web address the phone listed.
  Future<Map<String, String>> coversFor(Set<String> fileIds) async {
    final covers = <String, String>{};
    if (fileIds.isEmpty) return covers;
    for (final sourceId in await sourceIds()) {
      final held = await coverPaths(sourceId);
      await for (final song in songs(sourceId)) {
        if (!fileIds.contains(song.fileId) || covers.containsKey(song.fileId)) {
          continue;
        }
        final cover = held[song.coverKey] ?? song.coverUrl;
        if (cover != null) covers[song.fileId] = cover;
      }
    }
    return covers;
  }

  /// The phones with a folder here, by source id.
  Future<List<String>> sourceIds() async {
    final ids = <String>[];
    try {
      await for (final entry in (await _root()).list(followLinks: false)) {
        final name = entry.uri.pathSegments.lastWhere(
          (segment) => segment.isNotEmpty,
          orElse: () => '',
        );
        if (entry is Directory && isLinkPhoneSourceId(name)) ids.add(name);
      }
    } on FileSystemException {
      // No phone sent its songs yet.
    }
    return ids;
  }

  /// Whether the phone's Library source was added once already.
  Future<bool> hasLibrarySource(String sourceId) async =>
      File('${await _folder(sourceId)}/$_librarySourceName').exists();

  /// Notes that the phone's Library source was added, so a later commit
  /// does not add it again after the owner removed it.
  Future<void> markLibrarySource(String sourceId) async {
    final folder = await _folder(sourceId);
    await Directory(folder).create(recursive: true);
    await File('$folder/$_librarySourceName').writeAsString('');
  }

  /// Removes everything kept for the phone [sourceId].
  Future<void> remove(String sourceId) => _serial(sourceId, () async {
    await _uploads.remove(sourceId)?.discard();
    _versions.remove(sourceId);
    _coverBytes.remove(sourceId);
    _triedCovers.remove(sourceId);
    _deleted.remove(sourceId);
    try {
      await Directory(await _folder(sourceId)).delete(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
  });
}

/// A list a phone is sending, written to a part file page by page.
class _Upload {
  _Upload(this.file, this.version, this.total);

  final File file;
  final String version;
  final int total;

  /// The cover keys the songs name.
  final coverIds = <String>{};

  /// The web addresses of covers the phone holds no file of, by cover key.
  final coverUrls = <String, String>{};

  /// The offset of the next page.
  int next = 0;

  static Future<_Upload> start(File file, String version, int total) async {
    await file.writeAsString(
      '${jsonEncode({'version': version})}\n',
      flush: true,
    );
    return _Upload(file, version, total);
  }

  /// Appends a page. Songs the desktop cannot list are left out; they still
  /// count towards [total].
  Future<void> add(List<Object?> songs) async {
    final buffer = StringBuffer();
    for (final json in songs) {
      final song = LinkPhoneSong.fromJson(json);
      if (song == null) continue;
      final line = jsonEncode(song.toJson());
      if (line.length > LinkPhoneCatalogs.maxSongLine) continue;
      buffer.writeln(line);
      if (song.coverKey case final key?) {
        coverIds.add(key);
        if (song.coverId == null) coverUrls[key] = song.coverUrl!;
      }
    }
    if (buffer.isNotEmpty) {
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
    }
    next += songs.length;
  }

  /// Puts the list in place of [target]. On Windows a reader with the old
  /// list open blocks the rename briefly.
  Future<void> commit(File target) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await file.rename(target.path);
        return;
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> discard() async {
    try {
      await file.delete();
    } on FileSystemException {
      // Never written.
    }
  }
}
