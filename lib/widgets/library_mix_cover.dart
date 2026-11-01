import 'package:flutter/material.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';

/// A Library song's own artwork, available offline first: a scanned
/// thumbnail or the cover embedded in the file, then a download's online
/// cover.
class LibraryItemArtwork extends StatelessWidget {
  const LibraryItemArtwork({
    super.key,
    required this.item,
    required this.size,
    this.iconSize = 24,
  });

  final UnifiedLibraryItem item;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    Widget fallback(BuildContext context) => ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: AppIcon.adaptive(
          Icons.music_note,
          size: iconSize,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: LocalLibraryArtworkBuilder(
        coverPath: item.localCoverPath,
        filePath: item.filePath,
        builder: (context, cover) {
          final source = cover ?? item.coverUrl?.trim();
          if (source == null || source.isEmpty) return fallback(context);
          return LocalOrNetworkCoverImage(
            url: source,
            width: size,
            height: size,
            localCacheWidth: cacheWidth,
            networkCacheWidth: cacheWidth,
            placeholder: fallback,
          );
        },
      ),
    );
  }
}

/// A mix's cover: four of its albums in a grid, or its first song's
/// artwork while it spans fewer albums.
class LibraryMixCover extends StatelessWidget {
  const LibraryMixCover({super.key, required this.items, required this.size});

  final List<UnifiedLibraryItem> items;
  final double size;

  @override
  Widget build(BuildContext context) {
    final albums = <String, UnifiedLibraryItem>{};
    for (final item in items) {
      final key =
          '${normalizeLookupText(item.artistName)}|'
          '${normalizeLookupText(item.albumName)}';
      albums.putIfAbsent(key, () => item);
      if (albums.length == 4) break;
    }
    if (albums.length < 4) {
      return items.isEmpty
          ? SizedBox.square(dimension: size)
          : LibraryItemArtwork(
              item: items.first,
              size: size,
              iconSize: size / 4,
            );
    }
    final half = size / 2;
    final tiles = albums.values.toList();
    // The quarters follow the space given, as a header background is wider
    // than it is tall.
    return SizedBox.square(
      dimension: size,
      child: Column(
        children: [
          for (var row = 0; row < 2; row++)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var column = 0; column < 2; column++)
                    Expanded(
                      child: LibraryItemArtwork(
                        item: tiles[row * 2 + column],
                        size: half,
                        iconSize: half / 3,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
