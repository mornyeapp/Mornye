import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkLibrary');

/// Where a paired desktop meets the existing network storage and Library:
/// its Subsonic connection and its Library source. Faked in tests.
abstract interface class LinkLibraryBridge {
  Future<NetworkConnection?> connection(String connectionId);

  Future<void> saveConnection(NetworkConnection connection);

  /// Points the connection at the desktop's new `https://host:port`.
  Future<void> updateAddress(String connectionId, String address);

  /// Whether the session reaches the desktop; its songs fail quickly while
  /// it does not.
  void setReachable(String connectionId, {required bool reachable});

  /// Adds the connection's root to Library and scans it, as the network
  /// storage screen does after adding a Subsonic server.
  Future<void> addLibrarySource(NetworkConnection connection);

  /// Rescans the connection's Library source incrementally, after any
  /// running scan.
  Future<void> rescan(String connectionId);

  /// Removes the Library source and the saved connection.
  Future<void> removeConnection(String connectionId);
}

class LinkNetworkLibraryBridge implements LinkLibraryBridge {
  LinkNetworkLibraryBridge(
    this._ref, {
    NetworkStorageService? storage,
    LibraryDatabase? database,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _database = database ?? LibraryDatabase.instance;

  final Ref _ref;
  final NetworkStorageService _storage;
  final LibraryDatabase _database;
  final _pendingScans = <String>{};
  ProviderSubscription<bool>? _scanWatch;

  static String _rootSource(String connectionId) =>
      NetworkStorageService.source(connectionId, '');

  @override
  Future<NetworkConnection?> connection(String connectionId) async {
    try {
      return await _storage.connection(connectionId);
    } on StateError {
      return null;
    }
  }

  @override
  Future<void> saveConnection(NetworkConnection connection) =>
      _storage.save(connection);

  @override
  Future<void> updateAddress(String connectionId, String address) async {
    final current = await connection(connectionId);
    if (current == null || current.address == address) return;
    await _storage.save(
      NetworkConnection(
        id: current.id,
        name: current.name,
        protocol: current.protocol,
        address: address,
        username: current.username,
        password: current.password,
        domain: current.domain,
        trustedCertificateSha256: current.trustedCertificateSha256,
        subsonicAuth: current.subsonicAuth,
        apiKey: current.apiKey,
      ),
    );
  }

  @override
  void setReachable(String connectionId, {required bool reachable}) =>
      _storage.setReachable(connectionId, reachable: reachable);

  @override
  Future<void> addLibrarySource(NetworkConnection connection) async {
    final source = await _ref
        .read(localLibraryProvider.notifier)
        .addSource(
          path: _rootSource(connection.id),
          displayName: connection.name,
        );
    _ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
    _scan(source.id);
  }

  @override
  Future<void> rescan(String connectionId) async {
    final source = await _database.getSourceByPath(_rootSource(connectionId));
    if (source == null || !source.enabled) return;
    _scan(source.id);
  }

  void _scan(String sourceId) {
    if (_ref.read(localLibraryProvider).isScanning) {
      // A request during another scan would be dropped; run it afterwards.
      _pendingScans.add(sourceId);
      _scanWatch ??= _ref.listen<bool>(
        localLibraryProvider.select((state) => state.isScanning),
        (_, scanning) {
          if (!scanning) _drainPending();
        },
      );
      return;
    }
    unawaited(
      _ref
          .read(localLibraryProvider.notifier)
          .startSourceScan(sourceId)
          .catchError((Object error) => _log.w('Library scan failed: $error')),
    );
  }

  void _drainPending() {
    _scanWatch?.close();
    _scanWatch = null;
    final pending = _pendingScans.toList();
    _pendingScans.clear();
    unawaited(() async {
      final library = _ref.read(localLibraryProvider.notifier);
      for (final sourceId in pending) {
        try {
          await library.startSourceScan(sourceId);
        } catch (error) {
          _log.w('Library scan failed: $error');
        }
      }
    }());
  }

  @override
  Future<void> removeConnection(String connectionId) async {
    final source = await _database.getSourceByPath(_rootSource(connectionId));
    if (source != null) {
      _pendingScans.remove(source.id);
      await _ref.read(localLibraryProvider.notifier).removeSource(source.id);
    }
    await _storage.remove(connectionId);
  }
}
