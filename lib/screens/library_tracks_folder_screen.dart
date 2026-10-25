import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_link_transfer_actions.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/m3u_playlist_service.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/library_tracks_folder_data.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/screens/playlist_reorder_page.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/in_library_badge.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

String? _resolveRawCoverUrl(Track track) {
  final rawCover = track.coverUrl?.trim();
  if (rawCover != null &&
      rawCover.isNotEmpty &&
      !rawCover.startsWith('content://')) {
    return rawCover;
  }
  return null;
}

class LibraryTracksFolderScreen extends ConsumerStatefulWidget {
  final LibraryTracksFolderMode mode;
  final String? playlistId;

  const LibraryTracksFolderScreen({
    super.key,
    required this.mode,
    this.playlistId,
  });

  @override
  ConsumerState<LibraryTracksFolderScreen> createState() =>
      _LibraryTracksFolderScreenState();
}

class _LibraryTracksFolderScreenState
    extends ConsumerState<LibraryTracksFolderScreen>
    with
        SelectionModeMixin<LibraryTracksFolderScreen>,
        CollapsingHeaderScrollMixin<LibraryTracksFolderScreen> {
  UserPlaylistCollection? playlist;
  final _folderData = LibraryTracksFolderData();

  @override
  void initState() {
    super.initState();
    final playlistId = widget.playlistId;
    if (widget.mode == LibraryTracksFolderMode.playlist && playlistId != null) {
      Future.microtask(
        () => ref
            .read(libraryCollectionsProvider.notifier)
            .ensurePlaylistLoaded(playlistId),
      );
    }
  }

  /// Exports the collection as an .m3u8 shared via the system sheet. Tracks
  /// without a resolvable local file are skipped; SAF entries are written
  /// relative to the download tree root.
  Future<void> _exportAsM3u8(
    BuildContext context,
    String title,
    List<CollectionTrackEntry> entries,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tracks = entries.map((e) => e.track).toList(growable: false);
      final paths = await ref
          .read(playbackProvider.notifier)
          .resolveTrackFilePaths(tracks);

      final exportEntries = <M3uExportEntry>[];
      for (var i = 0; i < tracks.length; i++) {
        final path = paths[i];
        if (path == null || isCueVirtualPath(path)) continue;
        final entryPath = M3uPlaylistService.exportPathFor(path);
        if (entryPath == null) continue;
        exportEntries.add(M3uExportEntry(track: tracks[i], path: entryPath));
      }

      if (exportEntries.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.collectionExportM3uNone)),
        );
        return;
      }

      final file = await M3uPlaylistService.writeExportEntries(
        title,
        exportEntries,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.collectionExportM3uDone(exportEntries.length, tracks.length),
          ),
        ),
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: title),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.collectionExportM3uFailed)),
      );
    }
  }

  IconData _modeIcon() {
    return switch (widget.mode) {
      LibraryTracksFolderMode.wishlist => Icons.bookmark,
      LibraryTracksFolderMode.loved => Icons.favorite,
      LibraryTracksFolderMode.playlist => Icons.queue_music,
    };
  }

  String? _firstRawCoverUrl(List<CollectionTrackEntry> entries) {
    for (final entry in entries) {
      final cover = _resolveRawCoverUrl(entry.track);
      if (cover != null && cover.isNotEmpty) {
        return cover;
      }
    }
    return null;
  }

  Future<void> _removeSelected(List<CollectionTrackEntry> entries) async {
    final keysToRemove = selectedIds.toSet();
    if (keysToRemove.isEmpty) return;

    final count = keysToRemove.length;
    final notifier = ref.read(libraryCollectionsProvider.notifier);

    switch (widget.mode) {
      case LibraryTracksFolderMode.wishlist:
        await notifier.removeWishlistTracks(keysToRemove);
        break;
      case LibraryTracksFolderMode.loved:
        await notifier.removeLovedTracks(keysToRemove);
        break;
      case LibraryTracksFolderMode.playlist:
        if (widget.playlistId != null) {
          await notifier.removeTracksFromPlaylist(
            widget.playlistId!,
            keysToRemove,
          );
        }
        break;
    }

    exitSelectionMode();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.selectionSelected(count))),
    );
  }

  LocalLibraryCoverBatchRequest _coverBatchRequest(
    List<CollectionTrackEntry> entries,
  ) {
    return LocalLibraryCoverBatchRequest(
      entries
          .map(
            (entry) => LocalLibraryCoverRequest(
              isrc: entry.track.isrc?.trim(),
              trackName: entry.track.name,
              artistName: entry.track.artistName,
            ),
          )
          .toList(growable: false),
    );
  }

  void _downloadSelected(List<CollectionTrackEntry> entries) {
    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final service = resolveEffectiveDownloadService(
      settings.defaultService,
      extensionState,
    );
    if (service.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
      );
      return;
    }
    final queueNotifier = ref.read(downloadQueueProvider.notifier);
    final tracks = entries
        .where((entry) => selectedIds.contains(entry.key))
        .map((entry) => entry.track)
        .toList(growable: false);
    queueNotifier.addIndividualTracksToQueue(tracks, service);
    final count = tracks.length;

    exitSelectionMode();

    if (!mounted || count == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.selectionSelected(count))),
    );
  }

  void _addSelectedToPlaylist(List<CollectionTrackEntry> entries) {
    final selectedTracks = entries
        .where((e) => selectedIds.contains(e.key))
        .map((e) => e.track)
        .toList(growable: false);
    if (selectedTracks.isEmpty) return;

    showAddTracksToPlaylistSheet(context, ref, selectedTracks);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
    final List<CollectionTrackEntry> entries;

    switch (widget.mode) {
      case LibraryTracksFolderMode.wishlist:
        playlist = null;
        entries = ref.watch(
          libraryCollectionsProvider.select((state) => state.wishlist),
        );
        break;
      case LibraryTracksFolderMode.loved:
        playlist = null;
        entries = ref.watch(
          libraryCollectionsProvider.select((state) => state.loved),
        );
        break;
      case LibraryTracksFolderMode.playlist:
        final playlistId = widget.playlistId;
        playlist = playlistId == null
            ? null
            : ref.watch(
                libraryCollectionsProvider.select(
                  (state) => state.playlistById(playlistId),
                ),
              );
        entries = playlist?.tracks ?? const <CollectionTrackEntry>[];
        break;
    }

    _folderData.update(entries);
    pruneSelection(_folderData.keys);

    final title = switch (widget.mode) {
      LibraryTracksFolderMode.wishlist => context.l10n.collectionWishlist,
      LibraryTracksFolderMode.loved => context.l10n.collectionLoved,
      LibraryTracksFolderMode.playlist =>
        playlist?.name ?? context.l10n.collectionPlaylist,
    };

    final emptyTitle = switch (widget.mode) {
      LibraryTracksFolderMode.wishlist =>
        context.l10n.collectionWishlistEmptyTitle,
      LibraryTracksFolderMode.loved => context.l10n.collectionLovedEmptyTitle,
      LibraryTracksFolderMode.playlist =>
        context.l10n.collectionPlaylistEmptyTitle,
    };

    final emptySubtitle = switch (widget.mode) {
      LibraryTracksFolderMode.wishlist =>
        context.l10n.collectionWishlistEmptySubtitle,
      LibraryTracksFolderMode.loved =>
        context.l10n.collectionLovedEmptySubtitle,
      LibraryTracksFolderMode.playlist =>
        context.l10n.collectionPlaylistEmptySubtitle,
    };
    final folderTracks = _folderData.tracks;
    final historyLookups = _folderData.historyRequest.tracks;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_folderData.historyRequest),
    );

    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    final inHistory = [
      for (final lookup in historyLookups)
        existingHistoryKeys.contains(lookup.lookupKey),
    ];
    final ids = [for (final entry in entries) entry.key];
    final scaffold = CollectionScaffold(
      scrollController: scrollController,
      isSelectionMode: showsSelectionBar,
      onExitSelectionMode: exitSelectionMode,
      selectionBar: _buildSelectionBottomBar(
        context,
        colorScheme,
        entries,
        ids,
        bottomPadding,
      ),
      appBar: _buildAppBar(context, colorScheme, title, entries, playlist),
      slivers: [
        if (entries.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyFolderState(
              title: emptyTitle,
              subtitle: emptySubtitle,
            ),
          )
        else if (isDesktopPlatform)
          TrackListTable(
            tracks: folderTracks,
            ids: ids,
            isInHistory: inHistory,
            selectedIds: selectedIds,
            onSelect: applyDesktopClick,
            onActivate: (index) =>
                _activateEntry(entries, folderTracks, inHistory, index),
            onContextMenu: (index, position) => showSelectionMenu(
              entries[index].key,
              () => _showEntryMenu(
                context,
                entries,
                folderTracks,
                inHistory,
                index,
                position,
              ),
            ),
            showArtwork: true,
            showAlbum: true,
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final entry = entries[index];
                final isSelected = selectedIds.contains(entry.key);
                final isInHistory = existingHistoryKeys.contains(
                  historyLookups[index].lookupKey,
                );
                return KeyedSubtree(
                  key: ValueKey(entry.key),
                  child: StaggeredListItem(
                    index: index,
                    child: _CollectionTrackTile(
                      entry: entry,
                      mode: widget.mode,
                      folderTracks: folderTracks,
                      trackIndex: index,
                      isInHistory: isInHistory,
                      isSelectionMode: isSelectionMode,
                      isSelected: isSelected,
                      onTap: isSelectionMode
                          ? () => toggleSelection(entry.key)
                          : null,
                      onLongPress: isSelectionMode
                          ? null
                          : () => enterSelectionMode(entry.key),
                    ),
                  ),
                );
              }, childCount: entries.length),
            ),
          ),
      ],
    );
    return DesktopListScope(
      onSelectAll: entries.isEmpty ? null : () => selectAll(ids),
      onClearSelection: isSelectionMode ? exitSelectionMode : null,
      onDelete: isSelectionMode ? () => _removeSelected(entries) : null,
      onActivate: () {
        final index = entries.indexWhere(
          (entry) => entry.key == selectionAnchorId,
        );
        if (index >= 0) {
          _activateEntry(entries, folderTracks, inHistory, index);
        }
      },
      child: scaffold,
    );
  }

  /// Double click and Enter on a desktop row: plays a downloaded track,
  /// downloads a wishlist one, and otherwise does what a tap on the mobile
  /// row does.
  void _activateEntry(
    List<CollectionTrackEntry> entries,
    List<Track> tracks,
    List<bool> inHistory,
    int index,
  ) {
    if (inHistory[index]) {
      _playFrom(tracks, index);
    } else if (widget.mode == LibraryTracksFolderMode.wishlist) {
      downloadSingleTrack(context, ref, entries[index].track);
    } else {
      _openCollectionTrack(context, ref, entries[index].track);
    }
  }

  Future<void> _playFrom(List<Track> tracks, int index) async {
    try {
      await ref
          .read(playbackProvider.notifier)
          .playTrackList(tracks, startIndex: index);
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  /// The right-click menu of a desktop row: the selection bar's actions for
  /// the selection the row joins, after the row's own Play and details, which
  /// end the selection.
  Future<bool> _showEntryMenu(
    BuildContext context,
    List<CollectionTrackEntry> entries,
    List<Track> tracks,
    List<bool> inHistory,
    int index,
    Offset position,
  ) {
    final l10n = context.l10n;
    final count = selectedIds.length;
    final isPlaylist = widget.mode == LibraryTracksFolderMode.playlist;
    return showContextMenu(
      context,
      position: position,
      groups: [
        [
          if (inHistory[index])
            ContextMenuAction(
              icon: Icons.play_arrow,
              label: l10n.tooltipPlay,
              onSelected: () {
                exitSelectionMode();
                _playFrom(tracks, index);
              },
            ),
          if (count == 1)
            ContextMenuAction(
              icon: Icons.info_outline,
              label: l10n.desktopMenuShowDetails,
              onSelected: () {
                exitSelectionMode();
                _openCollectionTrack(this.context, ref, tracks[index]);
              },
            ),
        ],
        [
          if (widget.mode == LibraryTracksFolderMode.wishlist)
            ContextMenuAction(
              icon: Icons.download,
              label: '${l10n.settingsDownload} ($count)',
              onSelected: () => _downloadSelected(entries),
            ),
          ContextMenuAction(
            icon: Icons.playlist_add,
            label: '${l10n.collectionAddToPlaylist} ($count)',
            onSelected: () => _addSelectedToPlaylist(entries),
          ),
        ],
        if (widget.mode != LibraryTracksFolderMode.wishlist)
          desktopLinkTransferTrackActions(context, ref, [
            for (final entry in entries)
              if (selectedIds.contains(entry.key)) entry.track,
          ], onDone: exitSelectionMode),
        [
          ContextMenuAction(
            icon: Icons.remove_circle_outline,
            label:
                '${isPlaylist ? l10n.collectionRemoveFromPlaylist : l10n.collectionRemoveFromFolder} ($count)',
            destructive: true,
            onSelected: () => _removeSelected(entries),
          ),
        ],
      ],
    );
  }

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<CollectionTrackEntry> entries,
    List<String> ids,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    final isWishlist = widget.mode == LibraryTracksFolderMode.wishlist;

    return buildSelectionBar(
      ids: ids,
      bottomPadding: bottomPadding,
      children: [
        Row(
          children: [
            if (isWishlist)
              Expanded(
                child: SelectionActionButton(
                  icon: Icons.download,
                  label: '${context.l10n.settingsDownload} ($selectedCount)',
                  onPressed: selectedCount > 0
                      ? () => _downloadSelected(entries)
                      : null,
                  colorScheme: colorScheme,
                ),
              ),
            if (isWishlist) const SizedBox(width: 8),
            Expanded(
              child: SelectionActionButton(
                icon: Icons.playlist_add,
                label:
                    '${context.l10n.collectionAddToPlaylist} ($selectedCount)',
                onPressed: selectedCount > 0
                    ? () => _addSelectedToPlaylist(entries)
                    : null,
                colorScheme: colorScheme,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        SizedBox(
          width: double.infinity,
          child: ExpressiveButton(
            onPressed: selectedCount > 0
                ? () => _removeSelected(entries)
                : null,
            icon: const Icon(Icons.remove_circle_outline),
            style: FilledButton.styleFrom(
              backgroundColor: selectedCount > 0
                  ? colorScheme.error
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: selectedCount > 0
                  ? colorScheme.onError
                  : colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              selectedCount > 0
                  ? '${widget.mode == LibraryTracksFolderMode.playlist ? context.l10n.collectionRemoveFromPlaylist : context.l10n.collectionRemoveFromFolder} ($selectedCount)'
                  : widget.mode == LibraryTracksFolderMode.playlist
                  ? context.l10n.collectionRemoveFromPlaylist
                  : context.l10n.collectionRemoveFromFolder,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickCoverImage() async {
    final playlistId = widget.playlistId;
    if (playlistId == null) return;

    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;

    Directory? materializedDir;
    try {
      var sourcePath = picked.path;
      if (sourcePath == null || sourcePath.isEmpty) {
        materializedDir = await Directory.systemTemp.createTemp(
          'mornye_playlist_cover_',
        );
        final pickedExtension = p.extension(picked.name);
        final materializedFile = File(
          p.join(
            materializedDir.path,
            'selected_cover${pickedExtension.isEmpty ? '.img' : pickedExtension}',
          ),
        );
        await materializedFile.writeAsBytes(
          await picked.readAsBytes(),
          flush: true,
        );
        sourcePath = materializedFile.path;
      }

      await ref
          .read(libraryCollectionsProvider.notifier)
          .setPlaylistCover(playlistId, sourcePath);
    } finally {
      try {
        if (materializedDir != null && await materializedDir.exists()) {
          await materializedDir.delete(recursive: true);
        }
      } catch (_) {
        // The cover has already been normalized into app storage.
      }
    }
  }

  Future<void> _removeCoverImage() async {
    final playlistId = widget.playlistId;
    if (playlistId == null) return;

    await ref
        .read(libraryCollectionsProvider.notifier)
        .removePlaylistCover(playlistId);
  }

  Widget _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    String title,
    List<CollectionTrackEntry> entries,
    UserPlaylistCollection? playlist,
  ) {
    final expandedHeight = calculateExpandedHeight(context);
    final customCoverPath = playlist?.coverImagePath;
    final isLovedMode = widget.mode == LibraryTracksFolderMode.loved;
    final isPlaylistMode = widget.mode == LibraryTracksFolderMode.playlist;
    final rawCoverUrl = isLovedMode ? null : _firstRawCoverUrl(entries);
    final localCoverUrl =
        rawCoverUrl == null && !isLovedMode && entries.isNotEmpty
        ? ref
              .watch(
                localLibraryFirstCoverProvider(_coverBatchRequest(entries)),
              )
              .maybeWhen(data: (cover) => cover, orElse: () => null)
        : null;
    final coverUrl = rawCoverUrl ?? localCoverUrl;
    final hasCustomCover =
        customCoverPath != null && customCoverPath.isNotEmpty;
    final hasCoverUrl = coverUrl != null;
    // Desktop: Mornye Link transfers of the whole collection while a phone
    // is connected.
    final linkTransfers =
        widget.mode != LibraryTracksFolderMode.wishlist &&
        entries.isNotEmpty &&
        watchDesktopLinkPhones(ref);

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (MediaQuery.sizeOf(context).width * dpr).round().clamp(
      320,
      2048,
    );
    final coverFallback = Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(_modeIcon(), size: 80, color: colorScheme.onSurfaceVariant),
    );
    Widget squarePlaceholder() => Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(_modeIcon(), size: 48, color: colorScheme.onSurfaceVariant),
    );

    final Widget background = hasCustomCover
        ? Image.file(
            File(customCoverPath),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) {
                return child;
              }
              return coverFallback;
            },
            errorBuilder: (_, _, _) => coverFallback,
          )
        : hasCoverUrl
        ? LocalOrNetworkCoverImage(
            url: coverUrl,
            fit: BoxFit.cover,
            localCacheWidth: cacheWidth,
            networkCacheWidth: cacheWidth,
            fadeInDuration: Duration.zero,
            urlTransform: (u) => highResCoverUrl(u) ?? u,
            placeholder: (_) => Container(color: colorScheme.surface),
          )
        : coverFallback;

    return AlbumDetailHeader(
      title: title,
      appBarTitle: isSelectionMode
          ? context.l10n.selectionSelected(selectedIds.length)
          : title,
      expandedHeight: expandedHeight,
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      background: background,
      paletteSource: coverUrl,
      blurAndScrimBackground: hasCustomCover || hasCoverUrl,
      coverBuilder: (context, coverSize) {
        if (hasCustomCover) {
          return Image.file(
            File(customCoverPath),
            fit: BoxFit.cover,
            width: coverSize,
            height: coverSize,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => squarePlaceholder(),
          );
        }
        if (hasCoverUrl) {
          return LocalOrNetworkCoverImage(
            url: coverUrl,
            fit: BoxFit.cover,
            width: coverSize,
            height: coverSize,
            localCacheWidth: cacheWidth,
            networkCacheWidth: cacheWidth,
            urlTransform: (u) => highResCoverUrl(u) ?? u,
            placeholder: (_) => squarePlaceholder(),
          );
        }
        return squarePlaceholder();
      },
      meta: entries.isNotEmpty
          ? HeaderMetaRow(
              items: [
                HeaderMetaItem(
                  context.l10n.tracksCount(entries.length),
                  icon: _modeIcon(),
                ),
              ],
            )
          : null,
      // Play is the one wide action, between Download All and Shuffle.
      actions: entries.isNotEmpty
          ? ExpressiveButtonGroup(
              flexible: const {1},
              spacing: 8,
              children: [
                _buildDownloadAllCenterButton(entries),
                _buildPlayAllCenterButton(entries),
                HeaderCircleButton(
                  key: const ValueKey('collection-shuffle'),
                  icon: Icons.shuffle,
                  tooltip: context.l10n.actionShuffle,
                  tonal: true,
                  onPressed: () => _shuffleAll(
                    entries.map((e) => e.track).toList(growable: false),
                  ),
                ),
              ],
            )
          : null,
      appBarActions: [
        if (!isSelectionMode && entries.isNotEmpty)
          HeaderCircleButton(
            icon: Icons.ios_share,
            iconSize: 20,
            tooltip: context.l10n.collectionExportM3u,
            onPressed: () => _exportAsM3u8(context, title, entries),
          ),
        if (isPlaylistMode &&
            !isSelectionMode &&
            entries.isNotEmpty &&
            ref.watch(linkPhoneClientProvider) != null) ...[
          const SizedBox(width: 8),
          LinkTrackTransferButton(
            tracks: entries.map((e) => e.track).toList(growable: false),
          ),
        ],
        if (isPlaylistMode && !isSelectionMode) ...[
          if (entries.length > 1) ...[
            const SizedBox(width: 8),
            HeaderCircleButton(
              icon: Icons.swap_vert,
              iconSize: 20,
              tooltip: context.l10n.playlistEditOrder,
              onPressed: () {
                final id = widget.playlistId ?? playlist?.id;
                if (id == null || id.isEmpty) return;
                Navigator.of(context).push(
                  slidePageRoute<void>(
                    page: PlaylistReorderPage(playlistId: id),
                  ),
                );
              },
            ),
          ],
          const SizedBox(width: 8),
          HeaderCircleButton(
            icon: Icons.edit_outlined,
            iconSize: 20,
            tooltip: context.l10n.collectionRenamePlaylist,
            onPressed: () {
              final id = widget.playlistId ?? playlist?.id;
              if (id == null || id.isEmpty) return;
              _showRenamePlaylistDialog(context, id, playlist?.name ?? title);
            },
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (buttonContext) => HeaderCircleButton(
              icon: Icons.camera_alt_outlined,
              iconSize: 20,
              tooltip: context.l10n.collectionPlaylistChangeCover,
              onPressed: () =>
                  _showCoverOptionsSheet(buttonContext, hasCustomCover),
            ),
          ),
        ],
      ],
      moreMenu: linkTransfers && !isSelectionMode
          ? () => [
              desktopLinkTransferTrackActions(context, ref, [
                for (final entry in entries) entry.track,
              ]),
            ]
          : null,
      // Centered so the tight leading slot cannot stretch it.
      leading: Center(
        child: HeaderCircleButton(
          icon: isSelectionMode ? Icons.close : Icons.arrow_back,
          tooltip: isSelectionMode
              ? MaterialLocalizations.of(context).closeButtonTooltip
              : MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: isSelectionMode
              ? exitSelectionMode
              : () => Navigator.pop(context),
        ),
      ),
    );
  }

  Widget _buildPlayAllCenterButton(List<CollectionTrackEntry> entries) {
    final tracks = entries.map((e) => e.track).toList(growable: false);
    return HeaderFilledButton(
      icon: Icons.play_arrow_rounded,
      label: context.l10n.tooltipPlay,
      onPressed: tracks.isEmpty ? null : () => _playAll(tracks),
    );
  }

  Widget _buildDownloadAllCenterButton(List<CollectionTrackEntry> entries) {
    final tracks = entries.map((e) => e.track).toList(growable: false);
    return HeaderCircleButton(
      key: const ValueKey('collection-download-all'),
      icon: Icons.download_rounded,
      tooltip: context.l10n.downloadAllCount(tracks.length),
      tonal: true,
      onPressed: tracks.isEmpty ? null : () => _confirmDownloadAll(tracks),
    );
  }

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;

    try {
      await ref.read(musicPlayerControllerProvider).setShuffle(false);
      await ref.read(playbackProvider.notifier).playTrackList(tracks);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarCannotOpenFile('$e'))),
      );
    }
  }

  /// Turns shuffle on and starts from a random song, as album headers do.
  Future<void> _shuffleAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;

    try {
      await ref.read(musicPlayerControllerProvider).setShuffle(true);
      await ref
          .read(playbackProvider.notifier)
          .playTrackList(tracks, startIndex: Random().nextInt(tracks.length));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarCannotOpenFile('$e'))),
      );
    }
  }

  void _confirmDownloadAll(List<Track> tracks) {
    confirmDownloadAllDialog(
      context,
      tracks.length,
      () => _downloadAll(tracks),
    );
  }

  Future<void> _downloadAll(List<Track> tracks) async {
    final playlistName = widget.mode == LibraryTracksFolderMode.playlist
        ? playlist?.name ?? context.l10n.collectionPlaylist
        : null;
    await queueTracksSkippingDownloaded(
      context,
      ref,
      tracks,
      artistNameForPicker: switch (widget.mode) {
        LibraryTracksFolderMode.wishlist => context.l10n.collectionWishlist,
        LibraryTracksFolderMode.loved => context.l10n.collectionLoved,
        LibraryTracksFolderMode.playlist => context.l10n.collectionPlaylist,
      },
      playlistName: playlistName,
      resolveDefaultService: false,
    );
  }

  void _showCoverOptionsSheet(BuildContext context, bool hasCustomCover) {
    final colorScheme = Theme.of(context).colorScheme;
    final menuPosition = isDesktopPlatform
        ? contextMenuPositionBelow(context)
        : null;
    if (menuPosition != null) {
      showContextMenu(
        context,
        position: menuPosition,
        groups: [
          [
            ContextMenuAction(
              icon: Icons.image_outlined,
              label: context.l10n.collectionPlaylistChangeCover,
              onSelected: _pickCoverImage,
            ),
          ],
          if (hasCustomCover)
            [
              ContextMenuAction(
                icon: Icons.delete_outline,
                label: context.l10n.collectionPlaylistRemoveCover,
                destructive: true,
                onSelected: _removeCoverImage,
              ),
            ],
        ],
      );
      return;
    }

    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSheetHandle(),
            const SizedBox(height: 16),
            AppSheetOption(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 4,
              ),
              leading: context.isMornye
                  ? Icon(
                      mornyeIconFor(Icons.image_outlined),
                      color: colorScheme.primary,
                    )
                  : Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.image_outlined,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
              title: Text(context.l10n.collectionPlaylistChangeCover),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickCoverImage();
              },
            ),
            if (hasCustomCover)
              AppSheetOption(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                leading: context.isMornye
                    ? Icon(
                        mornyeIconFor(Icons.delete_outline),
                        color: colorScheme.primary,
                      )
                    : Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.delete_outline,
                          color: colorScheme.onErrorContainer,
                        ),
                      ),
                title: Text(context.l10n.collectionPlaylistRemoveCover),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _removeCoverImage();
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _showRenamePlaylistDialog(
    BuildContext context,
    String playlistId,
    String currentName,
  ) async {
    final nextName = await promptPlaylistName(
      context,
      title: context.l10n.collectionRenamePlaylist,
      confirmLabel: context.l10n.dialogSave,
      initialName: currentName,
    );

    if (nextName == null || nextName.trim().isEmpty || !context.mounted) {
      return;
    }

    await ref
        .read(libraryCollectionsProvider.notifier)
        .renamePlaylist(playlistId, nextName.trim());

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistRenamed)),
    );
  }
}

