import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/listening_rewind_provider.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_collection_sync_store.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:mornye/services/link/sync/link_sync_protocol.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkSyncRunner');

/// Sync timing. Tests override [linkSyncSettingsProvider] with short delays.
class LinkSyncSettings {
  const LinkSyncSettings({
    this.localDebounce = const Duration(seconds: 5),
    this.messageDebounce = const Duration(milliseconds: 500),
    this.historyInterval = const Duration(minutes: 1),
    this.historyPeriod = const Duration(minutes: 10),
  });

  /// Quiet time after a local collection change before it is pushed.
  final Duration localDebounce;

  /// Coalesces bursts of `collections.changed` messages.
  final Duration messageDebounce;

  /// History runs with a collections sync at most this often.
  final Duration historyInterval;

  /// History also runs on its own this often while connected.
  final Duration historyPeriod;
}

final linkSyncSettingsProvider = Provider<LinkSyncSettings>(
  (ref) => const LinkSyncSettings(),
);

/// Writes buffered listening time before history is pushed.
final linkHistoryFlushProvider = Provider<Future<void> Function()>(
  (ref) => listeningRecorder.flush,
);

/// Reloads the statistics screens after peer listening was applied.
void refreshLinkListeningProviders(Ref ref) {
  ref.invalidate(listeningSummaryProvider);
  ref.invalidate(listeningRewindProvider);
  ref.invalidate(listeningRewindSpotlightProvider);
}

/// What the phone's sync is doing, for the Link UI.
class LinkSyncStatus {
  const LinkSyncStatus({
    this.serverId,
    this.syncing = false,
    this.lastSyncedMs,
    this.error,
  });

  /// The linked desktop, or null when none is paired.
  final String? serverId;
  final bool syncing;

  /// When the last sync with [serverId] finished, in Unix milliseconds.
  final int? lastSyncedMs;

  /// The last sync's failure, cleared by the next success.
  final String? error;

  LinkSyncStatus copyWith({
    bool? syncing,
    int? lastSyncedMs,
    String? Function()? error,
  }) => LinkSyncStatus(
    serverId: serverId,
    syncing: syncing ?? this.syncing,
    lastSyncedMs: lastSyncedMs ?? this.lastSyncedMs,
    error: error == null ? this.error : error(),
  );
}

class _SyncRequest {
  const _SyncRequest({
    this.collections = false,
    this.history = false,
    this.pull = false,
  });

  static const all = _SyncRequest(collections: true, history: true, pull: true);

  final bool collections;
  final bool history;

  /// Pull even when there is nothing local to push.
  final bool pull;

  _SyncRequest merge(_SyncRequest other) => _SyncRequest(
    collections: collections || other.collections,
    history: history || other.history,
    pull: pull || other.pull,
  );
}

String _prefsKey(String serverId, String name) => 'link_sync_${serverId}_$name';

/// Keeps the phone's collections and listening history in sync with the
/// linked desktop: on connect, when the desktop sends `collections.changed`,
/// after local collection edits (debounced), and on [syncNow]. Pull applies
/// the desktop's changes since the stored cursor by last writer wins, push
/// sends the changes the desktop did not author since this device's own
/// cursor, and a push that changed something tells the desktop with
/// `collections.changed`. Cursors per `serverId` live in SharedPreferences
/// (`link_sync_*`) and only advance after a page succeeded, so an
/// interrupted sync resumes safely; a replaced desktop database (new sync
/// id or lower sequence) restarts both directions from zero.
///
/// App-lifetime on phones: the app root keeps it alive.
class LinkSyncRunner extends Notifier<LinkSyncStatus> {
  LinkClientApi? _client;
  StreamSubscription<LinkConnectionState>? _states;
  StreamSubscription<Map<String, dynamic>>? _messages;
  Timer? _debounce;
  Timer? _historyTimer;
  _SyncRequest? _debounced;
  Future<void>? _running;
  _SyncRequest? _pending;
  DateTime? _lastHistory;

  @override
  LinkSyncStatus build() {
    ref.onDispose(_detach);
    ref.listen(linkActiveClientProvider, (_, client) => _attach(client));
    ref.listen(
      libraryCollectionsProvider,
      (_, _) => _schedule(
        const _SyncRequest(collections: true),
        ref.read(linkSyncSettingsProvider).localDebounce,
      ),
    );
    final client = ref.read(linkActiveClientProvider);
    _attach(client, building: true);
    return LinkSyncStatus(serverId: client?.server.serverId);
  }

  /// Syncs collections and history now; completes when done.
  Future<void> syncNow() => _run(_SyncRequest.all);

