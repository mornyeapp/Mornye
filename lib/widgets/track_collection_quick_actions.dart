import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/utils/service_track_link.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/track_collection_action_policy.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

class TrackCollectionQuickActions extends ConsumerWidget {
  final Track track;
  final bool hasLocalPlaybackCandidate;

  /// A 32dp pointer target for desktop table rows.
  final bool dense;

  const TrackCollectionQuickActions({
    super.key,
    required this.track,
    this.hasLocalPlaybackCandidate = false,
    this.dense = false,
  });

  /// Track options: a bottom sheet (Material) or popover (Mornye) on phones
  /// and tablets, a context menu at [position] or under [context] on
  /// desktop.
  static void showTrackOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    bool hasLocalPlaybackCandidate = false,
    Offset? position,
  }) {
    final origin =
        position ??
        contextMenuOriginOf(context) ??
        MediaQuery.sizeOf(context).center(Offset.zero);
    showContextMenu(
      context,
      position: origin,
      groups: trackOptionMenuGroups(
        context,
        ref,
        track,
        hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppIconButton(
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      icon: AppIcon(
        context.isMornye ? CupertinoIcons.ellipsis : Icons.more_vert,
        color: colorScheme.onSurfaceVariant,
        size: 20,
      ),
      onPressed: () => showTrackOptionsSheet(
        context,
        ref,
        track,
        hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
        position: contextMenuPositionBelow(context),
      ),
      padding: EdgeInsets.zero,
      constraints: dense
          ? const BoxConstraints(minWidth: 32, minHeight: 32)
          : const BoxConstraints(minWidth: 48, minHeight: 48),
      style: dense
          ? IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
    );
  }
}

/// The track options as desktop context menu groups: playback and download,
/// collections, navigation, then copying.
List<List<ContextMenuAction>> trackOptionMenuGroups(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  bool hasLocalPlaybackCandidate = false,
}) {
  final l10n = context.l10n;
  final root = Navigator.of(context, rootNavigator: true).context;
  final collections = ref.read(libraryCollectionsProvider);
  final isLoved = collections.isLoved(track);
  final isInWishlist = collections.isInWishlist(track);
  final qualityVariantAction = resolveQualityVariantMenuAction(
    allowQualityVariants: ref.read(settingsProvider).allowQualityVariants,
    hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
  );
  final link = serviceTrackLinkFor(track);

  void notify(String message) {
    if (!root.mounted) return;
    ScaffoldMessenger.of(root).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> toggle({required bool wishlist}) async {
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final added = wishlist
        ? await notifier.toggleWishlist(track)
        : await notifier.toggleLoved(track);
    if (!root.mounted) return;
    final l10n = root.l10n;
    notify(
      wishlist
          ? (added
                ? l10n.collectionAddedToWishlist(track.name)
                : l10n.collectionRemovedFromWishlist(track.name))
          : (added
                ? l10n.collectionAddedToLoved(track.name)
                : l10n.collectionRemovedFromLoved(track.name)),
    );
  }

  void copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (root.mounted) notify(root.l10n.trackCopiedToClipboard);
  }

  return [
    [
      if (qualityVariantAction == QualityVariantMenuAction.playLocal)
        ContextMenuAction(
          icon: Icons.play_arrow_rounded,
          label: l10n.trackMetadataPlay,
          onSelected: () async {
            final played = await playLocalIfAvailable(root, ref, track);
            if (!played && root.mounted) {
              notify(root.l10n.snackbarFileNotFound);
            }
          },
        ),
      ContextMenuAction(
        icon: Icons.download_outlined,
        label: l10n.dialogDownload,
        onSelected: () => downloadSingleTrack(root, ref, track),
      ),
      if (qualityVariantAction ==
          QualityVariantMenuAction.downloadAnotherQuality)
        ContextMenuAction(
          icon: Icons.high_quality_outlined,
          label: l10n.trackOptionDownloadQualityVariant,
          onSelected: () =>
              downloadSingleTrack(root, ref, track, forceQualityPicker: true),
        ),
    ],
    [
      ContextMenuAction(
        icon: isLoved ? Icons.favorite : Icons.favorite_border,
        label: isLoved
            ? l10n.trackOptionRemoveFromLoved
            : l10n.trackOptionAddToLoved,
        onSelected: () => toggle(wishlist: false),
      ),
      ContextMenuAction(
        icon: isInWishlist
            ? Icons.playlist_add_check_circle
            : Icons.add_circle_outline,
        label: isInWishlist
            ? l10n.trackOptionRemoveFromWishlist
            : l10n.trackOptionAddToWishlist,
        onSelected: () => toggle(wishlist: true),
      ),
      ContextMenuAction(
        icon: Icons.playlist_add,
        label: l10n.collectionAddToPlaylist,
        onSelected: () => showAddTrackToPlaylistSheet(root, ref, track),
      ),
    ],
    [
      ContextMenuAction(
        icon: Icons.album_outlined,
        label: l10n.homeGoToAlbum,
        onSelected: () => navigateToTrackAlbum(root, track),
      ),
    ],
    [
      ContextMenuAction(
        icon: Icons.content_copy_rounded,
        label: l10n.trackOptionCopyTrackName,
        onSelected: () => copy(track.name),
      ),
      ContextMenuAction(
        icon: Icons.person_outline_rounded,
        label: l10n.trackOptionCopyArtist,
        onSelected: () => copy(track.artistName),
      ),
      ContextMenuAction(
        icon: Icons.copy_all_rounded,
        label: l10n.trackOptionCopyTrackAndArtist,
        onSelected: () => copy('${track.name} - ${track.artistName}'),
      ),
      if (link != null)
        ContextMenuAction(
          icon: Icons.link,
          label: l10n.trackOptionCopyLink(link.serviceName),
          onSelected: () {
            Clipboard.setData(ClipboardData(text: link.webUrl));
            if (root.mounted) {
              notify(root.l10n.snackbarUrlCopied(link.serviceName));
            }
          },
        ),
    ],
  ];
}
