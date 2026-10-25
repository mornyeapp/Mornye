import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/widgets/app_icon.dart';

class PlayerArtwork extends StatelessWidget {
  /// Shared decode for the mini player and the full player's blurred cover.
  static const miniCacheWidth = 132;

  /// An HTTP(S) URL, file URI, or absolute local artwork path.
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

  /// Resolves the same cache entry used by the artwork widgets.
  static ImageProvider<Object>? imageProvider(
    String? artUri, {
    int? cacheWidth,
  }) {
    final ImageProvider<Object> provider;
    if (artUri == null || artUri.isEmpty) return null;
    if (artUri.startsWith('http')) {
      provider = CachedNetworkImageProvider(
        artUri,
        cacheManager: CoverCacheManager.instance,
      );
    } else if (artUri.startsWith('file://') || p.isAbsolute(artUri)) {
      provider = FileImage(
        File(
          artUri.startsWith('file://')
              ? Uri.parse(artUri).toFilePath()
              : artUri,
        ),
      );
    } else {
      return null;
    }
    return ResizeImage.resizeIfNeeded(cacheWidth, null, provider);
  }

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
    if (uri == null || uri.isEmpty) return placeholder;

    if (uri.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: uri,
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
    if (uri.startsWith('file://') || p.isAbsolute(uri)) {
      final path = uri.startsWith('file://')
          ? Uri.parse(uri).toFilePath()
          : uri;
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return placeholder;
  }
}
