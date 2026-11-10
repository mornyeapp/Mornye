import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/utils/logger.dart';

typedef TrackCanvasRequest = ({
  String id,
  String title,
  String artist,
  String album,
  String? source,
  String? spotifyId,
  String? canvasUrl,
});

/// Resolves looping vertical video canvases (Spotify Canvas & Apple Music Motion).
class SpotifyCanvasService {
  SpotifyCanvasService({MotionArtworkStore? store, http.Client? client})
    : _store = store ?? MotionArtworkStore(),
      _client = client ?? http.Client();

  static final instance = SpotifyCanvasService();

  final MotionArtworkStore _store;
  final http.Client _client;
  static final _log = AppLogger('SpotifyCanvas');

  /// Canvas endpoints to try in priority order.
  static const _canvasEndpoints = [
    'https://spotify-canvas.vercel.app/api/canvas?trackId=',
    'https://sp-canvas.vercel.app/api/canvas?trackId=',
    'https://canvaz.deno.dev/',
  ];

  String _trackKey(String title, String artist) {
    String normalize(String v) =>
        v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return sha256
        .convert(utf8.encode(jsonEncode([normalize(title), normalize(artist)])))
        .toString();
  }

  /// Resolves a Canvas video for the given track.
  Future<MotionArtwork?> resolveCanvas(TrackCanvasRequest request) async {
    // 1. Direct canvas URL from metadata/extras
    final directUrl = request.canvasUrl?.trim();
    if (directUrl != null && directUrl.isNotEmpty) {
      return MotionArtwork(directUrl, aspectRatio: 9 / 16);
    }

    // 2. Local sidecar video file (e.g. track.canvas.mp4, track.mp4)
    final localSidecar = await _findLocalSidecar(request.source);
    if (localSidecar != null) {
      return localSidecar;
    }

    // 3. Cached track canvas in MotionArtworkStore
    final cached = await _findCachedTrackCanvas(request.title, request.artist);
    if (cached != null) {
      return cached;
    }

    // 4. Remote Spotify Canvas resolution via Spotify ID
    final spotifyId = request.spotifyId?.trim();
    if (spotifyId != null && spotifyId.isNotEmpty) {
      final remote = await _fetchAndCacheRemoteCanvas(
        spotifyId: spotifyId,
        title: request.title,
        artist: request.artist,
      );
      if (remote != null) return remote;
    }

    // 5. Fallback to album motion artwork from Apple Music / metadata store
    if (request.album.trim().isNotEmpty && request.artist.trim().isNotEmpty) {
      return _store.find((album: request.album, artist: request.artist));
    }

    return null;
  }

  Future<MotionArtwork?> _findLocalSidecar(String? source) async {
    if (source == null || source.isEmpty) return null;
    final path = source.startsWith('file://')
        ? Uri.parse(source).toFilePath()
        : source;
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('content://')) {
      return null;
    }

    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final parent = file.parent;
      final basename = file.uri.pathSegments.last;
      final dot = basename.lastIndexOf('.');
      final nameWithoutExt = dot > 0 ? basename.substring(0, dot) : basename;

      final candidates = [
        File('${parent.path}/$nameWithoutExt.canvas.mp4'),
        File('${parent.path}/$nameWithoutExt-canvas.mp4'),
        File('${parent.path}/$nameWithoutExt.mp4'),
        File('${parent.path}/canvas.mp4'),
      ];

      for (final candidate in candidates) {
        if (await candidate.exists() && await candidate.length() > 0) {
          return MotionArtwork(candidate.uri.toString(), aspectRatio: 9 / 16);
        }
      }
    } catch (e) {
      _log.w('Error checking local canvas sidecar: $e');
    }
    return null;
  }

  Future<MotionArtwork?> _findCachedTrackCanvas(
    String title,
    String artist,
  ) async {
    if (title.trim().isEmpty || artist.trim().isEmpty) return null;
    try {
      final dir = await MotionArtworkStore.defaultDirectory();
      final key = 'canvas_${_trackKey(title, artist)}';
      final file = File('${dir.path}/$key.mp4');
      if (await file.exists() && await file.length() > 0) {
        return MotionArtwork(file.uri.toString(), aspectRatio: 9 / 16);
      }
    } catch (_) {}
    return null;
  }

  Future<MotionArtwork?> _fetchAndCacheRemoteCanvas({
    required String spotifyId,
    required String title,
    required String artist,
  }) async {
    for (final base in _canvasEndpoints) {
      try {
        final uri = Uri.parse('$base$spotifyId');
        final response = await _client
            .get(uri)
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          String? canvasUrl;
          if (data is Map) {
            canvasUrl =
                data['canvas_url']?.toString() ??
                data['canvasUrl']?.toString() ??
                data['url']?.toString() ??
                data['video_url']?.toString();
          }
          if (canvasUrl != null && canvasUrl.trim().startsWith('http')) {
            final remoteUrl = canvasUrl.trim();
            try {
              final dir = await MotionArtworkStore.defaultDirectory();
              final key = 'canvas_${_trackKey(title, artist)}';
              final cacheFile = File('${dir.path}/$key.mp4');
              final videoResp = await _client
                  .get(Uri.parse(remoteUrl))
                  .timeout(const Duration(seconds: 8));
              if (videoResp.statusCode == 200 &&
                  videoResp.bodyBytes.isNotEmpty) {
                await cacheFile.writeAsBytes(videoResp.bodyBytes);
                return MotionArtwork(
                  cacheFile.uri.toString(),
                  aspectRatio: 9 / 16,
                );
              }
            } catch (e) {
              _log.w('Could not cache canvas video to disk: $e');
            }
            return MotionArtwork(remoteUrl, aspectRatio: 9 / 16);
          }
        }
      } catch (_) {
        // Try next fallback endpoint
      }
    }
    return null;
  }
}
