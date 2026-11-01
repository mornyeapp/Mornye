import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Only registered media is exposed, through unguessable URLs on the interface
/// that reaches the selected TV. Source paths and NAS credentials stay private.
class CastMediaServer {
  final _sources = <String, ({String source, String mime})>{};
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  HttpServer? _server;
  bool _closed = false;

  Future<void> start(String receiverHost) async {
    final probe = await Socket.connect(
      receiverHost,
      8009,
      timeout: const Duration(seconds: 5),
    );
    final address = probe.address;
    probe.destroy();
    await bind(address);
  }

  /// Also permits loopback for host tests, without contacting a receiver.
  Future<void> bind(InternetAddress address) async {
    if (_closed) throw StateError('Cast media server is closed');
    final server = await HttpServer.bind(address, 0, shared: false);
    if (_closed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
  }

  Uri register(String source, String mime) {
    final server = _server;
    if (_closed || server == null) throw StateError('No Cast media server');
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _sources[token] = (source: source, mime: mime);
    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      path: '/media/$token',
    );
  }

  void clear() => _sources.clear();

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Range')
      ..set('Access-Control-Expose-Headers', 'Content-Range, Accept-Ranges')
      ..set('Cache-Control', 'no-store');
    try {
      final parts = request.uri.pathSegments;
      final source = parts.length == 2 && parts.first == 'media'
          ? _sources[parts.last]
          : null;
      if (source == null) {
        response.statusCode = HttpStatus.notFound;
      } else if (request.method == 'OPTIONS') {
        response.headers.set(
          'Access-Control-Allow-Methods',
          'GET, HEAD, OPTIONS',
        );
        response.statusCode = HttpStatus.noContent;
      } else if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
      } else if (const {
        'http',
        'https',
      }.contains(Uri.tryParse(source.source)?.scheme)) {
        await _relay(request, source.source, source.mime);
      } else {
        await _file(request, source.source, source.mime);
      }
    } on Object {
      // A seek or track change can close an in-flight receiver request.
      try {
        response.statusCode = HttpStatus.badGateway;
      } on Object {
        // Headers may already have been sent.
      }
    } finally {
      try {
        await response.close();
      } on Object {
        // The receiver disconnected.
      }
    }
  }

  Future<void> _file(HttpRequest request, String path, String mime) async {
    final file = File(path);
    final length = await file.length();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0, end = length - 1;
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
        _invalidRange(request.response, length);
        return;
      }
      if (match[1]!.isEmpty) {
        final suffix = int.tryParse(match[2]!);
        if (suffix == null || suffix <= 0) {
          _invalidRange(request.response, length);
          return;
        }
        start = max(0, length - suffix);
      } else {
        start = int.tryParse(match[1]!) ?? length;
        end = match[2]!.isEmpty
            ? length - 1
            : min(int.tryParse(match[2]!) ?? -1, length - 1);
      }
      if (start >= length || start > end) {
        _invalidRange(request.response, length);
        return;
      }
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
    }
    request.response.headers
      ..set(HttpHeaders.contentTypeHeader, mime)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.contentLength = max(0, end - start + 1);
    if (request.method != 'HEAD' && length > 0) {
      await request.response.addStream(file.openRead(start, end + 1));
    }
  }

  static void _invalidRange(HttpResponse response, int length) {
    response
      ..statusCode = HttpStatus.requestedRangeNotSatisfiable
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
  }

  Future<void> _relay(HttpRequest request, String source, String mime) async {
    final upstream = await _client.openUrl(request.method, Uri.parse(source));
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);
    upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final reply = await upstream.close();
    request.response.statusCode = reply.statusCode;
    for (final header in [
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final value = reply.headers.value(header);
      if (value != null) request.response.headers.set(header, value);
    }
    request.response.headers.set(HttpHeaders.contentTypeHeader, mime);
    if (reply.contentLength >= 0) {
      request.response.contentLength = reply.contentLength;
    }
    if (request.method == 'HEAD') {
      await reply.drain<void>();
    } else {
      await request.response.addStream(reply);
    }
  }

  Future<void> close() async {
    _closed = true;
    clear();
    _client.close(force: true);
    await _server?.close(force: true);
    _server = null;
  }
}
