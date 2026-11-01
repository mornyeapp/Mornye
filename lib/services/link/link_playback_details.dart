import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_cover_shrink.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/utils/int_utils.dart';

const _maxCoverBytes = 256 * 1024;
final _windowsPaths = p.Context(style: p.Style.windows);

/// Display details for a validated queue entry, including transient uploads.
/// File paths stay on the host. The thumbnail travels over the paired channel.
class LinkPlaybackDetails {
  LinkPlaybackDetails({
    PlaybackMetadataReader? readMetadata,
    Future<String?> Function(String)? artwork,
    LinkCoverShrinker? shrink,
  }) : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry,
       _artwork = artwork ?? DownloadedEmbeddedCoverResolver.resolveOrExtract,
       _shrink = shrink ?? _thumbnail;

  final PlaybackMetadataReader _readMetadata;
  final Future<String?> Function(String) _artwork;
  final LinkCoverShrinker _shrink;
  final _thumbnails = <String, Future<Uint8List?>>{};

  Future<Uint8List?> _readCover(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size > 32 * 1024 * 1024) {
      return null;
    }
    final key = '$path|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    if (_thumbnails[key] case final pending?) return pending;
    if (_thumbnails.length >= 64) _thumbnails.remove(_thumbnails.keys.first);
    final pending = () async {
      try {
        final image = await _shrink(await file.readAsBytes());
        return image != null && image.length <= _maxCoverBytes ? image : null;
      } on Object {
        return null;
      }
    }();
    _thumbnails[key] = pending;
    return pending;
  }

  static Future<Uint8List?> _thumbnail(Uint8List bytes) async {
    final image = await shrinkLinkCover(bytes, maxSize: 384);
    if (image == null || image.length <= _maxCoverBytes) return image;
    return shrinkLinkCover(bytes, maxSize: 192);
  }

  Future<Map<String, dynamic>> read(LinkPlayerItem item) async {
    final source = _localPath(item.metadataSource) ?? item.path;
    var metadata = item.audioMetadata;
    try {
      metadata = mergePlaybackFileMetadata(
        metadata,
        await _readMetadata(source).timeout(const Duration(seconds: 4)),
      );
    } on Object {
      // A file still arriving can already have useful queue metadata.
    }
    final result = <String, dynamic>{
      'metadata': playbackDisplayMetadata(metadata),
      'album': item.album?.isNotEmpty == true
          ? item.album!
          : metadata['album']?.toString() ?? '',
      for (final key in ['bit_depth', 'sample_rate', 'bitrate'])
        key: ?readPositiveInt(metadata[key]),
      for (final key in ['format', 'genre'])
        if (metadata[key] case final String value
            when value.isNotEmpty && value.length <= 2048)
          key: value,
    };
    String? cover = _localPath(item.artwork);
    cover ??= _localPath(metadata['cover_path']?.toString());
    if (cover == null && _localPath(source) != null) {
      try {
        cover = await _artwork(source);
      } on Object {
        // Details are useful even when embedded artwork cannot be extracted.
      }
    }
    if (cover != null) {
      try {
        final bytes = await _readCover(cover);
        if (bytes != null && bytes.length <= _maxCoverBytes) {
          result['cover'] = base64Encode(bytes);
        }
      } on Object {
        // A removed cache entry must not discard the song's other details.
      }
    }
    return result;
  }
}

String? _localPath(String? value) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'file') {
    try {
      return uri!.toFilePath();
    } on Object {
      return null;
    }
  }
  return p.isAbsolute(value) || _windowsPaths.isAbsolute(value) ? value : null;
}

/// Complements the phone's own match without changing its playback source.
/// Older hosts and unavailable thumbnails keep the existing description.
Future<PlayableMedia?> readLinkPlaybackDetails({
  required LinkClientApi client,
  required TrackRef track,
  required CoverStore covers,
  PlayableMedia? local,
}) async {
  try {
    final reply = await client.post(LinkOps.playbackDetails, {
      'track': track.toJson(),
    });
    if (reply is! Map) return local;
    String? artwork = local?.artUri;
    final localArtwork = _localPath(artwork);
    final missingArtwork =
        artwork == null ||
        artwork.isEmpty ||
        (localArtwork != null && !await File(localArtwork).exists());
    if (missingArtwork) {
      final encoded = reply['cover'];
      if (encoded is String &&
          encoded.length <= (_maxCoverBytes + 2) ~/ 3 * 4) {
        try {
          final bytes = base64Decode(encoded);
          if (bytes.length <= _maxCoverBytes) {
            final key =
                'network://${client.server.connectionId}/link-player/'
                '${sha256.convert(bytes)}';
            var cached = covers.cachedFile(key);
            if (cached == null) {
              final temp = await Directory.systemTemp.createTemp(
                'mornye-link-cover-',
              );
              try {
                final file = File('${temp.path}/cover.png');
                await file.writeAsBytes(bytes);
                cached = await covers.adopt(key, file.path);
              } finally {
                await temp.delete(recursive: true);
              }
            }
            if (cached != null) artwork = Uri.file(cached).toString();
          }
        } on Object {
          // Malformed or unavailable artwork does not discard metadata.
        }
      }
    }
    String? text(String key) {
      final value = reply[key];
      return value is String && value.isNotEmpty && value.length <= 2048
          ? value
          : null;
    }

    return PlayableMedia(
      id: local?.id ?? 'link:${track.fileId ?? track.matchKey ?? track.title}',
      source: local?.source ?? '',
      title: track.title,
      artist: track.artist,
      album: local?.album.isNotEmpty == true
          ? local!.album
          : text('album') ?? track.album ?? '',
      artUri: artwork,
      networkArtworkSource: artwork == null
          ? local?.networkArtworkSource
          : null,
      duration:
          local?.duration ??
          (track.durationMs == null
              ? null
              : Duration(milliseconds: track.durationMs!)),
      bitDepth: local?.bitDepth ?? readPositiveInt(reply['bit_depth']),
      sampleRate: local?.sampleRate ?? readPositiveInt(reply['sample_rate']),
      bitrate: local?.bitrate ?? readPositiveInt(reply['bitrate']),
      format: local?.format ?? text('format'),
      genre: local?.genre ?? text('genre'),
      explicit: local?.explicit ?? false,
      autoplay: local?.autoplay ?? false,
      displayMetadata: {
        ...playbackDisplayMetadata(reply['metadata']),
        ...?local?.displayMetadata,
      },
    );
  } on Object {
    return local;
  }
}
