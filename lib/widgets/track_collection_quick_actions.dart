import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:flutter/services.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/suggestion_outcomes.dart' show SuggestionAction;
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/service_track_link.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/song_share_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/track_card.dart';
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
  /// desktop. [onAction] hears the options that show interest in the song.
  static void showTrackOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    bool hasLocalPlaybackCandidate = false,
    Offset? position,
    ValueChanged<SuggestionAction>? onAction,
  }) {
    if (isDesktopPlatform) {
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
          onAction: onAction,
        ),
      );
      return;
    }
    if (context.isMornye) {
      showMornyeContextMenu<void>(
        context: context,
        builder: (_) => _TrackOptionsSheet(
          track: track,
          hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
          onAction: onAction,
        ),
      );
      return;
    }
    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      // The sheet owns the scrolling, so a pull down at the top closes it.
      builder: (_) => AppScrollableSheet(
        builder: (_, controller) => _TrackOptionsSheet(
          track: track,
          hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
          scrollController: controller,
          onAction: onAction,
        ),
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

/// The text "Copy track and artist" puts on the clipboard.
String trackAndArtistText(Track track) => '${track.name} - ${track.artistName}';

/// Copies [text] and confirms it on [context]'s messenger.
void copyTrackText(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  showAppSnackBar(context, content: Text(context.l10n.trackCopiedToClipboard));
}

/// The track options as desktop context menu groups: playback and download,
/// collections, navigation, then copying. [onAction] hears the options that
/// show interest in the song.
List<List<ContextMenuAction>> trackOptionMenuGroups(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  bool hasLocalPlaybackCandidate = false,
  ValueChanged<SuggestionAction>? onAction,
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
    showAppSnackBar(root, content: Text(message));
  }

  Future<void> toggle({required bool wishlist}) async {
    if (!(wishlist ? isInWishlist : isLoved)) {
      onAction?.call(
        wishlist ? SuggestionAction.wishlisted : SuggestionAction.loved,
      );
    }
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

  void copy(String text) => copyTrackText(root, text);

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
        onSelected: () {
          onAction?.call(SuggestionAction.downloaded);
          downloadSingleTrack(root, ref, track);
        },
      ),
      if (qualityVariantAction ==
          QualityVariantMenuAction.downloadAnotherQuality)
        ContextMenuAction(
          icon: Icons.high_quality_outlined,
          label: l10n.trackOptionDownloadQualityVariant,
          onSelected: () {
            onAction?.call(SuggestionAction.downloaded);
            downloadSingleTrack(root, ref, track, forceQualityPicker: true);
          },
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
        onSelected: () {
          onAction?.call(SuggestionAction.playlisted);
          showAddTrackToPlaylistSheet(root, ref, track);
        },
      ),
    ],
    [
      ContextMenuAction(
        icon: Icons.album_outlined,
        label: l10n.homeGoToAlbum,
        onSelected: () {
          onAction?.call(SuggestionAction.opened);
          navigateToTrackAlbum(root, track);
        },
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
        onSelected: () => copy(trackAndArtistText(track)),
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

class _TrackOptionsSheet extends ConsumerWidget {
  final Track track;
  final bool hasLocalPlaybackCandidate;

  /// The Material sheet's controller; the Mornye popover scrolls by itself.
  final ScrollController? scrollController;
  final ValueChanged<SuggestionAction>? onAction;

  const _TrackOptionsSheet({
    required this.track,
    required this.hasLocalPlaybackCandidate,
    this.scrollController,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final link = serviceTrackLinkFor(track);

    final isLoved = ref.watch(
      libraryCollectionsProvider.select((state) => state.isLoved(track)),
    );
    final isInWishlist = ref.watch(
      libraryCollectionsProvider.select((state) => state.isInWishlist(track)),
    );
    final allowQualityVariants = ref.watch(
      settingsProvider.select((settings) => settings.allowQualityVariants),
    );
    final qualityVariantAction = resolveQualityVariantMenuAction(
      allowQualityVariants: allowQualityVariants,
      hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
    );
    final pairedClient = ref.watch(linkPhoneClientProvider);
    // A phone host downloads nothing for other phones.
    final linkClient =
        pairedClient != null &&
            pairedClient.server.supports(LinkHostFeatures.downloads)
        ? pairedClient
        : null;

    if (context.isMornye) {
      final l10n = context.l10n;
      return MornyeContextMenu(
        quickActions: [
          MornyeMenuAction(
            icon: CupertinoIcons.arrow_down_circle_fill,
            label: l10n.dialogDownload,
            onPressed: () {
              final root = Navigator.of(context, rootNavigator: true).context;
              Navigator.pop(context);
              onAction?.call(SuggestionAction.downloaded);
              downloadSingleTrack(root, ref, track);
            },
          ),
          MornyeMenuAction(
            icon: CupertinoIcons.star_fill,
            label: isLoved ? l10n.mornyeFavorited : l10n.mornyeFavorite,
            selected: isLoved,
            onPressed: () => _toggleCollection(context, ref, wishlist: false),
          ),
          MornyeMenuAction(
            icon: CupertinoIcons.share_solid,
            label: l10n.trackMetadataShare,
            onPressed: () {
              final root = Navigator.of(context, rootNavigator: true).context;
              Navigator.pop(context);
              showSongShare(root, title: track.name, artist: track.artistName);
            },
          ),
        ],
        groups: [
          [
            if (qualityVariantAction == QualityVariantMenuAction.playLocal)
              MornyeMenuAction(
                icon: CupertinoIcons.play,
                label: l10n.trackMetadataPlay,
                onPressed: () => _playLocal(context, ref),
              ),
            if (qualityVariantAction ==
                QualityVariantMenuAction.downloadAnotherQuality)
              MornyeMenuAction(
                icon: CupertinoIcons.arrow_down_circle,
                label: l10n.trackOptionDownloadQualityVariant,
                onPressed: () => _downloadQualityVariant(context, ref),
              ),
            if (linkClient != null)
              MornyeMenuAction(
                icon: CupertinoIcons.desktopcomputer,
                label: l10n.linkDownloadOnDesktop(linkDesktopName(linkClient)),
                onPressed: () => _downloadOnDesktop(context, ref),
              ),
            MornyeMenuAction(
              icon: CupertinoIcons.square_stack,
              label: l10n.homeGoToAlbum,
              onPressed: () => _goToAlbum(context),
            ),
          ],
          [
            MornyeMenuAction(
              icon: CupertinoIcons.text_badge_plus,
              label: l10n.collectionAddToPlaylist,
              onPressed: () {
                final root = Navigator.of(context, rootNavigator: true).context;
                Navigator.pop(context);
                onAction?.call(SuggestionAction.playlisted);
                showAddTrackToPlaylistSheet(root, ref, track);
              },
            ),
            MornyeMenuAction(
              icon: isInWishlist
                  ? CupertinoIcons.checkmark_circle
                  : CupertinoIcons.add_circled,
              label: isInWishlist
                  ? l10n.trackOptionRemoveFromWishlist
                  : l10n.trackOptionAddToWishlist,
              onPressed: () => _toggleCollection(context, ref, wishlist: true),
            ),
          ],
          [
            MornyeMenuAction(
              icon: CupertinoIcons.doc_on_doc,
              label: l10n.trackOptionCopyTrackName,
              onPressed: () => _copyText(context, track.name),
            ),
            MornyeMenuAction(
              icon: CupertinoIcons.person,
              label: l10n.trackOptionCopyArtist,
              onPressed: () => _copyText(context, track.artistName),
            ),
            MornyeMenuAction(
              icon: CupertinoIcons.doc_on_doc,
              label: l10n.trackOptionCopyTrackAndArtist,
              onPressed: () => _copyText(context, trackAndArtistText(track)),
            ),
            if (link != null)
              MornyeMenuAction(
                icon: CupertinoIcons.link,
                label: l10n.trackOptionCopyLink(link.serviceName),
                onPressed: () => _copyLink(context, link),
              ),
          ],
        ],
      );
    }

    // The song stays in place above the rows, which are one connected group
    // like the other menus.
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              connectedRunTitleInset,
              12,
              connectedRunTitleInset,
              8,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: track.coverUrl != null && track.coverUrl!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: track.coverUrl!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          memCacheWidth: 112,
                          cacheManager: CoverCacheManager.instance,
                          errorWidget: (context, url, error) => Container(
                            width: 56,
                            height: 56,
                            color: colorScheme.surfaceContainerHighest,
                            child: AppIcon(
                              Icons.music_note,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : Container(
                          width: 56,
                          height: 56,
                          color: colorScheme.surfaceContainerHighest,
                          child: AppIcon(
                            Icons.music_note,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      ClickableArtistName(
                        artistName: track.artistName,
                        artistId: track.artistId,
                        coverUrl: track.coverUrl,
                        extensionId: track.source,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: EdgeInsets.only(bottom: context.tokens.gapLg),
              child: SettingsGroup(
                children: [
                  if (qualityVariantAction ==
                      QualityVariantMenuAction.playLocal)
                    SettingsItem(
                      icon: Icons.play_arrow_rounded,
                      title: context.l10n.trackMetadataPlay,
                      onTap: () => _playLocal(context, ref),
                    )
                  else if (qualityVariantAction ==
                      QualityVariantMenuAction.downloadAnotherQuality)
                    SettingsItem(
                      icon: Icons.download_outlined,
                      title: context.l10n.trackOptionDownloadQualityVariant,
                      onTap: () => _downloadQualityVariant(context, ref),
                    ),
                  if (linkClient != null)
                    SettingsItem(
                      icon: Icons.computer,
                      title: context.l10n.linkDownloadOnDesktop(
                        linkDesktopName(linkClient),
                      ),
                      onTap: () => _downloadOnDesktop(context, ref),
                    ),

                  SettingsItem(
                    icon: Icons.content_copy_rounded,
                    title: context.l10n.trackOptionCopyTrackName,
                    onTap: () => _copyText(context, track.name),
                  ),
                  SettingsItem(
                    icon: Icons.person_outline_rounded,
                    title: context.l10n.trackOptionCopyArtist,
                    onTap: () => _copyText(context, track.artistName),
                  ),
                  SettingsItem(
                    icon: Icons.copy_all_rounded,
                    title: context.l10n.trackOptionCopyTrackAndArtist,
                    onTap: () => _copyText(context, trackAndArtistText(track)),
                  ),
                  if (link != null)
                    SettingsItem(
                      icon: Icons.link,
                      title: context.l10n.trackOptionCopyLink(link.serviceName),
                      onTap: () => _copyLink(context, link),
                    ),

                  SettingsItem(
                    icon: Icons.album_outlined,
                    title: context.l10n.homeGoToAlbum,
                    onTap: () => _goToAlbum(context),
                  ),

                  SettingsItem(
                    icon: isLoved ? Icons.favorite : Icons.favorite_border,
                    iconColor: isLoved ? colorScheme.error : null,
                    title: isLoved
                        ? context.l10n.trackOptionRemoveFromLoved
                        : context.l10n.trackOptionAddToLoved,
                    onTap: () async {
                      Navigator.pop(context);
                      if (!isLoved) onAction?.call(SuggestionAction.loved);
                      final added = await ref
                          .read(libraryCollectionsProvider.notifier)
                          .toggleLoved(track);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            added
                                ? context.l10n.collectionAddedToLoved(
                                    track.name,
                                  )
                                : context.l10n.collectionRemovedFromLoved(
                                    track.name,
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                  SettingsItem(
                    icon: isInWishlist
                        ? Icons.playlist_add_check_circle
                        : Icons.add_circle_outline,
                    iconColor: isInWishlist ? colorScheme.primary : null,
                    title: isInWishlist
                        ? context.l10n.trackOptionRemoveFromWishlist
                        : context.l10n.trackOptionAddToWishlist,
                    onTap: () async {
                      Navigator.pop(context);
                      if (!isInWishlist) {
                        onAction?.call(SuggestionAction.wishlisted);
                      }
                      final added = await ref
                          .read(libraryCollectionsProvider.notifier)
                          .toggleWishlist(track);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            added
                                ? context.l10n.collectionAddedToWishlist(
                                    track.name,
                                  )
                                : context.l10n.collectionRemovedFromWishlist(
                                    track.name,
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                  SettingsItem(
                    icon: Icons.playlist_add,
                    title: context.l10n.collectionAddToPlaylist,
                    onTap: () {
                      final rootContext = Navigator.of(
                        context,
                        rootNavigator: true,
                      ).context;
                      Navigator.pop(context);
                      onAction?.call(SuggestionAction.playlisted);
                      showAddTrackToPlaylistSheet(rootContext, ref, track);
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _downloadQualityVariant(BuildContext context, WidgetRef ref) {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    onAction?.call(SuggestionAction.downloaded);
    downloadSingleTrack(rootContext, ref, track, forceQualityPicker: true);
  }

  void _downloadOnDesktop(BuildContext context, WidgetRef ref) {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    onAction?.call(SuggestionAction.downloaded);
    linkDownloadTracksOnDesktop(rootContext, ref, [track]);
  }

  Future<void> _toggleCollection(
    BuildContext context,
    WidgetRef ref, {
    required bool wishlist,
  }) async {
    final root = Navigator.of(context, rootNavigator: true).context;
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final collections = ref.read(libraryCollectionsProvider);
    Navigator.pop(context);
    if (!(wishlist
        ? collections.isInWishlist(track)
        : collections.isLoved(track))) {
      onAction?.call(
        wishlist ? SuggestionAction.wishlisted : SuggestionAction.loved,
      );
    }
    final added = wishlist
        ? await notifier.toggleWishlist(track)
        : await notifier.toggleLoved(track);
    if (!root.mounted) return;
    final l10n = root.l10n;
    final message = wishlist
        ? (added
              ? l10n.collectionAddedToWishlist(track.name)
              : l10n.collectionRemovedFromWishlist(track.name))
        : (added
              ? l10n.collectionAddedToLoved(track.name)
              : l10n.collectionRemovedFromLoved(track.name));
    ScaffoldMessenger.of(root).showSnackBar(SnackBar(content: Text(message)));
  }

  void _copyText(BuildContext context, String text) {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    copyTrackText(rootContext, text);
  }

  void _copyLink(BuildContext context, ServiceTrackLink link) {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    Clipboard.setData(ClipboardData(text: link.webUrl));
    ScaffoldMessenger.of(rootContext).showSnackBar(
      SnackBar(
        content: Text(rootContext.l10n.snackbarUrlCopied(link.serviceName)),
      ),
    );
  }

  Future<void> _goToAlbum(BuildContext context) async {
    final navigationContext = Navigator.of(
      context,
      rootNavigator: true,
    ).context;
    Navigator.pop(context);
    onAction?.call(SuggestionAction.opened);
    await navigateToTrackAlbum(navigationContext, track);
  }

  Future<void> _playLocal(BuildContext context, WidgetRef ref) async {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    final played = await playLocalIfAvailable(rootContext, ref, track);
    if (!played && rootContext.mounted) {
      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(content: Text(rootContext.l10n.snackbarFileNotFound)),
      );
    }
  }
}
