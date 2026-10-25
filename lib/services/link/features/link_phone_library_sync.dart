import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneLibrary');

/// The most base64 cover data one `POST phone/covers` carries.
const _coverRequestBytes = 4 * 1024 * 1024;

/// A publish that a newer one, a lost connection or disposal replaced.
class _Stale implements Exception {
  const _Stale();
}

/// Encodes covers for one `POST phone/covers`; the default is
/// [encodeLinkPhoneCoversShrinking].
typedef LinkPhoneCoverEncoder =
    Future<List<Map<String, dynamic>>> Function(List<LinkPhoneCover> covers);

/// Reads [covers] and encodes them as `phone/covers` entries
/// (`{"id","ext","data"}`), leaving out any that changed since the list was
/// built. Runs in an isolate.
List<Map<String, dynamic>> encodeLinkPhoneCovers(List<LinkPhoneCover> covers) {
  final encoded = <Map<String, dynamic>>[];
  for (final cover in covers) {
    final Uint8List bytes;
    try {
      bytes = File(cover.path).readAsBytesSync();
    } on FileSystemException {
      continue;
    }
    // A cover replaced since the build has another id; the next build
    // lists it.
    if (bytes.length != cover.size) continue;
    encoded.add({
      'id': cover.id,
      'ext': cover.ext,
      'data': base64Encode(bytes),
    });
  }
  return encoded;
}

Future<List<Map<String, dynamic>>> _encodeInIsolate(
  List<LinkPhoneCover> covers,
) => compute(encodeLinkPhoneCovers, covers);

/// Encodes [covers] as [encode] does, except the ones that
/// [LinkPhoneCover.shrinks]: those are read here and sent as the PNG
/// [shrink] makes, which decodes on this isolate. A shrunk cover over
/// [linkPhoneShrunkCoverMaxBytes] is left out.
Future<List<Map<String, dynamic>>> encodeLinkPhoneCoversShrinking(
  List<LinkPhoneCover> covers, {
  LinkCoverShrinker shrink = shrinkLinkCover,
  LinkPhoneCoverEncoder encode = _encodeInIsolate,
}) async {
  final encoded = await encode([
    for (final cover in covers)
      if (!cover.shrinks) cover,
  ]);
  for (final cover in covers) {
    if (!cover.shrinks) continue;
    final Uint8List bytes;
    try {
      bytes = await File(cover.path).readAsBytes();
    } on FileSystemException {
      continue;
    }
    if (bytes.length != cover.size) continue;
    final png = await shrink(bytes);
    if (png == null || png.length > linkPhoneShrunkCoverMaxBytes) continue;
    encoded.add({'id': cover.id, 'ext': 'png', 'data': base64Encode(png)});
  }
  return encoded;
}

/// The base64 length of [bytes] bytes.
int _base64Length(int bytes) => (bytes + 2) ~/ 3 * 4;

/// Keeps the paired desktop's list of this phone's songs current: on each
/// connection, and [debounce] after the Library changes while connected, it
/// sends the list, with the covers the desktop lacks, when the desktop holds
/// another version. The list is built again only when the Library changed
/// since the last build. Failures are logged; the next trigger tries again.
class LinkPhoneLibraryPublisher {
  LinkPhoneLibraryPublisher({
    required this.client,
    required this.library,
    LinkPhoneCoverEncoder? encodeCovers,
    this.debounce = const Duration(seconds: 2),
  }) : _encodeCovers = encodeCovers ?? encodeLinkPhoneCoversShrinking;

  final LinkClientApi client;
  final LinkPhoneLibrary library;
  final Duration debounce;
  final LinkPhoneCoverEncoder _encodeCovers;

  StreamSubscription<LinkConnectionState>? _connection;
  Timer? _debounceTimer;
  Future<void> _running = Future.value();
  bool _busy = false;
  bool _disposed = false;

  /// Bumped by each [publish]; a run stops once it is not the latest.
  int _run = 0;

  /// Completes when no publish runs.
  @visibleForTesting
  Future<void> get idle => _running;

  bool get _connected =>
      client.connectionState == LinkConnectionState.connected;

  void start() {
    _connection = client.connectionStates.listen((state) {
      if (state == LinkConnectionState.connected) publish();
    });
    if (_connected) publish();
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    unawaited(_connection?.cancel());
  }

