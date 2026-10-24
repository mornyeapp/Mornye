import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';

/// Requests to the desktop give up after this long.
const linkRequestTimeout = Duration(seconds: 20);

/// Response bodies above this size are refused (the server's request limit).
const _maxBodyBytes = 8 * 1024 * 1024;

/// Error codes the phone adds to the contract's `invalid`, `not_found`,
/// `unavailable` and `timeout` when the failure happens on the way.
abstract final class LinkClientErrors {
  static const unauthorized = 'unauthorized';
  static const certificate = 'certificate';
  static const unavailable = 'unavailable';
  static const timeout = 'timeout';
  static const invalid = 'invalid';
  static const localNetworkPermission = 'local_network_permission';
}

/// The certificate fingerprint as the contract and the network storage trust
/// store write it: lowercase hex SHA-256 of the DER bytes.
String linkCertificateFingerprint(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();

/// `https://host:port` for a desktop, or null when [host] or [port] cannot
/// form one. IPv6 literals are bracketed; a scheme or path is refused.
Uri? linkServerAddress(String host, int port) {
  final trimmed = host.trim().replaceAll(RegExp(r'^\[|\]$'), '');
  if (trimmed.isEmpty ||
      port < 1 ||
      port > 65535 ||
      trimmed.contains('/') ||
      trimmed.contains('@') ||
      trimmed.contains(' ') ||
      (trimmed.contains(':') && InternetAddress.tryParse(trimmed) == null)) {
    return null;
  }
  try {
    return Uri(scheme: 'https', host: trimmed, port: port);
  } on FormatException {
    return null;
  }
}

/// An [HttpClient] that trusts exactly the certificate whose fingerprint is
/// [fingerprint]. It loads no CA roots, so every handshake reaches the
/// callback and nothing but the pinned certificate passes, not even a
/// publicly trusted one.
HttpClient linkPinnedHttpClient(String fingerprint) {
  final pin = fingerprint.toLowerCase();
  return HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = linkRequestTimeout
    ..idleTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (certificate, _, _) =>
        linkCertificateFingerprint(certificate) == pin;
}

/// An [HttpClient] for first contact with an unpaired desktop. It accepts the
/// certificate presented by [target]'s host and port, and no other host, so
/// the caller can read the fingerprint from the response
/// ([LinkHttpResponse.certificateFingerprint]) and compare it with what the
/// desktop claims before trusting anything.
HttpClient linkFirstContactHttpClient(Uri target) =>
    HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = linkRequestTimeout
      ..badCertificateCallback = (_, host, port) =>
          host == target.host && port == target.port;

class LinkHttpResponse {
  const LinkHttpResponse({
    required this.statusCode,
    this.body,
    this.certificateFingerprint,
  });

  final int statusCode;

  /// The decoded JSON body, or null when it was empty or not JSON.
  final Object? body;

  /// The fingerprint of the certificate the server presented, or null over
  /// plain HTTP.
  final String? certificateFingerprint;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// Sends one JSON request and reads the whole JSON answer.
Future<LinkHttpResponse> linkHttpSend(
  HttpClient client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  Map<String, dynamic>? json,
  Duration timeout = linkRequestTimeout,
}) async {
  var expired = false;
  final request = await client
      .openUrl(method, uri)
      .then((request) {
        if (expired) request.abort();
        return request;
      })
      .timeout(
        timeout,
        onTimeout: () {
          expired = true;
          throw TimeoutException('The computer did not answer in time');
        },
      );
  final HttpClientResponse response;
  try {
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(request.headers.set);
    if (json != null) {
      final bytes = utf8.encode(jsonEncode(json));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    response = await request.close().timeout(timeout);
  } catch (_) {
    request.abort();
    rethrow;
  }
  return _readResponse(response, timeout);
}

/// Uploads [file] with `PUT` and reads the JSON answer. [onProgress] gets
/// the bytes sent so far. The upload may take as long as a slow network
/// needs for the file's size; [timeout] covers connecting and the answer.
Future<LinkHttpResponse> linkHttpUpload(
  HttpClient client,
  Uri uri,
  File file, {
  Map<String, String> headers = const {},
  void Function(int sent)? onProgress,
  Duration timeout = linkRequestTimeout,
}) async {
  final size = await file.length();
  final request = await client.openUrl('PUT', uri).timeout(timeout);
  final HttpClientResponse response;
  try {
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.binary;
    request.contentLength = size;
    var sent = 0;
    await request
        .addStream(
          file.openRead().map((chunk) {
            sent += chunk.length;
            onProgress?.call(sent);
            return chunk;
          }),
        )
        // At least 256 KiB a second, so a stalled network ends the upload.
        .timeout(timeout + Duration(seconds: size ~/ (256 * 1024)));
    response = await request.close().timeout(timeout);
  } catch (_) {
    request.abort();
    rethrow;
  }
  return _readResponse(response, timeout);
}

Future<LinkHttpResponse> _readResponse(
  HttpClientResponse response,
  Duration timeout,
) async {
  final certificate = response.certificate;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(timeout)) {
    if (bytes.length + chunk.length > _maxBodyBytes) {
      throw const HttpException('The computer sent too much data');
    }
    bytes.add(chunk);
  }
  Object? body;
  if (bytes.isNotEmpty) {
    try {
      body = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      body = null;
    }
  }
  return LinkHttpResponse(
    statusCode: response.statusCode,
    body: body,
    certificateFingerprint: certificate == null
        ? null
        : linkCertificateFingerprint(certificate),
  );
}

/// The [LinkException] for a failed response: the body's
/// `{"error","message"}` when present, else a code from the status.
LinkException linkResponseException(LinkHttpResponse response) {
  final body = response.body;
  if (body is Map && body['error'] is String) {
    final message = body['message'];
    return LinkException(
      body['error'] as String,
      message is String ? message : '',
    );
  }
  final status = response.statusCode;
  return LinkException(switch (status) {
    400 => LinkClientErrors.invalid,
    401 => LinkClientErrors.unauthorized,
    404 => 'not_found',
    503 => LinkClientErrors.unavailable,
    504 => LinkClientErrors.timeout,
    _ => 'http_$status',
  }, 'HTTP $status');
}

/// The [LinkException] for a transport failure. Messages stay generic, so no
/// address or credential leaks into logs or the UI.
LinkException linkTransportException(Object error) => switch (error) {
  LinkException() => error,
  TimeoutException() => const LinkException(
    LinkClientErrors.timeout,
    'The computer did not answer in time',
  ),
  LocalNetworkPermissionException() => const LinkException(
    LinkClientErrors.localNetworkPermission,
    'Local network access is not allowed',
  ),
  TlsException() => const LinkException(
    LinkClientErrors.certificate,
    'The computer presented another certificate',
  ),
  WebSocketException(httpStatusCode: 401) => const LinkException(
    LinkClientErrors.unauthorized,
    'The computer no longer accepts this phone',
  ),
  _ => const LinkException(
    LinkClientErrors.unavailable,
    'The computer could not be reached',
  ),
};
