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
