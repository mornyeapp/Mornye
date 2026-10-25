import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneLibrary');

/// The most base64 cover data one `POST phone/covers` carries.
const _coverRequestBytes = 4 * 1024 * 1024;

/// A publish that a newer one, a lost connection or disposal replaced.
class _Stale implements Exception {
  const _Stale();
}

/// Keeps the paired desktop's list of this phone's songs current: on each
/// connection, and [debounce] after the Library changes while connected, it
/// builds the list and sends it, with the covers the desktop lacks, when the
/// desktop holds another version. Failures are logged; the next trigger
/// tries again.
class LinkPhoneLibraryPublisher {
  LinkPhoneLibraryPublisher({
    required this.client,
    required this.library,
    Future<Uint8List> Function(String path)? readCover,
    this.debounce = const Duration(seconds: 2),
  }) : _readCover = readCover ?? ((path) => File(path).readAsBytes());

  final LinkClientApi client;
  final LinkPhoneLibrary library;
  final Duration debounce;
  final Future<Uint8List> Function(String path) _readCover;

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
    library.changed();
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
      final catalog = await library.build();
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
  /// base64 a request.
  Future<void> _sendCovers(
    LinkPhoneCatalog catalog,
    void Function() check,
  ) async {
    if (catalog.covers.isEmpty) return;
    final reply = await client.get(LinkOps.phoneCovers);
    check();
    final ids = reply is Map ? reply['ids'] : null;
    final held = {if (ids is List) ...ids.whereType<String>()};
    var batch = <Map<String, dynamic>>[];
    var batchBytes = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      await client.post(LinkOps.phoneCovers, {'covers': batch});
      check();
      batch = [];
      batchBytes = 0;
    }

    for (final cover in catalog.covers) {
      if (held.contains(cover.id)) continue;
      final Uint8List bytes;
      try {
        bytes = await _readCover(cover.path);
      } on FileSystemException {
        continue;
      }
      check();
      // A cover replaced since the build has another id; the next build
      // lists it.
      if (bytes.length != cover.size) continue;
      final data = base64Encode(bytes);
      if (batchBytes + data.length > _coverRequestBytes) await flush();
      batch.add({'id': cover.id, 'ext': cover.ext, 'data': data});
      batchBytes += data.length;
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
