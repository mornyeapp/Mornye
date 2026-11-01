import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('LinkWebCovers');

final _coverName = RegExp(r'^([0-9a-f]{32})\.(jpg|png|webp)$');
const _picturesName = 'pictures.json';
const _maxRedirects = 5;

/// A host of only numbers, which some resolvers read as an IPv4 address.
final _numericHost = RegExp(
  r'^(?:(?:0x[0-9a-f]*|\d+)\.)*(?:0x[0-9a-f]*|\d+)\.?$',
);

/// Fetches a cover from its web address; null when it cannot.
typedef LinkCoverFetcher = Future<Uint8List?> Function(Uri url);

/// Whether each audio file of [paths] embeds a picture; null for one that
/// cannot be read.
typedef LinkPictureProbe = Future<List<bool?>> Function(List<String> paths);

/// A song without a local cover file whose cover is the web address [url].
/// [stamp] is the [linkPictureStamp] of its audio file [path].
typedef LinkWebCoverSong = ({String path, String stamp, String url});

/// One version of the audio file at [path]: its path, mtime and size.
String linkPictureStamp(String path, FileStat stat) =>
    '$path\n${stat.modified.millisecondsSinceEpoch}\n${stat.size}';

/// The largest cover fetched from the web; a larger one is left out.
const linkMaxFetchedCoverBytes = 24 * 1024 * 1024;

/// Fetches a cover of at most [linkMaxFetchedCoverBytes]. With [allow],
/// redirects are followed by hand, at most 5, and every address must pass
/// [allow]. With [deadline], the request is closed once it passes.
Future<Uint8List?> fetchLinkCover(
  Uri url, {
  bool Function(Uri url)? allow,
  Duration? deadline,
}) async {
  const timeout = Duration(seconds: 20);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  var expired = false;
  final timer = deadline == null
      ? null
      : Timer(deadline, () {
          expired = true;
          client.close(force: true);
        });
  try {
    var target = url;
    for (var redirects = 0; ; redirects++) {
      if (allow != null && !allow(target)) return null;
      final request = await client.getUrl(target);
      if (allow != null) request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (allow != null && response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        unawaited(response.listen(null).cancel());
        if (location == null || redirects >= _maxRedirects) return null;
        target = target.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > linkMaxFetchedCoverBytes) return null;
      }
      return expired ? null : bytes.takeBytes();
    }
  } finally {
    timer?.cancel();
    client.close(force: true);
  }
}

/// Fetches the web cover of one of the desktop's own songs: only from
/// [isLinkWebCoverUrl] addresses, redirects included, within [deadline].
Future<Uint8List?> fetchLinkWebCover(
  Uri url, {
  Duration deadline = LinkWebCovers.fetchTimeout,
}) => fetchLinkCover(url, allow: isLinkWebCoverUrl, deadline: deadline);

/// Whether the desktop fetches a web cover from [url]: `https`, and not
/// `localhost` or a loopback, link-local or private address literal.
bool isLinkWebCoverUrl(Uri url) {
  if (linkCoverUrl(url.toString()) == null) return false;
  var host = url.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host == 'localhost' || host.endsWith('.localhost')) return false;
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    return !host.contains(':') && !_numericHost.hasMatch(host);
  }
  var bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    // Only the plain dotted form; a resolver may read `0177.1` as loopback.
    if (address.address != host) return false;
  } else {
    final embedded =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == bytes[11] &&
        (bytes[10] == 0 || bytes[10] == 0xFF);
    if (!embedded) {
      return !(address.isLoopback ||
          address.isLinkLocal ||
          (bytes[0] & 0xFE) == 0xFC);
    }
    // An IPv4 address in IPv6 form (`::ffff:a.b.c.d`, `::a.b.c.d`, and so
    // `::` and `::1`) counts as that address.
    bytes = bytes.sublist(12);
  }
  final [a, b, _, _] = bytes;
  return !(a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 100 && b >= 64 && b <= 127));
}

