import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

/// Durable local files for cover references.
///
/// A file reference (an absolute path or a `file://` URI) passes through
/// while its file exists. A `network://` cover is fetched once, directly
/// over its connection, into `<support>/covers/` as
/// `<reference key>_<content key>.image`: a reference keeps one path while
/// its bytes stay the same, and changed bytes give a new path, so caches
/// keyed by path show the new image. `https` covers stay with
/// CoverCacheManager; `content://` and other references are not stored.
///
/// Stored covers are caches: [trim] may delete any of them, as their
/// reference can always fetch them again.
class CoverStore {
  CoverStore({
    Future<Directory> Function()? directory,
    Future<void> Function(String ref, File output)? fetch,
    this.maxFiles = 2000,
    this.maxBytes = 200 * 1024 * 1024,
    this.maxFetches = 4,
    this.retryDelay = const Duration(minutes: 1),
  }) : assert(maxFetches > 0),
       _directory = directory ?? defaultDirectory,
       _fetcher = fetch ?? NetworkStorageService.instance.downloadCover;

  static final instance = CoverStore();

  static Future<Directory> defaultDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'covers'),
  );

  /// How many stored covers, and how many bytes of them, [trim] keeps.
  final int maxFiles, maxBytes;

  /// How many covers are fetched at once; more fetches wait their turn.
  final int maxFetches;

  /// How long a reference whose fetch failed waits before fetching again;
  /// an hour when the server answered that the cover is missing or not an
  /// image.
  final Duration retryDelay;

  final Future<Directory> Function() _directory;
  final Future<void> Function(String ref, File output) _fetcher;
  static final _log = AppLogger('CoverStore');
  static final _storedName = RegExp(r'^([0-9a-f]{32})_[0-9a-f]{16}\.image$');
  static const _refreshAge = Duration(days: 1);
  static const _stagingAge = Duration(hours: 1);
  static const _missingRetryDelay = Duration(hours: 1);
  static const _heifBrands = {
    'avif',
    'avis',
    'heic',
    'heim',
    'heis',
    'heix',
    'hevc',
    'hevm',
    'hevs',
    'hevx',
    'mif1',
    'msf1',
  };

  /// The current stored file name of each reference key.
  final _index = <String, String>{};

  /// Fetches under way and when fetches last failed, by reference key.
  final _fetches = <String, Future<String?>>{};
  final _failures = <String, ({DateTime at, Duration wait})>{};

  /// Reference keys [invalidate]d since their cover was last checked.
  final _stale = <String>{};

  /// Fetches holding a turn, and fetches waiting for one: fetches a caller
  /// awaits go before background rechecks.
  var _fetching = 0;
  final _turns = Queue<Completer<void>>();
  final _rechecks = Queue<Completer<void>>();

  /// Names being written or touched now, which [trim] leaves alone.
  final _busy = <String>{};
  final _changes = StreamController<String>.broadcast();
  Future<void>? _warming;
  String? _root;

  /// References whose stored cover moved to a new path because its bytes
  /// changed; [cachedFile] answers the new path.
  Stream<String> get changes => _changes.stream;

  /// Whether [ref] names a cover the store fetches (`network://`).
  static bool fetches(String? ref) =>
      ref != null && ref.startsWith('network://');

  /// The reference [adopt] keeps the cover in the tags of the `network://`
  /// song [source] under. No server answers it, so it lasts while stored.
  static String songCoverReference(String source) => '$source$_songCover';

  static const _songCover = '#cover';

  /// Whether only [adopt] stores [ref], which no server answers.
  static bool _adoptedOnly(String ref) => ref.endsWith(_songCover);

  /// Reads which covers are stored, so [cachedFile] answers covers saved
  /// in earlier runs. [file] and [trim] wait for it themselves.
  Future<void> warmUp() {
    if (_root != null) return Future.value();
    return _warming ??= _readIndex().whenComplete(() => _warming = null);
  }

  /// The durable local file for [ref] when it is on disk now, without
  /// fetching: an existing absolute path or `file://` file, or a network
  /// cover stored earlier (covers of earlier runs once [warmUp] is done).
  /// Safe on the first frame.
  String? cachedFile(String? ref) {
    if (ref == null || ref.isEmpty) return null;
    final path = fetches(ref) ? indexedFile(ref) : _localPath(ref);
    return path != null && File(path).existsSync() ? path : null;
  }

  /// The file the store names for the network cover [ref], read from memory
  /// without any file IO, so it is safe while building widgets. Null for
  /// other references, for covers not stored, and for covers of earlier
  /// runs until [warmUp] is done. The file can be gone since, as after a
  /// cleared folder; [file] checks it and fetches again.
  String? indexedFile(String? ref) {
    if (!fetches(ref)) return null;
    final root = _root;
    final name = _index[_key(ref!)];
    return root == null || name == null ? null : p.join(root, name);
  }

  /// The durable local file for [ref], fetching a `network://` cover once.
  /// Null for references the store does not materialize (`https`, which
  /// stays with CoverCacheManager) or when the cover is unavailable.
  /// Concurrent calls for one reference share one fetch, at most
  /// [maxFetches] references are fetched at once, and a failed fetch waits
  /// [retryDelay] before the next. A cover stored more than a day ago (or
  /// dated more than a day ahead) is answered at once and fetched again in
  /// the background, after the fetches callers await: [changes] reports
  /// when its bytes changed.
  Future<String?> file(String? ref) async {
    if (ref == null || ref.isEmpty) return null;
    if (!fetches(ref)) {
      final path = _localPath(ref);
      return path != null && await File(path).exists() ? path : null;
    }
    await warmUp();
    final root = _root;
    if (root == null) return null;
    final key = _key(ref);
    if (_index[key] case final name?) {
      final path = p.join(root, name);
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.file) {
        // A date ahead of the clock means the clock was wrong when saved.
        final due =
            _stale.remove(key) ||
            DateTime.now().difference(stat.modified).abs() >= _refreshAge;
        if (due && !_failedRecently(key) && !_adoptedOnly(ref)) {
          unawaited(_fetch(ref, root, key, recheck: true));
        }
        return path;
      }
      if (_index[key] == name) _index.remove(key);
    }
    if (_failedRecently(key) || _adoptedOnly(ref)) return null;
    _stale.remove(key);
    return _fetch(ref, root, key);
  }

  /// The server changed the cover [ref], or can be reached again: drops
  /// the wait after a failed fetch, and the next [file] call checks a
  /// stored copy again in the background. Fetches nothing itself, so a
  /// burst of changes to covers nobody shows costs nothing.
  void invalidate(String? ref) {
    if (!fetches(ref)) return;
    final key = _key(ref!);
    _failures.remove(key);
    _stale.add(key);
  }

  /// Deletes the stored cover [ref] and its older copies, which the next
  /// run would read as the cover, as for a song whose tags hold no cover
  /// any more.
  Future<void> forget(String? ref) async {
    if (!fetches(ref)) return;
    await warmUp();
    final root = _root;
    final key = _key(ref!);
    if (_index.remove(key) == null || root == null) return;
    try {
      await for (final entry in Directory(root).list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (entry is File &&
            !_busy.contains(name) &&
            _storedName.firstMatch(name)?[1] == key) {
          await deleteFileQuietly(entry);
        }
      }
    } on FileSystemException catch (error) {
      _log.d('Could not delete a cover: ${error.runtimeType}');
    }
  }

  /// The stored cover the song [source] shows, read from the index like
  /// [indexedFile]: the cover from its tags once [adopt]ed (see
  /// [songCoverReference]), else its network cover [reference]. Null when
  /// neither is stored.
  ({String reference, String path})? songCover(
    String source, [
    String? reference,
  ]) {
    final tags = songCoverReference(source);
    if (indexedFile(tags) case final path?) {
      return (reference: tags, path: path);
    }
    if (indexedFile(reference) case final path?) {
      return (reference: reference!, path: path);
    }
    return null;
  }

  /// Stores a copy of the image at the local [path] as the cover of the
  /// network reference [ref], named by its bytes as a fetched cover is,
  /// for a cover that reached the device another way (see
  /// [songCoverReference]). Null when [path] is not a cover image or could
  /// not be copied.
  Future<String?> adopt(String ref, String path) async {
    if (!fetches(ref)) return null;
    await warmUp();
    final root = _root;
    if (root == null) return null;
    try {
      return await _write(ref, root, _key(ref), (staged) async {
        await Directory(root).create(recursive: true);
        await File(path).copy(staged.path);
      });
    } catch (error) {
      _log.d('Could not store a cover: ${error.runtimeType}');
      return null;
    }
  }

  /// Deletes superseded covers and abandoned staging files, then the
  /// covers validated longest ago (a cover dated more than a day ahead
  /// counts as the oldest) until at most [maxFiles] covers of at most
  /// [maxBytes] remain.
  Future<void> trim() async {
    await warmUp();
    final root = _root;
    if (root == null) return;
    final directory = Directory(root);
    if (!await directory.exists()) return;
    final now = DateTime.now();
    final current = <({String key, String name, File file, FileStat stat})>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      final stat = await entry.stat();
      // A fetch can take up the name while the stat is under way.
      if (_busy.contains(name) || stat.type != FileSystemEntityType.file) {
        continue;
      }
      if (name.endsWith('.tmp')) {
        if (now.difference(stat.modified) > _stagingAge) {
          await deleteFileQuietly(entry);
        }
        continue;
      }
      final key = _storedName.firstMatch(name)?[1];
      if (key == null) continue;
      if (_index[key] == name) {
        current.add((key: key, name: name, file: entry, stat: stat));
      } else {
        await deleteFileQuietly(entry);
      }
    }
    current.sort(
      (a, b) => _validated(
        a.stat.modified,
        now,
      ).compareTo(_validated(b.stat.modified, now)),
    );
    var count = current.length;
    var bytes = current.fold(0, (sum, cover) => sum + cover.stat.size);
    for (final cover in current) {
      if (count <= maxFiles && bytes <= maxBytes) break;
      if (_busy.contains(cover.name)) continue;
      await deleteFileQuietly(cover.file);
      if (_index[cover.key] == cover.name) _index.remove(cover.key);
      count--;
      bytes -= cover.stat.size;
    }
  }

  /// Waits for fetches under way, then closes [changes].
  Future<void> dispose() async {
    await Future.wait(_fetches.values.toList());
    await _changes.close();
  }

  Future<void> _readIndex() async {
    try {
      final root = await _directory();
      final now = DateTime.now();
      final newest = <String, ({String name, DateTime modified})>{};
      if (await root.exists()) {
        await for (final entry in root.list(followLinks: false)) {
          if (entry is! File) continue;
          final name = p.basename(entry.path);
          final key = _storedName.firstMatch(name)?[1];
          if (key == null) continue;
          final stat = await entry.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final modified = _validated(stat.modified, now);
          final known = newest[key];
          if (known == null || modified.isAfter(known.modified)) {
            newest[key] = (name: name, modified: modified);
          }
        }
      }
      for (final MapEntry(:key, :value) in newest.entries) {
        _index.putIfAbsent(key, () => value.name);
      }
      _root = root.path;
    } catch (error) {
      _log.w('Could not read stored covers: ${error.runtimeType}');
    }
  }

  Future<String?> _fetch(
    String ref,
    String root,
    String key, {
    bool recheck = false,
  }) => _fetches.putIfAbsent(key, () async {
    try {
      return await _save(ref, root, key, recheck: recheck);
    } catch (error) {
      _failures[key] = (
        at: DateTime.now(),
        wait: error is NetworkMediaUnavailable || error is FormatException
            ? _missingRetryDelay
            : retryDelay,
      );
      _log.d('Could not fetch a network cover: ${error.runtimeType}');
      return null;
    } finally {
      _fetches.remove(key);
    }
  });

  Future<String> _save(
    String ref,
    String root,
    String key, {
    required bool recheck,
  }) => _write(ref, root, key, (staged) async {
    await _takeTurn(recheck: recheck);
    try {
      await Directory(root).create(recursive: true);
      await _fetcher(ref, staged);
    } finally {
      _endTurn();
    }
  });

  /// Stores the cover [fill] writes to a staged file as the cover of [ref].
  Future<String> _write(
    String ref,
    String root,
    String key,
    Future<void> Function(File staged) fill,
  ) async {
    final stagedName = '$key.${NetworkStorageService.newId()}.tmp';
    final staged = File(p.join(root, stagedName));
    String? name;
    _busy.add(stagedName);
    try {
      await fill(staged);
      name = '${key}_${await _contentKey(staged)}.image';
      _busy.add(name);
      final target = File(p.join(root, name));
      if (await target.exists()) {
        await target.setLastModified(DateTime.now());
      } else {
        await staged.rename(target.path);
      }
      _failures.remove(key);
      final previous = _index[key];
      _index[key] = name;
      if (previous != null && previous != name && !_changes.isClosed) {
        _changes.add(ref);
      }
      return target.path;
    } finally {
      _busy
        ..remove(stagedName)
        ..remove(name);
      await deleteFileQuietly(staged);
    }
  }

  /// The content key of the staged cover [file]; throws unless it is a
  /// known image format of at most [NetworkStorageService.maxCoverBytes].
  static Future<String> _contentKey(File file) async {
    final size = await file.length();
    if (size == 0 || size > NetworkStorageService.maxCoverBytes) {
      throw const FormatException('Invalid cover size');
    }
    final head = await file.openRead(0, 12).expand((chunk) => chunk).toList();
    if (!_isImage(head)) throw const FormatException('Not a cover image');
    final digest = await sha256.bind(file.openRead()).single;
    return digest.toString().substring(0, 16);
  }

  /// Whether [head], the first 12 bytes of a file, starts a JPEG, PNG, GIF,
  /// WebP, BMP, HEIF or AVIF image.
  static bool _isImage(List<int> head) {
    bool has(int offset, String magic) =>
        head.length >= offset + magic.length &&
        String.fromCharCodes(head, offset, offset + magic.length) == magic;
    return has(0, '\xFF\xD8\xFF') ||
        has(0, '\x89PNG\r\n\x1A\n') ||
        has(0, 'GIF8') ||
        (has(0, 'RIFF') && has(8, 'WEBP')) ||
        has(0, 'BM') ||
        (has(4, 'ftyp') &&
            head.length >= 12 &&
            _heifBrands.contains(String.fromCharCodes(head, 8, 12)));
  }

  static String _key(String ref) =>
      sha256.convert(utf8.encode(ref)).toString().substring(0, 32);

  Future<void> _takeTurn({required bool recheck}) async {
    if (_fetching < maxFetches) {
      _fetching++;
      return;
    }
    final turn = Completer<void>();
    (recheck ? _rechecks : _turns).add(turn);
    await turn.future;
  }

  /// Hands the turn to the next waiting fetch, if any: a fetch a caller
  /// awaits goes before a background recheck.
  void _endTurn() {
    if (_turns.isNotEmpty) {
      _turns.removeFirst().complete();
    } else if (_rechecks.isNotEmpty) {
      _rechecks.removeFirst().complete();
    } else {
      _fetching--;
    }
  }

  /// [modified] as a validation time: a file dated more than a day ahead
  /// counts as the oldest, so a clock that ran ahead cannot pin it.
  static DateTime _validated(DateTime modified, DateTime now) =>
      modified.difference(now) >= _refreshAge
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : modified;

  bool _failedRecently(String key) {
    final failed = _failures[key];
    if (failed == null) return false;
    if (DateTime.now().difference(failed.at) < failed.wait) return true;
    _failures.remove(key);
    return false;
  }

  /// The local path an absolute path or `file://` reference names.
  static String? _localPath(String ref) {
    if (File(ref).isAbsolute) return ref;
    final uri = Uri.tryParse(ref);
    if (uri == null || !uri.isScheme('file')) return null;
    try {
      return uri.toFilePath();
    } on UnsupportedError {
      return null;
    }
  }
}

/// [reference] when it names a cover that outlasts this run, else null: a
/// loopback URL ends with the app's process, and a file in a temporary
/// folder goes with the next purge. Other references pass unchanged.
String? durableCoverReference(String? reference) {
  final value = reference?.trim();
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
    final host = uri.host.toLowerCase();
    final loopback =
        host == 'localhost' ||
        (InternetAddress.tryParse(host)?.isLoopback ?? false);
    return loopback ? null : value;
  }
  final path = CoverStore._localPath(value);
  if (path == null) return value;
  final normalized = p.normalize(path);
  // Network tags and download previews are read to these temporary folders.
  final temporary =
      p
          .split(normalized)
          .any(
            (part) =>
                part == 'network_metadata' ||
                part.startsWith('download_cover_preview_'),
          ) ||
      p.isWithin(p.normalize(Directory.systemTemp.path), normalized);
  return temporary ? null : value;
}
