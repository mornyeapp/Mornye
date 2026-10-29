import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// Queue entries may not have artwork yet, as for files a phone sent through
/// Link. Recover only visible rows through the shared bounded cover cache.
class PlayerQueueArtwork extends StatelessWidget {
  const PlayerQueueArtwork({
    super.key,
    required this.item,
    required this.colorScheme,
    required this.cacheWidth,
    this.iconSize = 22,
  });

  final MediaItem item;
  final ColorScheme colorScheme;
  final int cacheWidth;
  final double iconSize;

  String? get _localSource {
    var source = item.extras?['source']?.toString() ?? item.id;
    if (source.startsWith('file://')) {
      try {
        source = Uri.parse(source).toFilePath();
      } on FormatException {
        return null;
      } on UnsupportedError {
        return null;
      }
    }
    return p.isAbsolute(source) || source.startsWith('content://')
        ? source
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final artwork = item.artUri?.toString();
    final source = _localSource;
    Widget image(String? uri) => PlayerArtwork(
      artUri: uri,
      colorScheme: colorScheme,
      cacheWidth: cacheWidth,
      iconSize: iconSize,
    );
    if (source == null || isHttpCoverUrl(artwork)) {
      return image(artwork);
    }
    return LocalLibraryArtworkBuilder(
      coverPath: artwork,
      filePath: source,
      builder: (_, cover) => image(cover),
    );
  }
}
