import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A Gaussian blur of [child] that is drawn from a cached image once the
/// child has stopped changing.
///
/// A changed child blurs live, exactly like [ImageFiltered]. On the first
/// later frame that composites it unchanged, the blurred child is rasterized
/// once at [resolution] of the physical pixels, and from then on that image
/// is drawn: moving, scrolling, fading or scaling the blur, and frames
/// elsewhere on screen, do not run the blur again.
///
/// The image is dropped, and the child blurs live until it settles again, on
/// a new [child] widget, a new [sigma], [resolution] or device pixel ratio, a
/// new size, or a repaint below it. While the child blurs live, animations in
/// nested layers below it (such as a [FadeTransition]) also count, so a
/// fading image is not captured halfway. Once settled, a paint-only change in
/// a nested layer is not seen unless it comes with a rebuild of [child] or a
/// relayout. A [Texture] or platform view below keeps the blur live.
///
/// The image covers the widget's own bounds: the blur that spreads past its
/// edges is not drawn once settled, so use it where those edges are clipped
/// or off screen.
class SettledBlur extends SingleChildRenderObjectWidget {
  const SettledBlur({
    super.key,
    required this.sigma,
    this.resolution = 0.25,
    required Widget super.child,
  }) : assert(resolution > 0);

  /// The blur radius in logical pixels, as for [ui.ImageFilter.blur].
  final double sigma;

  /// Image pixels per physical pixel along each axis. The default, a quarter
  /// (a sixteenth of the pixels), loses no visible detail of a wide blur.
  final double resolution;

  @override
  RenderSettledBlur createRenderObject(BuildContext context) =>
      RenderSettledBlur(
        sigma: sigma,
        pixelRatio: MediaQuery.devicePixelRatioOf(context) * resolution,
        source: child!,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSettledBlur renderObject,
  ) => renderObject
    ..sigma = sigma
    ..pixelRatio = MediaQuery.devicePixelRatioOf(context) * resolution
    ..source = child!;
}

/// Paints its child blurred by [sigma]: live while the child changes, then
/// from one image with [pixelRatio] image pixels per logical pixel. With a
/// zero [sigma] it is a plain repaint boundary.
class RenderSettledBlur extends RenderProxyBox with WidgetsBindingObserver {
  RenderSettledBlur({
    required double sigma,
    required double pixelRatio,
    required Widget source,
  }) : _sigma = sigma,
       _pixelRatio = pixelRatio,
       _source = source;

  double _sigma;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    markNeedsPaint();
  }

  double _pixelRatio;
  set pixelRatio(double value) {
    if (value == _pixelRatio) return;
    _pixelRatio = value;
    markNeedsPaint();
  }

  // A rebuild can change what a nested layer below paints without reaching
  // this box, so a new child widget counts as a change.
  Widget _source;
  set source(Widget value) {
    if (identical(value, _source)) return;
    _source = value;
    markNeedsPaint();
  }

  final _live = LayerHandle<_LiveBlurLayer>();
  Rect _bounds = Rect.zero;
  ui.Image? _image;
  // The live layer's scene count at the last check; null after a change.
  int? _checkedScenes;
  bool _checkScheduled = false;
  bool _keepImage = false;

  @visibleForTesting
  ui.Image? get debugImage => _image;

  bool get _canSnapshot =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  // Keeps the blur on its own layer, so moving it reuses that layer.
  @override
  bool get isRepaintBoundary => true;

  @override
  void markNeedsPaint() {
    if (!_keepImage) {
      _checkedScenes = null;
      _disposeImage();
    }
    super.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_sigma <= 0 || child == null) {
      _live.layer = null;
      _disposeImage();
      super.paint(context, offset);
      return;
    }
    _bounds = offset & size;
    if (_image case final image?) {
      _live.layer = null;
      context.canvas.drawImageRect(
        image,
        Offset.zero & size * _pixelRatio,
        _bounds,
        Paint()..filterQuality = FilterQuality.low,
      );
      return;
    }
    final layer = _live.layer ??= _LiveBlurLayer();
    layer.imageFilter = ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma);
    context.pushLayer(layer, super.paint, offset);
    _scheduleCheck();
  }

  void _scheduleCheck() {
    if (_checkScheduled || !_canSnapshot) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(_check);
  }

  /// Runs after frames that show the live blur. A frame that retained the
  /// live layer as it was at the previous check changed nothing below it, so
  /// its blur is rasterized for the later frames.
  void _check(Duration _) {
    _checkScheduled = false;
    final live = _live.layer;
    if (!attached || !_canSnapshot || live == null || _image != null) return;
    if (!live.attached) {
      // Off screen: it paints live again, and settles, once it is back.
      markNeedsPaint();
      return;
    }
    if (live.scenes != _checkedScenes) {
      _checkedScenes = live.scenes;
      _scheduleCheck();
      return;
    }
    if (_bounds.isEmpty || !_isStill(live)) return;
    _image = live.toImageSync(_bounds, pixelRatio: _pixelRatio);
    _repaintKeepingImage();
  }

  void _repaintKeepingImage() {
    _keepImage = true;
    markNeedsPaint();
    _keepImage = false;
  }

  // Textures and platform views change without a new layer tree.
  static bool _isStill(Layer layer) {
    if (layer is TextureLayer ||
        layer is PlatformViewLayer ||
        layer is PerformanceOverlayLayer) {
      return false;
    }
    if (layer is ContainerLayer) {
      for (
        var child = layer.firstChild;
        child != null;
        child = child.nextSibling
      ) {
        if (!_isStill(child)) return false;
      }
    }
    return true;
  }

  void _disposeImage() {
    _image?.dispose();
    _image = null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    WidgetsBinding.instance.addObserver(this);
    // Moved boxes repaint, as their old layer may hold an unchecked live blur.
    markNeedsPaint();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A hidden surface may lose its GPU context. Rebuild its cache on resume.
    _live.layer = null;
    markNeedsPaint();
  }

  @override
  void detach() {
    WidgetsBinding.instance.removeObserver(this);
    _live.layer = null;
    _disposeImage();
    super.detach();
  }

  @override
  void dispose() {
    _live.layer = null;
    _disposeImage();
    super.dispose();
  }
}

/// The live blur. [scenes] counts the frames that added it to the scene
/// instead of retaining it, which happens when it or anything below changed.
class _LiveBlurLayer extends ImageFilterLayer {
  int scenes = 0;

  @override
  void addToScene(ui.SceneBuilder builder) {
    scenes += 1;
    super.addToScene(builder);
  }
}
