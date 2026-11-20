import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/queue_swipe.dart';
import 'package:mornye/widgets/song_row_tap.dart';
import 'package:mornye/widgets/track_card.dart';

/// Album-style track row: track number, title/subtitle, and a trailing play
/// button that's hidden once selection mode is active. The Library song tap
/// setting can swap the tap and the button (see [songRowTap]).
///
/// A thin arrangement over [TrackCard]; the container, selection tick, padding
/// and typography all come from there.
class AlbumTrackTile extends ConsumerWidget {
  const AlbumTrackTile({
    super.key,
    required this.trackNumber,
    required this.trackName,
    required this.subtitle,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onToggleSelection,
    required this.onOpen,
    required this.onEnterSelectionMode,
    required this.onPlay,
    this.isCurrent = false,
    this.isPlaying = false,
    this.queueSwipe,
    this.filePath,
  });

  final int? trackNumber;
  final String trackName;
  final Widget subtitle;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onToggleSelection;
  final VoidCallback onOpen;
  final VoidCallback onEnterSelectionMode;
  final VoidCallback onPlay;

  /// The row is the player's current track. See [TrackCard.isCurrent].
  final bool isCurrent;

  /// The current track is playing: the button offers pause.
  final bool isPlaying;

  /// See [TrackCard.queueSwipe].
  final QueueSwipeActions? queueSwipe;

  /// The track's file. A CUE virtual track's tap opens it ([songRowTap]).
  final String? filePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TrackCard(
      style: collectionTrackCardStyle(context),
      queueSwipe: queueSwipe,
      isSelectionMode: isSelectionMode,
      isSelected: isSelected,
      isCurrent: isCurrent,
      isPlaying: isPlaying,
      onTap: isSelectionMode
          ? onToggleSelection
          : songRowTap(ref, path: filePath, openDetails: onOpen, play: onPlay),
      onLongPress: onEnterSelectionMode,
      leading: SizedBox(
        width: 24,
        // Takes the row's supporting colour, which follows a current fill.
        child: Text(
          trackNumber?.toString() ?? '-',
          style: const TextStyle(fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
      ),
      title: trackName,
      subtitle: subtitle,
      trailing: SongRowButton(
        playButton: AlbumTrackPlayButton(isPlaying: isPlaying, onPlay: onPlay),
        onOpenDetails: onOpen,
        path: filePath,
      ),
    );
  }
}

/// The play or pause button at the end of an album track row.
class AlbumTrackPlayButton extends StatelessWidget {
  const AlbumTrackPlayButton({
    super.key,
    required this.isPlaying,
    required this.onPlay,
    this.dense = false,
  });

  final bool isPlaying;
  final VoidCallback? onPlay;

  /// A 32dp pointer target for desktop table rows.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Material draws a filled tonal icon button: a solid role pair rather
    // than a faded primary container.
    return AppIconButton(
      tooltip: isPlaying ? context.l10n.actionPause : context.l10n.tooltipPlay,
      onPressed: onPlay,
      icon: Icon(
        context.isMornye
            ? (isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill)
            : (isPlaying ? Icons.pause : Icons.play_arrow),
        color: context.isMornye
            ? colorScheme.primary
            : colorScheme.onSecondaryContainer,
        size: dense ? 18 : null,
      ),
      style: IconButton.styleFrom(
        minimumSize: Size.square(dense ? 32 : context.tokens.minTouchTarget),
        padding: dense ? EdgeInsets.zero : null,
        tapTargetSize: dense ? MaterialTapTargetSize.shrinkWrap : null,
        backgroundColor: context.isMornye
            ? Colors.transparent
            : colorScheme.secondaryContainer,
      ),
    );
  }
}
