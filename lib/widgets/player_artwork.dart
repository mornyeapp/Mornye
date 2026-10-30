import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

class PlayerArtwork extends StatelessWidget {
  /// Shared decode for the mini player and the full player's blurred cover.
  static const miniCacheWidth = 132;

  /// An HTTP(S) URL, file URI, absolute local artwork path, or `network://`
  /// cover reference.
  final String? artUri;
  final ColorScheme colorScheme;
  final int? cacheWidth;
  final double iconSize;

  const PlayerArtwork({
    super.key,
    required this.artUri,
    required this.colorScheme,
    this.cacheWidth,
    this.iconSize = 40,
  });

  /// Share one full-size decode while artwork moves between player panels.
  static int transitionCacheWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context))
          .round();

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: colorScheme.surfaceContainerHighest,
      child: AppIcon(
        Icons.music_note,
        size: iconSize,
        color: colorScheme.onSurfaceVariant,
      ),
    );

    final uri = artUri;
    if (isHttpCoverUrl(uri)) {
      return CachedNetworkImage(
        imageUrl: uri!,
        fit: BoxFit.cover,
        cacheManager: CoverCacheManager.instance,
        memCacheWidth: cacheWidth,
        fadeInDuration: Duration.zero,
        fadeOutDuration: const Duration(milliseconds: 0),
        useOldImageOnUrlChange: true,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    final image = coverImageProvider(uri, cacheWidth: cacheWidth);
    if (image == null) {
      return pendingCover(uri, placeholder: placeholder, builder: build);
    }
    return Image(
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}
