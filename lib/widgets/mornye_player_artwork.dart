import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/player_artwork.dart';

class MornyePlayerArtwork extends ConsumerStatefulWidget {
  const MornyePlayerArtwork({
    super.key,
    required this.mediaItem,
    this.videoUrl,
    this.onAspectRatioChanged,
    this.onError,
    this.resolvingVideo = false,
    this.squareWhileLoading = true,
    this.crossfade,
  });

  final MediaItem mediaItem;
  final String? videoUrl;
  final ValueChanged<double>? onAspectRatioChanged;
  final VoidCallback? onError;
  final bool resolvingVideo;

  /// Keeps the still cover square at the top until the video shows, for a
  /// video that may be wider than its box. False fills the box with the
  /// cover, cropped the way the video will be.
  final bool squareWhileLoading;

  /// Fades the still cover of the next track in over this one, as
  /// [PlayerArtwork.crossfade] does. Null swaps it at once.
  final AppMotionSpec? crossfade;

  @override
  ConsumerState<MornyePlayerArtwork> createState() =>
      _MornyePlayerArtworkState();
}

class _MornyePlayerArtworkState extends ConsumerState<MornyePlayerArtwork> {
  final _shown = ShownArtworkVideo();

  @override
  Widget build(BuildContext context) {
    final cover = PlayerArtwork(
      artUri: widget.mediaItem.artUri?.toString(),
      colorScheme: Theme.of(context).colorScheme,
      cacheWidth: PlayerArtwork.transitionCacheWidth(context),
      crossfade: widget.crossfade,
    );
    // Without a video, the still cover fills its box (a full-screen box is
    // taller than wide and crops the sides). A video keeps the square cover
    // at its top while it loads, since its own frame may be wider.
    final fallback = widget.videoUrl == null || !widget.squareWhileLoading
        ? SizedBox.expand(child: cover)
        : Align(
            alignment: Alignment.topCenter,
            child: AspectRatio(aspectRatio: 1, child: cover),
          );
    if (MediaQuery.disableAnimationsOf(context) ||
        !ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
      _shown.clear();
      return fallback;
    }
    final failed = _shown.watch(
      ref,
      widget.videoUrl,
      resolving: widget.resolvingVideo,
    );
    if (failed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onError?.call();
      });
    }
    final source = _shown.source;
    final controller = _shown.controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        fallback,
        if (source != null && controller != null)
          MotionHeaderBanner(
            videoUrl: source,
            fallback: const SizedBox.shrink(),
            controller: controller,
            fadeDuration: Duration.zero,
            onAspectRatioChanged: (ratio) {
              if (_shown.source == widget.videoUrl) {
                widget.onAspectRatioChanged?.call(ratio);
              }
            },
            onError: () {
              if (_shown.source == widget.videoUrl) widget.onError?.call();
            },
          ),
      ],
    );
  }
}
