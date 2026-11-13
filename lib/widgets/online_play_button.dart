import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/play_online.dart';
import 'package:mornye/models/track.dart';

/// A direct ▶ control next to a song; hold to select streaming quality.
/// Normal taps never open the old track-options menu or download anything.
class OnlinePlayButton extends ConsumerWidget {
  const OnlinePlayButton({
    super.key,
    required this.tracks,
    required this.index,
    this.size = 24,
  });

  final List<Track> tracks;
  final int index;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tracks.isEmpty || index < 0 || index >= tracks.length) {
      return const SizedBox.shrink();
    }
    return Semantics(
      button: true,
      label: 'Play online; hold to select quality',
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => playOnlineQueue(context, ref, tracks, startIndex: index),
        onLongPress: () =>
            chooseOnlineQuality(context, ref, tracks, startIndex: index),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(Icons.play_circle_outline_rounded, size: size),
          ),
        ),
      ),
    );
  }
}
