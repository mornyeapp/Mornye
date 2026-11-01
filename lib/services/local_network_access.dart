import 'dart:io';

import 'package:flutter/services.dart';

class LocalNetworkPermissionException implements Exception {
  const LocalNetworkPermissionException();

  @override
  String toString() => 'Local network permission is required';
}

/// Android 17 gates LAN sockets, including SMB and local WebDAV/HTTP servers.
class LocalNetworkAccess {
  LocalNetworkAccess({
    bool? isAndroid,
    MethodChannel channel = const MethodChannel(
      'com.zarz.mornye/local_network',
    ),
    Future<List<InternetAddress>> Function(String)? lookup,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _channel = channel,
       _lookup = lookup ?? InternetAddress.lookup;

  static final instance = LocalNetworkAccess();
  final bool _isAndroid;
  final MethodChannel _channel;
  final Future<List<InternetAddress>> Function(String) _lookup;
  Future<void>? _pending;
  Future<bool>? _checking;

  Future<void> ensureAccess(Uri target) async {
    if (!_isAndroid) return;
    // Also returns true on older Android releases. Recheck after revocation.
    if (await isGranted()) return;
    if (!await _isLocalTarget(target)) return;
    await (_pending ??= _request().whenComplete(() => _pending = null));
  }

  /// For settings that open LAN access before any target is known, such as
  /// extension requests to a local media server.
  Future<void> ensureGranted() async {
    if (await isGranted()) return;
    await (_pending ??= _request().whenComplete(() => _pending = null));
  }

  /// Whether LAN access is allowed. Always true off Android and before
  /// Android 17, which have no such permission.
  Future<bool> isGranted() {
    if (!_isAndroid) return Future.value(true);
    return _checking ??= _channel
        .invokeMethod<bool>('isGranted')
        .then((value) => value == true)
        .whenComplete(() => _checking = null);
  }

  Future<void> _request() async {
    if (await _channel.invokeMethod<bool>('request') != true) {
      throw const LocalNetworkPermissionException();
    }
  }

  Future<bool> _isLocalTarget(Uri target) async {
    final host = target.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final address = InternetAddress.tryParse(host.split('%').first);
    if (address != null) return _isLocalAddress(address);
    if (host == 'localhost' || host.endsWith('.localhost')) return false;
    // mDNS itself needs permission, so do not resolve .local first.
    if (!host.contains('.') ||
        host.endsWith('.local') ||
        host == 'home.arpa' ||
        host.endsWith('.home.arpa')) {
      return true;
    }
    // A public DNS name can still point at a NAS on the local network.
    return (await _lookup(
      host,
    ).timeout(const Duration(seconds: 5))).any(_isLocalAddress);
  }

  static bool _isLocalAddress(InternetAddress address) {
    if (address.isLoopback) return false;
    if (address.isLinkLocal) return true;
    var bytes = address.rawAddress;
    if (bytes.length == 16) {
      if (bytes.take(10).every((byte) => byte == 0) &&
          bytes[10] == 255 &&
          bytes[11] == 255) {
        bytes = bytes.sublist(12);
      } else {
        return bytes[0] & 0xfe == 0xfc;
      }
    }
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
  }
}
