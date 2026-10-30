import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('LinkWebCovers');

final _coverName = RegExp(r'^([0-9a-f]{32})\.(jpg|png|webp)$');

/// Fetches a cover from its web address; null when it cannot.
typedef LinkCoverFetcher = Future<Uint8List?> Function(Uri url);

/// The largest cover fetched from the web; a larger one is left out.
const linkMaxFetchedCoverBytes = 24 * 1024 * 1024;

/// Fetches a cover of at most [linkMaxFetchedCoverBytes].
Future<Uint8List?> fetchLinkCover(Uri url) async {
  const timeout = Duration(seconds: 20);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final response = await (await client.getUrl(url)).close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length > linkMaxFetchedCoverBytes) return null;
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
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
/// reader never sees part of it.
Future<void> writeLinkCover(
  String folder,
  String id,
  String ext,
  Uint8List bytes,
) async {
  final staged = File('$folder/.$id.$ext.tmp');
  await staged.writeAsBytes(bytes, flush: true);
  await staged.rename('$folder/$id.$ext');
}

/// The covers of the desktop's own songs that have only a web address, for
/// the catalog the Link server reads (contract section 5). Each address is
/// kept once as `<linkCoverUrlId(url)>.<ext>` in its folder: fetched after
/// an export, named by the next one, removed once no exported song wants it.
class LinkWebCovers {
  LinkWebCovers({
    required Future<Directory> Function() folder,
    LinkCoverFetcher? fetchCover,
    LinkCoverShrinker? shrinkCover,
    DateTime Function()? now,
    this.firstRetry = const Duration(minutes: 1),
    this.lastRetry = const Duration(hours: 6),
  }) : _folder = folder,
       _fetch = fetchCover ?? fetchLinkCover,
       _shrink = shrinkCover ?? shrinkLinkCover,
       _now = now ?? DateTime.now;

  /// The largest cover kept as fetched; a larger one is kept shrunk to
  /// [linkShrunkCoverSize].
  static const maxCoverBytes = 2 * 1024 * 1024;

  /// The most cover bytes kept; further covers are left out.
  static const maxStore = 1024 * 1024 * 1024;

  /// The covers fetched at once.
  static const fetchesAtOnce = 4;

  /// The longest one cover may take to fetch.
  static const fetchTimeout = Duration(minutes: 1);

  /// The wait before a failed cover is tried again; it doubles with each
  /// failure in a row, up to [lastRetry].
  final Duration firstRetry;
  final Duration lastRetry;

  final Future<Directory> Function() _folder;
  final LinkCoverFetcher _fetch;
  final LinkCoverShrinker _shrink;
  final DateTime Function() _now;
  final _added = StreamController<void>.broadcast();

  /// The covers the catalog the server reads wants, by cover id.
  var _wanted = <String, Uri>{};

  /// The covers that failed, by cover id: how often in a row, and when to
  /// try again.
  final _failures = <String, ({int count, DateTime retryAt})>{};
  Future<void> _queue = Future.value();
  Future<void>? _running;
  var _runAgain = false;
  Timer? _retry;

  /// Fires after covers were added, so the next export names them.
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

  /// Removes the covers no address in [urls] names. The host calls it once
  /// the server reads a catalog that wants [urls], so no cover the server
  /// names goes, and the next export's [held] waits for it.
  Future<void> prune(Set<String> urls) => _serial(() async {
    final keep = {for (final url in urls) linkCoverUrlId(url)};
    for (final MapEntry(:key, :value) in (await _list()).entries) {
      if (keep.contains(key)) continue;
      try {
        await File(value).delete();
      } on FileSystemException {
        // Already gone, or open elsewhere; the next prune tries again.
      }
    }
  });

  /// The catalog the server reads wants the covers of [urls]: fetches, in
  /// the background, those not held yet, except failed ones still waiting
  /// to be tried again.
  void fetch(Set<String> urls) {
    _wanted = {for (final url in urls) linkCoverUrlId(url): ?Uri.tryParse(url)};
    _failures.removeWhere((id, _) => !_wanted.containsKey(id));
    _start();
  }

  /// Stops fetching until the next [fetch].
  void stop() {
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
    var added = 0;
    try {
      if (_wanted.isEmpty) return;
      final held = await _list();
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
          _log.w('Web covers are over their limit; leaving the rest out');
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
          if (image == null) {
            _failed(id);
            continue;
          }
          if (stored + image.bytes.length > maxStore) {
            _log.w('Web covers are over their limit; leaving the rest out');
            _failed(id);
            break fetching;
          }
          await writeLinkCover(folder, id, image.ext, image.bytes);
          _failures.remove(id);
          stored += image.bytes.length;
          added++;
        }
      }
    } on Object catch (error) {
      _log.w('Could not fetch the web covers: $error');
    } finally {
      if (added > 0 && !_added.isClosed) _added.add(null);
    }
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
  );
  ref.onDispose(covers.close);
  return covers;
});