/// `jpg`, `png` or `webp` from an image's first bytes, else null.
String? linkCoverExtension(Uint8List bytes) {
  bool starts(int offset, List<int> magic) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts(0, const [0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (starts(0, ascii.encode('RIFF')) && starts(8, ascii.encode('WEBP'))) {
    return 'webp';
  }
  return null;
}

/// Writes the cover `<id>.<ext>` into [folder] through a staged file, so a
/// reader never sees part of it. A failed write leaves nothing behind.
Future<void> writeLinkCover(
  String folder,
  String id,
  String ext,
  Uint8List bytes,
) async {
  final staged = File('$folder/.$id.$ext.tmp');
  try {
    await staged.writeAsBytes(bytes, flush: true);
    await staged.rename('$folder/$id.$ext');
  } on Object {
    try {
      await staged.delete();
    } on FileSystemException {
      // Never written.
    }
    rethrow;
  }
}

/// The covers of the desktop's own songs that have no picture but a web
/// address, for the catalog the Link server reads (contract section 5):
/// songs without a local cover file whose audio file embeds no picture.
/// Each address is kept once as `<linkCoverUrlId(url)>.<ext>` in its
/// folder: fetched after an export, named by the next one, removed once no
/// exported song wants it. Which files embed a picture is asked once per
/// file version and kept in `pictures.json` there.
class LinkWebCovers {
  LinkWebCovers({
    required Future<Directory> Function() folder,
    required LinkPictureProbe probe,
    LinkCoverFetcher? fetchCover,
    LinkCoverShrinker? shrinkCover,
    DateTime Function()? now,
    this.firstRetry = const Duration(minutes: 1),
    this.lastRetry = const Duration(hours: 6),
    this.maxStore = 1024 * 1024 * 1024,
  }) : _folder = folder,
       _probe = probe,
       _fetch = fetchCover ?? fetchLinkWebCover,
       _shrink = shrinkCover ?? shrinkLinkCover,
       _now = now ?? DateTime.now;

  /// The largest cover kept as fetched; a larger one is kept shrunk to
  /// [linkShrunkCoverSize].
  static const maxCoverBytes = 2 * 1024 * 1024;

  /// The covers fetched at once.
  static const fetchesAtOnce = 4;

  /// The audio files asked about at once.
  static const probesAtOnce = 64;

  /// The longest one cover may take to fetch.
  static const fetchTimeout = Duration(minutes: 1);

  /// The wait before a failed cover is tried again; it doubles with each
  /// failure in a row, up to [lastRetry].
  final Duration firstRetry;
  final Duration lastRetry;

  /// The most cover bytes kept; further covers are left out until a prune
  /// frees space.
  final int maxStore;

  final Future<Directory> Function() _folder;
  final LinkPictureProbe _probe;
  final LinkCoverFetcher _fetch;
  final LinkCoverShrinker _shrink;
  final DateTime Function() _now;
  final _added = StreamController<void>.broadcast();

  /// The songs of the catalog the server reads.
  var _songs = const <LinkWebCoverSong>[];

  /// The covers those songs want, by cover id: songs whose audio file is
  /// known to embed no picture.
  var _wanted = <String, Uri>{};

  /// Whether each audio file version ([linkPictureStamp]) embeds a picture.
  Future<Map<String, bool>>? _pictures;

  /// The covers that failed, by cover id: how often in a row, and when to
  /// try again.
  final _failures = <String, ({int count, DateTime retryAt})>{};

  /// The covers fill [maxStore]; nothing is fetched until a prune frees
  /// space.
  var _full = false;
  Future<void> _queue = Future.value();
  Future<void>? _running;
  var _runAgain = false;
  Timer? _retry;

  /// Fires after the next export can name more covers.
  Stream<void> get added => _added.stream;

  /// Completes when no fetch runs.
  @visibleForTesting
  Future<void> idle() async {
    for (var running = _running; running != null; running = _running) {
      await running;
    }
  }

  /// Runs the listings and removals one after another.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// The covers held by cover id. It waits for a removal queued before it,
  /// so an export never names a cover about to go.
  Future<Map<String, String>> held() => _serial(_list);

  /// Whether each audio file version ([linkPictureStamp]) is known to embed
  /// a picture, for an export.
  Future<Map<String, bool>> pictures() async => Map.of(await _loadPictures());

  Future<Map<String, String>> _list() async {
    final covers = <String, String>{};
    try {
      final folder = (await _folder()).path;
      await for (final entry in Directory(folder).list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final match = _coverName.firstMatch(name);
        if (match != null) covers[match[1]!] = '$folder/$name';
      }
    } on FileSystemException {
      // No covers yet.
    } on Object catch (error) {
      _log.w('Could not list the web covers: $error');
    }
    return covers;
  }

  Future<Map<String, bool>> _loadPictures() => _pictures ??= () async {
    try {
      final file = File('${(await _folder()).path}/$_picturesName');
      final json = jsonDecode(await file.readAsString());
      final pictures = json is Map ? json['pictures'] : null;
      if (pictures is Map) {
        return {
          for (final MapEntry(:key, :value) in pictures.entries)
            if (key is String && value is bool) key: value,
        };
      }
    } on Object {
      // Not asked yet, or a damaged file: ask again.
    }
    return <String, bool>{};
  }();

  Future<void> _savePictures(Map<String, bool> pictures) async {
    try {
      final folder = (await _folder()).path;
      await Directory(folder).create(recursive: true);
      final staged = File('$folder/.$_picturesName.tmp');
      await staged.writeAsString(
        jsonEncode({'version': 1, 'pictures': pictures}),
        flush: true,
      );
      await staged.rename('$folder/$_picturesName');
    } on Object catch (error) {
      _log.w('Could not keep which songs embed a picture: $error');
    }
  }

  /// Removes the covers no song of [songs] may want: those whose audio file
  /// is not known to embed a picture keep theirs. The host calls it once the
  /// server reads the catalog of [songs], so no cover the server names
  /// goes, and the next export's [held] waits for it.
  Future<void> prune(List<LinkWebCoverSong> songs) => _serial(() async {
    final pictures = await _loadPictures();
    final keep = {
      for (final song in songs)
        if (pictures[song.stamp] != true) linkCoverUrlId(song.url),
    };
    var freed = false;
    for (final MapEntry(:key, :value) in (await _list()).entries) {
      if (keep.contains(key)) continue;
      try {
        await File(value).delete();
        freed = true;
      } on FileSystemException {
        // Already gone, or open elsewhere; the next prune tries again.
      }
    }
    if (freed && _full) {
      _full = false;
      if (_songs.isNotEmpty) _start();
    }
  });

  /// The catalog the server reads lists [songs]: in the background, asks
  /// which of their audio files embed a picture, then fetches the covers of
  /// those without one that are not held yet, except failed ones still
  /// waiting to be tried again.
  void fetch(List<LinkWebCoverSong> songs) {
    _songs = songs;
    _start();
  }

  /// Stops fetching until the next [fetch].
  void stop() {
    _songs = const [];
    _wanted = {};
    _retry?.cancel();
    _retry = null;
  }

  void close() {
    stop();
    unawaited(_added.close());
  }

  void _start() {
    _retry?.cancel();
    _retry = null;
    if (_running != null) {
      _runAgain = true;
      return;
    }
    _running = _run().whenComplete(() {
      _running = null;
      if (_runAgain) {
        _runAgain = false;
        _start();
      } else {
        _scheduleRetry();
      }
    });
  }

  /// Tries the failed covers again once the first of them is due.
  void _scheduleRetry() {
    if (_full) return;
    DateTime? next;
    for (final MapEntry(:key, :value) in _failures.entries) {
      if (_wanted.containsKey(key) &&
          (next == null || value.retryAt.isBefore(next))) {
        next = value.retryAt;
      }
    }
    if (next != null) _retry = Timer(next.difference(_now()), _start);
  }

  Future<void> _run() async {
    final songs = _songs;
    var changed = false;
    try {
      if (songs.isEmpty) {
        _wanted = {};
        _failures.clear();
        return;
      }
      final pictures = await _loadPictures();
      final bare = await _probeNew(songs, pictures);
      final held = await _list();
      // A held cover a file just found without a picture now takes.
      changed = bare.any((url) => held.containsKey(linkCoverUrlId(url)));
      // Stopped, or a newer catalog whose run follows this one.
      if (!identical(songs, _songs)) return;
      _wanted = {
        for (final song in songs)
          if (pictures[song.stamp] == false)
            linkCoverUrlId(song.url): ?Uri.tryParse(song.url),
      };
      _failures.removeWhere((id, _) => !_wanted.containsKey(id));
      if (_full) return;
      final now = _now();
      final due = [
        for (final MapEntry(:key, :value) in _wanted.entries)
          if (!held.containsKey(key) &&
              !(_failures[key]?.retryAt.isAfter(now) ?? false))
            (id: key, url: value),
      ];
      if (due.isEmpty) return;
      final folder = (await _folder()).path;
      await Directory(folder).create(recursive: true);
      var stored = 0;
      for (final path in held.values) {
        try {
          stored += await File(path).length();
        } on FileSystemException {
          // Removed meanwhile.
        }
      }
      // A few at a time, so a large Library does not flood the network.
      fetching:
      for (var start = 0; start < due.length; start += fetchesAtOnce) {
        if (stored >= maxStore) {
          _filled();
          break;
        }
        final batch = [
          for (final cover in due.skip(start).take(fetchesAtOnce))
            if (_wanted.containsKey(cover.id)) cover,
        ];
        final images = await Future.wait([
          for (final cover in batch) _image(cover.url),
        ]);
        for (var i = 0; i < batch.length; i++) {
          final id = batch[i].id;
          final image = images[i];
          // Stopped while it was fetched.
          if (!_wanted.containsKey(id)) continue;
          if (image == null) {
            _failed(id);
            continue;
          }
          if (stored + image.bytes.length > maxStore) {
            _filled();
            break fetching;
          }
          await writeLinkCover(folder, id, image.ext, image.bytes);
          _failures.remove(id);
          stored += image.bytes.length;
          changed = true;
        }
      }
    } on Object catch (error) {
      _log.w('Could not fetch the web covers: $error');
    } finally {
      if (changed && !_added.isClosed) _added.add(null);
    }
  }

  /// Asks which audio files of [songs] are not known yet, then keeps the
  /// answers for the songs the server still lists. Returns the web covers of
  /// the files found without a picture.
  Future<Set<String>> _probeNew(
    List<LinkWebCoverSong> songs,
    Map<String, bool> pictures,
  ) async {
    final unknown = <String, String>{
      for (final song in songs)
        if (!pictures.containsKey(song.stamp)) song.stamp: song.path,
    };
    var changed = false;
    final entries = unknown.entries.toList();
    for (var start = 0; start < entries.length; start += probesAtOnce) {
      if (_songs.isEmpty) break;
      final batch = entries.skip(start).take(probesAtOnce).toList();
      final List<bool?> answers;
      try {
        answers = await _probe([for (final entry in batch) entry.value]);
      } on Object catch (error) {
        _log.w('Could not tell which songs embed a picture: $error');
        break;
      }
      for (var i = 0; i < batch.length && i < answers.length; i++) {
        if (answers[i] case final embeds?) {
          pictures[batch[i].key] = embeds;
          changed = true;
        }
      }
    }
    if (identical(songs, _songs)) {
      final listed = {for (final song in songs) song.stamp};
      final before = pictures.length;
      pictures.removeWhere((stamp, _) => !listed.contains(stamp));
      changed |= pictures.length != before;
    }
    if (changed) await _savePictures(pictures);
    return {
      for (final song in songs)
        if (unknown.containsKey(song.stamp) && pictures[song.stamp] == false)
          song.url,
    };
  }

  /// The image at [url], shrunk when large; null when it cannot be had.
  Future<({String ext, Uint8List bytes})?> _image(Uri url) async {
    try {
      var bytes = await _fetch(url).timeout(fetchTimeout);
      // Stores often serve covers at full size, several megabytes.
      if (bytes != null && bytes.length > maxCoverBytes) {
        bytes = await _shrink(bytes);
      }
      final ext = bytes == null ? null : linkCoverExtension(bytes);
      return ext == null ? null : (ext: ext, bytes: bytes!);
    } on Object {
      return null;
    }
  }

  void _filled() {
    _log.w('Web covers are over their limit; leaving the rest out');
    _full = true;
  }

  void _failed(String id) {
    final count = (_failures[id]?.count ?? 0) + 1;
    final wait = firstRetry * math.pow(2, math.min(count - 1, 20));
    _failures[id] = (
      count: count,
      retryAt: _now().add(wait < lastRetry ? wait : lastRetry),
    );
  }
}

/// The desktop's web covers, kept in `<app support>/link_web_covers`.
/// Tests override it.
final linkWebCoversProvider = Provider<LinkWebCovers>((ref) {
  final covers = LinkWebCovers(
    folder: () async => Directory(
      '${(await getApplicationSupportDirectory()).path}/link_web_covers',
    ),
    probe: ref.read(linkDesktopBackendProvider).embeddedPictures,
  );
  ref.onDispose(covers.close);
  return covers;
});
