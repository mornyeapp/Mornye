import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/hover_play_button.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';

/// Slivers shared by Material's Library and Mornye's Library/Songs screens.
/// Only the current query's provider families are watched; late results from
/// an earlier query cannot replace what the user is currently searching for.
class LibrarySearchResults extends ConsumerStatefulWidget {
  const LibrarySearchResults({
    super.key,
    required this.query,
    required this.onOpenArtist,
    this.shelves = false,
  });

  final String query;
  final ValueChanged<String> onOpenArtist;

  /// Groups the overview as Music on the Mac does: artists, albums and
  /// playlists in rows of artwork that scroll sideways, songs as rows, and
  /// no filter chips until a section header opens one kind.
  final bool shelves;

  @override
  ConsumerState<LibrarySearchResults> createState() =>
      _LibrarySearchResultsState();
}

class _LibrarySearchResultsState extends ConsumerState<LibrarySearchResults> {
  LibrarySearchKind? _kind;
  int _pages = 1;

  // Long-pressed songs, keyed by UnifiedLibraryItem.id in selection order.
  // Only resolved records are kept, so every bar action sees real files.
  final Map<String, UnifiedLibraryItem> _selected = {};
  final SelectionOverlayController _selectionOverlay =
      SelectionOverlayController();
  // Hidden while a sheet or dialog opened from the bar is on screen.
  bool _suppressSelectionBar = false;
  // Hidden while a right-click selection exists only for its open menu.
  bool _menuSelection = false;
  List<LibrarySearchHit> _visibleSongs = const [];

  bool get _selecting => _selected.isNotEmpty;

