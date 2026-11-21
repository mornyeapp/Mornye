import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';

/// Resolves a link through the extension that handles it, the way a pasted
/// link is resolved, without any UI state.
abstract final class ExtensionLinkResolver {
  static const attempts = 3;
  static const retryDelay = Duration(milliseconds: 500);

  /// Whether [result] names a track with a title, a collection or an artist.
  static bool isComplete(Map<String, dynamic>? result) =>
      switch (result?['type']) {
        'track' => switch (result?['track']) {
          final Map<Object?, Object?> track =>
            track['name']?.toString().isNotEmpty ?? false,
          _ => false,
        },
        'album' || 'playlist' || 'artist' => true,
        _ => false,
      };

  /// The extension's answer for [url], asked again after [retryDelay] while
  /// it is incomplete, at most [attempts] times. Null once [isActive] fails.
  static Future<Map<String, dynamic>?> handle(
    String url, {
    bool Function()? isActive,
  }) async {
    Map<String, dynamic>? result;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      result = await PlatformBridge.handleURLWithExtension(url);
      if (isActive?.call() == false) return null;
      if (isComplete(result)) break;
      if (attempt < attempts) {
        await Future<void>.delayed(retryDelay);
        if (isActive?.call() == false) return null;
      }
    }
    return result;
  }

  /// The tracks [result] names in order: one track, or the tracks of an
  /// album or a playlist. Empty for anything else.
  static List<Track> tracksOf(Map<String, dynamic>? result) {
    final extensionId = result?['extension_id'] as String?;
    final type = result?['type'];
    if (type == 'track' && result?['track'] is Map) {
      final track = Track.fromBackendMap(
        Map<String, dynamic>.from(result!['track'] as Map),
        source: extensionId,
      );
      return track.name.isEmpty ? const [] : [track];
    }
    if ((type == 'album' || type == 'playlist') && result?['tracks'] is List) {
      final playlistName = type == 'playlist'
          ? result!['name'] as String?
          : null;
      return [
        for (final track in result!['tracks'] as List)
          if (track is Map)
            Track.fromBackendMap(
              Map<String, dynamic>.from(track),
              source: extensionId,
              playlistName: playlistName,
            ),
      ];
    }
    return const [];
  }

  /// The tracks [url] names, or null when no installed extension handles it.
  static Future<List<Track>?> resolveTracks(String url) async {
    if (await PlatformBridge.findURLHandler(url) == null) return null;
    return tracksOf(await handle(url));
  }
}
