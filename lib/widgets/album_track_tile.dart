import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/track_card.dart';

/// Album-style track row: track number, title/subtitle, and a trailing play
/// button that's hidden once selection mode is active.
///
/// A thin arrangement over [TrackCard]; the container, selection tick, padding
/// and typography all come from there.
class AlbumTrackTile extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    return TrackCard(
      style: TrackCardStyle.flat,
      isSelectionMode: isSelectionMode,
      isSelected: isSelected,
      isCurrent: isCurrent,
      isPlaying: isPlaying,
      onTap: isSelectionMode ? onToggleSelection : onOpen,
      onLongPress: isSelectionMode ? null : onEnterSelectionMode,
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
      trailing: AlbumTrackPlayButton(isPlaying: isPlaying, onPlay: onPlay),
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
