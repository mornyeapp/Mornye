import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:video_player/video_player.dart';

/// What moving artwork in the Mornye player ends in: the video turns soft
/// where it fades, then settles into one colour taken from its lower edge,
/// and both follow the frames as they play. Two more copies of the video's
/// texture draw it, so no frame is read back from the GPU.
///
/// It goes over [MornyePlayerBackground] with the same artwork geometry and
/// under [MornyeControlsDim]. Without a playing video, and where the device
/// does not draw continuously filtered effects ([mornyeLiquidGlassProvider]),
/// it draws nothing and the page keeps its cover-coloured fade.
class MornyeMotionGlow extends ConsumerStatefulWidget {
  const MornyeMotionGlow({
    super.key,
    required this.videoUrl,
    required this.visible,
    this.resolvingVideo = false,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.58,
  });

  /// The motion artwork of the current track, if it has one.
  final String? videoUrl;

  /// False behind lyrics and the queue, where the artwork is gone.
  final bool visible;

  /// True while a newer [videoUrl] is still being looked up, so the layers
  /// stay on the video that is still on screen.
  final bool resolvingVideo;

  final bool squareArtwork;
  final double? artworkAspectRatio;
  final double fadeStart;

  /// How far the soft copy of the video is blurred, in logical pixels.
  static const softSigma = 24.0;

  /// The share of the video, from its lower edge, that gives the one colour.
  static const colourEdge = 0.3;

  /// How much the one colour is darkened for the white labels on it, on top
  /// of [MornyeControlsDim].
  static const colourShade = 0.12;

  @override
  ConsumerState<MornyeMotionGlow> createState() => _MornyeMotionGlowState();
}

class _MornyeMotionGlowState extends ConsumerState<MornyeMotionGlow> {
  final _video = ShownArtworkVideo();

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion ||
        !ref.watch(mornyeLiquidGlassProvider) ||
        !ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
      _video.clear();
    } else {
      _video.watch(ref, widget.videoUrl, resolving: widget.resolvingVideo);
    }
    final controller = _video.controller;
    final videoSize = controller?.value.size ?? Size.zero;
    final size = MediaQuery.sizeOf(context);
    final artworkHeight = mornyeArtworkHeight(
      size,
      squareArtwork: widget.squareArtwork,
      aspectRatio: widget.artworkAspectRatio,
    );
    final fadeTop = artworkHeight * widget.fadeStart;
    final fade = artworkHeight - fadeTop;
    final shows = controller != null && !videoSize.isEmpty && fade > 0;
    final motion = mornyePlayerPanelMotion(context);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: shows && widget.visible ? 1 : 0,
        duration: motion.duration,
        curve: motion.curve,
        child: !shows
            ? const SizedBox.expand()
            : RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Starts under the part of the soft copy that hides
                    // the video, so its upper edge is never seen.
                    Positioned(
                      left: 0,
                      right: 0,
                      top: fadeTop + fade * 0.47,
                      bottom: 0,
                      child: _OneColour(controller: controller),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: fadeTop,
                      height: fade,
                      child: _SoftVideo(
                        controller: controller,
                        videoSize: videoSize,
                        artworkHeight: artworkHeight,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The lower edge of the video stretched over the box and blurred until one
/// colour is left.
class _OneColour extends StatelessWidget {
  const _OneColour({required this.controller});

  final VideoPlayerController controller;

  /// The video is drawn this many times smaller than the box, blurred there
  /// and stretched back. A blur as wide as the page would be cut short by
  /// the renderer's limit and leave a gradient across it.
  static const shrink = 8.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final small = constraints.biggest / shrink;
      // Wider than its input and mirrored at the edges, the blur leaves
      // the average of what it is given.
      final sigma = small.longestSide.clamp(1.0, 160.0);
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: small,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.compose(
                    // A little past the box, whose clip hides the rest, so
                    // no edge of the stretched image shows.
                    outer: ui.ImageFilter.matrix(
                      Matrix4.diagonal3Values(
                        shrink + 0.25,
                        shrink + 0.25,
                        1,
                      ).storage,
                      filterQuality: FilterQuality.low,
                    ),
                    inner: ui.ImageFilter.blur(
                      sigmaX: sigma,
                      sigmaY: sigma,
                      tileMode: TileMode.mirror,
                    ),
                  ),
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.bottomCenter,
                      minWidth: small.width,
                      maxWidth: small.width,
                      minHeight: small.height / MornyeMotionGlow.colourEdge,
                      maxHeight: small.height / MornyeMotionGlow.colourEdge,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
              ),
            ),
            const ColoredBox(
              color: Color.from(
                alpha: MornyeMotionGlow.colourShade,
                red: 0,
                green: 0,
                blue: 0,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The part of the video that fades, blurred in place: it comes in over the
/// sharp video and leaves again over [_OneColour].
class _SoftVideo extends StatelessWidget {
  const _SoftVideo({
    required this.controller,
    required this.videoSize,
    required this.artworkHeight,
  });

  final VideoPlayerController controller;
  final Size videoSize;
  final double artworkHeight;

  static const _mask = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, 0.4, 0.55, 1],
    colors: [
      Color(0x00000000),
      Color(0xff000000),
      Color(0xff000000),
      Color(0x00000000),
    ],
  );

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: _mask.createShader,
    // The blur spreads past its box, where the mask would not reach it.
    child: ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: MornyeMotionGlow.softSigma,
          sigmaY: MornyeMotionGlow.softSigma,
          tileMode: TileMode.clamp,
        ),
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) => OverflowBox(
              alignment: Alignment.bottomCenter,
              minWidth: constraints.maxWidth,
              maxWidth: constraints.maxWidth,
              minHeight: artworkHeight,
              maxHeight: artworkHeight,
              // Laid out as the sharp video above it.
              child: FittedBox(
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: videoSize.width,
                  height: videoSize.height,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
