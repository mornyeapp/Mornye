import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_codec.dart';
import 'package:mornye/utils/chunked_list.dart';

export 'package:mornye/services/download_queue_codec.dart'
    show downloadQueuePersistenceStatus, encodeDownloadQueueItemForPersistence;

/// Owns durable queue snapshots, including corrupt-row cleanup and write order.
/// A failed write leaves the previous snapshot intact so a later flush retries.
class DownloadQueuePersistence {
  DownloadQueuePersistence({
    required this.currentItems,
    required this.onError,
    this.loadRows = _loadRows,
    this.applyChanges = _applyChanges,
  });

  final List<DownloadItem> Function() currentItems;
  final void Function(Object error) onError;
  final Future<List<Map<String, dynamic>>> Function() loadRows;
  final Future<void> Function({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  })
  applyChanges;
  static const _pausedKey = 'download_queue_user_paused_v1';
  Timer? _debounce;
  List<DownloadItem>? _pendingItems;
  Future<void> _write = Future<void>.value();
  Future<void> _pauseWrite = Future<void>.value();
  Map<String, DownloadQueueSavedItem> _saved = {};
  List<DownloadItem>? _savedSnapshot;

  static Future<List<Map<String, dynamic>>> _loadRows() async {
    final database = AppStateDatabase.instance;
    await database.migrateQueueFromSharedPreferences();
    return database.getPendingDownloadQueueRows();
  }

  static Future<void> _applyChanges({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  }) => AppStateDatabase.instance.applyPendingDownloadQueueChanges(
    upserts: upserts,
    deletedIds: deletedIds,
  );

  Future<bool> loadUserPaused() async =>
      (await SharedPreferences.getInstance()).getBool(_pausedKey) == true;

  void setUserPaused(bool paused) {
    _pauseWrite = _pauseWrite
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (paused) {
            await prefs.setBool(_pausedKey, true);
          } else {
            await prefs.remove(_pausedKey);
          }
        })
        .catchError(onError);
  }

  Future<List<DownloadItem>> restore() {
    final restored = _write.then((_) async {
      _savedSnapshot = null;
      final decoded = await decodeDownloadQueueRows(await loadRows());
      _saved = decoded.saved;
      return decoded.items;
    });
    // Serialize restore with durable writes because decoding can yield to a
    // worker. Its error reaches the caller without preventing later retries.
    _write = restored.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return restored;
  }

  void schedule() {
    _debounce?.cancel();
    _pendingItems = currentItems();
    _debounce = Timer(const Duration(milliseconds: 350), flush);
  }

  Future<void> flush({bool requireDurable = false}) async {
    _debounce?.cancel();
    _debounce = null;
    _pendingItems = null;
    await _enqueue(currentItems(), requireDurable: requireDurable);
    await _pauseWrite;
  }

  void dispose() {
    final pending = _pendingItems;
    if (pending != null) unawaited(_enqueue(pending));
    _debounce?.cancel();
    _debounce = null;
    _pendingItems = null;
  }

  Future<void> _enqueue(
    List<DownloadItem> items, {
    bool requireDurable = false,
  }) {
    final write = _write.then((_) async {
      // Queue states use immutable storage. Repeated lifecycle/debounce
      // flushes of an already committed snapshot need no diff or encoding.
      if (identical(items, _savedSnapshot)) return;
      final seenIds = <String>{};
      final savedUpdates = <String, DownloadQueueSavedItem>{};
      final upserts = <Map<String, dynamic>>[];
      final now = DateTime.now().toIso8601String();
      final changed = <DownloadItem>[];
      for (final item in items) {
        if (item.status == DownloadStatus.completed ||
            (item.status == DownloadStatus.failed &&
                item.errorType != DownloadErrorType.verificationRequired)) {
          continue;
        }
        final saved = _saved[item.id];
        final cached = identical(saved?.item, item) && saved?.payload != null;
        seenIds.add(item.id);
        if (!cached) {
          savedUpdates[item.id] = (item: item, payload: null);
          changed.add(item);
        } else if (savedUpdates.containsKey(item.id)) {
          // Preserve the last non-terminal occurrence for malformed input
          // with repeated request IDs, just as the full snapshot did.
          savedUpdates[item.id] = saved!;
        }
      }
      final encoded = await encodeDownloadQueueItems(changed);
      for (var index = 0; index < changed.length; index++) {
        final item = changed[index];
        final saved = _saved[item.id];
        final payload = encoded[index];
        if (identical(savedUpdates[item.id]?.item, item)) {
          savedUpdates[item.id] = (item: item, payload: payload);
        }
        if (saved?.payload == payload) continue;
        upserts.add({
          'id': item.id,
          'item_json': payload,
          'status': downloadQueuePersistenceStatus(
            item.status,
            errorType: item.errorType,
          ).name,
          'created_at': item.createdAt.toIso8601String(),
          'updated_at': now,
        });
      }
      final deletedIds = _saved.keys
          .where((id) => !seenIds.contains(id))
          .toList(growable: false);
      if (upserts.isNotEmpty || deletedIds.isNotEmpty) {
        await applyChanges(upserts: upserts, deletedIds: deletedIds);
      }
      // Keep the last durable cache intact until the complete write has
      // succeeded, so failed changes are still retried by the next flush.
      for (final id in deletedIds) {
        _saved.remove(id);
      }
      _saved.addAll(savedUpdates);
      // Callers outside the notifier may supply a mutable List. Its
      // identity alone never proves that its contents stayed unchanged.
      _savedSnapshot = items is ChunkedList<DownloadItem> ? items : null;
    });
    // The writer stays usable after failure, but external-app handoffs must
    // know whether their snapshot actually reached disk before opening a URL.
    _write = write.catchError(onError);
    return requireDurable ? write : _write;
  }
}
