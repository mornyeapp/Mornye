import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_directory_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_directory_screen.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/services/library_directory_index.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/widgets/desktop/hover_play_button.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';
import 'package:mornye/widgets/track_card.dart';

/// One Library folder: its path and counts, Play and Shuffle over every
/// song under it, the folders inside it, then its own songs. Without
/// [folderKey] it shows the folder the Folders index opens on.
///
/// Songs keep the Library's actions: long-press selection with the Library
/// selection bar on phones, the song table with click selection and the
/// right-click menu on desktop. Desktop also opens a folder under the album
/// pages' header and shows the folders inside it as a grid of covers.
class LibraryDirectoryView extends ConsumerStatefulWidget {
  const LibraryDirectoryView({
    super.key,
    this.folderKey,
    this.showHeader = true,
  });

  final String? folderKey;

  /// False inside the Material Library pager, which has its own header.
  final bool showHeader;

  @override
  ConsumerState<LibraryDirectoryView> createState() =>
      _LibraryDirectoryViewState();
}

class _LibraryDirectoryViewState extends ConsumerState<LibraryDirectoryView>
    with SelectionModeMixin<LibraryDirectoryView> {
  final SelectionOverlayController _selectionOverlay =
      SelectionOverlayController();

  /// Hidden while a sheet or dialog opened from the bar is on screen.
  bool _suppressSelectionBar = false;

  /// The folder's own songs as last built, for the selection and the bar.
  List<UnifiedLibraryItem> _items = const [];

  bool _starting = false;

  @override
  void dispose() {
    _selectionOverlay.dispose();
    super.dispose();
  }

  List<UnifiedLibraryItem> get _selectedItems => [
    for (final item in _items)
      if (selectedIds.contains(item.id)) item,
  ];

  void _finishSelectionAction() {
    if (!mounted) return;
    _suppressSelectionBar = false;
    exitSelectionMode();
    ref.invalidate(libraryDirectoryIndexProvider);
  }

  void _hideSelectionBar() {
    _suppressSelectionBar = true;
    _selectionOverlay.hide();
  }

  Future<void> _restoreSelectionBar({Duration delay = Duration.zero}) async {
    // Wait out the sheet or dialog exit so the bar does not cover it.
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    _suppressSelectionBar = false;
    if (mounted) setState(() {});
  }

  void _syncSelectionBar() {
    if (!mounted) return;
    if (!showsSelectionBar || _suppressSelectionBar) {
      _selectionOverlay.hide();
      return;
    }
    _selectionOverlay.show(context, _buildSelectionBar);
  }

  Widget _buildSelectionBar(BuildContext _) {
    final items = _selectedItems;
    final allSelected = _items.isNotEmpty && items.length == _items.length;
    final flacEligible = items.every((item) => item.localItem != null)
        ? items
              .map((item) => item.localItem!)
              .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
              .toList(growable: false)
        : const <LocalLibraryItem>[];
    return LibraryTrackSelectionBar(
      playbackActions: LibrarySelectionPlaybackActions(
        items: items,
        onClose: exitSelectionMode,
      ),
      selectedCount: items.length,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: allSelected
          ? exitSelectionMode
          : () => selectAll(_items.map((item) => item.id)),
      bottomPadding: MediaQuery.paddingOf(context).bottom,
      flacEligibleCount: flacEligible.length,
      onQueueFlac: () => queueLocalTracksAsFlac(
        context,
        ref,
        flacEligible,
        isActive: () => mounted,
        onComplete: exitSelectionMode,
      ),
      onReEnrich: () => _reEnrich(items),
      onConvert: () => showBatchConvertSheet(
        context,
        ref,
        items,
        onExitSelectionMode: _finishSelectionAction,
        onSheetOpen: _hideSelectionBar,
        onSheetClosed: (_) =>
            _restoreSelectionBar(delay: const Duration(milliseconds: 260)),
      ),
      onReplayGain: ({required remove}) => runBatchReplayGain(
        context,
        items,
        remove: remove,
        onExitSelectionMode: exitSelectionMode,
        onConfirmOpen: _hideSelectionBar,
        onConfirmClosed: (confirmed) => _restoreSelectionBar(
          delay: confirmed ? Duration.zero : const Duration(milliseconds: 220),
        ),
      ),
      onDelete: () => _delete(items),
    );
  }

  Future<void> _reEnrich(List<UnifiedLibraryItem> items) =>
      reEnrichLibraryTracks(
        context,
        ref,
        items,
        isActive: () => mounted,
        onSelectionHide: () async => _hideSelectionBar(),
        onSelectionRestore: _restoreSelectionBar,
        onComplete: _finishSelectionAction,
      );

  Future<void> _delete(List<UnifiedLibraryItem> items) => deleteLibraryTracks(
    context,
    ref,
    items,
    isActive: () => mounted,
    onComplete: _finishSelectionAction,
  );

  PlaybackRowKey _playbackKey(UnifiedLibraryItem item) => (
    id: item.historyItem?.id ?? item.localItem?.id ?? item.id,
    path: item.filePath,
  );

  PlayableMedia _media(UnifiedLibraryItem item) => item.localItem != null
      ? playableFromLocal(item.localItem!)
      : playableFromHistory(item.historyItem!);

  /// Plays [items] from [start], or from the top, or shuffled. CUE virtual
  /// tracks need splitting first, so they are left out of the queue.
  Future<void> _play(
    List<UnifiedLibraryItem> items, {
    UnifiedLibraryItem? start,
    bool shuffle = false,
  }) async {
    if (start != null && isCueVirtualPath(start.filePath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(cueVirtualTrackRequiresSplitMessage)),
      );
      return;
    }
    final playable = items
        .where(
          (item) =>
              item.filePath.trim().isNotEmpty &&
              !isCueVirtualPath(item.filePath),
        )
        .toList(growable: false);
    if (playable.isEmpty) return;
    final index = start != null
        ? max(0, playable.indexWhere((item) => item.id == start.id))
        : shuffle
        ? Random().nextInt(playable.length)
        : 0;
    try {
      if (start == null) {
        await ref.read(musicPlayerControllerProvider).setShuffle(shuffle);
      }
      await ref
          .read(playbackProvider.notifier)
          .playMediaQueue(
            playable.map(_media),
            startIndex: index,
            externalPath: playable[index].filePath,
          );
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  /// Plays every song under [folder]: its own songs, then each folder below.
  Future<void> _playFolder(
    LibraryDirectory folder, {
    bool shuffle = false,
  }) async {
    if (_starting) return;
    _starting = true;
    try {
      final items = await ref.read(libraryDirectoryItemsLoaderProvider)(
        folder.allTracks,
      );
      if (mounted) await _play(items, shuffle: shuffle);
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    } finally {
      _starting = false;
    }
  }

  /// Adds every song under [folder] to a playlist the user picks.
  Future<void> _addFolderToPlaylist(LibraryDirectory folder) async {
    try {
      final items = await ref.read(libraryDirectoryItemsLoaderProvider)(
        folder.allTracks,
      );
      if (!mounted || items.isEmpty) return;
      await showAddTracksToPlaylistSheet(
        Navigator.of(context, rootNavigator: true).context,
        ref,
        [for (final item in items) item.toTrack()],
      );
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  void _openFolder(LibraryDirectory folder) {
    pushPage<void>(
      context,
      (_) => LibraryDirectoryScreen(folderKey: folder.key),
    );
  }

  Future<void> _openDetails(UnifiedLibraryItem item) {
    final local = [for (final item in _items) ?item.localItem];
    final downloads = [for (final item in _items) ?item.historyItem];
    // The details pager steps through one kind of record.
    final localOnly = local.length == _items.length;
    final downloadsOnly = downloads.length == _items.length;
    return pushPage<void>(
      context,
      (_) => TrackMetadataScreen(
        item: item.historyItem,
        localItem: item.localItem,
        localNavigationItems: localOnly ? local : null,
        historyNavigationItems: downloadsOnly ? downloads : null,
        navigationIndex: localOnly || downloadsOnly
            ? _items.indexWhere((entry) => entry.id == item.id)
            : null,
      ),
    );
  }

  Future<void> _showFolderMenu(LibraryDirectory folder, Offset position) async {
    final items = await ref.read(libraryDirectoryItemsLoaderProvider)(
      folder.allTracks,
    );
    if (!mounted) return;
    final l10n = context.l10n;
    final groups = libraryTrackMenuGroups(
      context,
      ref,
      items: items,
      onPlay: () => _play(items),
    );
    if (groups.isNotEmpty) {
      groups.first.insert(
        1,
        ContextMenuAction(
          icon: Icons.shuffle,
          label: l10n.actionShuffle,
          onSelected: () => _play(items, shuffle: true),
        ),
      );
    }
    await showContextMenu(
      context,
      position: position,
      groups: [
        [
          ContextMenuAction(
            icon: Icons.folder_open_outlined,
            label: l10n.desktopMenuOpen,
            onSelected: () => _openFolder(folder),
          ),
        ],
        ...groups,
      ],
    );
  }

  Future<bool> _showSongMenu(UnifiedLibraryItem item, Offset position) {
    final items = _selectedItems;
    return showContextMenu(
      context,
      position: position,
      groups: libraryTrackMenuGroups(
        context,
        ref,
        items: items,
        onPlay: () => _play(_items, start: item),
        onOpenDetails: () => _openDetails(item),
        onDone: exitSelectionMode,
        onReEnrich: () => _reEnrich(items),
        onConvert: () => showBatchConvertSheet(
          context,
          ref,
          items,
          onExitSelectionMode: _finishSelectionAction,
        ),
        onDelete: () => _delete(items),
      ),
    );
  }

  String _summary(LibraryDirectory folder) => [
    if (folder.folders.isNotEmpty)
      context.l10n.libraryFolderCount(folder.folders.length),
    if (folder.trackCount > 0) context.l10n.queueTrackCount(folder.trackCount),
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final indexValue = ref.watch(libraryDirectoryIndexProvider);
    final index = indexValue.value;
    final key = widget.folderKey;
    final folder = index == null
        ? null
        : (key == null ? index.root : index[key]);
    final title = key == null || folder == null
        ? context.l10n.libraryFolders
        : folder.name;
    // A folder that lost its songs keeps no selectable rows.
    _items = const [];
    if (folder == null || folder.trackCount == 0) pruneSelection(const {});
    // A folder opened on desktop takes the album pages' header.
    final detailHeader =
        isDesktopPlatform &&
        widget.showHeader &&
        key != null &&
        folder != null &&
        folder.trackCount > 0;
    final List<Widget> body;
    if (folder != null && folder.trackCount > 0) {
      body = _buildFolder(context, folder, summary: !detailHeader);
    } else if (index == null && indexValue.hasError) {
      body = [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.error_outline,
            title: context.l10n.libraryFoldersLoadFailed,
            action: ExpressiveButton(
              text: true,
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(libraryDirectoryIndexProvider),
              child: Text(context.l10n.dialogRetry),
            ),
          ),
        ),
      ];
    } else if (index == null) {
      body = const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: AppLoadingIndicator()),
        ),
      ];
    } else {
      body = [
        SliverFillRemaining(
          hasScrollBody: false,
          child: key == null
              ? EmptyState(
                  icon: Icons.folder_outlined,
                  title: context.l10n.libraryFoldersEmptyTitle,
                  message: context.l10n.libraryFoldersEmptyMessage,
                )
              : EmptyState(
                  icon: Icons.folder_off_outlined,
                  title: context.l10n.libraryFolderMissing,
                ),
        ),
      ];
    }
    if (showsSelectionBar || _selectionOverlay.isVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncSelectionBar());
    }
    final scrollView = CustomScrollView(
      key: PageStorageKey('library-folder:${key ?? ''}'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (detailHeader)
          ..._desktopHeader(context, folder)
        else if (widget.showHeader)
          AppSliverHeader.page(title: title),
        ...body,
        // Same reserve as the Library list, so the last rows can scroll
        // clear of the selection bar; desktop pages scroll under the
        // floating player.
        if (showsSelectionBar)
          const SliverToBoxAdapter(child: SizedBox(height: 100))
        else if (isDesktopPlatform)
          const SliverToBoxAdapter(
            child: SizedBox(height: desktopDetailBottomInset),
          ),
        const NavBarSliverSpacer(),
      ],
    );
    final items = _items;
    return PopScope(
      canPop: !isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isSelectionMode) exitSelectionMode();
      },
      child: DesktopListScope(
        onSelectAll: items.isEmpty
            ? null
            : () => selectAll(items.map((item) => item.id)),
        onClearSelection: isSelectionMode ? exitSelectionMode : null,
        onDelete: isSelectionMode ? () => _delete(_selectedItems) : null,
        onActivate: () {
          final anchor = items
              .where((item) => item.id == selectionAnchorId)
              .firstOrNull;
          if (anchor != null) _play(items, start: anchor);
        },
        child: AppRefreshIndicator(
          onRefresh: () async {
            ref.invalidate(libraryDirectoryIndexProvider);
            await ref.read(libraryDirectoryIndexProvider.future);
          },
          child: scrollView,
        ),
      ),
    );
  }

  /// Play, Shuffle and, on desktop, Add to Playlist over every song under
  /// [folder].
  Widget _playActions(LibraryDirectory folder) => AlbumPlayActions(
    playLabel: context.l10n.tooltipPlay,
    shuffleTooltip: context.l10n.actionShuffle,
    onPlay: () => _playFolder(folder),
    onShuffle: () => _playFolder(folder, shuffle: true),
    onAddToPlaylist: () => _addFolderToPlaylist(folder),
  );

  /// The album pages' desktop header: the folder's cover, name and path,
  /// its counts and the folder-wide actions.
  List<Widget> _desktopHeader(BuildContext context, LibraryDirectory folder) =>
      desktopDetailHeaderSlivers(
        context,
        title: folder.name,
        artwork: (context, size) =>
            _FolderArtwork(folder: folder, size: size, radius: 0),
        paletteSource: folder.cover,
        // A volume's top folder is already named by its path.
        subtitle: folder.name == folder.path
            ? null
            // Built inside the header, so Material reads its artwork scheme.
            : Builder(
                builder: (header) => Text(
                  folder.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(header).textTheme.titleMedium?.copyWith(
                    color: Theme.of(header).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
        meta: HeaderMetaRow(
          items: [
            if (folder.folders.isNotEmpty)
              HeaderMetaItem(
                context.l10n.libraryFolderCount(folder.folders.length),
              ),
            HeaderMetaItem(context.l10n.queueTrackCount(folder.trackCount)),
          ],
        ),
        actions: _playActions(folder),
      );

  List<Widget> _buildFolder(
    BuildContext context,
    LibraryDirectory folder, {
    required bool summary,
  }) {
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final desktop = isDesktopPlatform;
    final inset = wideListInset(context);
    // Desktop lines up with the detail header's artwork.
    final gutter = (mornye || desktop ? 20.0 : tokens.gapLg) + inset;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final songsValue = folder.tracks.isEmpty
        ? null
        : ref.watch(libraryDirectoryTracksProvider(folder.key));
    final items = songsValue?.value ?? const <UnifiedLibraryItem>[];
    if (songsValue == null || songsValue.hasValue) {
      _items = items;
      pruneSelection(items.map((item) => item.id).toSet());
    }
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (folder.key.isNotEmpty)
          Text(
            folder.path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        Text(
          _summary(folder),
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    // Desktop names the folders and the songs when a folder holds both.
    final sectionTitles =
        desktop && folder.folders.isNotEmpty && folder.tracks.isNotEmpty;
    Widget sectionTitle(String text) => SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          gutter,
          tokens.gapLg,
          gutter,
          tokens.gapMd,
        ),
        child: Text(
          text,
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
    );
    return [
      if (summary)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              gutter,
              widget.showHeader ? 0 : tokens.gapMd,
              gutter,
              tokens.gapMd,
            ),
            // Desktop keeps the actions beside the path, as a toolbar.
            child: desktop
                ? Row(
                    children: [
                      Expanded(child: details),
                      SizedBox(width: tokens.gapLg),
                      _playActions(folder),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      details,
                      SizedBox(height: tokens.gapMd),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: _playActions(folder),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      if (sectionTitles) sectionTitle(context.l10n.libraryFolders),
      if (folder.folders.isNotEmpty && desktop)
        _folderGrid(folder, gutter)
      else if (folder.folders.isNotEmpty)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverList.builder(
            itemCount: folder.folders.length,
            itemBuilder: (context, index) => TrackCardSegment.at(
              key: ValueKey('folder:${folder.folders[index].key}'),
              index: index,
              count: folder.folders.length,
              child: _folderRow(folder, folder.folders[index]),
            ),
          ),
        ),
      if (sectionTitles)
        sectionTitle(context.l10n.searchSongs)
      else if (folder.folders.isNotEmpty && folder.tracks.isNotEmpty)
        SliverToBoxAdapter(child: SizedBox(height: tokens.gapMd)),
      if (songsValue == null)
        const SliverToBoxAdapter(child: SizedBox.shrink())
      else if (!songsValue.hasValue && songsValue.hasError)
        SliverToBoxAdapter(
          child: Center(
            child: ExpressiveButton(
              text: true,
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  ref.invalidate(libraryDirectoryTracksProvider(folder.key)),
              child: Text(context.l10n.dialogRetry),
            ),
          ),
        )
      else if (!songsValue.hasValue)
        SliverToBoxAdapter(
          child: TrackListSkeleton(itemCount: min(folder.tracks.length, 8)),
        )
      else if (isDesktopPlatform)
        _songTable(context, items)
      else
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, index) => TrackCardSegment.at(
              key: ValueKey(items[index].id),
              index: index,
              count: items.length,
              child: _songRow(context, items, items[index]),
            ),
          ),
        ),
    ];
  }

  /// Desktop shows folders as a grid of covers like the album grids: Play
  /// on hover, the folder menu on right click.
  Widget _folderGrid(LibraryDirectory parent, double gutter) {
    final spacing = context.isMornye ? 20.0 : 12.0;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: gutter),
      sliver: SliverLayoutInfoBuilder(
        select: (constraints) => constraints.crossAxisExtent,
        builder: (context, crossAxisExtent) {
          // Cells of up to 180, as in the Library album grid.
          final columns = max(2, (crossAxisExtent / (180 + spacing)).ceil());
          final width = (crossAxisExtent - spacing * (columns - 1)) / columns;
          final textHeight =
              MediaQuery.textScalerOf(context).scale(16) * 3.2 + 24;
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: spacing,
              mainAxisSpacing: 16,
              mainAxisExtent: width + textHeight,
            ),
            itemCount: parent.folders.length,
            itemBuilder: (context, index) => KeyedSubtree(
              key: ValueKey('folder:${parent.folders[index].key}'),
              child: _folderTile(parent.folders[index], width),
            ),
          );
        },
      ),
    );
  }

  Widget _folderTile(LibraryDirectory folder, double size) {
    final mornye = context.isMornye;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      child: DesktopContextMenuRegion(
        onContextMenu: (position) => _showFolderMenu(folder, position),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openFolder(folder),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _FolderArtwork(
                      folder: folder,
                      size: size,
                      radius: mornye ? 8 : 12,
                    ),
                    DesktopHoverPlayButton(
                      tooltip: context.l10n.tooltipPlay,
                      onPlay: () => _playFolder(folder),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mornye
                    ? const TextStyle(fontSize: 16)
                    : textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
              ),
              Text(
                _summary(folder),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mornye
                    ? TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      )
                    : textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _folderRow(LibraryDirectory parent, LibraryDirectory folder) {
    return TrackCard(
      style: context.isMornye ? TrackCardStyle.flat : TrackCardStyle.filled,
      leading: _FolderArtwork(folder: folder),
      leadingArtwork: folder.cover != null,
      // Top-level entries of several volumes read as their paths.
      title: parent.key.isEmpty ? folder.path : folder.name,
      subtitle: Text(
        _summary(folder),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const AppIcon.adaptive(Icons.chevron_right),
      onTap: isSelectionMode ? null : () => _openFolder(folder),
      onContextMenu: (position) => _showFolderMenu(folder, position),
    );
  }

  Widget _songRow(
    BuildContext context,
    List<UnifiedLibraryItem> items,
    UnifiedLibraryItem item,
  ) {
    final qualityMode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final quality = item.qualityForMode(qualityMode);
    return Consumer(
      builder: (context, ref, _) {
        final playback = ref.watch(
          mediaItemPlaybackUiProvider(_playbackKey(item)),
        );
        return TrackCard(
          style: context.isMornye ? TrackCardStyle.flat : TrackCardStyle.filled,
          leading: _SongArtwork(item: item, size: context.tokens.coverList),
          leadingArtwork: true,
          title: item.trackName,
          subtitle: Text(
            [item.artistName, ?quality].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          isCurrent: playback.isCurrent,
          isPlaying: playback.isPlaying,
          trailing: AppIconButton(
            tooltip: playback.isPlaying
                ? context.l10n.actionPause
                : context.l10n.tooltipPlay,
            icon: Icon(
              playback.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
            ),
            // The current song pauses and resumes in place.
            onPressed: playback.isCurrent
                ? () => ref
                      .read(musicPlayerControllerProvider)
                      .togglePlayPause(playback.isPlaying)
                : () => _play(items, start: item),
          ),
          isSelectionMode: isSelectionMode,
          isSelected: selectedIds.contains(item.id),
          onTap: isSelectionMode
              ? () => toggleSelection(item.id)
              : () => _openDetails(item),
          onLongPress: isSelectionMode
              ? () => toggleSelection(item.id)
              : () => enterSelectionMode(item.id),
          onContextMenu: (position) =>
              showSelectionMenu(item.id, () => _showSongMenu(item, position)),
        );
      },
    );
  }

  Widget _songTable(BuildContext context, List<UnifiedLibraryItem> items) {
    final qualityMode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final byId = {for (final item in items) item.id: item};
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverTrackTable(
        rows: [
          for (final item in items)
            TrackTableRow(
              id: item.id,
              title: item.trackName,
              artist: item.artistName,
              album: item.albumName,
              quality: item.qualityForMode(qualityMode),
              duration: switch (item.historyItem?.duration ??
                  item.localItem?.duration) {
                final seconds? when seconds > 0 => Duration(seconds: seconds),
                _ => null,
              },
              leading: _SongArtwork(item: item, size: 32),
              playback: mediaItemPlaybackUiProvider(_playbackKey(item)),
            ),
        ],
        columns: const [
          TrackTableColumn.title,
          TrackTableColumn.artist,
          TrackTableColumn.album,
          TrackTableColumn.quality,
          TrackTableColumn.duration,
        ],
        selectedIds: selectedIds,
        onSelect: applyDesktopClick,
        onActivate: (id) {
          final item = byId[id];
          if (item != null) _play(items, start: item);
        },
        onContextMenu: (id, position) {
          final item = byId[id];
          if (item == null) return;
          showSelectionMenu(id, () => _showSongMenu(item, position));
        },
      ),
    );
  }
}

/// The cover of the folder's first song, or a folder glyph for a folder
/// whose songs have none or that only holds folders.
class _FolderArtwork extends StatelessWidget {
  const _FolderArtwork({required this.folder, this.size, this.radius = 8});

  final LibraryDirectory folder;

  /// The list cover size when null.
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = this.size ?? context.tokens.coverList;
    Widget glyph(BuildContext context) => ColoredBox(
      color: colorScheme.secondaryContainer,
      child: Center(
        child: AppIcon.adaptive(
          Icons.folder_outlined,
          size: min(size * 0.45, 72),
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
    final cover = folder.cover;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: cover == null
            ? glyph(context)
            : LocalOrNetworkCoverImage(
                url: cover,
                localCacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                placeholder: glyph,
              ),
      ),
    );
  }
}

/// A song's artwork: the download's cover, or the scanned file's thumbnail
/// with its embedded artwork recovered when the thumbnail is gone.
class _SongArtwork extends StatelessWidget {
  const _SongArtwork({required this.item, required this.size});

  final UnifiedLibraryItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget placeholder(BuildContext context) => ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: AppIcon.adaptive(
          Icons.music_note,
          size: size * 0.45,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    Widget image(String? cover) => cover == null || cover.isEmpty
        ? placeholder(context)
        : LocalOrNetworkCoverImage(
            url: cover,
            localCacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                .round(),
            placeholder: placeholder,
          );
    final local = item.localItem;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 40 ? 8 : 4),
      child: SizedBox.square(
        dimension: size,
        child: local == null
            ? image(item.coverUrl)
            : LocalLibraryArtworkBuilder(
                coverPath: local.coverPath,
                filePath: local.filePath,
                builder: (context, cover) => image(cover),
              ),
      ),
    );
  }
}
