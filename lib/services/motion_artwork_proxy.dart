import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Dart handles upstream TLS; FFmpeg sees only a short-lived loopback URL.
/// Only the initial resource and URLs discovered in its HLS playlists can be
/// requested, with a shared transfer budget across playlists, keys and ranges.
class MotionArtworkProxy {
  MotionArtworkProxy._(this._server, this._client, this._maxBytes);

  final HttpServer _server;
  final HttpClient _client;
  final int _maxBytes;
  final _resources = <String, Uri>{};
  final _paths = <Uri, String>{};
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  late final Timer _deadline;
  late final Uri source;
  int _transferred = 0;
  bool _closed = false;
  bool _hlsDetected = false;
  Future<void>? _closing;

  bool get isClosed => _closed;
  bool get isHls => _hlsDetected || source.path.endsWith('.m3u8');

  static Future<MotionArtworkProxy> start(
    Uri source, {
    HttpClient? client,
    int maxBytes = 24 << 20,
    Duration lifetime = const Duration(seconds: 30),
  }) async {
    _checkRemote(source);
    final upstream = client ?? HttpClient();
    upstream
      ..connectionTimeout = const Duration(seconds: 8)
      ..autoUncompress = false;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = MotionArtworkProxy._(server, upstream, maxBytes);
      proxy.source = proxy._register(source);
      proxy._deadline = Timer(lifetime, () => unawaited(proxy.close()));
      server.listen(proxy._handle, onError: (Object _) {});
      return proxy;
    } catch (_) {
      upstream.close(force: true);
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _deadline.cancel();
    _client.close(force: true);
    await _server.close(force: true);
  }

  static void _checkRemote(Uri uri) {
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.toString().length > 8192) {
      throw const FormatException('Artwork resource requires HTTP or HTTPS');
    }
  }

  Uri _register(Uri remote) {
    _checkRemote(remote);
    remote = remote.removeFragment();
    final existing = _paths[remote];
    if (existing != null) return _local(existing);
    if (_resources.length >= 4096 || remote.toString().length > 8192) {
      throw const FormatException('Too many artwork resources');
    }
    // HLS validates segment extensions before opening them; retain the
    // upstream suffix while hiding its URL/query behind the resource token.
    final extension =
        RegExp(r'\.[a-z0-9]{1,10}$').stringMatch(remote.path.toLowerCase()) ??
        '.bin';
    final path = '/$_token/${_resources.length}$extension';
    _resources[path] = remote;
    _paths[remote] = path;
    return _local(path);
  }

  Uri _local(String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: path,
  );

  Future<({HttpClientResponse response, Uri uri})> _request(
    Uri uri,
    HttpRequest incoming,
  ) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      _checkRemote(uri);
      final request = await _client
          .openUrl(incoming.method, uri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final name in [HttpHeaders.rangeHeader, HttpHeaders.ifRangeHeader]) {
        final value = incoming.headers.value(name);
        if (value != null) request.headers.set(name, value);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (!response.isRedirect) return (response: response, uri: uri);
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.listen(null).cancel();
      if (location == null) throw const HttpException('Missing redirect');
      uri = uri.resolve(location);
    }
    throw const HttpException('Too many artwork redirects');
  }

  Stream<List<int>> _body(HttpClientResponse response) async* {
    await for (final chunk in response.timeout(const Duration(seconds: 8))) {
      if (_closed || _transferred + chunk.length > _maxBytes) {
        unawaited(close());
        throw const HttpException('Artwork transfer budget exceeded');
      }
      _transferred += chunk.length;
      yield chunk;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final outgoing = request.response;
    outgoing.persistentConnection = false;
    outgoing.bufferOutput = false;
    try {
      final remote = _resources[request.uri.path];
      if (_closed || remote == null || request.uri.hasQuery) {
        outgoing.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        outgoing.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final upstream = await _request(remote, request);
      final response = upstream.response;
      outgoing.statusCode = response.statusCode;
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentEncodingHeader,
      ]) {
        final value = response.headers.value(name);
        if (value != null) outgoing.headers.set(name, value);
      }
      if (request.method == 'HEAD') {
        if (response.contentLength >= 0) {
          outgoing.contentLength = response.contentLength;
        }
        await response.drain<void>();
        return;
      }
      final body = StreamIterator(_body(response));
      try {
        final prefix = <int>[];
        while (prefix.length < 7 && await body.moveNext()) {
          prefix.addAll(body.current);
        }
        final playlist =
            response.statusCode >= 200 &&
            response.statusCode < 300 &&
            (upstream.uri.path.toLowerCase().endsWith('.m3u8') ||
                (response.headers.contentType?.mimeType.contains('mpegurl') ??
                    false) ||
                utf8
                    .decode(prefix.take(32).toList(), allowMalformed: true)
                    .trimLeft()
                    .startsWith('#EXTM3U'));
        if (playlist) {
          _hlsDetected = true;
          final bytes = <int>[...prefix];
          while (await body.moveNext()) {
            if (bytes.length + body.current.length > 512 << 10) {
              throw const FormatException(
                'Artwork playlist exceeds size limit',
              );
            }
            bytes.addAll(body.current);
          }
          if (bytes.length > 512 << 10) {
            throw const FormatException('Artwork playlist exceeds size limit');
          }
          final text = await _playlistText(bytes, response.headers);
          final rewritten = utf8.encode(_rewrite(text, upstream.uri));
          outgoing
            ..statusCode = HttpStatus.ok
            ..headers.removeAll(HttpHeaders.contentRangeHeader)
            ..headers.removeAll(HttpHeaders.contentEncodingHeader)
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..contentLength = rewritten.length
            ..add(rewritten);
        } else {
          if (response.contentLength >= 0) {
            outgoing.contentLength = response.contentLength;
          }
          outgoing.add(prefix);
          await outgoing.flush();
          while (await body.moveNext()) {
            outgoing.add(body.current);
            await outgoing.flush();
          }
        }
      } finally {
        await body.cancel();
      }
    } catch (_) {
      try {
        outgoing.statusCode = HttpStatus.badGateway;
      } catch (_) {
        // A stream failure can happen after binary response headers were sent.
      }
    } finally {
      try {
        await outgoing.close();
      } catch (_) {}
    }
  }

  Future<String> _playlistText(List<int> bytes, HttpHeaders headers) async {
    Stream<List<int>> stream = Stream.value(bytes);
    switch (headers.value(HttpHeaders.contentEncodingHeader)?.toLowerCase()) {
      case 'gzip':
        stream = gzip.decoder.bind(stream);
      case 'deflate':
        stream = zlib.decoder.bind(stream);
      case null || 'identity':
        break;
      default:
        throw const FormatException('Unsupported artwork playlist encoding');
    }
    final decoded = <int>[];
    await for (final chunk in stream) {
      if (decoded.length + chunk.length > 512 << 10) {
        throw const FormatException('Artwork playlist exceeds size limit');
      }
      decoded.addAll(chunk);
    }
    return utf8.decode(decoded);
  }

  String _rewrite(String text, Uri base) => const LineSplitter()
      .convert(text)
      .map((raw) {
        final line = raw.trim();
        if (line.isEmpty) return raw;
        if (!line.startsWith('#')) {
          return _register(base.resolve(line)).toString();
        }
        return raw.replaceAllMapped(RegExp(r'([:,])URI="([^"]+)"'), (match) {
          return '${match[1]}URI="${_register(base.resolve(match[2]!))}"';
        });
      })
      .join('\n');
}
