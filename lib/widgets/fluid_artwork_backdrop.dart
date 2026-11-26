import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/theme/cover_palette.dart';

class FluidArtworkBackdrop extends StatefulWidget {
  const FluidArtworkBackdrop({
    super.key,
    required this.artUri,
    required this.colorScheme,
    required this.isPlaying,
    required this.shallowBlur,
    this.darkMode = true,
  });

  final String? artUri;
  final ColorScheme colorScheme;
  final bool isPlaying;
  final bool shallowBlur;
  final bool darkMode;

  @override
  State<FluidArtworkBackdrop> createState() => FluidArtworkBackdropState();
}

class _FluidBakedTextures {
  _FluidBakedTextures({
    required this.uri,
    required this.bg,
    required this.ts,
    required this.be,
  });

  final String uri;
  final ui.Image bg;
  final ui.Image ts;
  final ui.Image be;

  int _refCount = 0;
  bool _disposed = false;

  void retain() {
    if (!_disposed) _refCount++;
  }

  void release() {
    if (_disposed) return;
    _refCount--;
    if (_refCount <= 0) {
      _disposed = true;
      bg.dispose();
      ts.dispose();
      be.dispose();
    }
  }
}

class _FluidBlendCache {
  static const int _maxTextureEntries = 6;
  static const int _maxTintEntries = 24;

  static final Map<String, _FluidBakedTextures> _textures = {};
  static final Map<String, Color> _deepTints = {};

  // Shared continuous rotation angles preserved across tab/view/route rebuilds
  static double sharedTsRad = 0.0;
  static double sharedBeRad = 0.0;
  static double sharedFrameRad = 0.0;
  static int _lastGlobalTickUs = 0;

  static _FluidBakedTextures? getTextures(String uri) {
    final entry = _textures.remove(uri);
    if (entry != null) {
      _textures[uri] = entry;
    }
    return entry;
  }

  static void putTextures(String uri, _FluidBakedTextures tex) {
    final existing = _textures.remove(uri);
    tex.retain();
    _textures[uri] = tex;
    existing?.release();
    while (_textures.length > _maxTextureEntries) {
      final oldestKey = _textures.keys.first;
      final oldest = _textures.remove(oldestKey);
      oldest?.release();
    }
  }

  static Color? getDeepTint(String uri) => _deepTints[uri];

  static void putDeepTint(String uri, Color color) {
    _deepTints.remove(uri);
    _deepTints[uri] = color;
    while (_deepTints.length > _maxTintEntries) {
      _deepTints.remove(_deepTints.keys.first);
    }
  }
}

class _FluidBlendRenderState extends ChangeNotifier {
  _FluidBakedTextures? currentTex;
  _FluidBakedTextures? prevTex;
  double crossfade = 1.0;
  double tsRad = _FluidBlendCache.sharedTsRad;
  double beRad = _FluidBlendCache.sharedBeRad;
  double frameRad = _FluidBlendCache.sharedFrameRad;
  Color deepTint = const Color(0xFF141416);

  void setTextures(_FluidBakedTextures? next, {required double startFade}) {
    final oldPrev = prevTex;
    final oldCurrent = currentTex;

    next?.retain();
    if (startFade < 1.0 && oldCurrent != null && !identical(oldCurrent, next)) {
      oldCurrent.retain();
      prevTex = oldCurrent;
    } else {
      prevTex = null;
    }
    currentTex = next;
    crossfade = startFade;

    oldPrev?.release();
    oldCurrent?.release();
    notifyListeners();
  }

  void clearPrevTex() {
    final oldPrev = prevTex;
    if (oldPrev == null) return;
    prevTex = null;
    oldPrev.release();
  }

  void notifyTick() => notifyListeners();

  void releaseTextures() {
    final oldPrev = prevTex;
    final oldCurrent = currentTex;
    prevTex = null;
    currentTex = null;
    oldPrev?.release();
    oldCurrent?.release();
  }
}

