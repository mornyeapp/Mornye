import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart'
    show LocalLibraryItem;
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/services/playable_media.dart' show PlayableMedia;
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/library_mix_cover.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/track_card.dart';

/// A mix's name: what it gathers, such as "Hip-Hop Mix".
String libraryMixTitle(AppLocalizations l10n, LibraryMix mix) =>
    switch (mix.kind) {
      LibraryMixKind.favorites => l10n.homeMixFavoritesTitle,
      LibraryMixKind.genre => l10n.homeMixGenreTitle(
        libraryGenreFamilyName(l10n, mix.key) ?? mix.label,
      ),
      LibraryMixKind.artist => l10n.homeMixArtistTitle(mix.label),
      LibraryMixKind.decade => l10n.homeMixDecadeTitle(mix.label),
      LibraryMixKind.fresh => l10n.homeMixFreshTitle,
      LibraryMixKind.rediscover => l10n.homeMixRediscoverTitle,
      LibraryMixKind.discover => l10n.homeMixDiscoverTitle,
    };

/// The translated name of a genre family; null for a tag outside the
/// families, which keeps its own spelling.
String? libraryGenreFamilyName(AppLocalizations l10n, String family) =>
    switch (family) {
      'hiphop' => l10n.homeMixGenreHipHop,
      'rnb' => l10n.homeMixGenreRnb,
      'pop' => l10n.homeMixGenrePop,
      'kpop' => l10n.homeMixGenreKpop,
      'jpop' => l10n.homeMixGenreJpop,
      'rock' => l10n.homeMixGenreRock,
      'metal' => l10n.homeMixGenreMetal,
      'punk' => l10n.homeMixGenrePunk,
      'indie' => l10n.homeMixGenreIndie,
      'electronic' => l10n.homeMixGenreElectronic,
      'chill' => l10n.homeMixGenreChill,
      'jazz' => l10n.homeMixGenreJazz,
      'blues' => l10n.homeMixGenreBlues,
      'classical' => l10n.homeMixGenreClassical,
      'soundtrack' => l10n.homeMixGenreSoundtrack,
      'country' => l10n.homeMixGenreCountry,
      'folk' => l10n.homeMixGenreFolk,
      'latin' => l10n.homeMixGenreLatin,
      'reggae' => l10n.homeMixGenreReggae,
      'afro' => l10n.homeMixGenreAfro,
      'gospel' => l10n.homeMixGenreGospel,
      'dangdut' => l10n.homeMixGenreDangdut,
      _ => null,
    };

/// The artists a mix is heard with, such as "Tyler, The Creator, Frank
/// Ocean and more". Translations set the punctuation and word order.
String libraryMixSubtitle(AppLocalizations l10n, LibraryMix mix) =>
    switch (mix.artists) {
      [] => '',
      [final first] => l10n.homeMixArtistsOne(first),
      [final first, final second] => l10n.homeMixArtistsTwo(first, second),
      [final first, final second, ...] => l10n.homeMixArtistsMore(
        first,
        second,
      ),
    };

/// A mix of the Library's own songs: its cover, Play, Shuffle, Save as
/// playlist and its songs in play order.
class LibraryMixScreen extends ConsumerStatefulWidget {
  const LibraryMixScreen({super.key, required this.view});

  final LibraryMixView view;

  @override
  ConsumerState<LibraryMixScreen> createState() => _LibraryMixScreenState();
}

