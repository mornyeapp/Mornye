import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/controllers/play_online.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/widgets/app_icon_button.dart';

/// Backward-compatible widget name for legacy layouts.
///
/// This is now a full-song Play control. It NEVER calls the short preview
/// player or a previewUrl. Download actions use a separate button.
class PreviewButton extends ConsumerWidget {
  const PreviewButton({
    super.key,
    required this.track,
    this.size = 24,
    this.dense = false,
  });

  final Track track;
  final double size;
  final bool dense;

  BoxConstraints get _constraints => dense
      ? const BoxConstraints(minWidth: 32, minHeight: 32)
      : const BoxConstraints(minWidth: 48, minHeight: 48);

  bool _isCurrentMainTrack(MediaItem? item) {
    if (item == null) return false;
    String norm(String? value) => (value ?? '').toLowerCase().trim();
    return norm(item.title) == norm(track.name) &&
        norm(item.artist) == norm(track.artistName);
  }

  Future<void> _play(BuildContext context, WidgetRef ref) async {
    final playedLocal = await playLocalIfAvailable(context, ref, track);
    if (playedLocal || !context.mounted) return;
    await playOnline(context, ref, track);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrent = ref.watch(
      currentMediaItemProvider.select(
        (item) => _isCurrentMainTrack(item.value),
      ),
    );
    final isPlaying = isCurrent && ref.watch(playbackPlayingProvider);
    return AppIconButton(
      iconSize: size,
      padding: EdgeInsets.zero,
      constraints: _constraints,
      style: dense
          ? IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      icon: Icon(
        isPlaying
            ? Icons.pause_circle_filled_rounded
            : Icons.play_circle_outline_rounded,
        color: isCurrent
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: isPlaying ? 'Pause full track' : 'Play full track',
      onPressed: isCurrent
          ? () => ref
              .read(musicPlayerControllerProvider)
              .togglePlayPause(isPlaying)
          : () => _play(context, ref),
    );
  }
}
