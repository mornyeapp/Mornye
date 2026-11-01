import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dart_smb2/dart_smb2.dart' show Smb2DirEntry, Smb2Exception;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html;
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/network_smb_client.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:xml/xml.dart';

part 'network_storage_upload.dart';
part 'network_storage_delete.dart';
part 'network_storage_subsonic.dart';

typedef _SmbListingInput = ({
  List<({String name, bool directory, int size, int modifiedTime})> files,
  String path,
});

/// A file under a connection opened for one read: the status and headers a
/// proxy answers with and the `bytes` of a GET. Read `bytes` or call
/// `discard`, then `close`.
typedef _NetworkRead = ({
  int status,
  Map<String, String> headers,
  Stream<List<int>> bytes,
  Future<void> Function() discard,
  Future<void> Function() close,
});

List<NetworkEntry> _prepareSmbListingInBackground(_SmbListingInput input) =>
    NetworkStorageService._sorted([
      for (final file in input.files)
        if (file.name != '.' && file.name != '..')
          NetworkEntry(
            '${input.path}${file.name}${file.directory ? '/' : ''}',
            file.name,
            directory: file.directory,
            size: file.size,
            modifiedTime: file.modifiedTime,
          ),
    ]);

List<NetworkEntry> _parseNetworkListingInBackground(
  Map<String, dynamic> request,
) {
  final connection = NetworkConnection(
    id: 'listing',
    name: 'listing',
    protocol: NetworkProtocol.values.byName(request['protocol'] as String),
    address: request['address'] as String,
  );
  return NetworkStorageService.parseListing(
    connection,
    request['path'] as String,
    utf8.decode(request['bytes'] as Uint8List, allowMalformed: true),
  );
}

List<NetworkEntry> _hydrateNetworkEntriesInBackground(List<dynamic> entries) =>
    [
      for (final raw in entries)
        NetworkEntry(
          (raw as Map)['path'] as String,
          raw['name'] as String,
          directory: raw['directory'] as bool,
          size: (raw['size'] as num?)?.toInt(),
          modifiedTime: (raw['modifiedTime'] as num?)?.toInt(),
          etag: raw['etag'] as String?,
        ),
    ];

enum NetworkProtocol { smb, webdav, http, subsonic }

enum SubsonicAuth { saltedToken, password, apiKey }

class NetworkConnection {
  const NetworkConnection({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    this.username = '',
    this.password = '',
    this.domain = '',
    this.trustedCertificateSha256,
    this.subsonicAuth = SubsonicAuth.saltedToken,
    this.apiKey = '',
  });
  final String id, name, address, username, password, domain;
  final NetworkProtocol protocol;
  final String? trustedCertificateSha256;
  final SubsonicAuth subsonicAuth;
  final String apiKey;
  bool get writable =>
      protocol == NetworkProtocol.smb || protocol == NetworkProtocol.webdav;
  Uri get root => Uri.parse(address);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'address': address,
    'username': username,
    'password': password,
    'domain': domain,
    if (protocol == NetworkProtocol.subsonic) ...{
      'subsonicAuth': subsonicAuth.name,
      'apiKey': apiKey,
    },
    if (trustedCertificateSha256 != null)
      'trustedCertificateSha256': trustedCertificateSha256,
  };
  factory NetworkConnection.fromJson(Map<String, dynamic> json) =>
      NetworkConnection(
        id: json['id'] as String,
        name: json['name'] as String,
        protocol: NetworkProtocol.values.byName(json['protocol'] as String),
        address: json['address'] as String,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        domain: json['domain'] as String? ?? '',
        trustedCertificateSha256: json['trustedCertificateSha256'] as String?,
        subsonicAuth: SubsonicAuth.values.byName(
          json['subsonicAuth'] as String? ?? 'saltedToken',
        ),
        apiKey: json['apiKey'] as String? ?? '',
      );

  void validate() {
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(id) ||
        name.trim().isEmpty ||
        root.host.isEmpty ||
        root.userInfo.isNotEmpty ||
        root.hasFragment ||
        root.pathSegments.any((s) => s == '..') ||
        (root.hasQuery && protocol != NetworkProtocol.http) ||
        (protocol == NetworkProtocol.smb
            ? root.scheme != 'smb' ||
                  (root.hasPort && (root.port < 1 || root.port > 65535))
            : !['http', 'https'].contains(root.scheme))) {
      throw const FormatException('Invalid network address');
    }
  }
}

class NetworkEntry {
  const NetworkEntry(
    this.path,
    this.name, {
    this.directory = false,
    this.size,
    this.modifiedTime,
    this.etag,
    this.song,
  });
  final String path, name;
  final bool directory;
  final int? size;
  final int? modifiedTime;
  final String? etag;
  final SubsonicSong? song;
  String get extension => song?.format ?? name.split('.').last.toLowerCase();
  bool get audio =>
      !directory &&
      (song != null ||
          const {
            'flac',
            'mp3',
            'm4a',
            'mp4',
            'aac',
            'ogg',
            'opus',
            'wav',
            'aiff',
            'aif',
            'alac',
          }.contains(extension));
}