class FluidArtworkBackdropState extends State<FluidArtworkBackdrop>
    with SingleTickerProviderStateMixin {
  static const _radPerDeg = math.pi / 180.0;
  static const _twoPi = 2.0 * math.pi;
  static const _texSize = 192.0;
  static const _texInt = 192;

  // Continuous layer angular velocities:
  // +1.2 deg / 34ms = +35.29 deg/s
  // +0.67 deg / 34ms = +19.71 deg/s
  // -0.6 deg / 34ms = -17.65 deg/s
  static const _tsSpeedRad = (0.45 / 0.034) * _radPerDeg;
  static const _beSpeedRad = (0.25 / 0.034) * _radPerDeg;
  static const _frameSpeedRad = (-0.22 / 0.034) * _radPerDeg;

  // Saturation boost color matrix (2.5x) for rich ambient tones
  static const _fluidSaturationFilter = ColorFilter.matrix(<double>[
    2.1805,
    -1.0725,
    -0.1080,
    0,
    0,
    -0.3195,
    1.4275,
    -0.1080,
    0,
    0,
    -0.3195,
    -1.0725,
    2.3920,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  late final Ticker _ticker = createTicker(_onTick);
  late final _FluidBlendRenderState _renderState = _FluidBlendRenderState();
  Duration? _lastElapsed;
  double _acc = 0.0;

  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  String? _loadingUri;
  int _bakeGeneration = 0;

  Animation<double>? _routeAnim;
  Animation<double>? _routeSecAnim;

  @override
  void initState() {
    super.initState();
    _resolveAndBake(widget.artUri);
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final anim = route?.animation;
    final secAnim = route?.secondaryAnimation;
    if (!identical(anim, _routeAnim) || !identical(secAnim, _routeSecAnim)) {
      _routeAnim?.removeStatusListener(_onRouteStatus);
      _routeSecAnim?.removeStatusListener(_onRouteStatus);
      _routeAnim = anim;
      _routeSecAnim = secAnim;
      _routeAnim?.addStatusListener(_onRouteStatus);
      _routeSecAnim?.addStatusListener(_onRouteStatus);
    }
    _syncTicker();
  }

  void _onRouteStatus(AnimationStatus _) => _syncTicker();

  bool get _isRouteTransitioning {
    final route = ModalRoute.of(context);
    if (route?.navigator?.userGestureInProgress ?? false) return true;
    final anim = _routeAnim;
    if (anim != null &&
        (anim.status == AnimationStatus.forward ||
            anim.status == AnimationStatus.reverse)) {
      return true;
    }
    final secAnim = _routeSecAnim;
    if (secAnim != null &&
        (secAnim.status == AnimationStatus.forward ||
            secAnim.status == AnimationStatus.reverse)) {
      return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant FluidArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artUri != widget.artUri) {
      _resolveAndBake(widget.artUri);
    }
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncTicker();
    }
  }

  void _syncTicker() {
    final animatingFade = _renderState.crossfade < 1.0;
    final animatingRotation = widget.isPlaying && !_isRouteTransitioning;
    final needTicks = animatingFade || animatingRotation;
    if (needTicks && !_ticker.isActive) {
      _lastElapsed = null;
      _acc = 0.0;
      _ticker.start();
    } else if (!needTicks && _ticker.isActive) {
      _ticker.stop();
      _lastElapsed = null;
      _acc = 0.0;
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted) {
      _lastElapsed = null;
      _acc = 0.0;
      return;
    }
    final prev = _lastElapsed;
    _lastElapsed = elapsed;
    if (prev == null) return;
    final dt = (elapsed - prev).inMicroseconds / 1e6;
    if (dt <= 0.0 || dt > 0.25) return;

    _acc += dt;
    // 60 Hz VSync pacing (~15.5ms) keeping CPU ~20% while UI runs at 120 FPS
    if (_acc < 0.033) return;
    final step = _acc;
    _acc = 0.0;

    var dirty = false;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final canAdvanceGlobal =
        (nowUs - _FluidBlendCache._lastGlobalTickUs).abs() > 24000;
    if (widget.isPlaying && !_isRouteTransitioning && canAdvanceGlobal) {
      _FluidBlendCache._lastGlobalTickUs = nowUs;
      _FluidBlendCache.sharedTsRad =
          (_FluidBlendCache.sharedTsRad + step * _tsSpeedRad) % _twoPi;
      _FluidBlendCache.sharedBeRad =
          (_FluidBlendCache.sharedBeRad + step * _beSpeedRad) % _twoPi;
      _FluidBlendCache.sharedFrameRad =
          (_FluidBlendCache.sharedFrameRad + step * _frameSpeedRad) % _twoPi;

      _renderState.tsRad = _FluidBlendCache.sharedTsRad;
      _renderState.beRad = _FluidBlendCache.sharedBeRad;
      _renderState.frameRad = _FluidBlendCache.sharedFrameRad;
      dirty = true;
    }

    if (_renderState.crossfade < 1.0) {
      // Gradual 400ms fade-in on open and between track changes
      _renderState.crossfade = (_renderState.crossfade + step / 0.40).clamp(
        0.0,
        1.0,
      );
      if (_renderState.crossfade >= 1.0) {
        _renderState.clearPrevTex();
        if (!widget.isPlaying || _isRouteTransitioning) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncTicker();
          });
        }
      }
      dirty = true;
    }

    if (dirty) {
      _renderState.notifyTick();
    }
  }

  void _stopImageStream() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  void _resolveAndBake(String? rawUri) {
    final uri = rawUri?.trim() ?? '';
    if (uri.isEmpty) {
      _loadingUri = '';
      _stopImageStream();
      _bakeGeneration++;
      _renderState.setTextures(
        null,
        startFade: _renderState.currentTex == null ? 1.0 : 0.0,
      );
      _syncTicker();
      return;
    }

    final cachedTint = _FluidBlendCache.getDeepTint(uri);
    if (cachedTint != null) {
      _renderState.deepTint = cachedTint;
    }

    // Immediate hit from static cache: keeps identical position & aspect across
    // tab switches, immersive controls toggling, or re-opening the screen.
    final cached = _FluidBlendCache.getTextures(uri);
    if (cached != null) {
      _loadingUri = uri;
      _stopImageStream();
      _bakeGeneration++;
      if (!identical(_renderState.currentTex, cached)) {
        final shouldFade = _renderState.currentTex != null;
        _renderState.setTextures(cached, startFade: shouldFade ? 0.0 : 1.0);
      }
      _syncTicker();
      return;
    }

    if (uri == _loadingUri) return;
    _loadingUri = uri;
    _stopImageStream();

    final ImageProvider provider =
        (uri.startsWith('http://') || uri.startsWith('https://'))
        ? CachedNetworkImageProvider(
            uri,
            maxWidth: 64,
            maxHeight: 64,
            cacheManager: CoverCacheManager.instance,
          )
        : ResizeImage(
            FileImage(
              File(
                uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri,
              ),
            ),
            width: 64,
            height: 64,
          );
    if (provider == null) return;

    final gen = ++_bakeGeneration;
    final stream = provider.resolve(ImageConfiguration.empty);
    _imageStream = stream;
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) async {
        _stopImageStream();
        final baked = await _bakeFluidTextures(uri, info.image);
        _FluidBlendCache.putTextures(uri, baked);
        if (!mounted || gen != _bakeGeneration) return;
        // Fade in smoothly from 0.0 -> 1.0 even on initial open or when paused
        _renderState.setTextures(baked, startFade: 0.0);
        _syncTicker();
      },
      onError: (Object _, StackTrace? _) {
        _stopImageStream();
      },
    );
    _imageListener = listener;
    stream.addListener(listener);
  }

  static Future<_FluidBakedTextures> _bakeFluidTextures(
    String uri,
    ui.Image src,
  ) async {
    final sw = src.width.toDouble();
    final sh = src.height.toDouble();
    final fullSrc = Rect.fromLTWH(0, 0, sw, sh);
    final tlSrc = Rect.fromLTWH(0, 0, sw * 0.5, sh * 0.5);
    final brSrc = Rect.fromLTWH(sw * 0.5, sh * 0.5, sw * 0.5, sh * 0.5);

    final bg = await _bakeSingleLayer(src, fullSrc, isQuadrant: false);
    final ts = await _bakeSingleLayer(src, tlSrc, isQuadrant: true);
    final be = await _bakeSingleLayer(src, brSrc, isQuadrant: true);
    return _FluidBakedTextures(uri: uri, bg: bg, ts: ts, be: be);
  }

  static Future<ui.Image> _bakeSingleLayer(
    ui.Image src,
    Rect srcRect, {
    required bool isQuadrant,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, _texSize, _texSize),
    );

    if (!isQuadrant) {
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = _fluidSaturationFilter
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 30.0,
          sigmaY: 30.0,
          tileMode: TileMode.clamp,
        );
      canvas.drawImageRect(
        src,
        srcRect,
        const Rect.fromLTWH(-12, -12, _texSize + 24, _texSize + 24),
        paint,
      );
    } else {
      const fullBounds = Rect.fromLTWH(0, 0, _texSize, _texSize);
      canvas.saveLayer(fullBounds, Paint());

      final blurLayerPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 24.0,
          sigmaY: 24.0,
          tileMode: TileMode.decal,
        );
      canvas.saveLayer(fullBounds, blurLayerPaint);
      const ovalRect = Rect.fromLTWH(40, 40, _texSize - 80, _texSize - 80);
      canvas.clipPath(Path()..addOval(ovalRect));
      final imgPaint = Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = _fluidSaturationFilter;
      canvas.drawImageRect(src, srcRect, ovalRect, imgPaint);
      canvas.restore();

      final radialMask = Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.radial(
          const Offset(_texSize * 0.5, _texSize * 0.5),
          _texSize * 0.48,
          const <Color>[
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
            Color(0x00FFFFFF),
          ],
          const <double>[0.0, 0.62, 1.0],
        );
      canvas.drawRect(fullBounds, radialMask);
      canvas.restore();
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(_texInt, _texInt);
    picture.dispose();
    return img;
  }

  @override
  void dispose() {
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _routeSecAnim?.removeStatusListener(_onRouteStatus);
    _stopImageStream();
    _ticker.dispose();
    _renderState.releaseTextures();
    _renderState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uri = widget.artUri ?? '';
    return CoverSourceColorBuilder(
      imageSource: uri.isEmpty ? null : uri,
      builder: (context, dominantColor) {
        if (dominantColor != null) {
          final hsl = HSLColor.fromColor(dominantColor);
          final computed = hsl
              .withSaturation((hsl.saturation * 1.38).clamp(0.0, 0.88))
              .withLightness(0.14)
              .toColor();
          if (uri.isNotEmpty) {
            _FluidBlendCache.putDeepTint(uri, computed);
          }
          _renderState.deepTint = computed;
        } else if (uri.isNotEmpty) {
          final cachedTint = _FluidBlendCache.getDeepTint(uri);
          if (cachedTint != null) {
            _renderState.deepTint = cachedTint;
          }
        }

        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _FluidBlendPainter(
                state: _renderState,
                shallowBlur: widget.shallowBlur,
                darkMode: widget.darkMode,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

class _FluidBlendPainter extends CustomPainter {
  _FluidBlendPainter({
    required this.state,
    this.shallowBlur = false,
    this.darkMode = true,
  }) : super(repaint: state);

  final _FluidBlendRenderState state;
  final bool shallowBlur;
  final bool darkMode;

  static const _srcRect = Rect.fromLTWH(0, 0, 192, 192);

  void _drawSet(
    Canvas canvas,
    Size size,
    _FluidBakedTextures tex,
    double alpha,
    double tsRad,
    double beRad,
    double frameRad,
  ) {
    if (alpha <= 0.0 || tex._disposed) return;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(255, 255, 255, alpha.clamp(0.0, 1.0));

    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final side = math.max(size.width, size.height) * 1.38;

    // 1. Base full-bleed blurred layer
    canvas.drawImageRect(
      tex.bg,
      _srcRect,
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: size.width * 1.25,
        height: size.height * 1.25,
      ),
      paint,
    );

    // 2. Counter-rotating composite group (-17.65 deg/s)
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(frameRad);

    // 2a. Bottom-right quadrant layer (+19.71 deg/s)
    canvas.save();
    canvas.translate(side * 0.16, side * 0.16);
    canvas.rotate(beRad);
    final beSize = side * 0.96;
    canvas.drawImageRect(
      tex.be,
      _srcRect,
      Rect.fromCenter(center: Offset.zero, width: beSize, height: beSize),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(255, 255, 255, (alpha * 0.92).clamp(0.0, 1.0)),
    );
    canvas.restore();

    // 2b. Top-left quadrant layer (+35.29 deg/s)
    canvas.save();
    canvas.translate(-side * 0.16, -side * 0.16);
    canvas.rotate(tsRad);
    final tsSize = side * 0.90;
    canvas.drawImageRect(
      tex.ts,
      _srcRect,
      Rect.fromCenter(center: Offset.zero, width: tsSize, height: tsSize),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(255, 255, 255, (alpha * 0.92).clamp(0.0, 1.0)),
    );
    canvas.restore();

    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    final deepTint = state.deepTint;
    final currentTex = state.currentTex;
    final prevTex = state.prevTex;
    final eased = Curves.easeOutCubic.transform(
      state.crossfade.clamp(0.0, 1.0),
    );
    final tsRad = state.tsRad;
    final beRad = state.beRad;
    final frameRad = state.frameRad;

    // Soft ambient radial-vertical base so opening never looks like a harsh flat block
    final ambientPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width * 0.5, size.height * 0.36),
        math.max(size.width, size.height) * 0.85,
        <Color>[deepTint, deepTint, Colors.black],
        const <double>[0.0, 0.55, 1.0],
      );
    canvas.drawRect(bounds, ambientPaint);

    if (prevTex != null && eased < 1.0) {
      _drawSet(canvas, size, prevTex, 1.0, tsRad, beRad, frameRad);
    }
    if (currentTex != null) {
      _drawSet(canvas, size, currentTex, eased, tsRad, beRad, frameRad);
    }

    final overlayAlpha = darkMode
        ? (shallowBlur ? 0.34 : 0.47)
        : (shallowBlur ? 0.15 : 0.18);
    canvas.drawRect(
      bounds,
      Paint()..color = Color.fromRGBO(0, 0, 0, overlayAlpha),
    );
  }

  @override
  bool shouldRepaint(covariant _FluidBlendPainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.shallowBlur != shallowBlur ||
      oldDelegate.darkMode != darkMode;
}
