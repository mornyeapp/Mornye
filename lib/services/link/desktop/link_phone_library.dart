import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneLibrary');

/// Where paired phones' songs meet the desktop's Library: one
/// `network://<sourceId>/` source per phone. Faked in tests.
abstract interface class LinkPhoneLibrary {
  /// Adds the source of [sourceId] named [name] and turns Local Library on.
  Future<void> add(String sourceId, String name);

  /// Rescans the source after any running scan; nothing when the owner
  /// removed it or turned it off.
  Future<void> rescan(String sourceId);

  /// Removes the source and its songs.
  Future<void> remove(String sourceId);

  /// The cover files the rows of [sourceId] name now.
  Future<Set<String>> coverPaths(String sourceId);
}

class LinkPhoneLibraryBridge implements LinkPhoneLibrary {
  LinkPhoneLibraryBridge(this._ref, {LibraryDatabase? database})
    : _database = database ?? LibraryDatabase.instance {
    _ref.onDispose(() {
      _scanWatch?.close();
      _pendingScans.clear();
    });
  }

  final Ref _ref;
  final LibraryDatabase _database;
  final _pendingScans = <String>{};
  ProviderSubscription<bool>? _scanWatch;

  static String _rootSource(String sourceId) =>
      NetworkStorageService.source(sourceId, '');

  @override
  Future<void> add(String sourceId, String name) async {
    await _ref
        .read(localLibraryProvider.notifier)
        .addSource(path: _rootSource(sourceId), displayName: name);
    if (!_ref.mounted) return;
    _ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
  }

  @override
  Future<void> rescan(String sourceId) async {
    final source = await _database.getSourceByPath(_rootSource(sourceId));
    if (!_ref.mounted || source == null || !source.enabled) return;
    _scan(source.id);
  }

  void _scan(String librarySourceId) {
    if (!_ref.mounted) return;
    if (_ref.read(localLibraryProvider).isScanning) {
      // A request during another scan would be dropped; run it afterwards.
      _pendingScans.add(librarySourceId);
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
          .startSourceScan(
            librarySourceId,
            notify: false,
            waitForCurrentScan: true,
          )
          .catchError((Object error) => _log.w('Library scan failed: $error')),
    );
  }

  void _drainPending() {
    _scanWatch?.close();
    _scanWatch = null;
    final pending = _pendingScans.toList();
    _pendingScans.clear();
    unawaited(() async {
      if (!_ref.mounted) return;
      final library = _ref.read(localLibraryProvider.notifier);
      for (final librarySourceId in pending) {
        try {
          if (!_ref.mounted) return;
          await library.startSourceScan(
            librarySourceId,
            notify: false,
            waitForCurrentScan: true,
          );
        } catch (error) {
          _log.w('Library scan failed: $error');
        }
      }
    }());
  }

  @override
  Future<void> remove(String sourceId) async {
    final source = await _database.getSourceByPath(_rootSource(sourceId));
    if (source == null) return;
    _pendingScans.remove(source.id);
    await _ref.read(localLibraryProvider.notifier).removeSource(source.id);
  }

  @override
  Future<Set<String>> coverPaths(String sourceId) async {
    final source = await _database.getSourceByPath(_rootSource(sourceId));
    if (source == null) return const {};
    final rows = await (await _database.database).rawQuery(
      'SELECT DISTINCT cover_path FROM library '
      "WHERE source_id = ? AND COALESCE(cover_path, '') != ''",
      [source.id],
    );
    return {
      for (final row in rows)
        if (row['cover_path'] case final String path) path,
    };
  }
}

/// The desktop's Library as paired phones' songs use it.
final linkPhoneLibraryProvider = Provider<LinkPhoneLibrary>(
  LinkPhoneLibraryBridge.new,
);
