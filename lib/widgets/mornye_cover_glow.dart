import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart'
    show mornyeLabelBackgroundLuminance;
import 'package:mornye/widgets/mornye_motion_glow.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// What a still cover in the Mornye player ends in, the look moving artwork
/// has ([MornyeMotionGlow]): the cover turns soft where it fades, then
/// settles into one colour taken from its lower edge.
///
/// A cover does not change, so both are drawn once into a small image per
/// cover and page size, and no filter runs on the frames after that. Every
/// device shows it for that reason, unlike the video's glow. The one colour
/// is the exact average of the small decode the mini player holds, kept dark
/// enough that the controls' dark layer still clears white labels on a white
/// cover.
///
/// It goes over [MornyePlayerBackground] with the same artwork geometry, and
/// inside the contrast sample, which then reads the colour the labels really
/// sit on. Without a cover image it draws nothing and the page keeps its
/// cover-coloured fade.
class MornyeCoverGlow extends StatefulWidget {
  const MornyeCoverGlow({
    super.key,
    required this.artUri,
    required this.visible,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.58,
  });

  /// The still cover that fills the top of the page.
  final String? artUri;

  /// False behind lyrics and the queue, and while the artwork is a video.
  /// The glow then keeps what it last drew until it is back.
  final bool visible;

  final bool squareArtwork;
  final double? artworkAspectRatio;
  final double fadeStart;

  /// The one colour taken from a cover's raw RGBA [pixels] for artwork laid
  /// out at [artwork].
  @visibleForTesting
  static Color lowerEdgeColour(
    ByteData pixels, {
    required int width,
    required int height,
    required Size artwork,
  }) => _MornyeCoverGlowState._lowerEdgeColour(
    pixels,
    width: width,
    height: height,
    artwork: artwork,
  );

  @override
  State<MornyeCoverGlow> createState() => _MornyeCoverGlowState();
}

/// One drawn glow, where on the page it goes and what it was drawn from.
typedef _Glow = ({ui.Image image, double top, double height, Object inputs});

