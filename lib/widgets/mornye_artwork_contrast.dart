import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// Readback uses 8-bit sRGB. Cache each channel's exact Flutter luminance
// contribution (6 KiB total), avoiding three powers and a Color per pixel.
final _redLuminance = Float64List.fromList(
  List.generate(
    256,
    (value) => Color.fromARGB(255, value, 0, 0).computeLuminance(),
  ),
);
final _greenLuminance = Float64List.fromList(
  List.generate(
    256,
    (value) => Color.fromARGB(255, 0, value, 0).computeLuminance(),
  ),
);
final _blueLuminance = Float64List.fromList(
  List.generate(
    256,
    (value) => Color.fromARGB(255, 0, 0, value).computeLuminance(),
  ),
);

/// Matches [Color.computeLuminance] for an RGB pixel from an 8-bit readback.
double artworkPixelLuminance(int red, int green, int blue) =>
    _redLuminance[red] + _greenLuminance[green] + _blueLuminance[blue];

/// Samples the rendered still artwork and its fade, rather than an album
/// palette, and reads it again only after its scene or target geometry
/// changes. Moving artwork stays out: labels that followed its frames would
/// flip between black and white, so the player dims behind them instead.
class MornyeArtworkContrast extends StatefulWidget {
  const MornyeArtworkContrast({
    super.key,
    required this.enabled,
    required this.targets,
    required this.onChanged,
    required this.child,
  });

  final bool enabled;
  final Map<String, GlobalKey> targets;
  final ValueChanged<Map<String, Color>> onChanged;
  final Widget child;

  @visibleForTesting
  static int debugReadbackCount(GlobalKey key) =>
      (key.currentState! as _MornyeArtworkContrastState)._readbacks;

  @visibleForTesting
  static Future<ui.Image> Function(RenderRepaintBoundary, double)?
  debugReadback;

  @override
  State<MornyeArtworkContrast> createState() => _MornyeArtworkContrastState();
}

