import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// Full-screen cover style for the Material player: the cover fills the top
/// of the page edge to edge, then fades into a blurred copy of itself.
///
/// The blurred layer is tinted with the surface colour so titles, controls
/// and lyrics keep the same contrast as on the plain surface.
class MaterialPlayerBackdrop extends StatelessWidget {
  const MaterialPlayerBackdrop({
    super.key,
    required this.mediaItem,
    required this.colorScheme,
    required this.showArtwork,
  });

  final MediaItem mediaItem;
  final ColorScheme colorScheme;

  /// False behind lyrics, where only the blurred surface remains.
  final bool showArtwork;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final blurredCover = _BlurredCover(
      artUri: mediaItem.artUri?.toString(),
      colorScheme: colorScheme,
    );
    // Landscape keeps the sharp cover and its Hero in the player pane.
    if (size.width > size.height) return blurredCover;
    final artUri = mediaItem.artUri?.toString();
    final appBarHeight = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    return Stack(
      fit: StackFit.expand,
      children: [
        blurredCover,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          // Taller than wide on phones: the sides are cropped so the cover
          // reaches down to the title instead of leaving an empty band.
          height: size.width < size.height * 0.56
              ? size.height * 0.56
              : size.width.clamp(0.0, size.height * 0.62),
          child: AnimatedOpacity(
            opacity: showArtwork ? 1 : 0,
            duration: motion,
            curve: Curves.easeInOutCubic,
            child: Hero(
              tag: kNowPlayingArtworkHeroTag,
              // The flying cover must keep its fade in the route overlay.
              child: _FadedArtwork(
                child: PlayerArtwork(
                  artUri: artUri,
                  colorScheme: colorScheme,
                  cacheWidth: PlayerArtwork.transitionCacheWidth(context),
                ),
              ),
            ),
          ),
        ),
        // Keeps the status bar and app bar readable over bright covers.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: appBarHeight + 32,
          child: AnimatedOpacity(
            opacity: showArtwork ? 1 : 0,
            duration: motion,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // A light shade that eases out across the bar: enough for
                  // white icons without darkening the top of the cover.
                  stops: [0, appBarHeight / (appBarHeight + 32), 1],
                  colors: const [
                    Color(0x40000000),
                    Color(0x14000000),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const _fadeStart = 0.72;

const _fade = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  stops: [0, _fadeStart, 1],
  colors: [Colors.white, Colors.white, Colors.transparent],
);

/// Top of the band [_fade] changes: a whole device pixel at least one pixel
/// above the first faded row, so a row the edge crosses is unfaded on
/// either side of it.
double _fadeTop(double height, double devicePixelRatio) {
  final row = (height * _fadeStart * devicePixelRatio).floorToDouble() - 1;
  return math.max(0.0, row) / devicePixelRatio;
}

/// The cover faded out by [_fade]. Only the faded band goes through an
/// offscreen mask; a second copy of the same artwork, sharing its decode,
/// draws the rows above it directly.
class _FadedArtwork extends StatelessWidget {
  const _FadedArtwork({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        ClipRect(clipper: _AboveFade(devicePixelRatio), child: child),
        ExcludeSemantics(
          child: _FadeBand(devicePixelRatio: devicePixelRatio, child: child),
        ),
      ],
    );
  }
}

class _AboveFade extends CustomClipper<Rect> {
  const _AboveFade(this.devicePixelRatio);

  final double devicePixelRatio;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width, _fadeTop(size.height, devicePixelRatio));

  @override
  bool shouldReclip(_AboveFade oldClipper) =>
      oldClipper.devicePixelRatio != devicePixelRatio;
}

class _FadeBand extends SingleChildRenderObjectWidget {
  const _FadeBand({required this.devicePixelRatio, required super.child});

  final double devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFadeBand(devicePixelRatio);

