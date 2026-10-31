import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dart_smb2/dart_smb2.dart'
    show Smb2DirEntry, Smb2Exception, Smb2ErrorType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html;
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/network_smb_client.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:xml/xml.dart';

part 'network_storage_upload.dart';
part 'network_storage_delete.dart';
part 'network_storage_subsonic.dart';

typedef _SmbListingInput = ({
  List<({String name, bool directory, int size, int modifiedTime})> files,
  String path,
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

class NetworkStorageService {
  NetworkStorageService({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    Future<void> Function(Uri)? ensureAccess,
  }) : _read = read ?? (() => _storage.read(key: _key)),
       _write = write ?? ((value) => _storage.write(key: _key, value: value)),
       _ensureAccess = ensureAccess ?? LocalNetworkAccess.instance.ensureAccess;
  static final instance = NetworkStorageService();
  static const _storage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );
  static const _key = 'network_storage_connections_v1';
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final Future<void> Function(Uri) _ensureAccess;

  /// Default timeout for general network operations, listings, and downloads.
  static const timeout = Duration(seconds: 20);

  /// Maximum socket backpressure wait time per chunk during file uploads.
  /// Prevents false stall failures on slow or fluctuating mobile networks.
  static const uploadChunkTimeout = Duration(minutes: 2);

  /// Maximum wait time for the server to commit and return response headers
  /// after all upload bytes have been flushed. Accommodates slow NAS disk I/O.
  static const uploadResponseTimeout = Duration(minutes: 30);

  @visibleForTesting
  static Duration? debugTimeoutOverride;

  @visibleForTesting
  static Duration? debugUploadChunkTimeoutOverride;

  @visibleForTesting
  static Duration? debugUploadResponseTimeoutOverride;
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
    _closeReadClients(id);
  });

  Future<NetworkConnection> connection(String id) async =>
      (await connections()).firstWhere(
        (c) => c.id == id,
        orElse: () => throw StateError('Network connection unavailable'),
      );

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

  Future<String> resolve(String source) async {
    final uri = Uri.parse(source);
    if (uri.scheme != 'network' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid network source');
    }
    final path = networkPath(uri.pathSegments.join('/'));
    final c = await connection(uri.host);
    await _ensureAccess(networkTarget(c, path));
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
    _routes[token] = (id: uri.host, path: path);
    return 'http://127.0.0.1:${server.port}/$token';
  }

  Future<NetworkSmbClient> _smb(NetworkConnection c, Uri target) async {
    await _ensureAccess(target);
    var expired = false;
    final pending = NetworkSmbClient.connect(
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

  void _closeReadClients(String id) {
    for (final key in _readClients.keys.where((key) => key.id == id).toList()) {
      // Let in-flight reads finish; new requests use the updated configuration.
      _readClients.remove(key)!.close();
    }
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
        final chunkTimeout =
            debugUploadChunkTimeoutOverride ?? uploadChunkTimeout;
        await for (final chunk in upload.openRead()) {
          checkpoint?.call();
          request.add(chunk);
          await request.flush().timeout(chunkTimeout);
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
      final effectiveTimeout = upload != null
          ? (debugUploadResponseTimeoutOverride ?? uploadResponseTimeout)
          : (debugTimeoutOverride ?? timeout);
      response = await request.close().timeout(
        effectiveTimeout,
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
      final smb = await _smb(c, target);
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
    final found = <String, NetworkEntry>{};
    void add(
      String href,
      bool directory,
      int? size, {
      int? modifiedTime,
      String? etag,
    }) {
      final uri = base.resolve(href);
      if (uri.origin != base.origin ||
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
      for (final response in doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'response',
      )) {
        final elements = response.descendants.whereType<XmlElement>();
        final href = elements
            .where((e) => e.name.local == 'href')
            .firstOrNull
            ?.innerText;
        final props = elements
            .where((e) => e.name.local == 'propstat')
            .where(
              (e) => e.childElements.any(
                (s) =>
                    s.name.local == 'status' && s.innerText.contains(' 200 '),
              ),
            );
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

  Future<void> _serve(HttpRequest request) async {
    NetworkSmbClient? smb;
    try {
      final route = _routes[request.uri.path.replaceFirst('/', '')];
      if (route == null || !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      final c = await connection(route.id);
      final target = c.protocol == NetworkProtocol.subsonic
          ? _subsonicMediaTarget(c, route.path)
          : networkTarget(c, route.path);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (c.protocol == NetworkProtocol.smb) {
        smb = await _smb(c, target);
        final file = await smb.stat().timeout(timeout);
        if (!file.isFile) {
          throw const HttpException('File unavailable');
        }
        final ({int start, int end}) part;
        try {
          part = networkByteRange(range, file.size);
        } on FormatException {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${file.size}',
          );
          return;
        }
        request.response.statusCode = range == null ? 200 : 206;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.contentType = ContentType.parse(
          networkContentType(target.pathSegments.last),
        );
        request.response.contentLength = part.end - part.start + 1;
        if (range != null) {
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${part.start}-${part.end}/${file.size}',
          );
        }
        if (request.method == 'GET' && file.size > 0) {
          await request.response.addStream(
            smb.read(part.start, part.end + 1).timeout(timeout),
          );
        }
      } else {
        final client = _readClient(c);
        final response = await _request(
          client,
          c,
          c.protocol == NetworkProtocol.subsonic ? 'GET' : request.method,
          target,
          range: range,
        );
        if (c.protocol == NetworkProtocol.subsonic &&
            const {
              'application/json',
              'application/xml',
              'text/xml',
            }.contains(response.headers.contentType?.mimeType)) {
          await _discardResponse(response);
          throw const HttpException('Subsonic media unavailable');
        }
        request.response.statusCode =
            response.statusCode >= 300 && response.statusCode < 400
            ? HttpStatus.badGateway
            : response.statusCode;
        for (final header in [
          HttpHeaders.contentTypeHeader,
          HttpHeaders.contentLengthHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.acceptRangesHeader,
        ]) {
          final value = response.headers.value(header);
          if (value != null) request.response.headers.set(header, value);
        }
        if (request.method == 'GET') {
          await request.response.addStream(response.timeout(timeout));
        } else if (c.protocol == NetworkProtocol.subsonic) {
          await _discardResponse(response);
        } else {
          await response.drain<void>().timeout(timeout);
        }
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      try {
        await smb?.close();
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  @visibleForTesting
  Future<HttpClientResponse> debugRequest({
    required HttpClient client,
    required NetworkConnection connection,
    required String method,
    required Uri uri,
    File? upload,
  }) => _request(client, connection, method, uri, upload: upload);

  Future<void> dispose() async {
    final server = _server;
    _server = null;
    _routes.clear();
    for (final client in _readClients.values) {
      client.close(force: true);
    }
    _readClients.clear();
    if (server != null) await (await server).close(force: true);
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
