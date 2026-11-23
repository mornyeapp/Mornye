import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
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
import 'package:mornye/widgets/home_pin_action.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/page_transitions.dart';
import 'package:mornye/widgets/song_row_tap.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/queue_swipe.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/header_toolbar_actions.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/home_pin.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/m3u_playlist_service.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/track_file_resolver.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/collection_track_files_provider.dart';
import 'package:mornye/providers/collection_track_sort_provider.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/confirm_and_delete_tracks.dart';
import 'package:mornye/controllers/library_tracks_folder_data.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/widgets/collection_reorder_sliver.dart';
import 'package:mornye/widgets/collection_track_sort_button.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/destructive_selection_button.dart';
import 'package:mornye/widgets/in_library_badge.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/link/link_keep_actions.dart';
import 'package:mornye/widgets/network_offline_actions.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/collection_suggestions_section.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/services/playable_media.dart';

export 'package:mornye/models/library_collections.dart'
    show LibraryTracksFolderMode;

String? _resolveRawCoverUrl(Track track) =>
    LocalLibraryCoverRequest.of(track).cover;

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

  /// The looked-up cover of each desktop row by entry key. The last answer
  /// stays while a changed list is looked up again.
  Map<String, String?> _desktopCovers = const {};
  List<CollectionTrackEntry>? _orderDraft;
  List<String> _orderBefore = const [];
  bool _savingOrder = false;
  bool _draggingOrder = false;
  bool _confirmingDiscard = false;
  bool _trackActionInProgress = false;

  /// The songs in their saved order, which Edit order and the M3U export
  /// use whatever sort the page shows.
  List<CollectionTrackEntry> _savedEntries = const [];
  List<CollectionTrackEntry>? _sortedFrom;
  CollectionTrackSort? _sortedBy;
  List<CollectionTrackEntry> _sorted = const [];

  String get _sortKey => switch (widget.mode) {
    LibraryTracksFolderMode.wishlist => 'wishlist',
    LibraryTracksFolderMode.loved => 'loved',
    LibraryTracksFolderMode.playlist => playlistTrackSortKey(
      widget.playlistId ?? '',
    ),
  };

  /// [entries] in the page's sort, the same list until either changes.
  List<CollectionTrackEntry> _sortedEntries(
    List<CollectionTrackEntry> entries,
    CollectionTrackSort sort,
  ) {
    if (!identical(entries, _sortedFrom) || sort != _sortedBy) {
      _sortedFrom = entries;
      _sortedBy = sort;
      _sorted = sortCollectionEntries(entries, sort);
    }
    return _sorted;
  }

  bool get _editingOrder => _orderDraft != null;
  bool get _orderChanged =>
      _orderDraft?.indexed.any(
        (item) => item.$2.key != _orderBefore[item.$1],
      ) ??
      false;

  void _editOrder(List<CollectionTrackEntry> entries) {
    exitSelectionMode();
    setState(() {
      _orderDraft = [...entries];
      _orderBefore = [for (final entry in entries) entry.key];
      _draggingOrder = false;
    });
  }

  Future<void> _cancelOrder() async {
    if (_savingOrder || _confirmingDiscard) return;
    _confirmingDiscard = true;
    try {
      if (_orderChanged && !await showDiscardChangesDialog(context)) return;
      if (mounted) {
        setState(() {
          _orderDraft = null;
          _draggingOrder = false;
        });
      }
    } finally {
      _confirmingDiscard = false;
    }
  }

  Future<void> _saveOrder() async {
    final draft = _orderDraft;
    if (draft == null || _savingOrder || _draggingOrder) return;
    setState(() => _savingOrder = true);
    try {
      final keys = [for (final entry in draft) entry.key];
      final notifier = ref.read(libraryCollectionsProvider.notifier);
      final saved = widget.mode == LibraryTracksFolderMode.playlist
          ? await notifier.reorderPlaylistTracks(widget.playlistId!, keys)
          : await notifier.reorderSavedTracks(widget.mode, keys);
      if (!mounted) return;
      // The page shows the order that was just saved.
      ref
          .read(collectionTrackSortsProvider.notifier)
          .setSort(_sortKey, CollectionTrackSort.custom);
      setState(() => _orderDraft = null);
      showAppSnackBar(
        context,
        content: Text(
          saved
              ? context.l10n.collectionOrderSaved
              : context.l10n.collectionOrderChanged,
        ),
      );
    } on Object {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.collectionOrderSaveFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _savingOrder = false);
    }
  }

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
    return LocalLibraryCoverBatchRequest([
      for (final entry in entries) LocalLibraryCoverRequest.of(entry.track),
    ]);
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
    List<CollectionTrackEntry> entries;

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

    _savedEntries = entries;
    final sort = ref.watch(
      collectionTrackSortsProvider.select(
        (sorts) => sorts[_sortKey] ?? CollectionTrackSort.custom,
      ),
    );
    entries = _orderDraft ?? _sortedEntries(entries, sort);
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
    final existingHistoryKeys = _editingOrder
        ? const <String>{}
        : ref.watch(
            downloadHistoryVisibleBatchExistsProvider(
              _folderData.historyRequest,
            ),
          );

    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    final inHistory = _folderData.inHistory(existingHistoryKeys);
    final ids = [for (final entry in entries) entry.key];
    slideSelectIds = ids;
    // The desktop table builds every row at once, so one lookup answers the
    // covers the rows cannot load from their own stored path.
    if (isDesktopPlatform &&
        !_editingOrder &&
        entries.any(
          (entry) =>
              !collectionCoverIsPortable(_resolveRawCoverUrl(entry.track)),
        )) {
      final covers = ref
          .watch(localLibraryCoversProvider(_coverBatchRequest(entries)))
          .maybeWhen(data: (covers) => covers, orElse: () => null);
      if (covers != null && covers.length == entries.length) {
        _desktopCovers = {
          for (var i = 0; i < entries.length; i++) entries[i].key: covers[i],
        };
      }
    }
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
        if (_editingOrder)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                connectedRunTitleInset + wideListInset(context),
                16,
                connectedRunTitleInset + wideListInset(context),
                12,
              ),
              child: Text(context.l10n.playlistEditOrderDescription),
            ),
          ),
        if (entries.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyFolderState(
              title: emptyTitle,
              subtitle: emptySubtitle,
            ),
          )
        else if (_editingOrder)
          CollectionReorderSliver(
            entries: entries,
            enabled: !_savingOrder,
            onDraggingChanged: (dragging) {
              if (mounted) setState(() => _draggingOrder = dragging);
            },
            onReorder: (oldIndex, newIndex) {
              if (_orderDraft == null || _savingOrder) return;
              setState(() {
                final next = [..._orderDraft!];
                next.insert(newIndex, next.removeAt(oldIndex));
                _orderDraft = next;
              });
            },
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
            covers: [
              for (final entry in entries)
                _desktopCovers.containsKey(entry.key)
                    ? _desktopCovers[entry.key]
                    : entry.track.coverUrl,
            ],
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: wideListInset(context),
            ).copyWith(top: collectionRunTopGap(context)),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final entry = entries[index];
                final isSelected = selectedIds.contains(entry.key);
                final isInHistory = inHistory[index];
                return TrackCardSegment.at(
                  key: ValueKey(entry.key),
                  index: index,
                  count: entries.length,
                  child: slideSelectRow(
                    entry.key,
                    StaggeredListItem(
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
                        onLongPress: () => holdToSelect(entry.key),
                      ),
                    ),
                  ),
                );
              }, childCount: entries.length),
            ),
          ),
        if (playlist case final playlist?
            when playlist.tracks.isNotEmpty &&
                !showsSelectionBar &&
                !_editingOrder)
          CollectionSuggestionsSliver(
            collectionKey: 'playlist:${playlist.id}',
            // The newest additions say most about where the playlist goes.
            tracks: _folderData.newestFirstTracks,
            playlistId: playlist.id,
          ),
      ],
    );
    return PopScope(
      canPop: !_editingOrder,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editingOrder) _cancelOrder();
      },
      child: DesktopListScope(
        onSelectAll: entries.isEmpty || _editingOrder
            ? null
            : () => selectAll(ids),
        onClearSelection: _editingOrder
            ? _cancelOrder
            : isSelectionMode
            ? exitSelectionMode
            : null,
        onDelete: isSelectionMode ? () => _removeSelected(entries) : null,
        onActivate: () {
          if (_editingOrder) return;
          final index = entries.indexWhere(
            (entry) => entry.key == selectionAnchorId,
          );
          if (index >= 0) {
            _activateEntry(entries, folderTracks, inHistory, index);
          }
        },
        child: scaffold,
      ),
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

  CollectionTrackFilesRequest _selectedTrackFiles(
    List<CollectionTrackEntry> entries,
  ) => CollectionTrackFilesRequest([
    for (final entry in entries)
      if (selectedIds.contains(entry.key)) entry.track,
  ]);

  Future<void> _queueSelectedAsFlac(List<LocalLibraryItem> items) =>
      queueLocalTracksAsFlac(
        context,
        ref,
        items,
        isActive: () => mounted,
        onComplete: exitSelectionMode,
      );

  Future<void> _playSelectedFiles(
    List<PlayableMedia> media, {
    bool? playNext,
  }) async {
    if (media.isEmpty || _trackActionInProgress) return;
    setState(() => _trackActionInProgress = true);
    try {
      if (playNext == null) {
        await ref
            .read(playbackProvider.notifier)
            .playMediaQueue(
              media,
              startIndex: 0,
              externalPath: media.first.source,
            );
      } else {
        await ref
            .read(musicPlayerControllerProvider)
            .enqueueMedia(media, playNext: playNext);
      }
      if (mounted) exitSelectionMode();
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _trackActionInProgress = false);
    }
  }

  Future<void> _deleteSelectedFiles(List<PlayableMedia> media) async {
    final paths = {
      for (final item in media)
        if (!item.isNetwork && !isCueVirtualPath(item.source)) item.source,
    }.toList();
    if (paths.isEmpty || _trackActionInProgress) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _trackActionInProgress = true);
    try {
      await confirmAndDeleteTracks(
        context: context,
        ids: paths,
        message: context.l10n.collectionDeleteFilesMessage(paths.length),
        deleteItem: deleteFile,
        persistDeletedItems: (deleted) =>
            removeDeletedLibraryFileEntries(container, deleted),
        onExitSelectionMode: () {
          if (mounted) exitSelectionMode();
        },
      );
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _trackActionInProgress = false);
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
  ) async {
    final l10n = context.l10n;
    final count = selectedIds.length;
    final isPlaylist = widget.mode == LibraryTracksFolderMode.playlist;
    final request = _selectedTrackFiles(entries);
    final flacCandidates = ref
        .read(collectionTrackFlacCandidatesProvider(request).future)
        .catchError((Object _) => <LocalLibraryItem>[]);
    final media = await ref
        .read(collectionTrackFilesProvider(request).future)
        .catchError((Object _) => <PlayableMedia>[]);
    final flacEligible = await flacCandidates;
    if (!mounted ||
        !context.mounted ||
        request != _selectedTrackFiles(entries)) {
      return false;
    }
    final showPlayer = ref.read(playerUiEnabledProvider);
    final localCount = media
        .where((item) => !item.isNetwork)
        .map((item) => item.source)
        .toSet()
        .length;
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
          if (flacEligible.isNotEmpty)
            ContextMenuAction(
              icon: Icons.download_for_offline_outlined,
              label: '${l10n.queueFlacAction} (${flacEligible.length})',
              onSelected: () => _queueSelectedAsFlac(flacEligible),
            ),
          if (showPlayer && media.isNotEmpty)
            for (final next in [true, false])
              ContextMenuAction(
                icon: next ? Icons.playlist_play : Icons.queue_music,
                label: next ? l10n.trackPlayNext : l10n.trackAddToQueue,
                onSelected: () => _playSelectedFiles(media, playNext: next),
              ),
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
          if (localCount > 0)
            ContextMenuAction(
              icon: Icons.delete_outline,
              label: l10n.selectionDeleteTracksCount(localCount),
              destructive: true,
              onSelected: () => _deleteSelectedFiles(media),
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
    final request = _selectedTrackFiles(entries);
    final files = selectedCount == 0
        ? const <PlayableMedia>[]
        : ref.watch(collectionTrackFilesProvider(request)).value ??
              const <PlayableMedia>[];
    final flacEligible = selectedCount == 0
        ? const <LocalLibraryItem>[]
        : ref.watch(collectionTrackFlacCandidatesProvider(request)).value ??
              const <LocalLibraryItem>[];
    final showPlayer = ref.watch(playerUiEnabledProvider);
    final localCount = files
        .where((item) => !item.isNetwork)
        .map((item) => item.source)
        .toSet()
        .length;
    final canPlay = files.isNotEmpty && !_trackActionInProgress;
    final deleteLabel = context.l10n.selectionDeleteTracksCount(localCount);

    return buildSelectionBar(
      ids: ids,
      bottomPadding: bottomPadding,
      children: [
        SelectionActionGrid(
          children: [
            if (flacEligible.isNotEmpty)
              SelectionActionButton(
                icon: Icons.download_for_offline_outlined,
                label:
                    '${context.l10n.queueFlacAction} (${flacEligible.length})',
                onPressed: _trackActionInProgress
                    ? null
                    : () => _queueSelectedAsFlac(flacEligible),
                colorScheme: colorScheme,
              ),
            SelectionActionButton(
              icon: Icons.play_arrow,
              label: context.l10n.tooltipPlay,
              onPressed: canPlay ? () => _playSelectedFiles(files) : null,
              colorScheme: colorScheme,
            ),
            if (showPlayer)
              for (final next in [true, false])
                SelectionActionButton(
                  icon: next ? Icons.playlist_play : Icons.queue_music,
                  label: next
                      ? context.l10n.trackPlayNext
                      : context.l10n.trackAddToQueue,
                  onPressed: canPlay
                      ? () => _playSelectedFiles(files, playNext: next)
                      : null,
                  colorScheme: colorScheme,
                ),
            if (isWishlist)
              SelectionActionButton(
                icon: Icons.download,
                label: '${context.l10n.settingsDownload} ($selectedCount)',
                onPressed: selectedCount > 0
                    ? () => _downloadSelected(entries)
                    : null,
                colorScheme: colorScheme,
              ),
            SelectionActionButton(
              icon: Icons.playlist_add,
              label: '${context.l10n.collectionAddToPlaylist} ($selectedCount)',
              onPressed: selectedCount > 0
                  ? () => _addSelectedToPlaylist(entries)
                  : null,
              colorScheme: colorScheme,
            ),
            // Removing entries keeps the files, so it stays a plain action.
            // Desktop keeps file deletion a toolbar button beside it, as in
            // the Library selection bar.
            SelectionActionButton(
              onPressed: selectedCount > 0
                  ? () => _removeSelected(entries)
                  : null,
              icon: Icons.remove_circle_outline,
              colorScheme: colorScheme,
              label: selectedCount > 0
                  ? '${widget.mode == LibraryTracksFolderMode.playlist ? context.l10n.collectionRemoveFromPlaylist : context.l10n.collectionRemoveFromFolder} ($selectedCount)'
                  : widget.mode == LibraryTracksFolderMode.playlist
                  ? context.l10n.collectionRemoveFromPlaylist
                  : context.l10n.collectionRemoveFromFolder,
            ),
            if (isDesktopPlatform && localCount > 0)
              SelectionActionButton(
                icon: Icons.delete_outline,
                label: deleteLabel,
                colorScheme: colorScheme,
                destructive: true,
                onPressed: _trackActionInProgress
                    ? null
                    : () => _deleteSelectedFiles(files),
              ),
          ],
        ),
        if (!isDesktopPlatform && localCount > 0) ...[
          const SizedBox(height: 8),
          DestructiveSelectionButton(
            count: _trackActionInProgress ? 0 : localCount,
            colorScheme: colorScheme,
            label: deleteLabel,
            onPressed: () => _deleteSelectedFiles(files),
          ),
        ],
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
    // A stored file path can name a file this device does not have, so the
    // Library answers every cover that is not a web address.
    final coverUrl =
        isLovedMode || entries.isEmpty || collectionCoverIsPortable(rawCoverUrl)
        ? rawCoverUrl
        : ref
              .watch(
                localLibraryFirstCoverProvider(_coverBatchRequest(entries)),
              )
              .maybeWhen(data: (cover) => cover, orElse: () => rawCoverUrl);
    final hasCustomCover =
        customCoverPath != null && customCoverPath.isNotEmpty;
    final hasCoverUrl = coverUrl != null;
    // Desktop: Mornye Link transfers of the whole collection while a phone
    // is connected.
    final linkTransfers =
        widget.mode != LibraryTracksFolderMode.wishlist &&
        entries.isNotEmpty &&
        watchDesktopLinkPhones(ref);
    final moreMenu =
        !isSelectionMode &&
            !_editingOrder &&
            (entries.isNotEmpty || isPlaylistMode)
        ? () => _moreMenuGroups(
            title,
            entries,
            playlist,
            linkTransfers: linkTransfers,
          )
        : null;

    final cacheWidth = detailHeaderCoverCacheWidth(context);
    final coverFallback = Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(_modeIcon(), size: 80, color: colorScheme.onSurfaceVariant),
    );
    Widget squarePlaceholder() => Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(_modeIcon(), size: 48, color: colorScheme.onSurfaceVariant),
    );

    final Widget background = hasCustomCover
        ? LocalOrNetworkCoverImage(
            url: customCoverPath,
            localCacheWidth: cacheWidth,
            fadeInDuration: Duration.zero,
            placeholder: (_) => coverFallback,
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
    final toolbarActions = <Widget>[
      if (_editingOrder)
        ExpressiveButton(
          key: const ValueKey('collection-order-save'),
          text: true,
          onPressed: !_orderChanged || _savingOrder || _draggingOrder
              ? null
              : _saveOrder,
          child: Text(context.l10n.dialogSave),
        ),
      if (!_editingOrder && !isSelectionMode && entries.length > 1)
        CollectionTrackSortButton(sortKey: _sortKey),
      // The desktop header adds its own from [moreMenu].
      if (moreMenu != null && !isDesktopPlatform)
        HeaderMoreButton(groups: moreMenu),
    ];

    return AlbumDetailHeader(
      title: title,
      appBarTitle: _editingOrder
          ? context.l10n.playlistEditOrder
          : isSelectionMode
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
          ? LinkKeptMetaRow(
              collection: _keptCollection(playlist),
              items: [
                HeaderMetaItem(
                  context.l10n.tracksCount(entries.length),
                  icon: _modeIcon(),
                ),
              ],
            )
          : null,
      // Play is the one wide action, between Download All and Shuffle.
      actions: entries.isNotEmpty && !_editingOrder
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
        if (toolbarActions.isNotEmpty)
          HeaderToolbarGroup(children: toolbarActions),
      ],
      moreMenu: moreMenu,
      // Centered so the tight leading slot cannot stretch it.
      leading: Center(
        child: HeaderCircleButton(
          icon: isSelectionMode || _editingOrder
              ? Icons.close
              : Icons.arrow_back,
          tooltip: isSelectionMode || _editingOrder
              ? MaterialLocalizations.of(context).closeButtonTooltip
              : MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: _editingOrder
              ? _cancelOrder
              : isSelectionMode
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

  /// The Mornye Link kept collection id of this page: Loved or the playlist.
  String? _keptCollection(UserPlaylistCollection? playlist) {
    switch (widget.mode) {
      case LibraryTracksFolderMode.loved:
        return linkKeptLoved;
      case LibraryTracksFolderMode.playlist:
        final id = widget.playlistId ?? playlist?.id;
        return id == null || id.isEmpty ? null : linkKeptPlaylist(id);
      case LibraryTracksFolderMode.wishlist:
        return null;
    }
  }

  /// The actions behind the header's More button, built when it opens.
  List<List<ContextMenuAction>> _moreMenuGroups(
    String title,
    List<CollectionTrackEntry> entries,
    UserPlaylistCollection? playlist, {
    required bool linkTransfers,
  }) {
    final isPlaylistMode = widget.mode == LibraryTracksFolderMode.playlist;
    final hasCustomCover = playlist?.coverImagePath?.isNotEmpty ?? false;
    final tracks = [for (final entry in entries) entry.track];
    return [
      [
        if (entries.isNotEmpty) ...[
          networkOfflineTracksAction(context, ref, tracks),
          ContextMenuAction(
            icon: Icons.ios_share,
            label: context.l10n.collectionExportM3u,
            onSelected: () => _exportAsM3u8(context, title, _savedEntries),
          ),
        ],
        if (isPlaylistMode) ?linkTrackTransferAction(context, ref, tracks),
        if (_keptCollection(playlist) case final collection?)
          ?linkKeepAction(context, ref, collection),
      ],
      if (linkTransfers) desktopLinkTransferTrackActions(context, ref, tracks),
      [
        if (entries.length > 1)
          ContextMenuAction(
            icon: Icons.swap_vert,
            label: context.l10n.playlistEditOrder,
            onSelected: () => _editOrder(_savedEntries),
          ),
        if (isPlaylistMode) ...[
          ContextMenuAction(
            icon: Icons.edit_outlined,
            label: context.l10n.collectionRenamePlaylist,
            onSelected: () {
              final id = widget.playlistId ?? playlist?.id;
              if (id == null || id.isEmpty) return;
              _showRenamePlaylistDialog(context, id, playlist?.name ?? title);
            },
          ),
          ContextMenuAction(
            icon: Icons.image_outlined,
            label: context.l10n.collectionPlaylistChangeCover,
            onSelected: _pickCoverImage,
          ),
        ],
        if (_homePin(title, playlist) case final pin?)
          homePinMenuAction(context, ref, pin),
      ],
      if (isPlaylistMode && hasCustomCover)
        [
          ContextMenuAction(
            icon: Icons.delete_outline,
            label: context.l10n.collectionPlaylistRemoveCover,
            destructive: true,
            onSelected: _removeCoverImage,
          ),
        ],
    ];
  }

  /// The Home pin of this playlist or of Loved; the Wishlist has none.
  HomePin? _homePin(String title, UserPlaylistCollection? playlist) {
    switch (widget.mode) {
      case LibraryTracksFolderMode.loved:
        return HomePin.loved;
      case LibraryTracksFolderMode.playlist:
        final id = widget.playlistId ?? playlist?.id;
        if (id == null || id.isEmpty) return null;
        return HomePin.playlist(id: id, name: playlist?.name ?? title);
      case LibraryTracksFolderMode.wishlist:
        return null;
    }
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
    final effectiveCoverUrl = collectionCoverIsPortable(rawCoverUrl)
        ? rawCoverUrl
        : ref
              .watch(
                localLibraryCoverProvider(LocalLibraryCoverRequest.of(track)),
              )
              .maybeWhen(data: (cover) => cover, orElse: () => rawCoverUrl);

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
    final playback = ref.watch(
      catalogTrackPlaybackUiProvider(catalogTrackKey(track)),
    );
    final isCurrent = playback.isCurrent;
    final isPlaying = playback.isPlaying;
    final hasFile = isInHistory || isInLocalLibrary;
    // Songs with a file queue as the selection bar queues them.
    final queueSwipe = hasFile
        ? mediaQueueSwipe(
            ref,
            () => resolveCollectionTrackFiles(
              ref.read(playbackProvider.notifier),
              [track],
            ),
          )
        : null;
    final VoidCallback play = isCurrent
        ? () =>
              ref.read(musicPlayerControllerProvider).togglePlayPause(isPlaying)
        : () => _playFromHere(context, ref);
    void openDetails() => _navigateToMetadata(context, ref);

    return TrackCard(
      style: collectionTrackCardStyle(context),
      queueSwipe: queueSwipe,
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
                  ? _buildTrackCover(
                      context,
                      effectiveCoverUrl,
                      size,
                      songFile: inMemoryHistoryItem?.filePath,
                      hasFile: hasFile,
                    )
                  : TrackCoverPlaceholder(size: size),
            );
            return heroTag != null
                ? Hero(
                    tag: heroTag,
                    transitionOnUserGestures: heroFollowsBackSwipe(context),
                    child: cover,
                  )
                : cover;
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
      trailing: hasFile
          ? Builder(
              builder: (context) {
                final colorScheme = Theme.of(context).colorScheme;
                final playButton = AppIconButton(
                  tooltip: isPlaying
                      ? context.l10n.actionPause
                      : context.l10n.tooltipPlay,
                  onPressed: play,
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
                // A wishlist tap downloads, so its button stays Play.
                return mode == LibraryTracksFolderMode.wishlist
                    ? playButton
                    : SongRowButton(
                        playButton: playButton,
                        onOpenDetails: openDetails,
                      );
              },
            )
          : null,
      onTap: isSelectionMode
          ? onTap
          : mode == LibraryTracksFolderMode.wishlist
          ? () => _downloadTrack(context, ref)
          : hasFile
          ? songRowTap(ref, openDetails: openDetails, play: play)
          : openDetails,
      onLongPress: onLongPress,
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

  Widget _buildTrackCover(
    BuildContext context,
    String coverUrl,
    double size, {
    String? songFile,
    required bool hasFile,
  }) {
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
      songFile: songFile,
      // A file outside the recent History in memory is read only once the
      // cover fails.
      findSongFile: songFile == null && hasFile
          ? () => firstTrackSongFile(
              [entry.track],
              library: LibraryDatabase.instance,
              history: HistoryDatabase.instance,
            )
          : null,
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
    await prepareTrackDetailsCover(
      context,
      localItem.filePath,
      fallback: localItem.coverPath,
    );
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
