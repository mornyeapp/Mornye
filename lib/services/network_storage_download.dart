part of 'network_storage_service.dart';

/// One cancellable, original-file download. HTTP connections and SMB leases
/// belong to this transfer, so cancellation never interrupts another reader.
class NetworkFileDownload {
  NetworkFileDownload(this.storage);

  final NetworkStorageService storage;
  HttpClient? _http;
  NetworkSmbClient? _smb;
  bool _closed = false;

  void close() {
    _closed = true;
    _http?.close(force: true);
    unawaited(_smb?.close());
  }

  void _check() {
    if (_closed) throw StateError('Offline download cancelled');
  }

  /// A Subsonic catalog may expose the original relative file path. Other
  /// protocols already encode that path in their network source.
  Future<String?> originalPath(String source) async {
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    final connection = await storage.connection(host);
    if (connection.protocol != NetworkProtocol.subsonic) {
      if (path.isEmpty && connection.protocol == NetworkProtocol.http) {
        return connection.root.pathSegments.lastOrNull;
      }
      return path;
    }
    _check();
    final client = storage.openSubsonic(connection);
    _http = client._http;
    try {
      final song = await client.song(path);
      _check();
      return song.data['path'] as String?;
    } finally {
      client.close();
      _http = null;
    }
  }

  /// What tells the current content of [source] apart from an edited one:
  /// its size with the modification time or entity tag the server reports.
  /// Null when the server reports none of them.
  Future<String?> identity(String source) async {
    _check();
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    final connection = await storage._readyConnection(host, path);
    _check();
    try {
      switch (connection.protocol) {
        case NetworkProtocol.smb:
          final smb = await storage._smb(
            connection,
            networkTarget(connection, path),
            shared: true,
          );
          _smb = smb;
          _check();
          final stat = await smb.stat().timeout(NetworkStorageService.timeout);
          if (!stat.isFile) throw const HttpException('Not an audio file');
          return 'smb:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
        case NetworkProtocol.subsonic:
          final client = storage.openSubsonic(connection);
          _http = client._http;
          try {
            final size = (await client.song(path)).data['size'];
            return size is num ? 'subsonic:${size.toInt()}' : null;
          } finally {
            client.close();
          }
        case NetworkProtocol.webdav || NetworkProtocol.http:
          final client = storage._client();
          _http = client;
          final response = await storage._request(
            client,
            connection,
            'HEAD',
            networkTarget(connection, path),
          );
          await storage._discardResponse(response);
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'Audio file unavailable (${response.statusCode})',
            );
          }
          final etag = response.headers.value(HttpHeaders.etagHeader);
          final modified = response.headers.value(
            HttpHeaders.lastModifiedHeader,
          );
          if (etag == null && modified == null && response.contentLength < 0) {
            return null;
          }
          return 'http:${response.contentLength}:${etag ?? ''}:'
              '${modified ?? ''}';
      }
    } on HttpException catch (error) {
      // Request URLs can contain credentials. Never forward those URLs.
      throw HttpException(error.message);
    } finally {
      _http?.close(force: true);
      _http = null;
      await _smb?.close();
      _smb = null;
    }
  }

  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    _check();
    checkpoint();
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    final connection = await storage._readyConnection(host, path);
    _check();
    final Stream<List<int>> bytes;
    final int? total;
    try {
      if (connection.protocol == NetworkProtocol.smb) {
        final smb = await storage._smb(
          connection,
          networkTarget(connection, path),
          shared: true,
        );
        _smb = smb;
        _check();
        final stat = await smb.stat().timeout(NetworkStorageService.timeout);
        if (!stat.isFile) throw const HttpException('Not an audio file');
        total = stat.size;
        bytes = smb.read(0, stat.size).timeout(NetworkStorageService.timeout);
      } else {
        final client = storage._client();
        _http = client;
        final subsonic = connection.protocol == NetworkProtocol.subsonic;
        final target = subsonic
            ? _subsonicTarget(connection, 'download', {
                'id':
                    subsonicSongIdFromPath(path) ??
                    (throw const FormatException('Expected a song')),
              })
            : networkTarget(connection, path);
        final response = await storage._request(
          client,
          connection,
          'GET',
          target,
        );
        final mime = response.headers.contentType?.mimeType ?? '';
        if (response.statusCode != HttpStatus.ok ||
            mime.startsWith('text/') ||
            const {'application/json', 'application/xml'}.contains(mime)) {
          throw HttpException(
            'Audio download unavailable (${response.statusCode})',
          );
        }
        total = response.contentLength < 0 ? null : response.contentLength;
        bytes = response.timeout(NetworkStorageService.timeout);
      }
      var received = 0;
      final writer = output.openWrite();
      try {
        await writer.addStream(
          bytes.map((chunk) {
            _check();
            checkpoint();
            received += chunk.length;
            progress(received, total);
            return chunk;
          }),
        );
        _check();
        checkpoint();
        if (received == 0 || (total != null && received != total)) {
          throw const HttpException('Audio download ended early');
        }
      } finally {
        await writer.close();
      }
    } on HttpException catch (error) {
      // Request URLs can contain credentials. Never forward those URLs.
      throw HttpException(error.message);
    } finally {
      _http?.close(force: true);
      _http = null;
      await _smb?.close();
      _smb = null;
    }
  }
}
