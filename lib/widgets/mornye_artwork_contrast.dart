import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:mornye/widgets/mornye_player_background.dart'
    show mornyeControlsDimAlpha;

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

/// The lightest background the player's white labels sit on undimmed: white
/// keeps 3.5:1 on it, enough for the title and the controls. Mid-tone covers
/// stay as bright as they are.
const mornyeLabelBackgroundLuminance = 0.25;

/// How much of the dark layer (0 none, 1 all of it) brings a label
/// background of [luminance] down to [mornyeLabelBackgroundLuminance]. Black
/// at an opacity scales the encoded pixel values, so the luminance falls by
/// about that scale to the power 2.2. Steps of a twentieth keep a reading's
/// noise from moving the layer.
double mornyeDimStrength(double luminance) {
  if (luminance <= mornyeLabelBackgroundLuminance) return 0;
  final alpha =
      1 - math.pow(mornyeLabelBackgroundLuminance / luminance, 1 / 2.2);
  final strength = (alpha / mornyeControlsDimAlpha).clamp(0.0, 1.0);
  return (strength * 20).round() / 20;
}

/// Samples the rendered still artwork and its fade, rather than an album
/// palette, and reads it again only after its scene or target geometry
/// changes. The player's labels stay white over every cover; this reports
/// how much darker the lightest target must be for white text, so the player
/// darkens behind the labels only as far as needed instead of turning them
/// black. Moving artwork stays out: its frames would keep moving the layer,
/// so it is always dimmed.
class MornyeArtworkContrast extends StatefulWidget {
  const MornyeArtworkContrast({
    super.key,
    required this.enabled,
    required this.targets,
    required this.onDim,
    required this.child,
  });

  final bool enabled;
  final Map<String, GlobalKey> targets;

  /// Called after every reading with the strength of the dark layer white
  /// labels need (see [mornyeDimStrength]). Keep that layer outside [child],
  /// so it does not change what the sample reads.
  final ValueChanged<double> onDim;
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
    if (!widget.enabled || !_tickersEnabled) return;
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
      double? lightest;
      for (final rect in targets.values) {
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
        lightest = math.max(lightest ?? 0, luminance / count);
      }
      // One layer covers every label, so the lightest target sets it.
      if (lightest != null) widget.onDim(mornyeDimStrength(lightest));
    } catch (_) {
      // An unreadable surface keeps the current layer.
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
