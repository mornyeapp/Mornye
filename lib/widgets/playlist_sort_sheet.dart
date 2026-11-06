import 'package:flutter/material.dart';
import 'package:mornye/models/playlist_sort.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/track_table.dart';

PlaylistSortMode playlistSortFromTableSort(TrackTableSort? sort) {
  if (sort == null) return PlaylistSortMode.custom;
  return switch (sort.column) {
    TrackTableColumn.dateAdded =>
      sort.ascending
          ? PlaylistSortMode.dateAddedAsc
          : PlaylistSortMode.dateAddedDesc,
    TrackTableColumn.title =>
      sort.ascending ? PlaylistSortMode.titleAsc : PlaylistSortMode.titleDesc,
    TrackTableColumn.artist =>
      sort.ascending ? PlaylistSortMode.artistAsc : PlaylistSortMode.artistDesc,
    TrackTableColumn.album =>
      sort.ascending ? PlaylistSortMode.albumAsc : PlaylistSortMode.albumDesc,
    TrackTableColumn.duration =>
      sort.ascending
          ? PlaylistSortMode.durationAsc
          : PlaylistSortMode.durationDesc,
    _ => PlaylistSortMode.custom,
  };
}

TrackTableSort? tableSortFromPlaylistSort(PlaylistSortMode mode) {
  return switch (mode) {
    PlaylistSortMode.custom => null,
    PlaylistSortMode.dateAddedAsc => (
      column: TrackTableColumn.dateAdded,
      ascending: true,
    ),
    PlaylistSortMode.dateAddedDesc => (
      column: TrackTableColumn.dateAdded,
      ascending: false,
    ),
    PlaylistSortMode.titleAsc => (
      column: TrackTableColumn.title,
      ascending: true,
    ),
    PlaylistSortMode.titleDesc => (
      column: TrackTableColumn.title,
      ascending: false,
    ),
    PlaylistSortMode.artistAsc => (
      column: TrackTableColumn.artist,
      ascending: true,
    ),
    PlaylistSortMode.artistDesc => (
      column: TrackTableColumn.artist,
      ascending: false,
    ),
    PlaylistSortMode.albumAsc => (
      column: TrackTableColumn.album,
      ascending: true,
    ),
    PlaylistSortMode.albumDesc => (
      column: TrackTableColumn.album,
      ascending: false,
    ),
    PlaylistSortMode.durationAsc => (
      column: TrackTableColumn.duration,
      ascending: true,
    ),
    PlaylistSortMode.durationDesc => (
      column: TrackTableColumn.duration,
      ascending: false,
    ),
  };
}

/// Human-readable label for each sort mode.
String playlistSortLabel(PlaylistSortMode mode) => switch (mode) {
  PlaylistSortMode.custom => 'Custom order',
  PlaylistSortMode.dateAddedDesc => 'Date added (newest first)',
  PlaylistSortMode.dateAddedAsc => 'Date added (oldest first)',
  PlaylistSortMode.titleAsc => 'Title (A-Z)',
  PlaylistSortMode.titleDesc => 'Title (Z-A)',
  PlaylistSortMode.artistAsc => 'Artist (A-Z)',
  PlaylistSortMode.artistDesc => 'Artist (Z-A)',
  PlaylistSortMode.albumAsc => 'Album (A-Z)',
  PlaylistSortMode.albumDesc => 'Album (Z-A)',
  PlaylistSortMode.durationAsc => 'Duration (shortest first)',
  PlaylistSortMode.durationDesc => 'Duration (longest first)',
};

/// Icon representing each sort mode.
IconData playlistSortIcon(PlaylistSortMode mode) => switch (mode) {
  PlaylistSortMode.custom => Icons.swap_vert,
  PlaylistSortMode.dateAddedDesc ||
  PlaylistSortMode.dateAddedAsc => Icons.calendar_today_outlined,
  PlaylistSortMode.titleAsc ||
  PlaylistSortMode.titleDesc => Icons.sort_by_alpha,
  PlaylistSortMode.artistAsc ||
  PlaylistSortMode.artistDesc => Icons.person_outline,
  PlaylistSortMode.albumAsc ||
  PlaylistSortMode.albumDesc => Icons.album_outlined,
  PlaylistSortMode.durationAsc ||
  PlaylistSortMode.durationDesc => Icons.timer_outlined,
};

/// Shows a sheet or desktop context menu to pick a playlist sorting mode.
Future<PlaylistSortMode?> showPlaylistSortSheet({
  required BuildContext context,
  required PlaylistSortMode currentSort,
  bool hasDateAdded = true,
  BuildContext? anchor,
}) async {
  final modes = [
    PlaylistSortMode.custom,
    if (hasDateAdded) ...[
      PlaylistSortMode.dateAddedDesc,
      PlaylistSortMode.dateAddedAsc,
    ],
    PlaylistSortMode.titleAsc,
    PlaylistSortMode.titleDesc,
    PlaylistSortMode.artistAsc,
    PlaylistSortMode.artistDesc,
    PlaylistSortMode.albumAsc,
    PlaylistSortMode.albumDesc,
    PlaylistSortMode.durationAsc,
    PlaylistSortMode.durationDesc,
  ];

  final position = contextMenuPositionBelow(anchor ?? context);
  if (position != null) {
    PlaylistSortMode? picked;
    final chosen = await showContextMenu(
      context,
      position: position,
      groups: [
        [
          for (final mode in modes)
            ContextMenuAction(
              icon: playlistSortIcon(mode),
              label: playlistSortLabel(mode),
              checked: mode == currentSort,
              onSelected: () => picked = mode,
            ),
        ],
      ],
    );
    if (chosen && picked != null) return picked;
    return null;
  }

  return showModalBottomSheet<PlaylistSortMode>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => AppBottomSheet(
      title: 'Sort playlist',
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in modes)
                ListTile(
                  dense: true,
                  leading: Icon(
                    playlistSortIcon(mode),
                    color: mode == currentSort
                        ? Theme.of(sheetContext).colorScheme.primary
                        : Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                  title: Text(playlistSortLabel(mode)),
                  selected: mode == currentSort,
                  trailing: mode == currentSort
                      ? Icon(
                          Icons.check,
                          color: Theme.of(sheetContext).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(mode),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A button for the playlist header that opens the sort menu/sheet.
Widget buildPlaylistSortButton({
  required BuildContext context,
  required PlaylistSortMode currentSort,
  required ValueChanged<PlaylistSortMode> onSortChanged,
  bool hasDateAdded = true,
  String? tooltip,
}) {
  final isCustom = currentSort == PlaylistSortMode.custom;
  return Builder(
    builder: (btnContext) => HeaderCircleButton(
      key: const ValueKey('playlist-sort-button'),
      icon: isCustom ? Icons.sort : Icons.filter_list,
      iconColor: isCustom ? null : Theme.of(btnContext).colorScheme.primary,
      tooltip:
          tooltip ??
          (isCustom ? 'Sort' : 'Sorted: ${playlistSortLabel(currentSort)}'),
      onPressed: () async {
        final selected = await showPlaylistSortSheet(
          context: btnContext,
          currentSort: currentSort,
          hasDateAdded: hasDateAdded,
          anchor: btnContext,
        );
        if (selected != null) {
          onSortChanged(selected);
        }
      },
    ),
  );
}
