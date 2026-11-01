import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/platform_bridge.dart';

/// The tracks a shared link names, and the playlist they came from.
typedef LinkResolvedLink = ({List<Track> tracks, String? playlistName});

/// What the link host needs from the download queue. [AppLinkDownloadsPort]
/// uses the app's queue and extensions; tests fake it.
abstract interface class LinkDownloadsPort {
  /// Resolves [url] the way a shared link is, without touching the Search
  /// page. Throws [LinkException] when no extension handles it.
  Future<LinkResolvedLink> resolveUrl(String url);

  /// Queues [tracks] with [service] (the default download service when
  /// null) and returns how many were queued. Throws [LinkException] when no
  /// download provider is installed.
  int enqueue(
    List<Track> tracks, {
    String? service,
    String? quality,
    String? playlistName,
  });
}

/// One queue item as `GET downloads` and `downloads.changed` report it.
Map<String, dynamic> linkDownloadSummary(DownloadItem item) => {
  'id': item.id,
  'title': item.track.name,
  'artist': item.track.artistName,
  'status': item.status.name,
  'progress': switch (item.status) {
    DownloadStatus.completed || DownloadStatus.finalizing => 1.0,
    DownloadStatus.queued => 0.0,
    _ => item.progress.clamp(0.0, 1.0),
  },
};

/// The download queue as `GET downloads` reports it: the newest
/// [maxItems] items.
Map<String, dynamic> linkDownloadsPayload(
  List<DownloadItem> items, {
  int maxItems = 200,
}) => {
  'items': [
    for (final item in items.skip(
      items.length > maxItems ? items.length - maxItems : 0,
    ))
      linkDownloadSummary(item),
  ],
};

/// Negotiated queue updates, with a full snapshot for older phones and each
/// new subscription. Only the newest send request waits behind an active send.
class LinkDownloadUpdates {
  LinkDownloadUpdates({
    required List<DownloadItem> Function() items,
    required Future<int> Function(Map<String, dynamic>, String) send,
  }) : _items = items,
       _send = send;

  final List<DownloadItem> Function() _items;
  final Future<int> Function(Map<String, dynamic>, String) _send;
  final _peers = <String, _DownloadPeer>{};
  Future<void>? _sending;
  bool _pending = false;
  bool _updatesPending = false;
  bool _disposed = false;

  void keepConnected(List<LinkClientInfo> clients) {
    final ids = {for (final client in clients) client.deviceId};
    _peers.removeWhere((id, _) => !ids.contains(id));
    for (final client in clients) {
      if (_peers[client.deviceId]?.connectedMs != client.connectedMs) {
        _peers[client.deviceId] = _DownloadPeer(client.connectedMs);
      }
    }
  }

  bool subscribe(String deviceId, Object? version) {
    final peer = _peers[deviceId];
    if (_disposed || peer == null || version != 1) return false;
    peer.deltas = true;
    peer.full = true;
    return true;
  }

  Future<void> publish({bool snapshotsOnly = false}) {
    if (_disposed) return Future.value();
    _pending = true;
    _updatesPending |= !snapshotsOnly;
    return _sending ??= _drain().whenComplete(() {
      _sending = null;
      if (_pending && !_disposed) return publish(snapshotsOnly: true);
    });
  }

  Future<void> _drain() async {
    while (_pending && !_disposed) {
      _pending = false;
      final updates = _updatesPending;
      _updatesPending = false;
      if (_peers.isEmpty) continue;
      final items = (linkDownloadsPayload(_items())['items'] as List)
          .cast<Map<String, dynamic>>();
      for (final MapEntry(key: id, value: peer) in Map.of(_peers).entries) {
        if (_disposed) return;
        if (_peers[id] != peer) continue;
        if (!updates && !peer.full) continue;
        final before = peer.items;
        final delta = before == null ? null : _delta(before, items);
        if (!peer.full && before != null && delta == null) continue;
        final message = peer.deltas && !peer.full && before != null
            ? {'type': LinkMessageTypes.downloadsDelta, ...delta!}
            : {'type': LinkMessageTypes.downloadsChanged, 'items': items};
        peer.full = false;
        var sent = 0;
        try {
          sent = await _send(message, id);
        } catch (_) {
          // The next successful send must establish a complete baseline.
        }
        if (_peers[id] == peer) peer.items = sent > 0 ? items : null;
      }
    }
  }

