import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_metadata_row.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// Uses Mornye's TrackInfoView layout: artwork header, then selectable values
/// below small labels, separated by thin dividers on one glass surface.
class MornyePlayerDetailsSheet extends ConsumerWidget {
  const MornyePlayerDetailsSheet({
    super.key,
    required this.rows,
    required this.scrollController,
    this.mediaItem,
  });

  final List<(String, String)> rows;
  final ScrollController scrollController;
  final MediaItem? mediaItem;

  static const _artworkSize = 70.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final item = mediaItem;
    final artworkCacheWidth =
        (_artworkSize * MediaQuery.devicePixelRatioOf(context)).ceil();
    return MornyeGlass.navigation(
      blurEnabled: ref.watch(mornyeBlurEnabledProvider),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const AppSheetHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.nowPlayingDetails,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      context.l10n.dialogDone,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SelectionArea(
                child: CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    if (item != null)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                        sliver: SliverToBoxAdapter(
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox.square(
                                  dimension: _artworkSize,
                                  child: PlayerArtwork(
                                    artUri: item.artUri?.toString(),
                                    colorScheme: theme.colorScheme,
                                    cacheWidth: artworkCacheWidth,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      item.artist ?? '',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (rows.isEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.all(24),
                        sliver: SliverToBoxAdapter(
                          child: Text(
                            context.l10n.nowPlayingNoMetadata,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        sliver: SliverList.builder(
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final (label, value) = rows[index];
                            return MornyeMetadataRow(
                              label: label,
                              value: value,
                              showDivider: index < rows.length - 1,
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
