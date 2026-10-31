import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mornye/services/sync/sync_storage_driver.dart';
import 'package:mornye/utils/logger.dart';
import 'package:xml/xml.dart';

final _log = AppLogger('WebDavSyncDriver');

/// WebDAV storage driver connecting to the user's existing rclone WebDAV endpoint.
///
/// Typical setup:
/// - Base URL: `http://<ip>:8686/` (rclone serve webdav gdrive:Music)
/// - Target Root: `MornyeSync/`
/// - Atomic Writes: PUT to .tmp -> MOVE with Overwrite: T
class WebDavSyncDriver implements SyncStorageDriver {
  WebDavSyncDriver({
    required this.baseUrl,
    this.rootPath = 'MornyeSync',
    this.username = '',
    this.password = '',
  }) : _httpClient = HttpClient()
         ..connectionTimeout = const Duration(seconds: 15)
         ..badCertificateCallback = ((_, _, _) => true);

  final String baseUrl;
  final String rootPath;
  final String username;
  final String password;
  final HttpClient _httpClient;

  Uri _resolveUri(String path) {
    var base = baseUrl.trim().replaceAll(' ', '');
    if (!base.endsWith('/')) base = '$base/';
    var root = rootPath.trim();
    if (root.startsWith('/')) root = root.substring(1);
    if (root.isNotEmpty && !root.endsWith('/')) root = '$root/';

    var cleanPath = path.trim();
    if (cleanPath.startsWith('/')) cleanPath = cleanPath.substring(1);

    return Uri.parse('$base$root$cleanPath');
  }

  void _applyAuth(HttpClientRequest request) {
    if (username.isNotEmpty || password.isNotEmpty) {
      final token = base64.encode(utf8.encode('$username:$password'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final uri = _resolveUri('');
      final request = await _httpClient.openUrl('PROPFIND', uri);
      _applyAuth(request);
      request.headers.set('Depth', '0');
      final response = await request.close();
      await response.drain<void>();
      // 200/207: directory exists; 404: server reachable but root folder needs creation
      return response.statusCode == 200 ||
          response.statusCode == 207 ||
          response.statusCode == 404;
    } catch (e) {
      _log.w('WebDAV endpoint $baseUrl unavailable: $e');
      return false;
    }
  }

  @override
  Future<List<SyncFileEntry>> listFiles(String path) async {
    final uri = _resolveUri(path);
    try {
      final request = await _httpClient.openUrl('PROPFIND', uri);
      _applyAuth(request);
      request.headers.set('Depth', '1');
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 207) {
        await response.drain<void>();
        return const [];
      }

      final body = await utf8.decoder.bind(response).join();
      final doc = XmlDocument.parse(body);
      final entries = <SyncFileEntry>[];

      for (final resp in doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'response',
      )) {
        final elements = resp.descendants.whereType<XmlElement>();
        final href = elements
            .where((e) => e.name.local == 'href')
            .firstOrNull
            ?.innerText
            .trim();
        if (href == null) continue;

        final props = elements
            .where((e) => e.name.local == 'propstat')
            .where(
              (e) => e.childElements.any(
                (s) => s.name.local == 'status' && s.innerText.contains('200'),
              ),
            )
            .expand((p) => p.descendants.whereType<XmlElement>());

        String? prop(String name) => props
            .where((e) => e.name.local == name)
            .firstOrNull
            ?.innerText
            .trim();

        final isCollection = props.any((e) => e.name.local == 'collection');
        final lengthStr = prop('getcontentlength');
        final size = lengthStr != null ? int.tryParse(lengthStr) : null;
        final etag = prop('getetag');
        int? modTime;

        final modStr = prop('getlastmodified');
        if (modStr != null) {
          try {
            modTime = HttpDate.parse(modStr).millisecondsSinceEpoch;
          } catch (_) {}
        }

        // Parse path relative to root
        var resolvedPath = Uri.parse(href).path;
        var cleanRoot = _resolveUri('').path;
        if (resolvedPath == cleanRoot || resolvedPath == '$cleanRoot/') {
          // Skip the directory itself (Depth 0 entry)
          continue;
        }

        var rel = resolvedPath.startsWith(cleanRoot)
            ? resolvedPath.substring(cleanRoot.length)
            : resolvedPath;
        if (rel.startsWith('/')) rel = rel.substring(1);
        if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
        if (rel.isEmpty) continue;

        final name = rel.split('/').last;
        if (name.endsWith('.tmp') || name.startsWith('.')) continue;

        entries.add(
          SyncFileEntry(
            path: rel,
            name: name,
            isDirectory: isCollection,
            size: size,
            modifiedTime: modTime,
            etag: etag,
          ),
        );
      }
      return entries;
    } catch (e) {
      _log.w('Failed to list WebDAV files at $path: $e');
      return const [];
    }
  }

