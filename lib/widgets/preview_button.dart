import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/preview_player_provider.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

class PreviewButton extends ConsumerWidget {
  final Track track;
  final double size;

  /// A 32dp pointer target for desktop table rows.
  final bool dense;

  const PreviewButton({
    super.key,
    required this.track,
    this.size = 24,
    this.dense = false,
  });

  BoxConstraints get _constraints => dense
      ? const BoxConstraints(minWidth: 32, minHeight: 32)
      : const BoxConstraints(minWidth: 48, minHeight: 48);

  ButtonStyle? get _style => dense
      ? IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap)
      : null;

  Future<void> _onPressed(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(previewPlayerProvider.notifier).toggle(track.previewUrl);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.previewUnavailable)));
    }
  }

  /// Loosely matches the built-in player's current item to this track so the
  /// per-track button stays in sync with the mini player instead of showing a
  /// conflicting preview state.
  bool _isCurrentMainTrack(MediaItem? item) {
    if (item == null) return false;
    String norm(String? s) => (s ?? '').toLowerCase().trim();
    return norm(item.title) == norm(track.name) &&
        norm(item.artist) == norm(track.artistName);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    // When the built-in player is currently on this track, mirror and control
    // it (consistent with the mini player) rather than the preview snippet.
    final isCurrentMainTrack = ref.watch(
      currentMediaItemProvider.select(
        (item) => _isCurrentMainTrack(item.value),
      ),
    );
    if (isCurrentMainTrack) {
      final isPlaying = ref.watch(playbackPlayingProvider);
      return AppIconButton(
        iconSize: size,
        padding: EdgeInsets.zero,
        constraints: _constraints,
        style: _style,
        icon: Icon(
          isPlaying
              ? Icons.pause_circle_filled_rounded
              : Icons.play_circle_fill_rounded,
          color: colorScheme.primary,
        ),
        tooltip: isPlaying
            ? context.l10n.previewStop
            : context.l10n.previewPlay,
        onPressed: () =>
            ref.read(musicPlayerControllerProvider).togglePlayPause(isPlaying),
      );
    }

    if (!track.hasPreview) return const SizedBox.shrink();

    final status = ref.watch(
      previewPlayerProvider.select(
        (state) => state.isActiveUrl(track.previewUrl)
            ? state.status
            : PreviewStatus.idle,
      ),
    );

    final Widget icon;
    final String tooltip;
    switch (status) {
      case PreviewStatus.loading:
        icon = AppLoadingIndicator(
          size: size * 0.7,
          strokeWidth: 2,
          color: colorScheme.primary,
        );
        tooltip = context.l10n.previewStop;
        break;
      case PreviewStatus.playing:
        icon = Icon(
          Icons.pause_circle_filled_rounded,
          color: colorScheme.primary,
        );
        tooltip = context.l10n.previewStop;
        break;
      case PreviewStatus.paused:
        icon = Icon(Icons.play_circle_fill_rounded, color: colorScheme.primary);
        tooltip = context.l10n.previewPlay;
        break;
      case PreviewStatus.idle:
        icon = Icon(
          Icons.play_circle_outline_rounded,
          color: colorScheme.onSurfaceVariant,
        );
        tooltip = context.l10n.previewPlay;
        break;
    }

    return AppIconButton(
      iconSize: size,
      padding: EdgeInsets.zero,
      constraints: _constraints,
      style: _style,
      icon: icon,
      tooltip: tooltip,
      onPressed: () => _onPressed(context, ref),
    );
  }
}
