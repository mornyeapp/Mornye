import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Defocus blur for one lyric line.
///
/// While [sigma] is still easing the blur is composited live, as an
/// [ImageFiltered]. Once it has [settled], the blurred line is rasterized once
/// and later frames draw that image, so scrolling, fading or scaling the row
/// does not run the blur again. A new [child] widget, a new sigma or device
/// pixel ratio, a relayout below it, or a repaint below it that is not inside
/// a nested layer drops the image; the line then blurs live until it is
/// unchanged for a frame. A paint-only change inside a nested layer (such as
/// an [Opacity] or [FadeTransition]) does not, unless it comes with a rebuild
/// or, for [fadeTransition], an animation tick.
class LyricBlur extends StatelessWidget {
  const LyricBlur({
    super.key,
    required this.sigma,
    required this.settled,
    required this.child,
  });

  final double sigma;
  final bool settled;
  final Widget child;

  /// The [AnimatedSwitcher] fade for content under a [LyricBlur]. The fade
  /// has its own layer, so each of its frames also reports a repaint here and
  /// the line is not snapshotted halfway through.
  static Widget fadeTransition(Widget child, Animation<double> animation) =>
      _RepaintWhileAnimating(
        key: ValueKey<Key?>(child.key),
        animation: animation,
        child: FadeTransition(opacity: animation, child: child),
      );

  @override
  Widget build(BuildContext context) => ImageFiltered(
    enabled: sigma > 0 && !settled,
    imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    child: _BlurSnapshot(
      sigma: settled ? sigma : 0,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      source: child,
      child: child,
    ),
  );
}

class _BlurSnapshot extends SingleChildRenderObjectWidget {
  const _BlurSnapshot({
    required this.sigma,
    required this.devicePixelRatio,
    required this.source,
    required super.child,
  });

  final double sigma;
  final double devicePixelRatio;
  final Widget source;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderLyricBlurSnapshot(sigma, devicePixelRatio, source);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLyricBlurSnapshot renderObject,
  ) => renderObject
    ..sigma = sigma
    ..devicePixelRatio = devicePixelRatio
    ..source = source;
}

/// Paints its child blurred by [sigma], from a cached image once the child
/// has not changed for a frame. With a zero [sigma] it is a plain repaint
/// boundary.
class RenderLyricBlurSnapshot extends RenderProxyBox
    with WidgetsBindingObserver {
  RenderLyricBlurSnapshot(this._sigma, this._devicePixelRatio, this._source);

  double _sigma;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    markNeedsPaint();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  // Layers inside the line, such as fades, repaint without reaching this box,
  // so any rebuild of the line counts as a change.
  Widget _source;
  set source(Widget value) {
    if (identical(value, _source)) return;
    _source = value;
    if (_sigma > 0) markNeedsPaint();
  }

  ui.Image? _snapshot;
  final _live = LayerHandle<ImageFilterLayer>();
  // No repaint was requested since the last live paint.
  bool _unchanged = false;
  bool _repaintingForSnapshot = false;

  @visibleForTesting
  ui.Image? get debugSnapshot => _snapshot;

  bool get _canSnapshot =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  // Keeps the line on its own layer, like the boundary a live blur needs.
  @override
  bool get isRepaintBoundary => true;

  @override
  void markNeedsPaint() {
    if (!_repaintingForSnapshot) {
      _unchanged = false;
      _disposeSnapshot();
    }
    super.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_sigma == 0 || child == null) {
      _live.layer = null;
      _disposeSnapshot();
      super.paint(context, offset);
      return;
    }
    // A Gaussian blur fades out within three sigma of the text. Whole device
    // pixels keep the image on the same pixel grid as the live blur.
    final bounds = (offset & size).inflate(
      (_sigma * 3 * _devicePixelRatio).ceil() / _devicePixelRatio,
    );
    final live = _live.layer;
    if (_canSnapshot && _snapshot == null && _unchanged && live != null) {
      // The previous frame's live layer still holds the same, unchanged line.
      _snapshot = live.toImageSync(bounds, pixelRatio: _devicePixelRatio);
      _live.layer = null;
    }
    if (_snapshot case final snapshot?) {
      context.canvas.drawImageRect(
        snapshot,
        Offset.zero & bounds.size * _devicePixelRatio,
        bounds,
        Paint()..filterQuality = FilterQuality.low,
      );
      return;
    }
    final layer = _live.layer ??= ImageFilterLayer();
    layer.imageFilter = ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma);
    context.pushLayer(layer, super.paint, offset);
    if (!_canSnapshot) return;
    _unchanged = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!attached || !_canSnapshot || !_unchanged || _snapshot != null) {
        return;
      }
      _repaintingForSnapshot = true;
      markNeedsPaint();
      _repaintingForSnapshot = false;
    });
  }

  void _disposeSnapshot() {
    _snapshot?.dispose();
    _snapshot = null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    WidgetsBinding.instance.addObserver(this);
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
    _unchanged = false;
    _live.layer = null;
    _disposeSnapshot();
    super.detach();
  }

  @override
  void dispose() {
    _live.layer = null;
    _disposeSnapshot();
    super.dispose();
  }
}

class _RepaintWhileAnimating extends SingleChildRenderObjectWidget {
  const _RepaintWhileAnimating({
    super.key,
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRepaintWhileAnimating(animation);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRepaintWhileAnimating renderObject,
  ) => renderObject.animation = animation;
}

class _RenderRepaintWhileAnimating extends RenderProxyBox {
  _RenderRepaintWhileAnimating(this._animation);

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }
}