  @override
  void updateRenderObject(BuildContext context, _RenderFadeBand renderObject) =>
      renderObject.devicePixelRatio = devicePixelRatio;
}

/// Paints its child from [_fadeTop] down, masked by [_fade] laid over the
/// whole box, so the mask's offscreen layer spans only that band.
class _RenderFadeBand extends RenderProxyBox {
  _RenderFadeBand(this._devicePixelRatio);

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      layer = null;
      _clip.layer = null;
      return;
    }
    final top = _fadeTop(size.height, _devicePixelRatio);
    final band = Rect.fromLTRB(0, top, size.width, size.height);
    // The layer draws the shader from the band's corner, so the gradient's
    // box starts above it, where the cover's box starts.
    layer = (layer ?? ShaderMaskLayer())
      ..shader = _fade.createShader(
        Rect.fromLTWH(0, -top, size.width, size.height),
      )
      ..maskRect = band.shift(offset)
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(layer!, (context, offset) {
      _clip.layer = context.pushClipRect(
        child.needsCompositing,
        offset,
        band,
        super.paint,
        oldLayer: _clip.layer,
      );
    }, offset);
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

/// The surface, the blurred cover and its tint, drawn once into an image so
/// a playing track does not blur the whole screen again on every frame.
class _BlurredCover extends StatefulWidget {
  const _BlurredCover({required this.artUri, required this.colorScheme});

  final String? artUri;
  final ColorScheme colorScheme;

  @override
  State<_BlurredCover> createState() => _BlurredCoverState();
}

class _BlurredCoverState extends State<_BlurredCover> {
  static const _sigma = 48.0;
  static const _artWidth = PlayerArtwork.miniCacheWidth;

  late final _listener = ImageStreamListener(
    _setArt,
    onError: (_, _) => _setArt(null, false),
  );
  ImageStream? _stream;
  ImageInfo? _art;
  ui.Image? _blur;
  Object? _blurInputs;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_BlurredCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artUri != widget.artUri) _resolve();
  }

  /// Requests the same decode as [PlayerArtwork] so both share one cache
  /// entry. The previous cover stays until the next one decodes.
  void _resolve() {
    final provider = coverImageProvider(widget.artUri, cacheWidth: _artWidth);
    _stream?.removeListener(_listener);
    _stream = provider == null
        ? null
        : (provider.resolve(ImageConfiguration.empty)..addListener(_listener));
    if (provider == null) _setArt(null, false);
  }

  void _setArt(ImageInfo? art, bool _) {
    if (!mounted || (art == null && _art == null)) {
      art?.dispose();
      return;
    }
    setState(() {
      _art?.dispose();
      _art = art;
      if (art != null) return;
      _blur?.dispose();
      _blur = _blurInputs = null;
    });
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _art?.dispose();
    _blur?.dispose();
    super.dispose();
  }

  /// Draws at a quarter of the physical resolution, which a 48 dp blur
  /// leaves without visible detail. The live filter blurs in logical pixels
  /// under the device pixel ratio; this canvas has no transform, so sigma
  /// takes the same dpr / 4 scale and still spans 48 dp once drawn back.
  static ui.Image _render(ui.Image art, Size size, double dpr, Color surface) {
    final scale = dpr / 4;
    final width = math.max(1, (size.width * scale).ceil());
    final height = math.max(1, (size.height * scale).ceil());
    final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final sigma = _sigma * scale;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(rect, Paint()..color = surface)
      ..saveLayer(
        rect,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
    paintImage(
      canvas: canvas,
      rect: rect,
      image: art,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
    );
    canvas
      ..restore()
      ..drawRect(rect, Paint()..color = surface.withValues(alpha: 0.72));
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.colorScheme.surface;
    final art = _art?.image;
    if (art == null) {
      // Blur live while the cover decodes and for the placeholder.
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: surface),
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
            child: PlayerArtwork(
              artUri: widget.artUri,
              colorScheme: widget.colorScheme,
              cacheWidth: _artWidth,
            ),
          ),
          ColoredBox(color: surface.withValues(alpha: 0.72)),
        ],
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inputs = (art, constraints.biggest, dpr, surface);
        if (inputs != _blurInputs) {
          _blur?.dispose();
          _blur = _render(art, constraints.biggest, dpr, surface);
          _blurInputs = inputs;
        }
        return RawImage(
          image: _blur,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.low,
        );
      },
    );
  }
}