class _LibraryMixScreenState extends ConsumerState<LibraryMixScreen>
    with
        SelectionModeMixin<LibraryMixScreen>,
        CollapsingHeaderScrollMixin<LibraryMixScreen> {
  /// The mix's songs, less those deleted from this page.
  late List<UnifiedLibraryItem> _items = widget.view.items;

  List<UnifiedLibraryItem> get _selectedItems => [
    for (final item in _items)
      if (selectedIds.contains(item.id)) item,
  ];

  /// The first song artwork that names a file or address, for the header
  /// colors.
  String? get _paletteSource {
    for (final item in _items) {
      final source = item.localCoverPath ?? item.coverUrl;
      if (source != null && source.trim().isNotEmpty) return source;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: _paletteSource,
        neutralActions: true,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final ids = [for (final item in _items) item.id];
    pruneSelection(ids.toSet());
    return DesktopListScope(
      onSelectAll: ids.isEmpty ? null : () => selectAll(ids),
      onClearSelection: isSelectionMode ? exitSelectionMode : null,
      onDelete: isSelectionMode ? _deleteSelected : null,
      onActivate: () {
        final index = ids.indexOf(selectionAnchorId ?? '');
        if (index >= 0) _play(index);
      },
      child: CollectionScaffold(
        scrollController: scrollController,
        isSelectionMode: showsSelectionBar,
        onExitSelectionMode: exitSelectionMode,
        appBar: _buildHeader(context),
        slivers: [
          if (isDesktopPlatform)
            _buildDesktopTable(context, ids)
          else
            _buildTrackList(context),
        ],
        selectionBar: _buildSelectionBar(context, ids),
      ),
    );
  }

  /// The Library selection bar of the album pages: playback, FLAC upgrade,
  /// re-enrich, convert, ReplayGain and delete.
  Widget _buildSelectionBar(BuildContext context, List<String> ids) {
    final items = _selectedItems;
    final allSelected = ids.isNotEmpty && selectedIds.length == ids.length;
    final flacEligible = items.every((item) => item.localItem != null)
        ? [
            for (final item in items)
              if (LocalTrackRedownloadService.isFlacUpgradeEligible(
                item.localItem!,
              ))
                item.localItem!,
          ]
        : const <LocalLibraryItem>[];
    return LibraryTrackSelectionBar(
      selectedCount: selectedIds.length,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: allSelected ? exitSelectionMode : () => selectAll(ids),
      bottomPadding: showsSelectionBar
          ? MediaQuery.paddingOf(context).bottom
          : 0,
      playbackActions: LibrarySelectionPlaybackActions(
        items: items,
        onClose: exitSelectionMode,
      ),
      flacEligibleCount: flacEligible.length,
      onQueueFlac: () => queueLocalTracksAsFlac(
        context,
        ref,
        flacEligible,
        isActive: () => mounted,
        onComplete: exitSelectionMode,
      ),
      onReEnrich: _reEnrichSelected,
      onConvert: () => _convertSelected(context),
      onReplayGain: ({required remove}) => runBatchReplayGain(
        context,
        items,
        remove: remove,
        onExitSelectionMode: exitSelectionMode,
      ),
      onDelete: _deleteSelected,
    );
  }

  Future<void> _reEnrichSelected() => reEnrichLibraryTracks(
    context,
    ref,
    _selectedItems,
    isActive: () => mounted,
    onSelectionHide: () async {
      setState(() => isSelectionMode = false);
      // Allow the selection bar's 250 ms slide-out to finish.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    },
    onSelectionRestore: () => setState(() => isSelectionMode = true),
    onComplete: exitSelectionMode,
  );

  Future<void> _convertSelected(BuildContext context) => showBatchConvertSheet(
    context,
    ref,
    _selectedItems,
    onExitSelectionMode: exitSelectionMode,
  );

  /// Deletes the selected songs' files, and drops those gone from the mix.
  Future<void> _deleteSelected() async {
    final selected = _selectedItems;
    await deleteLibraryTracks(
      context,
      ref,
      selected,
      isActive: () => mounted,
      onComplete: exitSelectionMode,
    );
    final present = await Future.wait([
      for (final item in selected) fileExists(item.filePath),
    ]);
    final gone = {
      for (final (index, item) in selected.indexed)
        if (!present[index]) item.id,
    };
    if (gone.isEmpty || !mounted) return;
    setState(() {
      _items = [
        for (final item in _items)
          if (!gone.contains(item.id)) item,
      ];
    });
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = context.l10n;
    final mix = widget.view.mix;
    final colorScheme = Theme.of(context).colorScheme;
    final title = libraryMixTitle(l10n, mix);
    final minutes =
        _items.fold<int>(
          0,
          (sum, item) => sum + max(0, _durationSeconds(item) ?? 0),
        ) ~/
        60;
    final cover = _paletteSource;
    return AlbumDetailHeader(
      title: title,
      immersive: context.isMornye,
      expandedHeight: calculateExpandedHeight(context),
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      background: LibraryMixCover(items: _items, size: 400),
      paletteSource: cover,
      blurAndScrimBackground: cover != null,
      coverBuilder: (context, coverSize) =>
          LibraryMixCover(items: _items, size: coverSize),
      // Built inside the header, so desktop reads its artwork scheme.
      subtitle: Builder(
        builder: (header) => Text(
          libraryMixSubtitle(l10n, mix),
          style: isDesktopPlatform
              ? desktopDetailSubtitleStyle(header)
              : TextStyle(
                  color: context.isMornye
                      ? colorScheme.primary
                      : HeaderPalette.of(header).onSurfaceVariant,
                  fontSize: context.tokens.headerSubtitleSize,
                  fontWeight: context.isMornye
                      ? FontWeight.w400
                      : FontWeight.w600,
                ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      meta: HeaderMetaRow(
        items: [
          HeaderMetaItem(l10n.tracksCount(_items.length)),
          if (minutes > 0) HeaderMetaItem('$minutes min'),
          HeaderMetaItem(l10n.homeMixUpdatedDaily),
        ],
      ),
      // Phones save from the toolbar; the desktop header has its own "+".
      appBarActions: isDesktopPlatform
          ? null
          : [
              HeaderCircleButton(
                icon: Icons.playlist_add,
                tooltip: l10n.homeMixSaveAsPlaylist,
                onPressed: () => _saveAsPlaylist(context),
              ),
            ],
      actions: Consumer(
        builder: (context, ref, _) {
          final isCurrent = ref.watch(
            currentMediaItemProvider.select(
              (state) => _items.any(
                (item) => mediaItemPlaysRow(state.value, _rowKey(item)),
              ),
            ),
          );
          final isPlaying = isCurrent && ref.watch(playbackPlayingProvider);
          return AlbumPlayActions(
            isPlaying: isPlaying,
            playLabel: isPlaying ? l10n.actionPause : l10n.tooltipPlay,
            shuffleTooltip: l10n.actionShuffle,
            onPlay: isCurrent
                ? () => ref
                      .read(musicPlayerControllerProvider)
                      .togglePlayPause(isPlaying)
                : () => _play(0),
            onShuffle: _shuffle,
            onAddToPlaylist: () => _saveAsPlaylist(context),
          );
        },
      ),
      moreMenu: () => libraryTrackMenuGroups(
        context,
        ref,
        items: _items,
        onPlay: () => _play(0),
      ),
    );
  }

  Widget _buildTrackList(BuildContext context) {
    final tokens = context.tokens;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverList.builder(
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return Consumer(
            key: ValueKey(item.id),
            builder: (context, ref, _) {
              final playback = ref.watch(
                mediaItemPlaybackUiProvider(_rowKey(item)),
              );
              return TrackCard(
                style: context.isMornye
                    ? TrackCardStyle.flat
                    : TrackCardStyle.filled,
                leadingArtwork: true,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(tokens.radiusThumb),
                  child: LibraryItemArtwork(
                    item: item,
                    size: tokens.coverCompact,
                  ),
                ),
                title: item.trackName,
                subtitle: Text(
                  item.artistName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                isCurrent: playback.isCurrent,
                isPlaying: playback.isPlaying,
                isSelectionMode: isSelectionMode,
                isSelected: selectedIds.contains(item.id),
                // A long press selects, as on the album pages.
                onTap: isSelectionMode
                    ? () => toggleSelection(item.id)
                    : playback.isCurrent
                    ? () => ref
                          .read(musicPlayerControllerProvider)
                          .togglePlayPause(playback.isPlaying)
                    : () => _play(index),
                onLongPress: isSelectionMode
                    ? null
                    : () => enterSelectionMode(item.id),
              );
            },
          );
        },
      ),
    );
  }

  /// The desktop song table: a click selects, a double click plays from
  /// the song, a right click opens the Library song menu.
  Widget _buildDesktopTable(BuildContext context, List<String> ids) {
    final byId = {for (final item in _items) item.id: item};
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverTrackTable(
        rows: [
          for (final (index, item) in _items.indexed)
            TrackTableRow(
              id: item.id,
              number: index + 1,
              title: item.trackName,
              artist: item.artistName,
              album: item.albumName,
              duration: switch (_durationSeconds(item)) {
                final seconds? when seconds > 0 => Duration(seconds: seconds),
                _ => null,
              },
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LibraryItemArtwork(item: item, size: 32, iconSize: 16),
              ),
              playback: mediaItemPlaybackUiProvider(_rowKey(item)),
            ),
        ],
        columns: const [
          TrackTableColumn.number,
          TrackTableColumn.title,
          TrackTableColumn.artist,
          TrackTableColumn.album,
          TrackTableColumn.duration,
        ],
        selectedIds: selectedIds,
        onSelect: applyDesktopClick,
        onActivate: (id) => _play(ids.indexOf(id)),
        onContextMenu: (id, position) {
          final item = byId[id];
          if (item == null) return;
          showSelectionMenu(
            id,
            () => showContextMenu(
              context,
              position: position,
              groups: libraryTrackMenuGroups(
                context,
                ref,
                items: _selectedItems,
                onPlay: () => _play(ids.indexOf(id)),
                onDone: exitSelectionMode,
                onReEnrich: _reEnrichSelected,
                onConvert: () => _convertSelected(this.context),
                onDelete: _deleteSelected,
              ),
            ),
          );
        },
      ),
    );
  }

  PlaybackRowKey _rowKey(UnifiedLibraryItem item) => (
    id: item.localItem?.id ?? item.historyItem?.id ?? item.id,
    path: item.filePath,
  );

  static int? _durationSeconds(UnifiedLibraryItem item) =>
      item.historyItem?.duration ?? item.localItem?.duration;

  /// The mix's songs whose files can still play, each with its position in
  /// the mix.
  Future<List<(int, PlayableMedia)>> _playable() async {
    final present = await Future.wait([
      for (final item in _items) fileExists(item.filePath),
    ]);
    return [
      for (final (index, item) in _items.indexed)
        if (present[index])
          if (item.localItem case final local?)
            (index, playableFromLocal(local))
          else if (item.historyItem case final history?)
            (index, playableFromHistory(history)),
    ];
  }

  /// Plays the mix as the queue, from the song at [index] or the nearest
  /// playable one after it.
  Future<void> _play(int index) async {
    final songs = await _playable();
    if (songs.isEmpty || !mounted) return;
    final start = songs.indexWhere((song) => song.$1 >= index);
    final controller = ref.read(musicPlayerControllerProvider);
    await controller.setShuffle(false);
    await controller.playAll([
      for (final song in songs) song.$2,
    ], initialIndex: max(0, start));
  }

  Future<void> _shuffle() async {
    final songs = await _playable();
    if (songs.isEmpty || !mounted) return;
    final controller = ref.read(musicPlayerControllerProvider);
    await controller.playAll([
      for (final song in songs) song.$2,
    ], initialIndex: Random().nextInt(songs.length));
    await controller.setShuffle(true);
  }

  Future<void> _saveAsPlaylist(BuildContext context) =>
      showAddTracksToPlaylistSheet(
        Navigator.of(context, rootNavigator: true).context,
        ref,
        [for (final item in _items) item.toTrack()],
        playlistNamePrefill: libraryMixTitle(context.l10n, widget.view.mix),
      );
}
