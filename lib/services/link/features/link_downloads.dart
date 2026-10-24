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