  void _attach(LinkClientApi? client, {bool building = false}) {
    if (identical(client, _client)) return;
    _detach();
    _client = client;
    if (!building) {
      state = LinkSyncStatus(serverId: client?.server.serverId);
    }
    if (client == null) return;
    _states = client.connectionStates.listen((connection) {
      if (connection == LinkConnectionState.connected) {
        _connected();
      } else {
        _debounce?.cancel();
        _historyTimer?.cancel();
      }
    });
    _messages = client.messages.listen((message) {
      if (message['type'] == LinkMessageTypes.collectionsChanged) {
        _schedule(
          const _SyncRequest(collections: true, pull: true),
          ref.read(linkSyncSettingsProvider).messageDebounce,
        );
      }
    });
    unawaited(_loadLastSynced(client));
    if (client.connectionState == LinkConnectionState.connected) {
      // Never change state while building; start after build returns.
      scheduleMicrotask(_connected);
    }
  }

  void _connected() {
    final client = _client;
    if (client == null || !ref.mounted) return;
    _historyTimer?.cancel();
    _historyTimer = Timer.periodic(
      ref.read(linkSyncSettingsProvider).historyPeriod,
      (_) => unawaited(_run(const _SyncRequest(history: true))),
    );
    unawaited(_run(_SyncRequest.all));
  }

