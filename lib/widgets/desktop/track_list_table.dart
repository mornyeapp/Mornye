import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/preview_button.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/track_list_tile.dart';

/// The desktop song table for album, playlist and folder [Track] lists, in
/// place of
/// [TrackListTile] rows. Right-click opens the track options; a click and
/// Enter run [onActivate], which should match a tap on a mobile row (see
/// [TrackListTile.activate]).
class TrackListTable extends ConsumerStatefulWidget {
  const TrackListTable({
    super.key,
    required this.tracks,
    required this.ids,
    required this.isInHistory,
    required this.selectedIds,
    required this.onSelect,
    required this.onActivate,
    this.onContextMenu,
    this.showArtwork = false,
    this.showAlbum = false,
    this.albumLayout = false,
    this.albumArtist,
    this.showPreview = false,
    this.onSaveCover,
    this.rowAction,
  });

  /// See [SliverTrackTable.albumLayout] and [SliverTrackTable.albumArtist].
  final bool albumLayout;
  final String? albumArtist;

  final List<Track> tracks;

  /// Selection id of each track, by index.
  final List<String> ids;

  /// Whether each track, by index, is in the download history.
  final List<bool> isInHistory;
  final Set<String> selectedIds;
  final void Function(String id, DesktopClick kind, List<String> orderedIds)
  onSelect;

  /// Runs the row at this index.
  final ValueChanged<int> onActivate;

  /// Opens the menu of the row at this index. Defaults to the track options
  /// of the row's ellipsis button.
  final void Function(int index, Offset position)? onContextMenu;

  /// Playlists show artwork and the album; albums show track numbers.
  final bool showArtwork;
  final bool showAlbum;

  /// Search results keep the preview button of their phone rows beside the
  /// title.
  final bool showPreview;

  /// Saves the cover of the row at this index on a long press of its
  /// artwork, as the phone search rows do.
  final ValueChanged<int>? onSaveCover;

  /// A button before the More button of the row at this index, such as the
  /// add button of playlist suggestions.
  final Widget Function(int index)? rowAction;

  @override
  ConsumerState<TrackListTable> createState() => _TrackListTableState();
}

class _TrackListTableState extends ConsumerState<TrackListTable> {
  // Rows depend only on the tracks, ids, history flags and artwork, so a
  // selection change keeps the same list and the table keeps its order.
  late List<TrackTableRow> _rows = _buildRows();

  @override
  void didUpdateWidget(TrackListTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showArtwork != oldWidget.showArtwork ||
        widget.showPreview != oldWidget.showPreview ||
        (widget.onSaveCover == null) != (oldWidget.onSaveCover == null) ||
        (widget.rowAction == null) != (oldWidget.rowAction == null) ||
        !listEquals(widget.tracks, oldWidget.tracks) ||
        !listEquals(widget.ids, oldWidget.ids) ||
        !listEquals(widget.isInHistory, oldWidget.isInHistory)) {
      _rows = _buildRows();
    }
  }

  List<TrackTableRow> _buildRows() {
    final TrackListTable(
      :tracks,
      :ids,
      :isInHistory,
      :showArtwork,
      :showPreview,
      :onSaveCover,
    ) = widget;
    Widget badges(int i) =>
        TrackListTileBadges(track: tracks[i], isInHistory: isInHistory[i]);
    return [
      for (var i = 0; i < tracks.length; i++)
        TrackTableRow(
          id: ids[i],
          number: showArtwork ? i + 1 : tracks[i].trackNumber,
          title: tracks[i].name,
          artist: tracks[i].artistName,
          album: tracks[i].albumName,
          quality: tracks[i].audioQuality,
          duration: tracks[i].duration > 0
              ? Duration(seconds: tracks[i].duration)
              : null,
          leading: showArtwork
              ? _Artwork(
                  url: tracks[i].coverUrl,
                  title: tracks[i].name,
                  // Reads the current callback, as the rows outlive it.
                  onSave: onSaveCover == null
                      ? null
                      : () => widget.onSaveCover?.call(i),
                )
              : null,
          titleTrailing: showPreview
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PreviewButton(track: tracks[i], size: 20, dense: true),
                    badges(i),
                  ],
                )
              : badges(i),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reads the current callback, as the rows outlive it.
              ?widget.rowAction?.call(i),
              TrackCollectionQuickActions(
                track: tracks[i],
                hasLocalPlaybackCandidate: isInHistory[i],
                dense: true,
              ),
            ],
          ),
          playback: catalogTrackPlaybackUiProvider(catalogTrackKey(tracks[i])),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.ids;
    final indexById = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final rows = _rows;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverTrackTable(
        rows: rows,
        columns: [
          TrackTableColumn.number,
          TrackTableColumn.title,
          TrackTableColumn.artist,
          if (widget.showAlbum) TrackTableColumn.album,
          // Catalog pages often list no quality before a download.
          if (rows.any((row) => row.quality?.isNotEmpty ?? false))
            TrackTableColumn.quality,
          TrackTableColumn.duration,
        ],
        selectedIds: widget.selectedIds,
        albumLayout: widget.albumLayout,
        albumArtist: widget.albumArtist,
        onSelect: widget.onSelect,
        onActivate: (id) {
          final index = indexById[id];
          if (index != null) widget.onActivate(index);
        },
        onContextMenu: (id, position) {
          final index = indexById[id];
          if (index == null) return;
          final override = widget.onContextMenu;
          if (override != null) return override(index, position);
          TrackCollectionQuickActions.showTrackOptionsSheet(
            context,
            ref,
            widget.tracks[index],
            position: position,
            hasLocalPlaybackCandidate: widget.isInHistory[index],
          );
        },
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url, required this.title, this.onSave});

  final String? url;
  final String title;

  /// Saves the cover on a long press.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null || url.isEmpty) {
      return const TrackCoverPlaceholder(size: 32);
    }
    // Collection tracks can carry a local artwork path.
    final image = LocalOrNetworkCoverImage(
      url: url,
      width: 32,
      height: 32,
      borderRadius: BorderRadius.circular(4),
      networkCacheWidth: 96,
      localCacheWidth: 96,
      placeholder: (_) => const TrackCoverPlaceholder(size: 32),
    );
    final onSave = this.onSave;
    if (onSave == null) return image;
    return Semantics(
      label:
          '${context.l10n.dialogDownload} '
          '${context.l10n.editMetadataFieldCover}: $title',
      button: true,
      onLongPress: onSave,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: onSave,
        child: image,
      ),
    );
  }
}