/// Paths remain relative to the selected root, never credential-bearing URLs.
String networkPath(String path) {
  if (path.startsWith('/') ||
      path.contains('\\') ||
      path.split('/').any((part) => part == '..' || part == '.') ||
      path.contains('\u0000')) {
    throw const FormatException('Invalid network path');
  }
  return path;
}

Uri networkTarget(NetworkConnection connection, String path) {
  networkPath(path);
  final root = connection.root;
  if (path.isEmpty) return root;
  final segments = [...root.pathSegments];
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  return Uri(
    scheme: root.scheme,
    host: root.host,
    port: root.hasPort ? root.port : null,
    pathSegments: [...segments, ...path.split('/')],
  );
}

/// Inclusive byte range; a null header means the entire representation.
({int start, int end}) networkByteRange(String? header, int size) {
  if (header == null) return (start: 0, end: size - 1);
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
  if (match == null || size <= 0 || (match[1]!.isEmpty && match[2]!.isEmpty)) {
    throw const FormatException('Invalid range');
  }
  final suffix = match[1]!.isEmpty;
  final start = suffix
      ? max(0, size - int.parse(match[2]!))
      : int.parse(match[1]!);
  final end = suffix || match[2]!.isEmpty
      ? size - 1
      : min(size - 1, int.parse(match[2]!));
  if (start >= size || start > end) {
    throw const FormatException('Invalid range');
  }
  return (start: start, end: end);
}

/// One song of a [NetworkVirtualSources] host for a Library scan: its
/// `path` under the host, its `tags` (the keys
/// [NetworkVirtualSources.metadata] answers), its local cover file and file
/// details when known.
typedef NetworkVirtualSong = ({
  String path,
  Map<String, dynamic> tags,
  String? coverPath,
  int? size,
  int? modifiedTime,
});

/// `network://` hosts that are not saved connections, such as a paired
/// phone's songs on the Mornye Link desktop. Their owner installs them as
/// [NetworkStorageService.virtualSources]; Library scans, playback and tag
/// reads of a host they own go to them. Saved connection lists never show
/// them.
abstract interface class NetworkVirtualSources {
  /// Whether the `network://` host [id] is one of these sources.
  bool owns(String id);

  /// The songs a Library scan of the host [id] lists.
  Stream<NetworkVirtualSong> songs(String id);

  /// A local path or URL the player opens for [path] under [id].
  Future<String> resolve(String id, String path);

  /// The tags of [path] under [id], with the keys a network tag read
  /// answers. Answers what it knows while the song cannot be reached.
  Future<Map<String, dynamic>> metadata(String id, String path);

  /// Whether songs under the host [id] can play now.
  bool reachable(String id);
}

/// [NetworkVirtualSources] that keep local copies of the songs they play,
/// such as the songs paired phones sent the Mornye Link desktop, and fetch
/// one again once it is gone.
abstract interface class NetworkLocalCopies implements NetworkVirtualSources {
  /// What plays in place of the local file [path] when it is one of these
  /// copies and gone: a path, or a URL streaming it as it arrives again.
  /// Null for another path or a copy still there; throws when it cannot be
  /// fetched.
  Future<String?> recover(String path);
}

/// A server's answer that the media at a network source is missing or not
/// what was asked for, such as a 404 or a song where a cover was asked.
/// Asking again soon gets the same answer.
class NetworkMediaUnavailable extends HttpException {
  const NetworkMediaUnavailable(super.message);
}