class _MornyeCoverGlowState extends State<MornyeCoverGlow>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// The lightest the one colour may be: the controls' full dark layer
  /// ([MornyeControlsDim]) brings it down to the lightest background white
  /// labels sit on. Black at an opacity scales the encoded values, so the
  /// luminance falls by about that scale to the power 2.2.
  static final _brightest =
      mornyeLabelBackgroundLuminance /
      math.pow(1 - mornyeControlsDimAlpha, 2.2);

  late final _listener = ImageStreamListener(
    _setArt,
    onError: (_, _) => _setArt(null, false),
  );
  ImageStream? _stream;
  ImageInfo? _art;

  /// The pixels of [_art], read once to take the one colour from.
  ByteData? _pixels;

  /// The glow of [_art], drawn while the glow is visible.
  _Glow? _glow;
  ui.Image? _glowArt;
  Size? _glowPage;
  double? _glowFadeStart;
  double? _glowDpr;
  // The artwork's shape inputs; a change redraws even without a resize.
  (bool, double?)? _glowArtworkShape;
  Timer? _resizeSettle;
  static const _resizeSettleDelay = Duration(milliseconds: 150);

  static bool _stretches(Size drawn, Size current) {
    if (drawn.isEmpty || current.isEmpty) return false;
    final change = current.aspectRatio / drawn.aspectRatio;
    return change > 0.8 && change < 1.25;
  }

  void _settleResize() {
    if (!mounted) return;
    setState(() {
      _glowPage = null;
    });
  }

  /// The previous cover's glow, kept under the new one while it fades in.
  _Glow? _outgoing;
  late final _fade = AnimationController(vsync: this, value: 1)
    ..addStatusListener((status) {
      if (status.isCompleted && _outgoing != null && mounted) {
        setState(_dropOutgoing);
      }
    });
  AppMotionSpec _motion = const AppMotionSpec(Duration.zero, Curves.linear);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resolve();
  }

  @override
  void didUpdateWidget(MornyeCoverGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artUri != widget.artUri) _resolve();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A hidden surface may lose its GPU context. Draw the glow again.
    if (state != AppLifecycleState.resumed || !mounted) return;
    setState(() {
      _resizeSettle?.cancel();
      _dropOutgoing();
      _glow?.image.dispose();
      _glow = null;
      _glowArt = null;
      _glowPage = null;
      _glowFadeStart = null;
      _glowDpr = null;
    });
  }

  /// Requests the decode the mini player already holds: the glow shows
  /// nothing finer than a blur. The previous cover's glow stays until the
  /// next cover decodes. A cover that is still being fetched is asked for
  /// once more when it is [stored].
  void _resolve({bool stored = false}) {
    final source = widget.artUri;
    final provider = coverImageProvider(
      source,
      cacheWidth: PlayerArtwork.miniCacheWidth,
    );
    _stream?.removeListener(_listener);
    _stream = provider == null
        ? null
        : (provider.resolve(ImageConfiguration.empty)..addListener(_listener));
    if (provider != null) return;
    _setArt(null, false);
    if (stored || !CoverStore.fetches(source)) return;
    unawaited(
      CoverStore.instance.file(source!).then((path) {
        if (path != null && mounted && widget.artUri == source) {
          _resolve(stored: true);
        }
      }),
    );
  }

  /// Keeps the previous glow on screen until the next cover's pixels are
  /// read; a cover that is gone fades its glow out at once.
  void _setArt(ImageInfo? art, bool _) {
    if (!mounted || (art == null && _art == null)) {
      art?.dispose();
      return;
    }
    _art?.dispose();
    _art = art;
    _pixels = null;
    if (art == null) {
      setState(_replaceGlow);
      return;
    }
    final image = art.image.clone();
    unawaited(
      image
          .toByteData(format: ui.ImageByteFormat.rawRgba)
          .then((pixels) {
            if (pixels == null || !mounted || !identical(_art, art)) return;
            setState(() {
              _pixels = pixels;
              _replaceGlow();
            });
          }, onError: (Object _) {})
          .whenComplete(image.dispose),
    );
  }

  /// Moves the shown glow under the next one, which fades in over it.
  void _replaceGlow() {
    _resizeSettle?.cancel();
    final previous = _glow;
    _glow = null;
    _glowArt = null;
    _glowPage = null;
    _glowFadeStart = null;
    _glowDpr = null;
    if (previous == null) return;
    _dropOutgoing();
    // Reduced motion swaps at once.
    if (_motion.duration == Duration.zero) {
      previous.image.dispose();
      _fade.value = 1;
      return;
    }
    _outgoing = previous;
    _fade
      ..duration = _motion.duration
      ..forward(from: 0);
  }

  void _dropOutgoing() {
    _outgoing?.image.dispose();
    _outgoing = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeSettle?.cancel();
    _stream?.removeListener(_listener);
    _fade.dispose();
    _art?.dispose();
    _glow?.image.dispose();
    _outgoing?.image.dispose();
    super.dispose();
  }

  /// The average of the cover's lower edge as it shows on the page, shaded
  /// as the video's one colour is, and no lighter than [_brightest].
  static Color _lowerEdgeColour(
    ByteData pixels, {
    required int width,
    required int height,
    required Size artwork,
  }) {
    final size = Size(width.toDouble(), height.toDouble());
    final shown = Alignment.center.inscribe(
      applyBoxFit(BoxFit.cover, size, artwork).source,
      Offset.zero & size,
    );
    final left = shown.left.floor().clamp(0, width);
    final right = shown.right.ceil().clamp(left, width);
    final bottom = shown.bottom.ceil().clamp(0, height);
    final top = (shown.bottom - shown.height * MornyeMotionGlow.colourEdge)
        .floor()
        .clamp(0, bottom);
    // The readback is premultiplied, so the alpha weighs each pixel.
    var red = 0, green = 0, blue = 0, alpha = 0;
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final index = (y * width + x) * 4;
        red += pixels.getUint8(index);
        green += pixels.getUint8(index + 1);
        blue += pixels.getUint8(index + 2);
        alpha += pixels.getUint8(index + 3);
      }
    }
    if (alpha == 0) return const Color(0xff000000);
    var scale = (1 - MornyeMotionGlow.colourShade) / alpha;
    Color colour() => Color.from(
      alpha: 1,
      red: (red * scale).clamp(0.0, 1.0),
      green: (green * scale).clamp(0.0, 1.0),
      blue: (blue * scale).clamp(0.0, 1.0),
    );
    final luminance = colour().computeLuminance();
    if (luminance > _brightest) {
      scale *= math.pow(_brightest / luminance, 1 / 2.2);
    }
    return colour();
  }

  /// Draws the glow of [art] for a page of [page], from [fadeTop] to the end
  /// of the page, at a quarter of the physical resolution: nothing in it is
  /// finer than the blur. This canvas has no transform, so every length and
  /// the blur take that scale.
  static ui.Image _render(
    ui.Image art, {
    required Color colour,
    required Size page,
    required double artworkHeight,
    required double fadeTop,
    required double dpr,
  }) {
    final scale = dpr / 4;
    final width = math.max(1, (page.width * scale).ceil());
    final height = math.max(1, ((page.height - fadeTop) * scale).ceil());
    // The cover laid out as the sharp one, which starts above this image.
    final artwork = Rect.fromLTWH(
      0,
      -fadeTop * scale,
      width.toDouble(),
      artworkHeight * scale,
    );
    // Whole pixels: a last row the box covered in part would keep part of
    // the soft copy under the mask and show as a line at the cover's edge.
    final soft = Rect.fromLTWH(
      0,
      0,
      width.toDouble(),
      math.max(1, ((artworkHeight - fadeTop) * scale).roundToDouble()),
    );
    // Starts under the part of the soft copy that hides the cover, so its
    // upper edge is never seen.
    final oneColour = Rect.fromLTRB(
      0,
      soft.height * MornyeMotionGlow.colourStart,
      width.toDouble(),
      height.toDouble(),
    );
    final sigma = MornyeMotionGlow.softSigma * scale;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(oneColour, Paint()..color = colour)
      // The soft copy comes in over the sharp cover and leaves again over
      // the one colour.
      ..saveLayer(soft, Paint())
      ..clipRect(soft)
      ..saveLayer(
        soft,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
      )
      ..clipRect(soft);
    paintImage(
      canvas: canvas,
      rect: artwork,
      image: art,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
    );
    canvas
      ..restore()
      ..drawRect(
        soft,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = MornyeMotionGlow.softMask.createShader(soft),
      )
      ..restore();
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }

  static Widget _layer(_Glow glow, [Animation<double>? opacity]) => Positioned(
    left: 0,
    right: 0,
    top: glow.top,
    height: glow.height,
    child: RawImage(
      image: glow.image,
      opacity: opacity,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.low,
    ),
  );

  @override
  Widget build(BuildContext context) {
    _motion = mornyePlayerPanelMotion(context);
    final page = MediaQuery.sizeOf(context);
    final artworkHeight = mornyeArtworkHeight(
      page,
      squareArtwork: widget.squareArtwork,
      aspectRatio: widget.artworkAspectRatio,
    );
    final fadeTop = artworkHeight * widget.fadeStart;
    final art = _art?.image;
    final pixels = _pixels;
    if (art != null &&
        pixels != null &&
        widget.visible &&
        artworkHeight > fadeTop &&
        page.height > fadeTop) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final inputs = (art, page, artworkHeight, fadeTop, dpr);
      final drawnPage = _glowPage;
      final artworkShape = (widget.squareArtwork, widget.artworkAspectRatio);
      final needsRender =
          _glow == null ||
          _glowArt != art ||
          _glowFadeStart != widget.fadeStart ||
          _glowDpr != dpr ||
          _glowArtworkShape != artworkShape ||
          drawnPage == null ||
          !_stretches(drawnPage, page);
      if (needsRender) {
        _resizeSettle?.cancel();
        _glow?.image.dispose();
        _glow = (
          image: _render(
            art,
            colour: _lowerEdgeColour(
              pixels,
              width: art.width,
              height: art.height,
              artwork: Size(page.width, artworkHeight),
            ),
            page: page,
            artworkHeight: artworkHeight,
            fadeTop: fadeTop,
            dpr: dpr,
          ),
          top: fadeTop,
          height: page.height - fadeTop,
          inputs: inputs,
        );
        _glowArt = art;
        _glowPage = page;
        _glowFadeStart = widget.fadeStart;
        _glowDpr = dpr;
        _glowArtworkShape = artworkShape;
      } else if (drawnPage != page) {
        _resizeSettle?.cancel();
        _resizeSettle = Timer(_resizeSettleDelay, _settleResize);
        _glow = (
          image: _glow!.image,
          top: fadeTop,
          height: page.height - fadeTop,
          inputs: _glow!.inputs,
        );
      } else {
        _resizeSettle?.cancel();
      }
    }
    final glow = _glow;
    final outgoing = _outgoing;
    final fade = _fade.drive(CurveTween(curve: _motion.curve));
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.visible && (glow != null || outgoing != null) ? 1 : 0,
        duration: _motion.duration,
        curve: _motion.curve,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Under a new glow the previous one stays whole; with no cover
            // after it, it leaves on its own.
            if (outgoing != null)
              _layer(outgoing, glow == null ? ReverseAnimation(fade) : null),
            if (glow != null) _layer(glow, fade),
          ],
        ),
      ),
    );
  }
}
