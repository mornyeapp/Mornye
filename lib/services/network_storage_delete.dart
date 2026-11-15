part of 'network_storage_service.dart';

extension NetworkStorageDelete on NetworkStorageService {
  ({String id, String path})? _deletionTarget(String source) {
    final uri = Uri.parse(source);
    final segments = uri.pathSegments;
    if (uri.scheme != 'network' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        segments.isEmpty ||
        segments.any((s) => s.isEmpty || s.contains('/'))) {
      return null;
    }
    return (id: uri.host, path: networkPath(segments.join('/')));
  }

  Future<({NetworkConnection connection, String path})?> _deletionLocation(
    String source,
  ) async {
    final target = _deletionTarget(source);
    if (target == null) return null;
    final (:id, :path) = target;
    final c = await connection(id);
    c.validate();
    if (!c.writable) return null;
    // A server-level SMB connection may list shares. Never unlink a share.
    if (c.protocol == NetworkProtocol.smb &&
        networkTarget(c, path).pathSegments.length < 2) {
      return null;
    }
    return (connection: c, path: path);
  }

  /// Whether [source] is a `network://` song of a host the app no longer
  /// has: a removed connection that no virtual source owns. Adding the
  /// server again creates another connection, so the app can never reach
  /// that song again, and callers may drop it from their index.
  Future<bool> isOrphanedSource(String source) async {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'network' || uri.host.isEmpty) {
      return false;
    }
    // A paired phone's songs have no saved connection either, and with Link
    // off no virtual source: they come back when the phone does.
    if (virtualFor(uri.host) != null || isLinkPhoneSourceId(uri.host)) {
      return false;
    }
    try {
      return !(await connections()).any((c) => c.id == uri.host);
    } catch (error) {
      NetworkStorageService._log.w(
        'Could not read network connections: $error',
      );
      return false;
    }
  }

  /// Protocol capability only; the server still decides write permission.
  Future<bool> canDeleteFile(String source) async {
    try {
      final target = _deletionTarget(source);
      if (target == null) return false;
      final virtual = virtualSources;
      if (virtual != null && virtual.owns(target.id)) {
        return virtual is NetworkVirtualFileDeletion &&
            await virtual.canDeleteFile(target.id, target.path);
      }
      return await _deletionLocation(source) != null;
    } catch (_) {
      return false;
    }
  }

  /// Deletes one file, never a folder. Only confirmed absence is successful.
  /// Transport/permission failures propagate so callers keep their index rows.
  Future<bool> deleteFile(String source) async {
    final target = _deletionTarget(source);
    if (target == null) return false;
    final virtual = virtualSources;
    if (virtual != null && virtual.owns(target.id)) {
      return virtual is NetworkVirtualFileDeletion &&
          await virtual.deleteFile(target.id, target.path);
    }
    final location = await _deletionLocation(source);
    if (location == null) return false;
    final (:connection, :path) = location;
    if (connection.protocol == NetworkProtocol.smb) {
      final smb = await _smb(connection, networkTarget(connection, path));
      try {
        if (!(await smb.stat().timeout(NetworkStorageService.timeout)).isFile) {
          return false;
        }
        await smb.delete(smb.path).timeout(NetworkStorageService.timeout);
        return true;
      } on Smb2Exception catch (error) {
        if (error.isNotFound) return true;
        rethrow;
      } finally {
        try {
          await smb.close();
        } catch (_) {}
      }
    }

    final client = _client();
    try {
      final target = networkTarget(connection, path);
      final stat = await _request(
        client,
        connection,
        'PROPFIND',
        target,
        dav: true,
        davDepth: 0,
        directoryListing: true,
      );
      if (stat.statusCode == 404 || stat.statusCode == 410) return true;
      if (stat.statusCode != 207) {
        throw HttpException('Server returned ${stat.statusCode}');
      }
      final bytes = BytesBuilder();
      await for (final chunk in stat.timeout(NetworkStorageService.timeout)) {
        if (bytes.length + chunk.length > 256 * 1024) {
          throw const HttpException('File properties are too large');
        }
        bytes.add(chunk);
      }
      final parent = path.substring(0, path.lastIndexOf('/') + 1);
      final entries = NetworkStorageService.parseListing(
        connection,
        parent,
        utf8.decode(bytes.takeBytes()),
        requireResourceType: true,
      );
      if (!entries.any((entry) => entry.path == path && !entry.directory)) {
        return false;
      }
      final response = await _request(client, connection, 'DELETE', target);
      // 202 is only queued, and 207 may contain a failed deletion.
      final deleted = const {200, 204, 404, 410}.contains(response.statusCode);
      await _discardResponse(response);
      return deleted;
    } finally {
      client.close(force: true);
    }
  }
}
