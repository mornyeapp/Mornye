import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_storage_error.dart';

void main() {
  test('network diagnostics separate transport, login and share failures', () {
    final cases = <Object, NetworkStorageError>{
      const SocketException('private host'): NetworkStorageError.unreachable,
      const LocalNetworkPermissionException():
          NetworkStorageError.localNetworkPermission,
      TimeoutException('private host'): NetworkStorageError.timeout,
      const Smb2Exception('STATUS_LOGON_FAILURE'):
          NetworkStorageError.authentication,
      const Smb2Exception(
        'private share',
        errno: 13,
        type: Smb2ErrorType.accessDenied,
      ): NetworkStorageError.permission,
      const Smb2Exception('STATUS_BAD_NETWORK_NAME'):
          NetworkStorageError.missingShare,
      const Smb2Exception('Server does not support SMB2'):
          NetworkStorageError.incompatible,
      const Smb2Exception('private host', type: Smb2ErrorType.connection):
          NetworkStorageError.unreachable,
      const Smb2Exception(
        'private host',
        errno: 60,
        type: Smb2ErrorType.timeout,
      ): NetworkStorageError.timeout,
      const FormatException('private URL'): NetworkStorageError.invalidAddress,
      const HttpException('Server returned 401'):
          NetworkStorageError.authentication,
      const HttpException('Server returned 403'):
          NetworkStorageError.permission,
      StateError('unknown'): NetworkStorageError.unknown,
      const Smb2Exception(
        'Worker failed to start: Connect failed: socket connect failed',
      ): NetworkStorageError.unreachable,
      const Smb2Exception('Worker failed to start: Timeout expired'):
          NetworkStorageError.timeout,
      const Smb2Exception('SMB2_STATUS_PASSWORD_EXPIRED'):
          NetworkStorageError.authentication,
    };
    for (final entry in cases.entries) {
      expect(classifyNetworkStorageError(entry.key), entry.value);
    }
  });
}
