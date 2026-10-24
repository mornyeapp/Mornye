import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkArrivingFiles');

/// A song file a phone is still sending: where it lands in the received
/// folder, the loopback URL that serves it meanwhile, and its completion
/// (an error when the upload breaks off).
typedef LinkArrival = ({String path, String url, Future<void> done});

/// Lets the player stream [path] from [url] until [done] completes.
typedef LinkArrivalRegistrar =
    void Function(
      String path, {
      required String url,
      required Future<void> done,
    });

/// Serves song files a phone is still sending over loopback HTTP, so the
/// desktop starts a song before its upload ends. A read waits for the bytes
/// it asks for. The bytes come from the part file the Link server writes
/// (`.<name>.<random>.part` in the received folder) until it is renamed to
/// `<name>`, and the URL keeps serving the whole file afterwards, as the
/// player seeks through the same URL.
class LinkArrivingFiles {
  LinkArrivingFiles({
    required LinkArrivalRegistrar register,
    this.poll = const Duration(milliseconds: 100),
    this.patience = const Duration(seconds: 30),
  }) : _register = register;

  final LinkArrivalRegistrar _register;

  /// How often an arriving file is looked at.
  final Duration poll;

  /// How long an upload may take to start or stall before it counts as
  /// broken off.
  final Duration patience;

  static const _chunk = 256 * 1024;
  static const _kept = 32;

  final _token = [
    for (var i = 0; i < 16; i++) Random.secure().nextInt(256),
  ].map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final _arrivals = <String, _Arrival>{};
  Future<HttpServer>? _server;
  bool _closed = false;

  /// Expects `<fileId>.<ext>` of [size] bytes in [dir] and lets the player
  /// stream it until it is whole. Null for a name or size the desktop does
  /// not take.
  Future<LinkArrival?> expect(String dir, String name, int size) async {
    if (_closed || dir.isEmpty || size <= 0 || !_validName(name)) return null;
    final server = await (_server ??= _bind());
    var arrival = _arrivals[name];
    if (arrival == null || arrival.failed || arrival.dir != dir) {
      arrival?.close();
      arrival = _arrivals[name] = _Arrival(
        dir: dir,
        name: name,
        size: size,
        poll: poll,
        patience: patience,
      );
      _trim();
    }
    final url = 'http://127.0.0.1:${server.port}/$_token/$name';
    _register(arrival.path, url: url, done: arrival.done);
    return (path: arrival.path, url: url, done: arrival.done);
  }

  Future<void> close() async {
    _closed = true;
    for (final arrival in _arrivals.values) {
      arrival.close();
    }
    _arrivals.clear();
    final server = _server;
    _server = null;
    if (server != null) await (await server).close(force: true);
  }

  static bool _validName(String name) {
    final dot = name.indexOf('.');
    return dot > 0 &&
        isLinkFileId(name.substring(0, dot)) &&
        linkUploadExtensions.contains(name.substring(dot + 1));
  }

  /// Drops the oldest finished files beyond [_kept].
  void _trim() {
    if (_arrivals.length <= _kept) return;
    final finished = [
      for (final MapEntry(:key, :value) in _arrivals.entries)
        if (value.finished) key,
    ];
    for (final name in finished.take(_arrivals.length - _kept)) {
      _arrivals.remove(name)?.close();
    }
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
    return server;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final arrival = segments.length == 2 && segments.first == _token
        ? _arrivals[segments.last]
        : null;
    if (arrival == null ||
        (request.method != 'GET' && request.method != 'HEAD')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final size = arrival.size;
    var start = 0;
    var end = size - 1;
    final range = RegExp(
      r'^bytes=(\d*)-(\d*)$',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range != null) {
      final first = int.tryParse(range[1]!);
      final last = int.tryParse(range[2]!);
      if (first != null) {
        start = first;
        if (last != null && last < end) end = last;
      } else if (last != null) {
        start = max(0, size - last);
      }
      if (start > end || start >= size) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await response.close();
        return;
      }
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
    }
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType.binary
      ..contentLength = end - start + 1;
    try {
      if (request.method == 'GET') {
        var offset = start;
        while (offset <= end) {
          final bytes = await arrival.read(
            offset,
            min(_chunk, end - offset + 1),
          );
          // The upload broke off: closing short of the length drops the
          // connection, and the player reports the error.
          if (bytes == null) break;
          response.add(bytes);
          await response.flush();
          offset += bytes.length;
        }
      }
      await response.close();
    } on Object catch (error) {
      // The player closed the stream, as it does when it seeks.
      _log.d('Stopped serving an arriving file: $error');
    }
  }
}