class NetworkStorageService {
  NetworkStorageService({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    Future<void> Function(Uri)? ensureAccess,
    NetworkSmbSessions? smbSessions,
  }) : _read = read ?? (() => _storage.read(key: _key)),
       _write = write ?? ((value) => _storage.write(key: _key, value: value)),
       _ensureAccess = ensureAccess ?? LocalNetworkAccess.instance.ensureAccess,
       _smbSessions = smbSessions ?? NetworkSmbSessions(idle: timeout);
  static final instance = NetworkStorageService();
  static const _storage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );
  static const _key = 'network_storage_connections_v1';
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final Future<void> Function(Uri) _ensureAccess;
  final NetworkSmbSessions _smbSessions;

  /// Owners stop scans before removing the connection finishes.
  final connectionRemovals = SourceDeletionEvents();
  static const timeout = Duration(seconds: 20);
  static const _probeTimeout = Duration(seconds: 3);
  static const _probeReuse = Duration(seconds: 10);

  /// The largest cover image [downloadCover] saves.
  static const maxCoverBytes = 16 * 1024 * 1024;

  /// Hosts that are not saved connections; set by their owner.
  NetworkVirtualSources? virtualSources;

  /// Connections known to be out of reach, with when a probe last failed.
  final _unreachable = <String, DateTime?>{};
  Future<List<NetworkConnection>>? _loading;
  List<NetworkConnection>? _connections;
  Future<HttpServer>? _server;
  Future<void> _mutation = Future.value();
  final _routes = <String, ({String id, String path})>{};
  final _readClients =
      <
        ({
          String id,
          String address,
          String username,
          String password,
          SubsonicAuth auth,
          String apiKey,
          String? certificate,
        }),
        HttpClient
      >{};

  static String newId() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _mutate(Future<void> Function() action) {
    final result = _mutation.then((_) => action());
    _mutation = result.catchError((Object _) {});
    return result;
  }

  Future<List<NetworkConnection>> connections() async {
    if (_connections != null) return _connections!;
    return _loading ??= () async {
      try {
        final raw = await _read();
        final result = raw == null
            ? <NetworkConnection>[]
            : [
                for (final row in jsonDecode(raw) as List)
                  NetworkConnection.fromJson(
                    Map<String, dynamic>.from(row as Map),
                  ),
              ];
        _connections = List<NetworkConnection>.unmodifiable(result);
        return _connections!;
      } finally {
        _loading = null;
      }
    }();
  }

  Future<void> save(NetworkConnection connection) => _mutate(() async {
    connection.validate();
    final next = [...await connections()]
      ..removeWhere((c) => c.id == connection.id);
    next.add(connection);
    await _write(jsonEncode(next.map((c) => c.toJson()).toList()));
    _connections = List.unmodifiable(next);
    _closeReadClients(connection.id);
  });

  Future<void> remove(String id) => _mutate(() async {
    final next = [...await connections()]..removeWhere((c) => c.id == id);
    await _write(jsonEncode(next.map((c) => c.toJson()).toList()));
    _connections = List.unmodifiable(next);
    _routes.removeWhere((_, route) => route.id == id);
    _closeReadClients(id, force: true);
    await connectionRemovals.publish(id);
  });

  Future<NetworkConnection> connection(String id) async =>
      (await connections()).firstWhere(
        (c) => c.id == id,
        orElse: () => throw StateError('Network connection unavailable'),
      );

  /// Whether the `network://` [source] can play now: a host its virtual
  /// source reaches, or a saved connection not known to be out of reach.
  /// Songs of a host neither knows, such as a phone after Link stopped,
  /// cannot.
  Future<bool> reachable(String source) async {
    final host = Uri.tryParse(source)?.host ?? '';
    if (virtualFor(host) case final virtual?) return virtual.reachable(host);
    if (_unreachable.containsKey(host)) return false;
    return (await connections()).any((c) => c.id == host);
  }

  /// The [virtualSources] when they own the host [id], else null.
  NetworkVirtualSources? virtualFor(String id) {
    final sources = virtualSources;
    return sources != null && sources.owns(id) ? sources : null;
  }

  Future<void> checkUploadAccess(String folder) => _checkUploadAccess(folder);

  static String source(String id, String path) => Uri(
    scheme: 'network',
    host: id,
    pathSegments: networkPath(path).split('/'),
  ).toString();

  /// Identity of a remote file across saved connections to the same NAS root.
  /// Resolve relative paths before comparing; connection IDs are aliases, not
  /// physical storage identities. Credentials never leave this service.
  static String? physicalFileKey(
    String source,
    Map<String, NetworkConnection> connections,
  ) {
    final uri = Uri.tryParse(source);
    if (uri == null ||
        uri.scheme != 'network' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final connection = connections[uri.host];
    if (connection == null) return null;
    try {
      connection.validate();
      final target = networkTarget(
        connection,
        networkPath(uri.pathSegments.join('/')),
      );
      // Accounts can expose different virtual trees at an identical address.
      // Keep them separate and preserve path case, including on WebDAV.
      final identity = jsonEncode([
        connection.protocol.name,
        target.host,
        connection.protocol == NetworkProtocol.smb && !target.hasPort
            ? 445
            : target.port,
        connection.username,
        connection.protocol == NetworkProtocol.subsonic
            ? connection.id
            : connection.domain,
        target.pathSegments,
      ]);
      return 'network-file:${sha256.convert(utf8.encode(identity))}';
    } on FormatException {
      return null;
    }
  }

  /// The host and path of the `network://` [source]; throws a
  /// [FormatException] for any other source.
  static ({String host, String path}) _sourceParts(String source) {
    final uri = Uri.parse(source);
    if (uri.scheme != 'network' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid network source');
    }
    return (host: uri.host, path: networkPath(uri.pathSegments.join('/')));
  }

  /// The saved connection [id] for a read of [path], once local network
  /// access allows its server and, when it is marked out of reach, the
  /// server answers again.
  Future<NetworkConnection> _readyConnection(String id, String path) async {
    final c = await connection(id);
    final target = networkTarget(c, path);
    await _ensureAccess(target);
    await _checkReachable(c.id, target);
    return c;
  }

  /// Saves the cover image at the `network://` [source] to [output], read
  /// over its connection directly instead of through a loopback route:
  /// Subsonic cover art, a WebDAV, HTTP or SMB file, or the local file a
  /// virtual source answers with. Throws when the cover is unavailable,
  /// empty, a text document (such as a Subsonic error), audio or video, or
  /// larger than [maxCoverBytes], with a [NetworkMediaUnavailable] when the
  /// answer will not change soon; [output] may then hold part of it, so
  /// callers write to a staged file and rename it once this returns.
  Future<void> downloadCover(String source, File output) async {
    final (:host, :path) = _sourceParts(source);
    if (virtualFor(host) case final virtual?) {
      // Virtual sources answer URLs only for songs on their way.
      final file = _localFile(await virtual.resolve(host, path));
      if (file == null) throw const HttpException('Network cover unavailable');
      return _writeCover(file.openRead(), output);
    }
    final c = await _readyConnection(host, path);
    if (c.protocol == NetworkProtocol.subsonic &&
        !path.startsWith('subsonic/cover/')) {
      throw const FormatException('Expected a Subsonic cover');
    }
    _NetworkRead? read;
    var consumed = false;
    try {
      read = await _openRead(c, path);
      final problem = _coverProblem(
        read.status,
        read.headers[HttpHeaders.contentTypeHeader]
            ?.split(';')
            .first
            .trim()
            .toLowerCase(),
        int.tryParse(read.headers[HttpHeaders.contentLengthHeader] ?? ''),
      );
      if (problem != null) throw problem;
      consumed = true;
      await _writeCover(read.bytes, output);
    } on HttpException catch (error) {
      // HttpClient exceptions can carry the credential-bearing request URI.
      if (error.uri == null) rethrow;
      throw HttpException(error.message);
    } finally {
      // An unread response would hold its pooled connection.
      if (!consumed) {
        try {
          await read?.discard();
        } catch (_) {}
      }
      try {
        await read?.close();
      } catch (_) {}
    }
  }

  /// Why a cover answer of [status], [mime] type and declared [size]
  /// cannot be saved; null when it can.
  static HttpException? _coverProblem(int status, String? mime, int? size) {
    if (status != HttpStatus.ok) {
      return status == HttpStatus.notFound || status == HttpStatus.gone
          ? NetworkMediaUnavailable('Server returned $status')
          : HttpException('Server returned $status');
    }
    if (mime != null &&
        (mime.startsWith('audio/') || mime.startsWith('video/'))) {
      return const NetworkMediaUnavailable('Network cover is not an image');
    }
    if (mime != null &&
        (mime.startsWith('text/') ||
            mime == 'application/json' ||
            mime == 'application/xml')) {
      return const HttpException('Network cover unavailable');
    }
    if (size != null && size > maxCoverBytes) {
      return const NetworkMediaUnavailable('Network cover is too large');
    }
    return null;
  }

  /// The local file a virtual source answers with: an absolute path or a
  /// `file://` URI. Null for a URL.
  static File? _localFile(String location) {
    final file = File(location);
    if (file.isAbsolute) return file;
    final uri = Uri.tryParse(location);
    if (uri == null || !uri.isScheme('file')) return null;
    try {
      return File(uri.toFilePath());
    } on UnsupportedError {
      return null;
    }
  }

  static Future<void> _writeCover(Stream<List<int>> bytes, File output) async {
    final writer = output.openWrite();
    var size = 0;
    try {
      await for (final chunk in bytes) {
        size += chunk.length;
        if (size > maxCoverBytes) {
          throw const NetworkMediaUnavailable('Network cover is too large');
        }
        writer.add(chunk);
        await writer.flush();
      }
      if (size == 0) {
        throw const NetworkMediaUnavailable('Network cover is empty');
      }
    } finally {
      await writer.close();
    }
  }

  Future<String> resolve(String source) async {
    final (:host, :path) = _sourceParts(source);
    if (virtualFor(host) case final virtual?) {
      return virtual.resolve(host, path);
    }
    await _readyConnection(host, path);
    _server ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
      server.listen((request) => unawaited(_serve(request)));
      return server;
    });
    final HttpServer server;
    try {
      server = await _server!;
    } catch (_) {
      _server = null;
      rethrow;
    }
    final token = newId();
    while (_routes.length >= 256) {
      _routes.remove(_routes.keys.first);
    }
    _routes[token] = (id: host, path: path);
    return 'http://127.0.0.1:${server.port}/$token';
  }

  /// Marks connection [id] out of reach, as a paired Mornye Link desktop
  /// whose session cannot connect, or reachable again. Songs of a marked
  /// connection check its server briefly before playing instead of
  /// waiting [timeout] for it.
  void setReachable(String id, {required bool reachable}) {
    if (reachable) {
      _unreachable.remove(id);
    } else {
      _unreachable.putIfAbsent(id, () => null);
    }
  }

  /// Throws at once for a connection marked out of reach, unless its
  /// server accepts a connection again. A failed check is reused briefly
  /// so a song and its cover wait for one check.
  Future<void> _checkReachable(String id, Uri target) async {
    if (!_unreachable.containsKey(id) || target.port == 0) return;
    final failedAt = _unreachable[id];
    if (failedAt == null || DateTime.now().difference(failedAt) > _probeReuse) {
      try {
        final socket = await Socket.connect(
          target.host,
          target.port,
          timeout: _probeTimeout,
        );
        socket.destroy();
        _unreachable.remove(id);
        return;
      } on SocketException {
        if (!_unreachable.containsKey(id)) return;
        _unreachable[id] = DateTime.now();
      }
    }
    throw const SocketException('The server cannot be reached');
  }

  /// An SMB client for [target]: a lease on the connection's shared session
  /// for reads ([shared]), else a session of its own.
  Future<NetworkSmbClient> _smb(
    NetworkConnection c,
    Uri target, {
    bool shared = false,
  }) async {
    await _ensureAccess(target);
    var expired = false;
    final pending = shared
        ? _smbSessions.lease(
            c.id,
            target,
            username: c.username,
            password: c.password,
            domain: c.domain,
            timeout: timeout,
          )
        : NetworkSmbClient.connect(
            target,
            username: c.username,
            password: c.password,
            domain: c.domain,
            timeout: timeout,
          );
    unawaited(
      pending
          .then((smb) async {
            if (expired) await smb.close();
          })
          .catchError((Object _) {}),
    );
    return pending.timeout(
      timeout,
      onTimeout: () {
        expired = true;
        throw TimeoutException('Network connection timed out');
      },
    );
  }

  HttpClient _client() => HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = timeout
    ..autoUncompress = false;

  HttpClient _readClient(NetworkConnection connection) {
    // Pool only read requests with the same credentials and certificate pin.
    // Uploads retain their own scoped client and cancellation lifecycle.
    final key = (
      id: connection.id,
      address: connection.address,
      username: connection.username,
      password: connection.password,
      auth: connection.subsonicAuth,
      apiKey: connection.apiKey,
      certificate: connection.trustedCertificateSha256,
    );
    final client =
        _readClients.remove(key) ?? (_client()..maxConnectionsPerHost = 6);
    while (_readClients.length >= 8) {
      _readClients.remove(_readClients.keys.first)!.close();
    }
    _readClients[key] = client;
    return client;
  }

  void _closeReadClients(String id, {bool force = false}) {
    for (final key in _readClients.keys.where((key) => key.id == id).toList()) {
      // Edits let existing reads finish; removal aborts the old connection.
      _readClients.remove(key)!.close(force: force);
    }
    _smbSessions.retire(id);
  }

  Future<void> _discardResponse(HttpClientResponse response) =>
      response.listen((_) {}).cancel();

  Future<HttpClientResponse> _request(
    HttpClient client,
    NetworkConnection c,
    String method,
    Uri uri, {
    String? range,
    bool dav = false,
    int davDepth = 1,
    bool directoryListing = false,
    int redirects = 0,
    Map<String, String> headers = const {},
    File? upload,
    void Function()? checkpoint,
    void Function(int)? progress,
  }) async {
    await _ensureAccess(uri);
    NetworkCertificateException? rejectedCertificate;
    client.badCertificateCallback = (certificate, host, port) {
      if (uri.scheme != 'https' ||
          uri.origin != c.root.origin ||
          host != c.root.host ||
          port != c.root.port) {
        return false;
      }
      final presented = NetworkCertificateException.fromCertificate(
        uri,
        certificate,
      );
      if (c.trustedCertificateSha256 == presented.fingerprint) return true;
      rejectedCertificate = presented;
      return false;
    };
    final HttpClientRequest request;
    try {
      var expired = false;
      final opening = client.openUrl(method, uri).then((request) {
        if (expired) request.abort();
        return request;
      });
      request = await opening.timeout(
        timeout,
        onTimeout: () {
          expired = true;
          throw TimeoutException('Network connection timed out');
        },
      );
    } on HandshakeException {
      if (rejectedCertificate != null) throw rejectedCertificate!;
      rethrow;
    }
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (c.protocol != NetworkProtocol.subsonic &&
        (c.username.isNotEmpty || c.password.isNotEmpty)) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${c.username}:${c.password}'))}',
      );
    }
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    headers.forEach(request.headers.set);
    if (upload != null) {
      request.contentLength = await upload.length();
      var sent = 0;
      try {
        await for (final chunk in upload.openRead()) {
          checkpoint?.call();
          request.add(chunk);
          await request.flush().timeout(timeout);
          sent += chunk.length;
          progress?.call(sent);
        }
      } catch (error) {
        request.abort();
        rethrow;
      }
    }
    if (dav) {
      request.headers.set('Depth', davDepth.toString());
      request.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.write(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:resourcetype/><d:getcontentlength/>'
        '<d:getlastmodified/><d:getetag/></d:prop></d:propfind>',
      );
    }
    final HttpClientResponse response;
    try {
      response = await request.close().timeout(
        timeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('Network response timed out');
        },
      );
    } on HandshakeException {
      if (rejectedCertificate != null) throw rejectedCertificate!;
      rethrow;
    }
    if ([301, 302, 307, 308].contains(response.statusCode)) {
      // Never replay a mutating request to an unselected path.
      if (!['GET', 'HEAD', 'PROPFIND'].contains(method)) {
        await _discardResponse(response);
        throw const HttpException('Write destination redirected');
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      final next = location == null ? null : uri.resolve(location);
      // Keep credentials on the configured server; never forward them to a CDN
      // or follow a TLS downgrade, even when requested by a redirect.
      if (next == null ||
          next.origin != uri.origin ||
          next.userInfo.isNotEmpty ||
          (directoryListing &&
              next.path != uri.path &&
              next.path != '${uri.path}/') ||
          redirects >= 3) {
        await _discardResponse(response);
        throw const HttpException('Unsupported server redirect');
      }
      await response.drain<void>().timeout(timeout);
      return _request(
        client,
        c,
        method,
        next,
        range: range,
        dav: dav,
        davDepth: davDepth,
        directoryListing: directoryListing,
        redirects: redirects + 1,
      );
    }
    return response;
  }

  /// Lists the root of [c] to check it before saving: SMB logs on again
  /// instead of reusing a live session, which survives a password change.
  Future<List<NetworkEntry>> verify(NetworkConnection c) {
    _smbSessions.retire(c.id);
    return list(c);
  }

  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async {
    c.validate();
    if (c.protocol == NetworkProtocol.subsonic) {
      final client = openSubsonic(c);
      try {
        return await client.list(path);
      } finally {
        client.close();
      }
    }
    final target = networkTarget(c, path);
    if (c.protocol == NetworkProtocol.smb) {
      if (target.pathSegments.every((s) => s.isEmpty)) {
        await _ensureAccess(target);
        final shares = await NetworkSmbClient.shares(
          target,
          username: c.username,
          password: c.password,
          domain: c.domain,
          timeout: timeout,
        ).timeout(timeout);
        return _sorted([
          for (final share in shares)
            if (share.isDisk)
              NetworkEntry('$path${share.name}/', share.name, directory: true),
        ]);
      }
      final smb = await _smb(c, target, shared: true);
      final List<Smb2DirEntry> files;
      try {
        files = await smb.list().timeout(timeout);
      } finally {
        // A failed disconnect must not hide the original share/login error.
        try {
          await smb.close();
        } catch (_) {}
      }
      return prepareSmbEntries(files, path);
    }
    final client = _readClient(c);
    if (c.protocol == NetworkProtocol.http &&
        NetworkEntry('', target.pathSegments.lastOrNull ?? '').audio) {
      final response = await _request(
        client,
        c,
        'GET',
        target,
        range: 'bytes=0-0',
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        await _discardResponse(response);
        throw HttpException('Server returned ${response.statusCode}');
      }
      // Do not download a whole track when a server ignores the range.
      if (response.statusCode == 206 && response.contentLength == 1) {
        await response.drain<void>().timeout(timeout);
      } else {
        await _discardResponse(response);
      }
      return [NetworkEntry(path, target.pathSegments.last)];
    }
    final response = await _request(
      client,
      c,
      c.protocol == NetworkProtocol.webdav ? 'PROPFIND' : 'GET',
      target,
      dav: c.protocol == NetworkProtocol.webdav,
      directoryListing: true,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _discardResponse(response);
      throw HttpException('Server returned ${response.statusCode}');
    }
    final bytes = BytesBuilder();
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw const HttpException('Directory listing is too large');
      }
      bytes.add(chunk);
    }
    return await parseListingInBackground(c, path, bytes.takeBytes());
  }

  /// Large SMB listings arrive from native I/O as plain stat objects. Transfer
  /// only fields used by browsing and incremental Library scans.
  static Future<List<NetworkEntry>> prepareSmbEntries(
    List<Smb2DirEntry> files,
    String path,
  ) async {
    final input = (
      path: path,
      files: [
        for (final file in files)
          (
            name: file.name,
            directory: file.stat.isDirectory,
            size: file.stat.size,
            modifiedTime: file.stat.modified.millisecondsSinceEpoch,
          ),
      ],
    );
    // Small lists are cheaper inline; large sorts must leave the UI isolate.
    if (files.length < 4096) return _prepareSmbListingInBackground(input);
    return compute(_prepareSmbListingInBackground, input);
  }

  static List<NetworkEntry> _sorted(List<NetworkEntry> entries) {
    final keyed =
        [
          for (final entry in entries)
            (entry: entry, key: entry.name.toLowerCase()),
        ]..sort(
          (a, b) => a.entry.directory != b.entry.directory
              ? (a.entry.directory ? -1 : 1)
              : a.key.compareTo(b.key),
        );
    for (var index = 0; index < entries.length; index++) {
      entries[index] = keyed[index].entry;
    }
    return entries;
  }

  static List<NetworkEntry> parseListing(
    NetworkConnection c,
    String path,
    String body, {
    bool requireResourceType = false,
  }) {
    final target = networkTarget(c, path);
    final base = target.path.endsWith('/')
        ? target
        : target.replace(path: '${target.path}/');
    final baseSegments = [...base.pathSegments];
    if (baseSegments.isNotEmpty && baseSegments.last.isEmpty) {
      baseSegments.removeLast();
    }
    String? advertisedOrigin;
    final found = <String, NetworkEntry>{};
    void add(
      String href,
      bool directory,
      int? size, {
      int? modifiedTime,
      String? etag,
    }) {
      final uri = base.resolve(href);
      // A DAV server can advertise its LAN address behind a tunnel. Accept
      // that origin only when it identifies the requested collection itself.
      // Reads and writes still use child paths on the saved connection.
      final sameServer =
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          (uri.origin == base.origin ||
              (c.protocol == NetworkProtocol.webdav &&
                  (uri.host == base.host || uri.origin == advertisedOrigin)));
      if (!sameServer ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        return;
      }
      // Servers may encode '&', '+', brackets or percent escapes differently
      // from the request. Compare decoded components once, never a raw prefix
      // or a fully decoded path that could turn an encoded '/' into a folder.
      final segments = [...uri.pathSegments];
      if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
      if (segments.length != baseSegments.length + 1 ||
          segments.any(
            (segment) =>
                segment.contains('/') ||
                segment.contains('\\') ||
                segment.contains('\u0000') ||
                segment == '.' ||
                segment == '..',
          )) {
        return;
      }
      for (var index = 0; index < baseSegments.length; index++) {
        if (segments[index] != baseSegments[index]) return;
      }
      final name = segments.last;
      if (name.isEmpty) return;
      final relative = '$path$name${directory ? '/' : ''}';
      found[relative] = NetworkEntry(
        relative,
        name,
        directory: directory,
        size: size,
        modifiedTime: modifiedTime,
        etag: etag,
      );
    }

    if (c.protocol == NetworkProtocol.webdav) {
      final doc = XmlDocument.parse(body);
      if (doc.rootElement.name.local != 'multistatus') {
        throw const HttpException(
          'Server did not return a WebDAV directory listing',
        );
      }
      final successfulStatus = RegExp(r'^HTTP/\S+\s+200(?:\s|$)');
      final responses = doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'response',
      );
      Iterable<XmlElement> properties(XmlElement response) =>
          response.descendants.whereType<XmlElement>().where(
            (e) =>
                e.name.local == 'propstat' &&
                e.childElements.any(
                  (s) =>
                      s.name.local == 'status' &&
                      successfulStatus.hasMatch(s.innerText.trim()),
                ),
          );
      final origins = <String>{};
      for (final response in responses) {
        final href = response.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'href')
            .firstOrNull
            ?.innerText;
        if (href == null) continue;
        final uri = base.resolve(href);
        if ((uri.scheme != 'http' && uri.scheme != 'https') ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        final segments = [...uri.pathSegments];
        if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
        if (listEquals(segments, baseSegments) &&
            properties(response).any(
              (prop) => prop.descendants.whereType<XmlElement>().any(
                (e) => e.name.local == 'collection',
              ),
            )) {
          origins.add(uri.origin);
        }
      }
      if (origins.length == 1) advertisedOrigin = origins.single;
      for (final response in responses) {
        final elements = response.descendants.whereType<XmlElement>();
        final href = elements
            .where((e) => e.name.local == 'href')
            .firstOrNull
            ?.innerText;
        final props = properties(response);
        final values = props.expand(
          (p) => p.descendants.whereType<XmlElement>(),
        );
        if (requireResourceType &&
            !values.any((e) => e.name.local == 'resourcetype')) {
          continue;
        }
        if (href != null && props.isNotEmpty) {
          String? property(String name) => values
              .where((element) => element.name.local == name)
              .firstOrNull
              ?.innerText
              .trim();
          int? modifiedTime;
          try {
            final date = property('getlastmodified');
            if (date != null) {
              modifiedTime = HttpDate.parse(date).millisecondsSinceEpoch;
            }
          } on HttpException {
            // Missing or malformed validators require a fresh metadata read.
          }
          add(
            href,
            values.any((e) => e.name.local == 'collection'),
            int.tryParse(property('getcontentlength') ?? ''),
            modifiedTime: modifiedTime,
            etag: property('getetag'),
          );
        }
      }
    } else {
      for (final a in html.parse(body).querySelectorAll('a[href]')) {
        final href = a.attributes['href']!;
        add(href, Uri.tryParse(href)?.path.endsWith('/') == true, null);
      }
    }
    return _sorted(found.values.toList());
  }

  /// Keep DOM parsing and sorting away from the Flutter frame while retaining
  /// the synchronous parser for unsupported native hosts and contract tests.
  static Future<List<NetworkEntry>> parseListingInBackground(
    NetworkConnection connection,
    String path,
    Uint8List bytes,
  ) async {
    List<dynamic> entries;
    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'parse_network_listing',
        'protocol': connection.protocol.name,
        'base_url': networkTarget(connection, path).toString(),
        'path': path,
      }, bytes: bytes);
      entries = result['entries'] as List;
    } on MissingPluginException {
      return compute(_parseNetworkListingInBackground, {
        'protocol': connection.protocol.name,
        'address': connection.address,
        'path': path,
        'bytes': bytes,
      });
    } on PlatformException catch (error) {
      if (error.message?.contains('XML nesting exceeds') != true) rethrow;
      return compute(_parseNetworkListingInBackground, {
        'protocol': connection.protocol.name,
        'address': connection.address,
        'path': path,
        'bytes': bytes,
      });
    }
    return compute(_hydrateNetworkEntriesInBackground, entries);
  }

  /// Opens [path] under [c] for one [method] read over the connection's own
  /// client, limited to the HTTP [range] when one is given. Subsonic error
  /// documents (JSON or XML) throw instead of passing as media.
  Future<_NetworkRead> _openRead(
    NetworkConnection c,
    String path, {
    String method = 'GET',
    String? range,
  }) async {
    final target = c.protocol == NetworkProtocol.subsonic
        ? _subsonicMediaTarget(c, path)
        : networkTarget(c, path);
    if (c.protocol == NetworkProtocol.smb) {
      final smb = await _smb(c, target, shared: true);
      try {
        final file = await smb.stat().timeout(timeout);
        if (!file.isFile) {
          throw const HttpException('File unavailable');
        }
        final ({int start, int end}) part;
        try {
          part = networkByteRange(range, file.size);
        } on FormatException {
          return (
            status: HttpStatus.requestedRangeNotSatisfiable,
            headers: {
              if (method == 'GET') HttpHeaders.contentLengthHeader: '0',
              HttpHeaders.contentRangeHeader: 'bytes */${file.size}',
            },
            bytes: const Stream<List<int>>.empty(),
            discard: () async {},
            close: smb.close,
          );
        }
        return (
          status: range == null ? HttpStatus.ok : HttpStatus.partialContent,
          headers: {
            HttpHeaders.acceptRangesHeader: 'bytes',
            HttpHeaders.contentTypeHeader: networkContentType(
              target.pathSegments.last,
            ),
            HttpHeaders.contentLengthHeader: '${part.end - part.start + 1}',
            if (range != null)
              HttpHeaders.contentRangeHeader:
                  'bytes ${part.start}-${part.end}/${file.size}',
          },
          bytes: file.size > 0
              ? smb.read(part.start, part.end + 1).timeout(timeout)
              : const Stream<List<int>>.empty(),
          discard: () async {},
          close: smb.close,
        );
      } catch (_) {
        try {
          await smb.close();
        } catch (_) {}
        rethrow;
      }
    }
    final subsonic = c.protocol == NetworkProtocol.subsonic;
    final response = await _request(
      _readClient(c),
      c,
      subsonic ? 'GET' : method,
      target,
      range: range,
    );
    try {
      if (subsonic &&
          const {
            'application/json',
            'application/xml',
            'text/xml',
          }.contains(response.headers.contentType?.mimeType)) {
        throw response.statusCode == HttpStatus.notFound ||
                response.statusCode == HttpStatus.gone
            ? const NetworkMediaUnavailable('Subsonic media unavailable')
            : const HttpException('Subsonic media unavailable');
      }
      return (
        status: response.statusCode,
        headers: {
          for (final header in const [
            HttpHeaders.contentTypeHeader,
            HttpHeaders.contentLengthHeader,
            HttpHeaders.contentRangeHeader,
            HttpHeaders.acceptRangesHeader,
          ])
            header: ?response.headers.value(header),
        },
        bytes: response.timeout(timeout),
        discard: subsonic || method == 'GET'
            ? () => _discardResponse(response)
            : () => response.drain<void>().timeout(timeout),
        close: () async {},
      );
    } catch (_) {
      // Malformed headers throw here; release the connection all the same.
      try {
        await _discardResponse(response);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    _NetworkRead? read;
    var consumed = false;
    try {
      final route = _routes[request.uri.path.replaceFirst('/', '')];
      if (route == null || !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      read = await _openRead(
        await connection(route.id),
        route.path,
        method: request.method,
        range: request.headers.value(HttpHeaders.rangeHeader),
      );
      request.response.statusCode = read.status >= 300 && read.status < 400
          ? HttpStatus.badGateway
          : read.status;
      read.headers.forEach(request.response.headers.set);
      consumed = true;
      if (request.method == 'GET') {
        await request.response.addStream(read.bytes);
      } else {
        await read.discard();
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      if (!consumed) {
        try {
          await read?.discard();
        } catch (_) {}
      }
      try {
        await read?.close();
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    final server = _server;
    _server = null;
    _routes.clear();
    for (final client in _readClients.values) {
      client.close(force: true);
    }
    _readClients.clear();
    if (server != null) await (await server).close(force: true);
    await _smbSessions.close();
  }
}

String networkContentType(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'm4a' || 'mp4' || 'alac' => 'audio/mp4',
      'aac' => 'audio/aac',
      'ogg' || 'opus' => 'audio/ogg',
      'wav' => 'audio/wav',
      'aif' || 'aiff' => 'audio/aiff',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      _ => 'application/octet-stream',
    };
