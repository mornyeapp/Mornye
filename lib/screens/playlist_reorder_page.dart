import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/priority_settings_scaffold.dart';
import 'package:mornye/widgets/track_card.dart';

/// Reorders one playlist. Rows drag by their handle or after a long press,
/// so a touch drag elsewhere still scrolls a long playlist.
class PlaylistReorderPage extends ConsumerStatefulWidget {
  const PlaylistReorderPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistReorderPage> createState() =>
      _PlaylistReorderPageState();
}

class _PlaylistReorderPageState extends ConsumerState<PlaylistReorderPage> {
  late List<CollectionTrackEntry> _entries;
  bool _hasChanges = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _entries = [
      ...?ref
          .read(libraryCollectionsProvider)
          .playlistById(widget.playlistId)
          ?.tracks,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PrioritySettingsScaffold(
      hasChanges: _hasChanges,
      title: context.l10n.playlistEditOrder,
      description: context.l10n.playlistEditOrderDescription,
      onSave: _save,
      onConfirmDiscard: showDiscardChangesDialog,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
          sliver: SliverReorderableList(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(entry.key),
                index: index,
                child: _ReorderTrackRow(entry: entry, index: index),
              );
            },
            onReorderItem: (oldIndex, newIndex) {
              setState(() {
                final entry = _entries.removeAt(oldIndex);
                _entries.insert(newIndex, entry);
                _hasChanges = true;
              });
            },
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    try {
      // False when the order is unchanged or the playlist changed meanwhile.
      final saved = await ref
          .read(libraryCollectionsProvider.notifier)
          .reorderPlaylistTracks(widget.playlistId, [
            for (final entry in _entries) entry.key,
          ]);
      if (!mounted) return;
      setState(() => _hasChanges = false);
      if (saved) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.playlistEditOrderSaved),
        );
      }
      Navigator.pop(context);
    } finally {
      _saving = false;
    }
  }
}

class _ReorderTrackRow extends StatelessWidget {
  const _ReorderTrackRow({required this.entry, required this.index});

  final CollectionTrackEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final track = entry.track;
    final size = context.tokens.coverCompact;
    final coverUrl = track.coverUrl;
    return TrackCard(
      style: TrackCardStyle.flat,
      leadingArtwork: true,
      leading: ClipRRect(
        borderRadius: context.tokens.borderRadiusThumb,
        child: coverUrl != null && coverUrl.isNotEmpty
            ? LocalOrNetworkCoverImage(
                url: coverUrl,
                width: size,
                height: size,
                networkCacheWidth: (size * 2).toInt(),
                placeholder: (_) => TrackCoverPlaceholder(size: size),
              )
            : TrackCoverPlaceholder(size: size),
      ),
      title: track.name,
      subtitle: Text(
        track.artistName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: ReorderableDragStartListener(
        index: index,
        child: SizedBox.square(
          dimension: context.tokens.minTouchTarget,
          child: AppIcon.adaptive(
            Icons.drag_handle,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