class _MornyeArtworkContrastState extends State<MornyeArtworkContrast>
    with WidgetsBindingObserver {
  final _background = GlobalKey();
  Timer? _timer;
  bool _tickersEnabled = true;
  bool _sampling = false;
  bool _resamplePending = false;
  int _readbacks = 0;
  int? _sampledRevision;
  Map<String, Rect> _sampledTargets = {};
  Map<String, Color> _colors = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _schedule();

  @override
  void didUpdateWidget(MornyeArtworkContrast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    _sampledRevision = null;
    _resamplePending = false;
    if (!widget.enabled || !_tickersEnabled) {
      _colors = {};
      return;
    }
    // Playback can keep the Dart isolate alive after the UI is backgrounded.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sample());
  }

  void _queueSample() {
    if (!mounted || !widget.enabled || !_tickersEnabled || _timer != null) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // Composition also reports changes inside nested repaint boundaries, such
    // as a late image decode. Coalesce animation frames within one readback.
    _timer = Timer(const Duration(milliseconds: 333), () {
      _timer = null;
      _sample();
    });
  }

  Future<void> _sample() async {
    if (!mounted || !widget.enabled || !_tickersEnabled) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final route = ModalRoute.of(context);
    if (route != null &&
        (!route.isCurrent || route.animation?.isAnimating == true)) {
      return;
    }
    if (_sampling) {
      // A static scene may stop submitting frames before its current GPU
      // readback finishes. Retain the invalidation until that readback yields.
      _resamplePending = true;
      return;
    }
    final boundary = _background.currentContext?.findRenderObject();
    if (boundary is! _ContrastRenderBoundary ||
        !boundary.attached ||
        !boundary.hasSize ||
        boundary.debugNeedsPaint ||
        boundary.size.isEmpty) {
      return;
    }
    final origin = boundary.localToGlobal(Offset.zero);
    final targets = <String, Rect>{};
    for (final entry in widget.targets.entries) {
      final target = entry.value.currentContext?.findRenderObject();
      if (target is RenderBox && target.hasSize && target.attached) {
        targets[entry.key] =
            target.localToGlobal(Offset.zero) - origin & target.size;
      }
    }
    final revision = boundary.revision;
    if (revision == null) return;
    if (revision == _sampledRevision && mapEquals(targets, _sampledTargets)) {
      return;
    }
    _sampling = true;
    ui.Image? image;
    try {
      final scale = (48 / boundary.size.width).clamp(0.01, 1.0);
      _readbacks++;
      image =
          await (MornyeArtworkContrast.debugReadback?.call(boundary, scale) ??
              boundary.toImage(pixelRatio: scale));
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (!mounted || !widget.enabled || !_tickersEnabled || pixels == null) {
        return;
      }
      final currentLifecycle = WidgetsBinding.instance.lifecycleState;
      if (currentLifecycle != null &&
          currentLifecycle != AppLifecycleState.resumed) {
        return;
      }
      final currentRoute = ModalRoute.of(context);
      if (currentRoute != null &&
          (!currentRoute.isCurrent ||
              currentRoute.animation?.isAnimating == true)) {
        return;
      }
      _sampledRevision = revision;
      _sampledTargets = targets;
      final next = <String, Color>{};
      for (final entry in targets.entries) {
        final rect = entry.value;
        final left = (rect.left * scale).floor().clamp(0, image.width);
        final right = (rect.right * scale).ceil().clamp(0, image.width);
        final top = (rect.top * scale).floor().clamp(0, image.height);
        final bottom = (rect.bottom * scale).ceil().clamp(0, image.height);
        var luminance = 0.0;
        var count = 0;
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            final index = (y * image.width + x) * 4;
            luminance += artworkPixelLuminance(
              pixels.getUint8(index),
              pixels.getUint8(index + 1),
              pixels.getUint8(index + 2),
            );
            count++;
          }
        }
        if (count == 0) continue;
        // Prefer the player's white labels/icons while they retain 3:1
        // contrast. Pastel frames need not switch to black merely because
        // black has a higher contrast ratio. Hysteresis prevents flicker.
        final threshold = _colors[entry.key] == Colors.black ? 0.28 : 0.30;
        next[entry.key] = luminance / count > threshold
            ? Colors.black
            : Colors.white;
      }
      if (next.entries.any((entry) => _colors[entry.key] != entry.value)) {
        _colors = next;
        widget.onChanged(next);
      }
    } catch (_) {
      // Unreadable surfaces keep the light controls over the dark fade.
    } finally {
      image?.dispose();
      _sampling = false;
      if (_resamplePending) {
        _resamplePending = false;
        _queueSample();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ContrastBoundary(
    key: _background,
    onComposition: _queueSample,
    child: widget.child,
  );
}

class _ContrastBoundary extends SingleChildRenderObjectWidget {
  const _ContrastBoundary({
    super.key,
    required this.onComposition,
    required super.child,
  });

  final VoidCallback onComposition;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ContrastRenderBoundary(onComposition);

  @override
  void updateRenderObject(
    BuildContext context,
    _ContrastRenderBoundary renderObject,
  ) => renderObject.onComposition = onComposition;
}

class _ContrastRenderBoundary extends RenderRepaintBoundary {
  _ContrastRenderBoundary(this.onComposition);

  VoidCallback onComposition;

  int? get revision => (layer as _ContrastLayer?)?.revision;

  @override
  OffsetLayer updateCompositedLayer({required OffsetLayer? oldLayer}) =>
      oldLayer ?? _ContrastLayer(() => onComposition());

  @override
  Future<ui.Image> toImage({double pixelRatio = 1.0}) {
    final sceneLayer = layer! as _ContrastLayer;
    sceneLayer.capturing = true;
    try {
      // Scene construction is synchronous, rasterization finishes later.
      return super.toImage(pixelRatio: pixelRatio);
    } finally {
      sceneLayer.capturing = false;
    }
  }
}

class _ContrastLayer extends OffsetLayer {
  _ContrastLayer(VoidCallback onComposition) {
    _removeCallback = addCompositionCallback((layer) {
      if (layer.attached && !capturing) onComposition();
    });
  }

  late final VoidCallback _removeCallback;
  int revision = 0;
  bool capturing = false;

  @override
  void addToScene(ui.SceneBuilder builder) {
    // Retained layers skip this method when their subtree has not changed.
    // A snapshot must not invalidate its own cached contrast.
    if (!capturing) revision++;
    super.addToScene(builder);
  }

  @override
  void dispose() {
    _removeCallback();
    super.dispose();
  }
}