  @override
  Future<SyncFileEntry?> stat(String path) async {
    final uri = _resolveUri(path);
    try {
      final request = await _httpClient.openUrl('PROPFIND', uri);
      _applyAuth(request);
      request.headers.set('Depth', '0');
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 207) {
        await response.drain<void>();
        return null;
      }

      final body = await utf8.decoder.bind(response).join();
      final doc = XmlDocument.parse(body);
      final resp = doc.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'response')
          .firstOrNull;
      if (resp == null) return null;

      final props = resp.descendants.whereType<XmlElement>();
      String? prop(String name) => props
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText
          .trim();

      final isCollection = props.any((e) => e.name.local == 'collection');
      final size = int.tryParse(prop('getcontentlength') ?? '');
      final etag = prop('getetag');
      int? modTime;
      final modStr = prop('getlastmodified');
      if (modStr != null) {
        try {
          modTime = HttpDate.parse(modStr).millisecondsSinceEpoch;
        } catch (_) {}
      }

      final clean = path.replaceAll('\\', '/');
      final name = clean.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';

      return SyncFileEntry(
        path: clean,
        name: name,
        isDirectory: isCollection,
        size: size,
        modifiedTime: modTime,
        etag: etag,
      );
    } catch (e) {
      _log.w('Failed to stat WebDAV path $path: $e');
      return null;
    }
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final uri = _resolveUri(path);
    final request = await _httpClient.getUrl(uri);
    _applyAuth(request);
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException(
        'Failed to read WebDAV file: ${response.statusCode}',
        uri: uri,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<String> readText(String path) async {
    final bytes = await readFile(path);
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> writeFile(
    String path,
    Uint8List data, {
    bool overwrite = true,
  }) async {
    final targetUri = _resolveUri(path);
    // Ensure parent folder structure exists
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length > 1) {
      await createDirectory(segments.sublist(0, segments.length - 1).join('/'));
    }

    // Atomic upload: PUT to a unique temporary file first
    final tmpPath = '$path.${DateTime.now().microsecondsSinceEpoch}.tmp';
    final tmpUri = _resolveUri(tmpPath);

    final putRequest = await _httpClient.putUrl(tmpUri);
    _applyAuth(putRequest);
    putRequest.headers.contentLength = data.length;
    putRequest.add(data);
    final putResponse = await putRequest.close();
    await putResponse.drain<void>();

    if (putResponse.statusCode != 200 &&
        putResponse.statusCode != 201 &&
        putResponse.statusCode != 204) {
      throw HttpException(
        'WebDAV temporary file PUT failed: ${putResponse.statusCode}',
        uri: tmpUri,
      );
    }

    // Atomic commit: MOVE with Overwrite: T
    final moveRequest = await _httpClient.openUrl('MOVE', tmpUri);
    _applyAuth(moveRequest);
    moveRequest.headers.set('Destination', targetUri.path);
    moveRequest.headers.set('Overwrite', overwrite ? 'T' : 'F');
    final moveResponse = await moveRequest.close();
    await moveResponse.drain<void>();

    if (moveResponse.statusCode != 200 &&
        moveResponse.statusCode != 201 &&
        moveResponse.statusCode != 204) {
      // Clean up tmp on failure
      try {
        await deleteFile(tmpPath);
      } catch (_) {}
      throw HttpException(
        'WebDAV MOVE to target failed: ${moveResponse.statusCode}',
        uri: targetUri,
      );
    }
  }

  @override
  Future<void> writeText(
    String path,
    String text, {
    bool overwrite = true,
  }) async {
    await writeFile(
      path,
      Uint8List.fromList(utf8.encode(text)),
      overwrite: overwrite,
    );
  }

  @override
  Future<void> deleteFile(String path) async {
    final uri = _resolveUri(path);
    final request = await _httpClient.deleteUrl(uri);
    _applyAuth(request);
    final response = await request.close();
    await response.drain<void>();
  }

  @override
  Future<void> deleteDirectory(String path) => deleteFile(path);

  @override
  Future<void> createDirectory(String path) async {
    final clean = path.replaceAll('\\', '/');
    final segments = clean.split('/').where((s) => s.isNotEmpty).toList();
    var current = '';
    for (final segment in segments) {
      current = current.isEmpty ? segment : '$current/$segment';
      final uri = _resolveUri(current);
      try {
        final request = await _httpClient.openUrl('MKCOL', uri);
        _applyAuth(request);
        final response = await request.close();
        await response.drain<void>();
      } catch (_) {
        // Ignored if folder already exists
      }
    }
  }
}