  static Map<String, dynamic>? _delta(
    List<Map<String, dynamic>> before,
    List<Map<String, dynamic>> items,
  ) {
    final old = {for (final item in before) item['id']: item};
    final ids = [for (final item in items) item['id'] as String];
    final changed = [
      for (final item in items)
        if (!mapEquals(old[item['id']], item)) item,
    ];
    final removed = [
      for (final id in old.keys)
        if (!ids.contains(id)) id,
    ];
    final orderChanged = !listEquals(old.keys.toList(), ids);
    if (changed.isEmpty && removed.isEmpty && !orderChanged) return null;
    return {
      'items': changed,
      'removed': removed,
      if (orderChanged) 'order': ids,
    };
  }

  void dispose() {
    _disposed = true;
    _pending = false;
    _updatesPending = false;
    _peers.clear();
  }
}

class _DownloadPeer {
  _DownloadPeer(this.connectedMs);

  final int connectedMs;
  bool deltas = false;
  bool full = true;
  List<Map<String, dynamic>>? items;
}

class AppLinkDownloadsPort implements LinkDownloadsPort {
  AppLinkDownloadsPort(this._ref);

  static const _extensionWait = Duration(seconds: 10);

  final Ref _ref;

  @override
  Future<LinkResolvedLink> resolveUrl(String url) async {
    var handler = await PlatformBridge.findURLHandler(url);
    if (handler == null) {
      final extensions = _ref.read(extensionProvider);
      if (!extensions.isInitialized && extensions.isLoading) {
        await _ref
            .read(extensionProvider.notifier)
            .waitForInitialization(timeout: _extensionWait);
        handler = await PlatformBridge.findURLHandler(url);
      }
    }
    if (handler == null) {
      throw const LinkException('invalid', 'url_not_recognized');
    }
    final result = await PlatformBridge.handleURLWithExtension(url);
    final type = result?['type'] as String?;
    final extensionId = result?['extension_id'] as String?;
    if (type == 'track' && result?['track'] is Map) {
      final track = Track.fromBackendMap(
        Map<String, dynamic>.from(result!['track'] as Map),
        source: extensionId,
      );
      if (track.name.isEmpty) {
        throw const LinkException('not_found', 'The link has no track');
      }
      return (tracks: [track], playlistName: null);
    }
    if ((type == 'album' || type == 'playlist') && result?['tracks'] is List) {
      final name = result!['name'] as String?;
      final playlistName = type == 'playlist' ? name : null;
      return (
        tracks: [
          for (final track in result['tracks'] as List)
            if (track is Map)
              Track.fromBackendMap(
                Map<String, dynamic>.from(track),
                source: extensionId,
                playlistName: playlistName,
              ),
        ],
        playlistName: playlistName,
      );
    }
    throw LinkException('invalid', 'Links to a ${type ?? 'page'} not queued');
  }

  @override
  int enqueue(
    List<Track> tracks, {
    String? service,
    String? quality,
    String? playlistName,
  }) {
    if (tracks.isEmpty) return 0;
    final resolved = service?.trim().isNotEmpty == true
        ? service!.trim()
        : resolveEffectiveDownloadService(
            _ref.read(settingsProvider).defaultService,
            _ref.read(extensionProvider),
          );
    if (resolved.isEmpty) {
      throw const LinkException('unavailable', 'No download provider');
    }
    final queue = _ref.read(downloadQueueProvider.notifier);
    if (tracks.length == 1) {
      queue.addToQueue(
        tracks.single,
        resolved,
        qualityOverride: quality,
        playlistName: playlistName,
      );
    } else {
      queue.addMultipleToQueue(
        tracks,
        resolved,
        qualityOverride: quality,
        playlistName: playlistName,
      );
    }
    return tracks.length;
  }
}

/// The download queue the link host feeds. Tests override it.
final linkDesktopDownloadsProvider = Provider<LinkDownloadsPort>(
  AppLinkDownloadsPort.new,
);

/// The download queue items, for `GET downloads` and `downloads.changed`.
final linkDownloadItemsProvider = Provider<List<DownloadItem>>(
  (ref) => ref.watch(downloadQueueProvider.select((state) => state.items)),
);