class _CollectionTrackTile extends ConsumerWidget {
  final CollectionTrackEntry entry;
  final LibraryTracksFolderMode mode;
  final List<Track> folderTracks;
  final int trackIndex;
  final bool isInHistory;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _CollectionTrackTile({
    required this.entry,
    required this.mode,
    required this.folderTracks,
    required this.trackIndex,
    required this.isInHistory,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = entry.track;
    final rawCoverUrl = _resolveRawCoverUrl(track);
    final localCoverUrl = rawCoverUrl == null
        ? ref
              .watch(
                localLibraryCoverProvider(
                  LocalLibraryCoverRequest(
                    isrc: track.isrc?.trim(),
                    trackName: track.name,
                    artistName: track.artistName,
                  ),
                ),
              )
              .maybeWhen(data: (cover) => cover, orElse: () => null)
        : null;
    final effectiveCoverUrl = rawCoverUrl ?? localCoverUrl;

    // Fine-grained provider watches – only this tile rebuilds when its own
    // history / local-library entry changes.
    final inMemoryHistoryItem = ref.watch(
      downloadHistoryProvider.select((state) {
        final byId = state.getBySpotifyId(track.id);
        if (byId != null) return byId;
        final isrc = track.isrc?.trim();
        if (isrc != null && isrc.isNotEmpty) {
          final byIsrc = state.getByIsrc(isrc);
          if (byIsrc != null) return byIsrc;
        }
        return state.findByTrackAndArtist(track.name, track.artistName);
      }),
    );
    final showLocalLibraryIndicator = ref.watch(
      settingsProvider.select(
        (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
      ),
    );
    final isInLocalLibrary = showLocalLibraryIndicator
        ? ref.watch(
            localLibraryProvider.select((state) {
              final isrc = track.isrc?.trim();
              return state.existsInLibrary(
                isrc: isrc,
                trackName: track.name,
                artistName: track.artistName,
              );
            }),
          )
        : false;

    final heroTag = inMemoryHistoryItem != null
        ? 'cover_${inMemoryHistoryItem.id}'
        : null;
    // Material rows mark the current track; Mornye rows show no
    // current-track state.
    final playback = context.isMornye
        ? null
        : ref.watch(catalogTrackPlaybackUiProvider(catalogTrackKey(track)));
    final isCurrent = playback?.isCurrent ?? false;
    final isPlaying = playback?.isPlaying ?? false;

    return TrackCard(
      style: TrackCardStyle.flat,
      isSelectionMode: isSelectionMode,
      isSelected: isSelected,
      isCurrent: isCurrent,
      isPlaying: isPlaying,
      leadingArtwork: true,
      leading: HeroMode(
        enabled: heroTag != null,
        child: Builder(
          builder: (context) {
            final size = context.tokens.coverCompact;
            final cover = ClipRRect(
              borderRadius: context.tokens.borderRadiusThumb,
              child: effectiveCoverUrl != null && effectiveCoverUrl.isNotEmpty
                  ? _buildTrackCover(context, effectiveCoverUrl, size)
                  : TrackCoverPlaceholder(size: size),
            );
            return heroTag != null ? Hero(tag: heroTag, child: cover) : cover;
          },
        ),
      ),
      title: track.name,
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              track.artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isInLocalLibrary || isInHistory) ...[
            const SizedBox(width: 6),
            const InLibraryBadge(),
          ],
        ],
      ),
      // The button reads its colours inside the row, which follow the fill
      // of the current track.
      trailing: isInHistory || isInLocalLibrary
          ? Builder(
              builder: (context) {
                final colorScheme = Theme.of(context).colorScheme;
                return AppIconButton(
                  tooltip: isPlaying
                      ? context.l10n.actionPause
                      : context.l10n.tooltipPlay,
                  onPressed: isCurrent
                      ? () => ref
                            .read(musicPlayerControllerProvider)
                            .togglePlayPause(isPlaying)
                      : () => _playFromHere(context, ref),
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: colorScheme.primary,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: Size.square(context.tokens.minTouchTarget),
                    backgroundColor: colorScheme.primaryContainer.withValues(
                      alpha: 0.3,
                    ),
                  ),
                );
              },
            )
          : null,
      onTap: isSelectionMode
          ? onTap
          : () {
              if (mode == LibraryTracksFolderMode.wishlist) {
                _downloadTrack(context, ref);
                return;
              }

              _navigateToMetadata(context, ref);
            },
      onLongPress: isSelectionMode ? onTap : onLongPress,
    );
  }

  Future<void> _playFromHere(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(playbackProvider.notifier)
          .playTrackList(folderTracks, startIndex: trackIndex);
    } catch (error) {
      if (!context.mounted) return;
      showCannotOpenFileSnackBar(context, error);
    }
  }

  Widget _buildTrackCover(BuildContext context, String coverUrl, double size) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget placeholder() => Container(
      width: size,
      height: size,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
    );

    return LocalOrNetworkCoverImage(
      url: coverUrl,
      width: size,
      height: size,
      networkCacheWidth: (size * 2).toInt(),
      fadeInDuration: const Duration(milliseconds: 180),
      fadeOutDuration: const Duration(milliseconds: 90),
      placeholder: (_) => placeholder(),
    );
  }

  void _downloadTrack(BuildContext context, WidgetRef ref) {
    downloadSingleTrack(context, ref, entry.track);
  }

  Future<void> _navigateToMetadata(BuildContext context, WidgetRef ref) =>
      _openCollectionTrack(context, ref, entry.track);
}