  Future<void> _loadLastSynced(LinkClientApi client) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_prefsKey(client.server.serverId, 'last_ms'));
    if (last == null || !ref.mounted || !identical(client, _client)) return;
    state = state.copyWith(lastSyncedMs: last);
  }

  void _detach() {
    _debounce?.cancel();
    _historyTimer?.cancel();
    _debounced = null;
    unawaited(_states?.cancel());
    unawaited(_messages?.cancel());
    _states = null;
    _messages = null;
    _client = null;
  }

  void _schedule(_SyncRequest request, Duration delay) {
    if (_client == null) return;
    _debounced = _debounced?.merge(request) ?? request;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      final next = _debounced;
      _debounced = null;
      if (next != null) unawaited(_run(next));
    });
  }

  /// Runs [request] after the sync in progress, merging requests that
  /// arrive meanwhile.
  Future<void> _run(_SyncRequest request) {
    final running = _running;
    if (running != null) {
      _pending = _pending?.merge(request) ?? request;
      return running;
    }
    final done = () async {
      // The caller's synchronous code (and build) finishes first.
      await Future<void>.value();
      var next = request;
      try {
        while (true) {
          final client = _client;
          if (client != null) await _syncOnce(client, next);
          final pending = _pending;
          _pending = null;
          if (pending == null) break;
          next = pending;
        }
      } finally {
        // Cleared in the same turn as the last pending check, so a request
        // arriving later always starts a new run.
        _running = null;
      }
    }();
    _running = done;
    return done;
  }

  Future<void> _syncOnce(LinkClientApi client, _SyncRequest request) async {
    if (!ref.mounted ||
        client.connectionState != LinkConnectionState.connected) {
      return;
    }
    final serverId = client.server.serverId;
    try {
      final settings = ref.read(linkSyncSettingsProvider);
      final collections = ref.read(linkCollectionSyncStoreProvider);
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final lastHistory = _lastHistory;
      final collectionsDue =
          request.collections &&
          (request.pull ||
              await collections.latestLocalSeq() >
                  (prefs.getInt(_prefsKey(serverId, 'collections_push')) ?? 0));
      // History rides along with a collections sync at most once per
      // interval.
      final history =
          request.history ||
          (collectionsDue &&
              (lastHistory == null ||
                  now.difference(lastHistory) >= settings.historyInterval));
      if (!collectionsDue && !history) return;
      if (ref.mounted && identical(client, _client)) {
        state = state.copyWith(syncing: true);
      }
      var pushed = 0;
      if (collectionsDue) {
        pushed = await _syncCollections(client, collections, prefs);
      }
      if (history) {
        _lastHistory = now;
        await _syncHistory(client, prefs);
      }
      if (pushed > 0) {
        client.send({'type': LinkMessageTypes.collectionsChanged});
      }
      final finished = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt(_prefsKey(serverId, 'last_ms'), finished);
      if (ref.mounted && identical(client, _client)) {
        state = state.copyWith(
          syncing: false,
          lastSyncedMs: finished,
          error: () => null,
        );
      }
    } on Object catch (error) {
      _log.w('Link sync with $serverId failed: $error');
      if (ref.mounted && identical(client, _client)) {
        state = state.copyWith(syncing: false, error: () => error.toString());
      }
    }
  }

  /// Returns how many pushed changes the desktop applied.
  Future<int> _syncCollections(
    LinkClientApi client,
    LinkCollectionSyncStore store,
    SharedPreferences prefs,
  ) async {
    final device = await store.deviceId();
    final (applied, peer) = await _pull(
      client,
      prefs,
      name: 'collections',
      op: LinkOps.collections,
      device: device,
      listName: 'changes',
      decode: (item, origin) =>
          LinkSyncChange.fromJson(item, fallbackOrigin: origin),
      apply: (items) async => (await store.apply(items)).applied,
    );
    if (applied > 0 && ref.mounted) {
      await ref.read(libraryCollectionsProvider.notifier).reloadFromDatabase();
    }
    // Everything the desktop did not author, so changes from another
    // desktop and a replaced desktop database are offered too.
    return _push(
      client,
      prefs,
      name: 'collections',
      op: LinkOps.collections,
      device: device,
      listName: 'changes',
      read: (since) => store.changesSince(since, excludeOrigin: peer),
      latest: store.latestSeq,
      encode: (change) => change.toJson(),
    );
  }

  Future<void> _syncHistory(
    LinkClientApi client,
    SharedPreferences prefs,
  ) async {
    final store = ref.read(linkHistorySyncStoreProvider);
    final device = await store.deviceId();
    final (applied, peer) = await _pull(
      client,
      prefs,
      name: 'history',
      op: LinkOps.history,
      device: device,
      listName: 'events',
      decode: (item, origin) =>
          LinkHistoryEvent.fromJson(item, fallbackOrigin: origin),
      apply: (items) async => (await store.apply(items)).applied,
    );
    if (applied > 0 && ref.mounted) refreshLinkListeningProviders(ref);
    await ref.read(linkHistoryFlushProvider)();
    await _push(
      client,
      prefs,
      name: 'history',
      op: LinkOps.history,
      device: device,
      listName: 'events',
      read: (since) => store.eventsSince(since, excludeOrigin: peer),
      latest: store.latestSeq,
      encode: (event) => event.toJson(),
    );
  }

  /// Returns how many changes applied and the desktop's sync device id.
  Future<(int, String)> _pull<T>(
    LinkClientApi client,
    SharedPreferences prefs, {
    required String name,
    required String op,
    required String device,
    required String listName,
    required T? Function(Object? item, String origin) decode,
    required Future<int> Function(List<T> items) apply,
  }) async {
    final serverId = client.server.serverId;
    final cursorKey = _prefsKey(serverId, '${name}_pull');
    final peerKey = _prefsKey(serverId, '${name}_peer');
    var since = prefs.getInt(cursorKey) ?? 0;
    var applied = 0;
    while (true) {
      final reply = await client.get(op, {
        'since': '$since',
        'device': device,
        'limit': '$linkSyncPageSize',
      });
      final page = LinkSyncPage.fromJson<T>(reply, listName, decode);
      if (page == null) {
        throw const LinkException('invalid', 'Malformed sync page');
      }
      if (prefs.getString(peerKey) != page.device || since > page.latest) {
        // A new or replaced desktop database: exchange everything again.
        await prefs.setString(peerKey, page.device);
        await prefs.setInt(_prefsKey(serverId, '${name}_push'), 0);
        if (since > 0) {
          since = 0;
          await prefs.setInt(cursorKey, 0);
          continue;
        }
      }
      applied += await apply(page.items);
      if (page.more && page.cursor <= since) {
        throw const LinkException('invalid', 'Sync cursor did not advance');
      }
      since = page.cursor;
      await prefs.setInt(cursorKey, since);
      if (!page.more) return (applied, page.device);
    }
  }

  Future<int> _push<T>(
    LinkClientApi client,
    SharedPreferences prefs, {
    required String name,
    required String op,
    required String device,
    required String listName,
    required Future<LinkSyncPage<T>> Function(int since) read,
    required Future<int> Function() latest,
    required Map<String, dynamic> Function(T item) encode,
  }) async {
    final cursorKey = _prefsKey(client.server.serverId, '${name}_push');
    var since = prefs.getInt(cursorKey) ?? 0;
    // This device's database was replaced: offer everything again.
    if (since > await latest()) since = 0;
    var applied = 0;
    while (true) {
      final page = await read(since);
      if (page.items.isNotEmpty) {
        final reply = await client.post(op, {
          'device': device,
          listName: [for (final item in page.items) encode(item)],
        });
        applied += linkSyncInt(reply is Map ? reply['applied'] : null) ?? 0;
      }
      since = page.cursor;
      await prefs.setInt(cursorKey, since);
      if (!page.more) return applied;
    }
  }
}

final linkSyncRunnerProvider = NotifierProvider<LinkSyncRunner, LinkSyncStatus>(
  LinkSyncRunner.new,
);
