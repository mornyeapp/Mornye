import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/collection_suggestions_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/preview_button.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/widgets/track_list_tile.dart';

/// Songs like an album's, single's or playlist's under it, each with a
/// preview, an add button and a tap that downloads it. Phones list them as
/// rows, desktop in the song table the page uses. Shows nothing while
/// loading, without a source extension, or when nothing new was found: the
/// section is a bonus below the collection, not part of it.
class CollectionSuggestionsSliver extends ConsumerStatefulWidget {
  const CollectionSuggestionsSliver({
    super.key,
    required this.collectionKey,
    required this.tracks,
    this.playlistId,
  });

  /// Identifies the collection across rebuilds, such as `album:<id>`.
  final String collectionKey;

  /// The collection's songs, most important first.
  final List<Track> tracks;

  /// The user playlist the add button adds to; elsewhere it opens the
  /// playlist picker.
  final String? playlistId;

  @override
  ConsumerState<CollectionSuggestionsSliver> createState() =>
      _CollectionSuggestionsSliverState();
}

class _CollectionSuggestionsSliverState
    extends ConsumerState<CollectionSuggestionsSliver> {
  var _round = 0;
  var _selectedIds = const <String>{};

  Future<void> _add(Track track) async {
    final playlistId = widget.playlistId;
    if (playlistId == null) {
      await showAddTracksToPlaylistSheet(context, ref, [track]);
      return;
    }
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final added = await notifier.addTrackToPlaylist(playlistId, track);
    if (!mounted) return;
    final name =
        ref.read(libraryCollectionsProvider).playlistById(playlistId)?.name ??
        '';
    final l10n = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? l10n.collectionAddedToPlaylist(name)
              : l10n.collectionAlreadyInPlaylist(name),
        ),
      ),
    );
  }

  void _download(Track track, {bool forceQualityPicker = false}) =>
      downloadSingleTrack(
        context,
        ref,
        track,
        forceQualityPicker: forceQualityPicker,
      );

  @override
  Widget build(BuildContext context) {
    final suggestions = ref
        .watch(
          collectionSuggestionsProvider(
            CollectionSuggestionsRequest(
              key: widget.collectionKey,
              round: _round,
              tracks: widget.tracks,
            ),
          ),
        )
        .maybeWhen(data: (value) => value, orElse: () => null);
    final playlistId = widget.playlistId;
    // Songs added from here leave the list as they join the playlist.
    final entries = playlistId == null
        ? null
        : ref.watch(
            libraryCollectionsProvider.select(
              (state) => state.playlistById(playlistId)?.tracks,
            ),
          );
    final collection = entries == null
        ? widget.tracks
        : [for (final entry in entries) entry.track];
    final tracks = suggestions == null
        ? const <Track>[]
        : filterCollectionSuggestions(suggestions.tracks, collection);
    if (suggestions == null || tracks.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final header = _SuggestionsHeader(
      related: suggestions.related,
      onRefresh: () => setState(() {
        _round++;
        _selectedIds = const {};
      }),
    );
    final inset = wideListInset(context);
    final addTooltip = playlistId != null
        ? context.l10n.collectionSuggestionsAddHere
        : context.l10n.collectionAddToPlaylist;
    if (isDesktopPlatform) {
      final ids = [
        for (final (i, track) in tracks.indexed)
          'suggestion:$i:${track.source}:${track.id}',
      ];
      return SliverMainAxisGroup(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 32, inset, 8),
            sliver: SliverToBoxAdapter(child: header),
          ),
          TrackListTable(
            tracks: tracks,
            ids: ids,
            isInHistory: List.filled(tracks.length, false),
            selectedIds: _selectedIds,
            onSelect: (id, _, _) => setState(() => _selectedIds = {id}),
            onActivate: (index) => TrackListTile.activate(
              context,
              ref,
              tracks[index],
              isInHistory: false,
              onDownload: ({bool forceQualityPicker = false}) => _download(
                tracks[index],
                forceQualityPicker: forceQualityPicker,
              ),
            ),
            showArtwork: true,
            showAlbum: true,
            showPreview: true,
            rowAction: (index) => AppIconButton(
              icon: const AppIcon.adaptive(Icons.add_circle_outline, size: 20),
              tooltip: addTooltip,
              onPressed: () => _add(tracks[index]),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(inset, 24, inset, 0),
      sliver: SliverList.list(
        children: [
          header,
          for (final track in tracks)
            _SuggestionRow(
              key: ValueKey('suggestion:${track.source}:${track.id}'),
              track: track,
              addTooltip: addTooltip,
              onAdd: () => _add(track),
              onDownload: () => _download(track),
            ),
        ],
      ),
    );
  }
}

class _SuggestionsHeader extends StatelessWidget {
  const _SuggestionsHeader({required this.related, required this.onRefresh});

  final bool related;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.collectionSuggestionsTitle,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  related
                      ? l10n.collectionSuggestionsRelated
                      : l10n.collectionSuggestionsByArtists,
                  style: textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AppIconButton(
            icon: const AppIcon.adaptive(Icons.refresh),
            tooltip: l10n.collectionSuggestionsRefresh,
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends ConsumerWidget {
  const _SuggestionRow({
    super.key,
    required this.track,
    required this.addTooltip,
    required this.onAdd,
    required this.onDownload,
  });

  final Track track;
  final String addTooltip;
  final VoidCallback onAdd;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = context.tokens.coverCompact;
    final cover = track.coverUrl?.trim() ?? '';
    return TrackCard(
      style: TrackCardStyle.flat,
      leadingArtwork: true,
      leading: ClipRRect(
        borderRadius: context.tokens.borderRadiusThumb,
        child: cover.isEmpty
            ? TrackCoverPlaceholder(size: size)
            : LocalOrNetworkCoverImage(
                url: cover,
                width: size,
                height: size,
                networkCacheWidth: (size * 2).toInt(),
                placeholder: (_) => TrackCoverPlaceholder(size: size),
              ),
      ),
      title: track.name,
      subtitle: Text(
        track.artistName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PreviewButton(track: track),
          AppIconButton(
            icon: const AppIcon.adaptive(Icons.add_circle_outline),
            tooltip: addTooltip,
            onPressed: onAdd,
          ),
        ],
      ),
      onTap: onDownload,
      onLongPress: () => TrackCollectionQuickActions.showTrackOptionsSheet(
        context,
        ref,
        track,
      ),
    );
  }
}