/// Opens the metadata of [track]'s downloaded or library file, or downloads
/// it when there is none.
Future<void> _openCollectionTrack(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final historyNotifier = ref.read(downloadHistoryProvider.notifier);

  var historyItem = await historyNotifier.getBySpotifyIdAsync(track.id);
  if (!context.mounted) return;

  if (historyItem == null && track.isrc != null && track.isrc!.isNotEmpty) {
    historyItem = await historyNotifier.getByIsrcAsync(track.isrc!);
    if (!context.mounted) return;
  }

  historyItem ??= await historyNotifier.findByTrackAndArtistAsync(
    track.name,
    track.artistName,
  );
  if (!context.mounted) return;

  if (historyItem != null) {
    final embeddedCoverPath =
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(
          historyItem.filePath,
        );
    if (!context.mounted) return;
    await precacheMetadataBackdrop(
      context,
      embeddedCoverPath ?? historyItem.coverUrl,
    );
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(slidePageRoute<void>(page: TrackMetadataScreen(item: historyItem)));
    return;
  }

  final localItem = ref.read(settingsProvider).localLibraryEnabled
      ? await ref
            .read(localLibraryProvider.notifier)
            .findExistingAsync(
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            )
      : null;
  if (!context.mounted) return;

  if (localItem != null) {
    await precacheMetadataBackdrop(context, localItem.coverPath);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      slidePageRoute<void>(page: TrackMetadataScreen(localItem: localItem)),
    );
    return;
  }

  downloadSingleTrack(context, ref, track);
}

class _EmptyFolderState extends StatelessWidget {
  final String title;
  final String subtitle;

  const _EmptyFolderState({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open,
              size: 60,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum LibraryTracksFolderMode { wishlist, loved, playlist }
