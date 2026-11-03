part of 'network_storage_service.dart';

/// Writes share the browser's credentials, certificate pin and timeouts.
extension NetworkStorageUpload on NetworkStorageService {
  Future<({NetworkConnection connection, String path})> _uploadLocation(
    String source,
  ) async {
    final uri = Uri.parse(source);
    if (uri.scheme != 'network' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid network destination');
    }
    final c = await connection(uri.host);
    c.validate();
    if (!c.writable) {
      throw const FormatException('Downloads require SMB or WebDAV');
    }
    return (connection: c, path: networkPath(uri.pathSegments.join('/')));
  }

  Future<void> _uploadCommand(
    NetworkConnection c,
    String method,
    String path, {
    Map<String, String> headers = const {},
    File? file,
    Set<int> accepted = const {200, 201, 204},
    void Function()? checkpoint,
    void Function(int)? progress,
  }) async {
    final client = _client();
    try {
      final response = await _request(
        client,
        c,
        method,
        networkTarget(c, path),
        headers: headers,
        upload: file,
        checkpoint: checkpoint,
        progress: progress,
      );
      if (!accepted.contains(response.statusCode)) {
        throw HttpException(
          'Network upload: $method returned ${response.statusCode}',
        );
      }
      await response.drain<void>().timeout(NetworkStorageService.timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _makeUploadFolder(NetworkConnection c, String path) async {
    if (c.protocol == NetworkProtocol.webdav) {
      await _uploadCommand(c, 'MKCOL', path, accepted: {201, 405});
    } else {
      final smb = await _smb(c, networkTarget(c, path));
      try {
        if (!await smb.exists(smb.path)) {
          try {
            await smb.mkdir(smb.path);
          } catch (_) {
            // Concurrent album tracks can create the same parent folder.
            if (!await smb.exists(smb.path)) rethrow;
          }
        }
      } finally {
        await smb.close();
      }
    }
    // An existing file or a forbidden collection must not pass as a folder.
    await list(c, path);
  }

  /// Choose a non-colliding name before transfer and persist it in the journal.
  Future<String> prepareUpload(
    String folder,
    String relativeDir,
    String filename,
  ) async {
    final target = await _prepareUploadFolder(folder, relativeDir, filename);
    final name = target.name;
    final names = target.names;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final suffix = dot > 0 ? name.substring(dot) : '';
    var candidate = name;
    bool occupied(String value) =>
        names.contains(value.toLowerCase()) ||
        names.contains(
          '${value.substring(0, value.length - suffix.length)}.lrc'
              .toLowerCase(),
        );
    for (var i = 2; occupied(candidate); i++) {
      candidate = '$stem ($i)$suffix';
    }
    return NetworkStorageService.source(
      target.connection.id,
      '${target.parent}$candidate',
    );
  }

  /// [filename] under [folder]/[relativeDir], creating missing folders, or
  /// null when that folder already holds a file of the name. Unlike
  /// [prepareUpload] it never picks a numbered name: a Library song copied
  /// again is already there.
  Future<String?> prepareNewUpload(
    String folder,
    String relativeDir,
    String filename,
  ) async {
    final target = await _prepareUploadFolder(folder, relativeDir, filename);
    if (target.names.contains(target.name.toLowerCase())) return null;
    return NetworkStorageService.source(
      target.connection.id,
      '${target.parent}${target.name}',
    );
  }

  Future<
    ({
      NetworkConnection connection,
      String parent,
      String name,
      Set<String> names,
    })
  >
  _prepareUploadFolder(
    String folder,
    String relativeDir,
    String filename,
  ) async {
    final location = await _uploadLocation(folder);
    final c = location.connection;
    var parent = location.path;
    if (parent.isNotEmpty && !parent.endsWith('/')) {
      throw const FormatException('Expected a destination folder');
    }
    final name = networkPath(filename);
    if (name.isEmpty || name.contains('/')) {
      throw const FormatException('Invalid filename');
    }
    await list(c, parent);
    for (final segment in networkPath(
      relativeDir,
    ).split('/').where((s) => s.isNotEmpty)) {
      parent += '$segment/';
      await _makeUploadFolder(c, parent);
    }
    final entries = await list(c, parent);
    return (
      connection: c,
      parent: parent,
      name: name,
      names: entries.map((e) => e.name.toLowerCase()).toSet(),
    );
  }

  Future<bool> _matchesUpload(
    String source,
    File file,
    int length,
    void Function() checkpoint,
  ) async {
    final url = await resolve(source);
    checkpoint();
    final requestId = 'upload_hash_${NetworkStorageService.newId()}';
    Object? cancellationError;
    StackTrace? cancellationStack;
    final guard = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      try {
        checkpoint();
      } catch (error, stack) {
        cancellationError = error;
        cancellationStack = stack;
        timer.cancel();
        unawaited(_cancelUploadHash(requestId));
      }
    });
    void checkCancelled() {
      final error = cancellationError;
      if (error != null) {
        Error.throwWithStackTrace(error, cancellationStack!);
      }
    }

    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'matches_network_upload',
        'url': url,
        'path': file.path,
        'length': length,
        'idle_timeout_ms': NetworkStorageService.timeout.inMilliseconds,
      }, requestId: requestId);
      checkCancelled();
      checkpoint();
      final matches = result['matches'];
      if (matches is! bool) {
        throw const FormatException('Invalid native upload verification');
      }
      return matches;
    } on MissingPluginException {
      guard.cancel();
      checkCancelled();
      return _matchesUploadInDart(url, file, length, checkpoint);
    } catch (_) {
      checkCancelled();
      rethrow;
    } finally {
      guard.cancel();
    }
  }

  Future<void> _cancelUploadHash(String requestId) async {
    try {
      await PlatformBridge.cancelNativeDataJob(requestId);
    } catch (_) {
      // The worker is still awaited before the caller can release its file.
    }
  }

  Future<bool> _matchesUploadInDart(
    String url,
    File file,
    int length,
    void Function() checkpoint,
  ) async {
    final client = _client();
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(NetworkStorageService.timeout);
      final response = await request.close().timeout(
        NetworkStorageService.timeout,
      );
      if (response.statusCode != 200 ||
          (response.contentLength >= 0 && response.contentLength != length)) {
        return false;
      }
      var received = 0;
      final remote = await sha256
          .bind(
            response.timeout(NetworkStorageService.timeout).map((chunk) {
              checkpoint();
              received += chunk.length;
              if (received > length) {
                throw StateError('Network destination changed');
              }
              return chunk;
            }),
          )
          .first;
      final local = await sha256.bind(file.openRead()).first;
      return received == length && remote == local;
    } finally {
      client.close(force: true);
    }
  }

  /// Publish using a hidden temporary name and a non-overwriting rename.
  /// A lost rename response is reconciled by content, never length alone.
  Future<void> publishUpload(
    String source,
    File file,
    String transferId, {
    required void Function() checkpoint,
    required void Function(int, int) progress,
  }) async {
    final location = await _uploadLocation(source);
    final c = location.connection;
    final path = location.path;
    final slash = path.lastIndexOf('/');
    final parent = slash < 0 ? '' : path.substring(0, slash + 1);
    final name = path.substring(slash + 1);
    final length = await file.length();
    checkpoint();
    final entries = await list(c, parent);
    if (entries.any((e) => e.name.toLowerCase() == name.toLowerCase())) {
      if (await _matchesUpload(source, file, length, checkpoint)) return;
      throw StateError('Network destination already contains a different file');
    }
    final token = sha256.convert(utf8.encode(transferId)).toString();
    final temporary = '$parent.mornye-$token.part';
    if (c.protocol == NetworkProtocol.webdav) {
      try {
        await _uploadCommand(
          c,
          'PUT',
          temporary,
          file: file,
          checkpoint: checkpoint,
          progress: (sent) => progress(sent, length),
        );
        checkpoint();
        final uploaded = (await list(c, parent))
            .where((e) => e.name == temporary.substring(parent.length))
            .firstOrNull;
        if (uploaded?.size != length) {
          throw StateError('Network upload size mismatch');
        }
        await _uploadCommand(
          c,
          'MOVE',
          temporary,
          headers: {
            'Destination': networkTarget(c, path).toString(),
            'Overwrite': 'F',
          },
        );
      } catch (_) {
        try {
          await _uploadCommand(
            c,
            'DELETE',
            temporary,
            accepted: {200, 204, 404},
          );
        } catch (_) {}
        rethrow;
      }
    } else {
      final smb = await _smb(c, networkTarget(c, temporary));
      try {
        if (await smb.exists(smb.path)) await smb.delete(smb.path);
        await smb.upload(
          smb.path,
          file,
          checkpoint: checkpoint,
          progress: (sent) => progress(sent, length),
        );
        checkpoint();
        final reportedLength = (await smb.stat()).size;
        if (reportedLength != length &&
            !await smb.matchesFile(file, length, checkpoint: checkpoint)) {
          throw StateError(
            'Network upload size mismatch '
            '(SMB: expected $length bytes, reported $reportedLength bytes)',
          );
        }
        final destination = networkTarget(
          c,
          path,
        ).pathSegments.where((s) => s.isNotEmpty).skip(1).join('/');
        // libsmb2 uses replace_if_exist=0 for rename.
        await smb.rename(smb.path, destination);
      } catch (_) {
        try {
          await smb.delete(smb.path);
        } catch (_) {}
        rethrow;
      } finally {
        await smb.close();
      }
    }
    progress(length, length);
  }

  Future<void> _checkUploadAccess(String folder) async {
    final location = await _uploadLocation(folder);
    if (location.path.isNotEmpty && !location.path.endsWith('/')) {
      throw const FormatException('Expected a folder');
    }
    final temporary = await Directory.systemTemp.createTemp(
      'network-write-probe-',
    );
    final path =
        '${location.path}.mornye-probe-${NetworkStorageService.newId()}';
    try {
      final file = await File('${temporary.path}/probe').writeAsBytes([0]);
      if (location.connection.protocol == NetworkProtocol.webdav) {
        try {
          await _uploadCommand(
            location.connection,
            'PUT',
            path,
            file: file,
            headers: {'If-None-Match': '*'},
          );
        } finally {
          await _uploadCommand(
            location.connection,
            'DELETE',
            path,
            accepted: {200, 204, 404},
          );
        }
      } else {
        final smb = await _smb(
          location.connection,
          networkTarget(location.connection, path),
        );
        try {
          await smb.upload(smb.path, file, checkpoint: () {}, progress: (_) {});
          await smb.delete(smb.path);
        } finally {
          await smb.close();
        }
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