  @override
  void didUpdateWidget(covariant LibrarySearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _pages = 1;
      // A selection belongs to the results it was made in.
      _selected.clear();
      _suppressSelectionBar = false;
      _selectionOverlay.hide();
    }
  }

  @override
  void dispose() {
    _selectionOverlay.dispose();
    super.dispose();
  }

  static String _itemId(LibrarySearchHit hit) =>
      hit.source == 'local' ? 'local_${hit.id}' : 'dl_${hit.id}';

  Future<UnifiedLibraryItem?> _resolve(LibrarySearchHit hit) => ref.read(
    librarySearchTrackProvider((source: hit.source, id: hit.id)).future,
  );

  Future<void> _toggleSelection(LibrarySearchHit hit) async {
    final id = _itemId(hit);
    if (_selected.containsKey(id)) {
      setState(() => _selected.remove(id));
      return;
    }
    final item = await _resolve(hit);
    if (!mounted || item == null) return;
    if (_selected.isEmpty) {
      FocusScope.of(context).unfocus();
      HapticFeedback.mediumImpact();
    }
    setState(() => _selected[item.id] = item);
  }

  Future<void> _selectAllVisible() async {
    final items = await Future.wait(
      _visibleSongs
          .where((hit) => !_selected.containsKey(_itemId(hit)))
          .map(_resolve),
    );
    if (!mounted) return;
    setState(() {
      for (final item in items.whereType<UnifiedLibraryItem>()) {
        _selected[item.id] = item;
      }
    });
  }

  void _exitSelection() {
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _suppressSelectionBar = false;
    });
    _selectionOverlay.hide();
  }

  void _finishSelectionAction() {
    _exitSelection();
    ref.invalidate(librarySearchProvider);
  }

  void _hideSelectionBar() {
    _suppressSelectionBar = true;
    _selectionOverlay.hide();
  }

  Future<void> _restoreSelectionBar({Duration delay = Duration.zero}) async {
    // Wait out the sheet/dialog exit so the bar does not cover it.
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    _suppressSelectionBar = false;
    if (mounted) setState(() {});
  }

  void _syncSelectionBar() {
    if (!mounted) return;
    if (!_selecting || _suppressSelectionBar || _menuSelection) {
      _selectionOverlay.hide();
      return;
    }
    _selectionOverlay.show(context, _buildSelectionBar);
  }

  Widget _buildSelectionBar(BuildContext _) {
    final items = _selected.values.toList(growable: false);
    final visibleIds = _visibleSongs.map(_itemId).toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selected.containsKey);
    final flacEligible = items.every((item) => item.localItem != null)
        ? items
              .map((item) => item.localItem!)
              .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
              .toList(growable: false)
        : const <LocalLibraryItem>[];
    return LibraryTrackSelectionBar(
      playbackActions: LibrarySelectionPlaybackActions(
        items: items,
        onClose: _exitSelection,
      ),
      selectedCount: items.length,
      allSelected: allSelected,
      onClose: _exitSelection,
      onToggleSelectAll: allSelected ? _exitSelection : _selectAllVisible,
      bottomPadding: MediaQuery.paddingOf(context).bottom,
      flacEligibleCount: flacEligible.length,
      onQueueFlac: () => queueLocalTracksAsFlac(
        context,
        ref,
        flacEligible,
        isActive: () => mounted,
        onComplete: _exitSelection,
      ),
      onReEnrich: () => reEnrichLibraryTracks(
        context,
        ref,
        items,
        isActive: () => mounted,
        onSelectionHide: () async => _hideSelectionBar(),
        onSelectionRestore: _restoreSelectionBar,
        onComplete: _finishSelectionAction,
      ),
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
        onExitSelectionMode: _exitSelection,
        onConfirmOpen: _hideSelectionBar,
        onConfirmClosed: (confirmed) => _restoreSelectionBar(
          delay: confirmed ? Duration.zero : const Duration(milliseconds: 220),
        ),
      ),
      onDelete: () => deleteLibraryTracks(
        context,
        ref,
        items,
        isActive: () => mounted,
        onComplete: _finishSelectionAction,
      ),
    );
  }

  /// The desktop menu of a result. A song outside the selection becomes the
  /// selection for this menu only, so the menu acts on the song clicked: the
  /// selection bar stays hidden under the menu, and the selection ends if
  /// the menu closes without a choice.
  Future<void> _showHitMenu(LibrarySearchHit hit, Offset position) async {
    final l10n = context.l10n;
    if (hit.kind != LibrarySearchKind.songs) {
      await showContextMenu(
        context,
        position: position,
        groups: [
          [
            ContextMenuAction(
              icon: Icons.open_in_new,
              label: l10n.desktopMenuOpen,
              onSelected: () => _open(hit),
            ),
          ],
        ],
      );
      return;
    }
    final forMenu = !_selected.containsKey(_itemId(hit));
    if (forMenu) {
      final item = await _resolve(hit);
      if (!mounted || item == null) return;
      setState(() {
        _menuSelection = true;
        _selected
          ..clear()
          ..[item.id] = item;
      });
    }
    if (!mounted) return;
    final items = _selected.values.toList(growable: false);
    final chosen = await showContextMenu(
      context,
      position: position,
      groups: libraryTrackMenuGroups(
        context,
        ref,
        items: items,
        onPlay: () => _open(hit, play: true),
        onOpenDetails: () => _open(hit),
        onDone: _exitSelection,
        onReEnrich: () => reEnrichLibraryTracks(
          context,
          ref,
          items,
          isActive: () => mounted,
          onSelectionHide: () async => _hideSelectionBar(),
          onSelectionRestore: _restoreSelectionBar,
          onComplete: _finishSelectionAction,
        ),
        onConvert: () => showBatchConvertSheet(
          context,
          ref,
          items,
          onExitSelectionMode: _finishSelectionAction,
        ),
        onDelete: () => deleteLibraryTracks(
          context,
          ref,
          items,
          isActive: () => mounted,
          onComplete: _finishSelectionAction,
        ),
      ),
    );
    if (!forMenu || !mounted) return;
    // An action that kept the selection shows the bar again.
    setState(() => _menuSelection = false);
    if (!chosen) _exitSelection();
  }

  String _label(LibrarySearchKind kind) => switch (kind) {
    LibrarySearchKind.songs => context.l10n.searchSongs,
    LibrarySearchKind.albums => context.l10n.searchAlbums,
    LibrarySearchKind.artists => context.l10n.searchArtists,
    LibrarySearchKind.playlists => context.l10n.searchPlaylists,
  };

  void _select(LibrarySearchKind? kind) => setState(() {
    _kind = kind;
    _pages = 1;
  });

  Future<void> _open(LibrarySearchHit hit, {bool play = false}) async {
    FocusScope.of(context).unfocus();
    try {
      switch (hit.kind) {
        case LibrarySearchKind.songs:
          final item = await ref.read(
            librarySearchTrackProvider((source: hit.source, id: hit.id)).future,
          );
          if (!mounted || item == null) return;
          if (!play) {
            await pushPage<void>(
              context,
              (_) => TrackMetadataScreen(
                item: item.historyItem,
                localItem: item.localItem,
              ),
            );
            return;
          }
          final media = item.localItem != null
              ? playableFromLocal(item.localItem!)
              : playableFromHistory(item.historyItem!);
          await ref
              .read(playbackProvider.notifier)
              .playMediaQueue(
                [media],
                startIndex: 0,
                externalPath: media.source,
              );
        case LibrarySearchKind.artists:
          widget.onOpenArtist(hit.title);
        case LibrarySearchKind.playlists:
          await pushPage<void>(
            context,
            (_) => LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: hit.id,
            ),
          );
        case LibrarySearchKind.albums:
          if (hit.source == 'local') {
            final rows = await LibraryDatabase.instance
                .getQueueLocalAlbumTracksByKey(hit.id);
            if (!mounted) return;
            await pushPage<void>(
              context,
              (_) => LocalAlbumScreen(
                albumName: hit.title,
                artistName: hit.artist,
                coverPath: hit.cover,
                tracks: rows.map(LocalLibraryItem.fromJson).toList(),
              ),
            );
          } else {
            await pushPage<void>(
              context,
              (_) => DownloadedAlbumScreen(
                albumName: hit.title,
                artistName: hit.artist,
                coverUrl: hit.cover,
              ),
            );
          }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarCannotOpenFile('$error'))),
      );
    }
  }

  Widget _row(LibrarySearchHit hit) {
    final icon = switch (hit.kind) {
      LibrarySearchKind.songs => Icons.music_note_outlined,
      LibrarySearchKind.albums => Icons.album_outlined,
      LibrarySearchKind.artists => Icons.person_outline,
      LibrarySearchKind.playlists => Icons.queue_music,
    };
    final subtitle = hit.kind == LibrarySearchKind.songs
        ? hit.artist
        : [
            if (hit.kind == LibrarySearchKind.albums) hit.artist,
            context.l10n.queueTrackCount(hit.trackCount),
          ].join(' · ');
    Widget fallback(BuildContext context) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(icon)),
    );
    final song = hit.kind == LibrarySearchKind.songs;
    final key = ValueKey('${hit.kind.name}:${hit.source}:${hit.id}');
    Widget card({MediaPlaybackUi? playback}) => TrackCard(
      key: playback == null ? key : null,
      style: hit.kind == LibrarySearchKind.songs && !context.isMornye
          ? TrackCardStyle.filled
          : TrackCardStyle.flat,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(
          hit.kind == LibrarySearchKind.artists ? 28 : 8,
        ),
        child: SizedBox.square(
          dimension: 52,
          child: hit.cover?.isNotEmpty == true
              ? LocalOrNetworkCoverImage(url: hit.cover!, placeholder: fallback)
              : fallback(context),
        ),
      ),
      title: hit.title,
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      isCurrent: playback?.isCurrent ?? false,
      isPlaying: playback?.isPlaying ?? false,
      leadingArtwork: song,
      trailing: song
          ? AppIconButton(
              tooltip: playback?.isPlaying ?? false
                  ? context.l10n.actionPause
                  : context.l10n.tooltipPlay,
              icon: Icon(
                playback?.isPlaying ?? false
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              // The current track pauses and resumes in place.
              onPressed: playback?.isCurrent ?? false
                  ? () => ref
                        .read(musicPlayerControllerProvider)
                        .togglePlayPause(playback!.isPlaying)
                  : () => _open(hit, play: true),
            )
          : const Icon(Icons.chevron_right),
      // Long-press selects songs for the Library batch actions; while
      // selecting, song taps toggle and other results stay inert.
      isSelectionMode: song && _selecting,
      isSelected: song && _selected.containsKey(_itemId(hit)),
      onTap: !_selecting
          ? () => _open(hit)
          : song
          ? () => _toggleSelection(hit)
          : null,
      onLongPress: song ? () => _toggleSelection(hit) : null,
      onContextMenu: (position) => _showHitMenu(hit, position),
    );
    if (!song || context.isMornye) return card();
    // Material song rows follow the file they play, so a track change
    // rebuilds only the rows involved. Mornye rows show no current-track
    // state.
    return Consumer(
      key: key,
      builder: (context, ref, _) => card(
        playback: ref.watch(
          mediaItemPlaybackUiProvider((id: hit.id, path: hit.samplePath)),
        ),
      ),
    );
  }

  /// Switches wide results between rows and covers, as the extension
  /// search's view button does; both searches share the choice. [cover] is
  /// the layout on screen.
  Widget _viewToggle({required bool cover}) {
    return AppIconButton(
      tooltip: cover
          ? context.l10n.appearanceHistoryViewList
          : context.l10n.appearanceHistoryViewGrid,
      icon: AppIcon(
        cover ? Icons.view_list : Icons.grid_view,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: () => ref
          .read(settingsProvider.notifier)
          .setSearchViewMode(cover ? 'list' : 'grid'),
    );
  }

  Widget _shelfHeader(LibrarySearchKind kind, {Widget? trailing}) {
    final header = Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        header: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _select(kind),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _label(kind),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        14,
        20,
        trailing == null ? 20 : 8,
        8,
      ),
      child: Row(
        children: [
          Expanded(child: header),
          ?trailing,
        ],
      ),
    );
  }

  /// The title and subtitle under a cover, grown with the text size.
  double _tileTextHeight({required bool artist}) {
    final textTheme = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? style, double fontSize) =>
        scaler.scale(style?.fontSize ?? fontSize) * (style?.height ?? 1.3);
    return line(textTheme.bodyLarge, 17) +
        (artist ? 0 : line(textTheme.bodyMedium, 15));
  }

  /// A result as its cover over the title and subtitle, for the shelves and
  /// the cover grid. Songs keep their row actions: a click opens the
  /// details, the hover button plays, and a long press selects.
  Widget _tile(LibrarySearchHit hit, double size) {
    final artist = hit.kind == LibrarySearchKind.artists;
    final song = hit.kind == LibrarySearchKind.songs;
    final selected = song && _selected.containsKey(_itemId(hit));
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (hit.kind) {
      LibrarySearchKind.songs => Icons.music_note_outlined,
      LibrarySearchKind.artists => Icons.person_outline,
      LibrarySearchKind.playlists => Icons.queue_music,
      LibrarySearchKind.albums => Icons.album_outlined,
    };
    Widget fallback(BuildContext context) => ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          icon,
          size: size * 0.3,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final radius = BorderRadius.circular(artist ? size / 2 : 8);
    return SizedBox(
      key: ValueKey('${hit.kind.name}:${hit.source}:${hit.id}'),
      width: size,
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            _showHitMenu(hit, details.globalPosition),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // While selecting, song taps toggle and other results stay inert.
          onTap: !_selecting
              ? () => _open(hit)
              : song
              ? () => _toggleSelection(hit)
              : null,
          onLongPress: song ? () => _toggleSelection(hit) : null,
          child: Column(
            crossAxisAlignment: artist
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: radius,
                      child: hit.cover?.isNotEmpty == true
                          ? LocalOrNetworkCoverImage(
                              url: hit.cover!,
                              placeholder: fallback,
                            )
                          : fallback(context),
                    ),
                    if (selected) ...[
                      ClipRRect(
                        borderRadius: radius,
                        child: ColoredBox(
                          color: colorScheme.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      PositionedDirectional(
                        top: 8,
                        end: 8,
                        child: Container(
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.check,
                            size: 18,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ],
                    if (song && !_selecting)
                      DesktopHoverPlayButton(
                        tooltip: context.l10n.tooltipPlay,
                        onPlay: () => _open(hit, play: true),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hit.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: artist ? TextAlign.center : TextAlign.start,
                style: textTheme.bodyLarge,
              ),
              if (!artist)
                Text(
                  hit.kind == LibrarySearchKind.playlists
                      ? context.l10n.queueTrackCount(hit.trackCount)
                      : hit.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shelf(LibrarySearchKind kind, List<LibrarySearchHit> hits) {
    final artist = kind == LibrarySearchKind.artists;
    final size = artist ? 160.0 : 180.0;
    return SizedBox(
      height: size + 8 + _tileTextHeight(artist: artist) + 16,
      // Shelves have no paging arrows, so they keep the desktop scrollbar
      // the app hides on other sideways rows.
      child: ScrollConfiguration(
        behavior: const MaterialScrollBehavior().copyWith(
          physics: ScrollConfiguration.of(context).getScrollPhysics(context),
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          itemCount: hits.length,
          separatorBuilder: (_, _) => const SizedBox(width: 20),
          itemBuilder: (context, index) => _tile(hits[index], size),
        ),
      ),
    );
  }

  /// One kind, filtered, as covers in as many columns as the pane fits, as
  /// the extension search's grid does.
  Widget _grid(LibrarySearchKind kind, List<LibrarySearchHit> hits) {
    final artist = kind == LibrarySearchKind.artists;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      // Rebuilds when the pane is resized, not while it scrolls.
      sliver: SliverLayoutInfoBuilder<double>(
        select: (constraints) => constraints.crossAxisExtent,
        builder: (context, width) {
          final extent = searchCoverGridExtent(width);
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: searchCoverGridColumns(width),
              mainAxisSpacing: searchCoverGap,
              crossAxisSpacing: searchCoverGap,
              mainAxisExtent: extent + 8 + _tileTextHeight(artist: artist) + 4,
            ),
            itemCount: hits.length,
            itemBuilder: (context, index) => _tile(hits[index], extent),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Phones keep their rows in landscape too, as the extension search does.
    final coverAllowed =
        isDesktopPlatform || MediaQuery.sizeOf(context).shortestSide >= 600;
    final inset = wideListInset(context);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      // Rebuilds only when the pane crosses the breakpoint, not on every
      // scroll frame.
      child: SliverLayoutInfoBuilder<bool>(
        select: (constraints) =>
            coverAllowed &&
            constraints.crossAxisExtent - 2 * inset >=
                searchCoverLayoutMinWidth,
        builder: (context, wide) => Consumer(
          builder: (context, ref, _) =>
              SliverMainAxisGroup(slivers: _buildSlivers(ref, wide: wide)),
        ),
      ),
    );
  }

  /// The results. [wide] panes offer the cover layout, which the user's
  /// search view (shared with the extension search) picks: shelves for the
  /// overview and a grid for one kind, songs included.
  List<Widget> _buildSlivers(WidgetRef ref, {required bool wide}) {
    final cover =
        wide &&
        ref.watch(settingsProvider.select((s) => s.searchViewMode)) == 'grid';
    final shelves = (widget.shelves || cover) && _kind == null;
    // The first section header carries the view button.
    Widget? toggle = wide ? _viewToggle(cover: cover) : null;
    Widget? takeToggle() {
      final taken = toggle;
      toggle = null;
      return taken;
    }

    final slivers = <Widget>[
      if (!widget.shelves || _kind != null)
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              spacing: 8,
              children: [
                for (final kind in [null, ...LibrarySearchKind.values])
                  AppChoiceChip(
                    label: Text(
                      kind == null
                          ? context.l10n.historyFilterAll
                          : _label(kind),
                    ),
                    selected: _kind == kind,
                    singleChoice: true,
                    onSelected: (_) => _select(kind),
                  ),
              ],
            ),
          ),
        ),
    ];
    var hasResults = false;
    var loading = false;
    var failed = false;
    final visibleSongs = <LibrarySearchHit>[];
    final kinds = _kind != null
        ? [_kind!]
        : shelves
        ? const [
            LibrarySearchKind.artists,
            LibrarySearchKind.albums,
            LibrarySearchKind.songs,
            LibrarySearchKind.playlists,
          ]
        : LibrarySearchKind.values;
    for (final kind in kinds) {
      // In the cover layout songs take a shelf too, as every other kind.
      final shelf = shelves && (cover || kind != LibrarySearchKind.songs);
      // A filtered kind's pages fill one grid, so rows run on across pages.
      final grid = cover && _kind != null;
      final gridHits = <LibrarySearchHit>[];
      var more = false;
      for (var page = 0; page < (_kind == null ? 1 : _pages); page++) {
        final pageSize = _kind != null
            ? 40
            : !shelves
            ? 5
            : shelf
            ? 20
            : 8;
        final request = (
          query: widget.query,
          kind: kind,
          limit: pageSize + 1,
          offset: page * pageSize,
        );
        final result = ref.watch(librarySearchProvider(request));
        loading |= result.isLoading;
        failed |= result.hasError;
        final hits = result.value ?? const <LibrarySearchHit>[];
        if (kind == LibrarySearchKind.songs) {
          visibleSongs.addAll(hits.take(pageSize));
        }
        if (hits.isNotEmpty) {
          hasResults = true;
          if (page == 0 && shelves) {
            slivers.add(
              SliverToBoxAdapter(
                child: _shelfHeader(kind, trailing: takeToggle()),
              ),
            );
          } else if (page == 0) {
            final viewToggle = takeToggle();
            slivers.add(
              SliverToBoxAdapter(
                child: ListTile(
                  title: Text(
                    _label(kind),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  trailing: viewToggle == null && _kind != null
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ?viewToggle,
                            if (_kind == null) const Icon(Icons.chevron_right),
                          ],
                        ),
                  onTap: _kind == null ? () => _select(kind) : null,
                ),
              ),
            );
          }
          if (grid) {
            gridHits.addAll(hits.take(pageSize));
          } else {
            slivers.add(
              shelf
                  ? SliverToBoxAdapter(
                      child: _shelf(kind, hits.take(pageSize).toList()),
                    )
                  : SliverList.builder(
                      itemCount: hits.length.clamp(0, pageSize),
                      itemBuilder: (context, index) => _row(hits[index]),
                    ),
            );
          }
          more = _kind != null && page == _pages - 1 && hits.length > pageSize;
        }
        if (result.hasError) {
          slivers.add(
            SliverToBoxAdapter(
              child: Center(
                child: ExpressiveButton(
                  text: true,
                  icon: const Icon(Icons.refresh),
                  onPressed: () =>
                      ref.invalidate(librarySearchProvider(request)),
                  child: Text('${_label(kind)} · ${context.l10n.dialogRetry}'),
                ),
              ),
            ),
          );
        }
      }
      if (gridHits.isNotEmpty) slivers.add(_grid(kind, gridHits));
      if (more) {
        slivers.add(
          SliverToBoxAdapter(
            child: Center(
              child: AppIconButton(
                tooltip: _label(kind),
                icon: const Icon(Icons.expand_more),
                onPressed: () => setState(() => _pages++),
              ),
            ),
          ),
        );
      }
    }
    if (loading) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: AppLoadingIndicator()),
          ),
        ),
      );
    } else if (!hasResults && !failed) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              context.l10n.searchEmptyResultSubtitle,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (_selecting) {
      // Same reserve as the Library list, so the last rows can scroll clear
      // of the selection bar.
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 100)));
    }
    _visibleSongs = visibleSongs;
    if (_selecting || _selectionOverlay.isVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncSelectionBar());
    }
    return slivers;
  }
}