  /// The phone's Library changed: publishes [debounce] later while
  /// connected.
  void libraryChanged() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    if (_connected) _debounceTimer = Timer(debounce, publish);
  }

  /// Publishes now. A publish in progress stops at its next step, and this
  /// one runs after it.
  void publish() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _run++;
    if (_busy) return;
    _busy = true;
    _running = _loop();
  }

  Future<void> _loop() async {
    try {
      for (var run = _run; ; run = _run) {
        await _publish(run);
        if (_disposed || run == _run) return;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _publish(int run) async {
    void check() {
      if (_disposed || run != _run || !_connected) throw const _Stale();
    }

    try {
      check();
      final catalog = await library.catalog();
      check();
      final held = await client.get(LinkOps.phoneCatalog);
      check();
      if (held is Map && held['version'] == catalog.version) return;
      await _sendCovers(catalog, check);
      await _sendSongs(catalog, check);
      _log.i('Sent ${catalog.songs.length} songs to the desktop');
    } on _Stale {
      return;
    } on Object catch (error) {
      _log.w('Could not send this phone\'s songs to the desktop: $error');
    }
  }

  /// Posts the covers the desktop lacks, at most [_coverRequestBytes] of
  /// base64 a request. Each cover's size, known from the build, or the
  /// most a shrunk one takes, sets its share of a request before it is
  /// read.
  Future<void> _sendCovers(
    LinkPhoneCatalog catalog,
    void Function() check,
  ) async {
    if (catalog.covers.isEmpty) return;
    final reply = await client.get(LinkOps.phoneCovers);
    check();
    final ids = reply is Map ? reply['ids'] : null;
    final held = {if (ids is List) ...ids.whereType<String>()};
    var batch = <LinkPhoneCover>[];
    var batchBytes = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      final covers = await _encodeCovers(batch);
      check();
      batch = [];
      batchBytes = 0;
      if (covers.isEmpty) return;
      await client.post(LinkOps.phoneCovers, {'covers': covers});
      check();
    }

    for (final cover in catalog.covers) {
      if (held.contains(cover.id)) continue;
      final length = _base64Length(
        cover.shrinks ? linkPhoneShrunkCoverMaxBytes : cover.size,
      );
      if (batchBytes + length > _coverRequestBytes) await flush();
      batch.add(cover);
      batchBytes += length;
    }
    await flush();
  }

  /// Posts the songs page by page, starting over once when the desktop
  /// finds a page out of order.
  Future<void> _sendSongs(
    LinkPhoneCatalog catalog,
    void Function() check,
  ) async {
    for (var restarted = false; ; restarted = true) {
      try {
        await _sendPages(catalog, check);
        return;
      } on LinkException catch (error) {
        if (restarted || error.code != 'invalid') rethrow;
        check();
      }
    }
  }

  Future<void> _sendPages(
    LinkPhoneCatalog catalog,
    void Function() check,
  ) async {
    final songs = catalog.songs;
    var offset = 0;
    // An empty list goes as one empty page, which commits it.
    do {
      final end = math.min(offset + linkPhoneCatalogPage, songs.length);
      await client.post(LinkOps.phoneCatalog, {
        'version': catalog.version,
        'offset': offset,
        'total': songs.length,
        'songs': [for (var i = offset; i < end; i++) songs[i].toJson()],
      });
      check();
      offset = end;
    } while (offset < songs.length);
  }
}

/// Answers the desktop's `files.request` for a song of this phone's list:
/// uploads its file, saying `files.sending` as the upload starts and
/// `files.failed` when it cannot. At most [maxUploads] run at once; further
/// requests wait in order, and one for a song already waiting or uploading
/// is ignored.
class LinkPhoneFileRequests {
  LinkPhoneFileRequests({
    required this.client,
    required this.library,
    required this.files,
    this.maxUploads = 2,
  });

  final LinkClientApi client;
  final LinkPhoneLibrary library;
  final LinkPhoneFiles files;
  final int maxUploads;

  final _subscriptions = <StreamSubscription<Object?>>[];
  final _waiting = Queue<String>();

  /// The names waiting or uploading.
  final _requested = <String>{};
  int _uploading = 0;
  bool _disposed = false;

  void start() {
    _subscriptions
      ..add(client.messages.listen(_onMessage))
      ..add(
        client.connectionStates.listen((state) {
          // The desktop gave up on what it asked for before the drop.
          if (state != LinkConnectionState.connected) _dropWaiting();
        }),
      );
  }

  void dispose() {
    _disposed = true;
    _dropWaiting();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _dropWaiting() {
    _requested.removeAll(_waiting);
    _waiting.clear();
  }

  void _onMessage(Map<String, dynamic> message) {
    if (message['type'] != LinkMessageTypes.filesRequest) return;
    final name = message['name'];
    if (name is String && name.isNotEmpty) request(name);
  }

  /// Sends the song the desktop knows as [name] (`<fileId>.<suffix>`).
  void request(String name) {
    if (_disposed || !_requested.add(name)) return;
    _waiting.add(name);
    _next();
  }

  void _next() {
    while (!_disposed && _uploading < maxUploads && _waiting.isNotEmpty) {
      final name = _waiting.removeFirst();
      _uploading++;
      unawaited(
        _send(name).whenComplete(() {
          _uploading--;
          _requested.remove(name);
          _next();
        }),
      );
    }
  }

  Future<void> _send(String name) async {
    try {
      final file = await library.fileNamed(name);
      if (file == null) {
        throw const LinkException('not_found', 'Not a song of this phone');
      }
      await files.upload(
        client,
        file,
        onStart: (start) => _say({
          'type': LinkMessageTypes.filesSending,
          'name': name,
          'file': start.name,
          'size': start.size,
          'streamable': start.streamable,
        }),
      );
    } on Object catch (error) {
      _log.w('Could not send a song file to the desktop: $error');
      _say({
        'type': LinkMessageTypes.filesFailed,
        'name': name,
        'reason': error is LinkException ? error.code : 'unavailable',
      });
    }
  }

  void _say(Map<String, dynamic> message) {
    if (!_disposed) client.send(message);
  }
}