/// One file on its way: what the Link server has written of it so far.
class _Arrival {
  _Arrival({
    required this.dir,
    required this.name,
    required this.size,
    required this.poll,
    required this.patience,
  }) : path = '$dir${Platform.pathSeparator}$name' {
    // The player's registration hears a failure; nothing else has to.
    _done.future.ignore();
    _timer = Timer.periodic(poll, (_) => unawaited(_look()));
    unawaited(_look());
  }

  final String dir;
  final String name;
  final String path;
  final int size;
  final Duration poll;
  final Duration patience;

  final _done = Completer<void>();
  late final Timer _timer;
  String? _part;
  int _written = 0;
  bool _sawPart = false;
  bool _failed = false;
  bool _looking = false;
  DateTime _grew = DateTime.now();

  Future<void> get done => _done.future;
  bool get finished => _done.isCompleted;
  bool get failed => _failed;
  bool get _whole => _done.isCompleted && !_failed;

  /// Up to [length] bytes at [offset], once written; null once the upload
  /// broke off.
  Future<List<int>?> read(int offset, int length) async {
    var misses = 0;
    while (true) {
      if (_failed) return null;
      final available = _whole ? size : _written;
      final source = _whole ? path : _part;
      if (offset < available && source != null) {
        try {
          final file = await File(source).open();
          try {
            await file.setPosition(offset);
            final bytes = await file.read(min(length, available - offset));
            if (bytes.isNotEmpty) return bytes;
          } finally {
            await file.close();
          }
        } on FileSystemException {
          // Renamed into place under the reader; look again.
          if (++misses > 50) return null;
        }
      }
      await Future<void>.delayed(poll);
      await _look();
    }
  }

  /// Finds how much of the file is written, and whether it is whole or
  /// broke off.
  Future<void> _look() async {
    if (_done.isCompleted || _looking) return;
    _looking = true;
    try {
      if (await File(path).exists()) return _finish();
      final part = await _findPart();
      if (part == null) {
        if (_sawPart) {
          // Gone between two looks: renamed into place, or removed after
          // the upload broke off.
          return await File(path).exists()
              ? _finish()
              : _fail('The upload broke off');
        }
      } else {
        _sawPart = true;
        final written = await File(part).length();
        if (written > _written) {
          _written = written;
          _grew = DateTime.now();
        }
      }
      if (DateTime.now().difference(_grew) > patience) {
        _fail('The upload stalled');
      }
    } on FileSystemException {
      // Looked at while being renamed; the next look sees it.
    } finally {
      _looking = false;
    }
  }

  /// The part file the Link server writes this upload into.
  Future<String?> _findPart() async {
    if (_part case final part? when await File(part).exists()) return part;
    final prefix = '.$name.';
    String? found;
    try {
      await for (final entry in Directory(dir).list(followLinks: false)) {
        final entryName = entry.uri.pathSegments.last;
        if (entry is File &&
            entryName.startsWith(prefix) &&
            entryName.endsWith('.part')) {
          found = entry.path;
        }
      }
    } on FileSystemException {
      return null;
    }
    return _part = found;
  }

  void _finish() {
    _timer.cancel();
    if (!_done.isCompleted) _done.complete();
  }

  void _fail(String reason) {
    _timer.cancel();
    _failed = true;
    if (!_done.isCompleted) {
      _done.completeError(LinkException('unavailable', reason));
    }
  }

  void close() {
    if (!_done.isCompleted) _fail('Mornye Link stopped');
    _timer.cancel();
  }
}
