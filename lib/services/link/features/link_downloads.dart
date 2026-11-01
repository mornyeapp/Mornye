import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';

/// One download in the desktop's queue (`GET downloads`,
/// `downloads.changed`).
class LinkDesktopDownload {
  const LinkDesktopDownload({
    required this.id,
    required this.title,
    required this.artist,
    required this.status,
    this.progress,
  });

  final String id;
  final String title;
  final String artist;

  /// The desktop's queue status, such as `queued`, `downloading`,
  /// `completed` or `failed`.
  final String status;

  /// 0 to 1, or null when the desktop does not know yet.
  final double? progress;

  bool get finished =>
      const {'completed', 'done', 'skipped', 'exists'}.contains(status);

  bool get failed => const {'failed', 'error'}.contains(status);

  static LinkDesktopDownload? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id == null) return null;
    final progress = json['progress'];
    return LinkDesktopDownload(
      id: id.toString(),
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      status: json['status']?.toString().toLowerCase() ?? '',
      progress: progress is num
          // Accept a percentage as well as a fraction.
          ? (progress > 1 ? progress / 100 : progress).toDouble().clamp(0, 1)
          : null,
    );
  }
}

/// The `items` of a `GET downloads` reply or `downloads.changed` message.
List<LinkDesktopDownload> linkParseDownloads(Object? json) {
  final items = json is Map ? json['items'] : null;
  if (items is! List) return const [];
  return [for (final item in items) ?LinkDesktopDownload.fromJson(item)];
}

/// Applies a negotiated update to the newest 200 queue entries. A malformed
/// update needs a fresh snapshot instead of leaving a partial queue visible.
List<LinkDesktopDownload>? linkApplyDownloadDelta(
  List<LinkDesktopDownload> before,
  Map<String, dynamic> message,
) {
  final items = message['items'];
  final removed = message['removed'];
  final order = message['order'];
  if (items is! List ||
      removed is! List ||
      items.length > 200 ||
      removed.length > 200 ||
      (order != null && (order is! List || order.length > 200))) {
    return null;
  }
  final byId = {for (final item in before) item.id: item};
  for (final id in removed) {
    if (id is! String) return null;
    byId.remove(id);
  }
  for (final value in items) {
    final item = LinkDesktopDownload.fromJson(value);
    if (item == null) return null;
    byId[item.id] = item;
  }
  if (byId.length > 200) return null;
  if (order == null) return byId.values.toList();
  final ordered = <LinkDesktopDownload>[];
  final seen = <String>{};
  for (final id in order as List) {
    if (id is! String || !seen.add(id)) return null;
    final item = byId[id];
    if (item == null) return null;
    ordered.add(item);
  }
  return ordered.length == byId.length ? ordered : null;
}

/// The `POST downloads` body that queues [tracks] on the desktop.
Map<String, dynamic> linkDownloadTracksBody(
  List<Track> tracks, {
  String? service,
  String? quality,
  String? playlistName,
}) => {
  'tracks': [for (final track in tracks) track.toJson()],
  if (service != null && service.isNotEmpty) 'service': service,
  if (quality != null && quality.isNotEmpty) 'quality': quality,
  if (playlistName != null && playlistName.isNotEmpty)
    'playlistName': playlistName,
};

/// The `POST downloads` body that lets the desktop resolve a whole link.
Map<String, dynamic> linkDownloadUrlBody(String url) => {'url': url.trim()};

/// Sends a `POST downloads` [body]; returns how many tracks the desktop
/// queued.
Future<int> linkQueueDesktopDownloads(
  LinkClientApi client,
  Map<String, dynamic> body,
) async {
  final reply = await client.post(LinkOps.downloads, body);
  final queued = reply is Map ? reply['queued'] : null;
  return queued is num ? queued.toInt() : 0;
}

/// Opens [url] in the desktop app (`POST open`).
Future<void> linkOpenOnDesktop(LinkClientApi client, String url) async {
  await client.post(LinkOps.open, {'url': url.trim()});
}
