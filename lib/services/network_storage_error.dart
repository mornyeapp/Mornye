import 'dart:async';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/network_storage_service.dart';

enum NetworkStorageError {
  unreachable,
  timeout,
  authentication,
  permission,
  localNetworkPermission,
  missingShare,
  incompatible,
  invalidAddress,
  certificate,
  serverApi,
  unknown,
}

/// Classify transport failures without exposing URLs, usernames or passwords.
NetworkStorageError classifyNetworkStorageError(Object error) {
  if (error is SubsonicException) {
    return switch (error.code) {
      40 || 44 => NetworkStorageError.authentication,
      20 || 30 || 41 || 42 || 43 => NetworkStorageError.serverApi,
      50 || 60 => NetworkStorageError.permission,
      70 => NetworkStorageError.missingShare,
      _ => NetworkStorageError.unknown,
    };
  }
  if (error is LocalNetworkPermissionException) {
    return NetworkStorageError.localNetworkPermission;
  }
  if (error is NetworkCertificateException || error is HandshakeException) {
    return NetworkStorageError.certificate;
  }
  if (error is TimeoutException) return NetworkStorageError.timeout;
  if (error is SocketException) return NetworkStorageError.unreachable;
  if (error is FormatException) return NetworkStorageError.invalidAddress;
  final message = switch (error) {
    Smb2Exception(:final message) => message,
    HttpException(:final message) => message,
    String value => value,
    _ => '',
  }.toLowerCase();
  if (message.contains('not compatible') ||
      message.contains('does not support smb') ||
      message.contains('invalid dialect') ||
      message.contains('status_not_supported') ||
      message.contains('no matching dialect')) {
    return NetworkStorageError.incompatible;
  }
  if (message.contains('logon failure') ||
      message.contains('logon_failure') ||
      message.contains('wrong_password') ||
      message.contains('password_must_change') ||
      message.contains('password_expired') ||
      message.contains('account_disabled') ||
      message == 'server returned 401') {
    return NetworkStorageError.authentication;
  }
  if (message.contains('access denied') || message == 'server returned 403') {
    return NetworkStorageError.permission;
  }
  if (message == 'server returned 404') return NetworkStorageError.missingShare;
  if (message.contains('bad_network_name')) {
    return NetworkStorageError.missingShare;
  }
  if (error is Smb2Exception) {
    // A worker-start failure can wrap the native exception as text. Recover
    // its transport classification before suggesting a credential change.
    final transportType = Smb2ErrorType.fromMessage(message);
    return switch (transportType == Smb2ErrorType.unknown
        ? error.type
        : transportType) {
      Smb2ErrorType.connection => NetworkStorageError.unreachable,
      Smb2ErrorType.timeout => NetworkStorageError.timeout,
      Smb2ErrorType.auth => NetworkStorageError.authentication,
      Smb2ErrorType.accessDenied => NetworkStorageError.permission,
      Smb2ErrorType.notFound ||
      Smb2ErrorType.notADirectory => NetworkStorageError.missingShare,
      Smb2ErrorType.invalidParam => NetworkStorageError.invalidAddress,
      _ => NetworkStorageError.unknown,
    };
  }
  return NetworkStorageError.unknown;
}
