import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart'
    show artworkPixelLuminance, mornyeLabelBackgroundLuminance;
import 'package:mornye/widgets/mornye_mix_banner.dart';

/// A Top Pick that is an album: the cover fills the top of the card, turns
/// soft toward its lower edge and goes on under the caption as one long blur
/// of itself.
///
/// A cover does not change, so the soft part is drawn once into a small image
/// per cover and card width, and no filter runs on the frames after that.
/// The caption stays white: the blur is darkened only as far as a light
/// cover needs.
class MornyeAlbumPick extends StatefulWidget {
  const MornyeAlbumPick({
    super.key,
    required this.artUri,
    required this.title,
    required this.eyebrow,
    required this.subtitle,
    required this.width,
  });

  /// The album's cover in any stored form; null shows the card without one.
  final String? artUri;
  final String title;
  final String eyebrow;
  final String subtitle;
  final double width;

  /// Where down the cover its soft copy starts to show, as a share of the
  /// cover's height. It hides the cover's last row.
  static const softStart = 0.8;

  /// The least the caption's end is darkened, so the labels have an edge on
  /// any cover.
  static const leastDim = 0.18;

  /// How dark the caption's end of a soft image of raw RGBA [pixels] must be
  /// for white labels: none over a dark cover, more the lighter it is.
  @visibleForTesting
  static double captionDim(
    ByteData pixels, {
    required int width,
    required int height,
  }) {
    // The caption sits on the lower half; the upper is still the cover.
    var sum = 0.0;
    var count = 0;
    for (var y = height ~/ 2; y < height; y += 2) {
      for (var x = 0; x < width; x += 2) {
        final index = (y * width + x) * 4;
        sum += artworkPixelLuminance(
          pixels.getUint8(index),
          pixels.getUint8(index + 1),
          pixels.getUint8(index + 2),
        );
        count++;
      }
    }
    if (count == 0) return leastDim;
    final luminance = sum / count;
    // The small eyebrow needs more than the player's large labels do.
    const target = mornyeLabelBackgroundLuminance * 0.8;
    if (luminance <= target) return leastDim;
    // Black at an opacity scales the encoded values: about a power of 2.2.
    final needed = 1 - math.pow(target / luminance, 1 / 2.2).toDouble();
    return math.max(leastDim, needed);
  }

  @override
  State<MornyeAlbumPick> createState() => _MornyeAlbumPickState();
}

/// One drawn soft copy and what it was drawn from.
typedef _Soft = ({ui.Image image, Object inputs});

class _MornyeAlbumPickState extends State<MornyeAlbumPick>
    with WidgetsBindingObserver {
  /// What a card without a cover, or still waiting for it, is filled with.
  static const _bare = Color(0xff2c2c2e);

  late final _listener = ImageStreamListener(
    _setArt,
    onError: (_, _) => _setArt(null, false),
  );
  ImageStream? _stream;
  ImageInfo? _art;
  int _cacheWidth = 0;

  _Soft? _soft;

  /// How dark the caption's end of [_soft] is, once its pixels are read.
  double? _dim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAtWidth();
  }

  @override
  void didUpdateWidget(MornyeAlbumPick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artUri != widget.artUri) {
      _resolve();
    } else {
      _resolveAtWidth();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A hidden surface may lose its GPU context. Draw the soft copy again;
    // the dim read from the same cover holds.
    if (state != AppLifecycleState.resumed || !mounted) return;
    setState(_dropSoft);
  }

  Timer? _resizeSettle;
  static const _resizeSettleDelay = Duration(milliseconds: 150);
  String? _dimArtUri;
  ui.Image? _softArt;
  double? _softWidth;
  double? _softDpr;

  /// Asks for the cover again when the card's width in pixels changed; on
  /// desktop in 64 px steps, so a window drag does not decode every frame.
  void _resolveAtWidth() {
    final rawWidth = (widget.width * MediaQuery.devicePixelRatioOf(context))
        .round();
    final cacheWidth = isDesktopPlatform
        ? ((rawWidth + 63) ~/ 64) * 64
        : rawWidth;
    if (cacheWidth == _cacheWidth) return;
    _cacheWidth = cacheWidth;
    _resolve();
  }

  /// Asks for the cover at the card's width. A cover that is still being
  /// fetched is asked for once more when it is [stored].
  void _resolve({bool stored = false}) {
    final source = widget.artUri;
    final provider = coverImageProvider(source, cacheWidth: _cacheWidth);
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

  void _setArt(ImageInfo? art, bool _) {
    if (!mounted || (art == null && _art == null)) {
      art?.dispose();
      return;
    }
    setState(() {
      _art?.dispose();
      _art = art;
      _dropSoft();
      if (art == null || widget.artUri != _dimArtUri) {
        _dim = null;
        _dimArtUri = null;
      }
    });
  }

  void _dropSoft() {
    _soft?.image.dispose();
    _soft = null;
    _softArt = null;
    _softWidth = null;
    _softDpr = null;
  }

  void _settleResize() {
    if (mounted) setState(_dropSoft);
  }

  /// Reads how light the caption's end of [soft] is, drawn from [art]. A
  /// read that fails leaves the labels the dim a white cover needs.
  void _measure(_Soft soft, ImageInfo art) {
    const whole = 0.5;
    final source = widget.artUri;
    void settle(double dim) {
      if (!mounted || !identical(_art, art)) return;
      setState(() {
        _dim = dim;
        _dimArtUri = source;
      });
    }

    final image = soft.image.clone();
    unawaited(
      image
          .toByteData(format: ui.ImageByteFormat.rawRgba)
          .then(
            (pixels) => settle(
              pixels == null
                  ? whole
                  : MornyeAlbumPick.captionDim(
                      pixels,
                      width: image.width,
                      height: image.height,
                    ),
            ),
            onError: (Object _) => settle(whole),
          )
          .whenComplete(image.dispose),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeSettle?.cancel();
    _stream?.removeListener(_listener);
    _art?.dispose();
    _soft?.image.dispose();
    super.dispose();
  }

  /// Draws the soft copy of [art] for a card of [width] by [height], from
  /// [softTop] to the card's end, at a quarter of the physical resolution:
  /// nothing in it is finer than the blur. This canvas has no transform, so
  /// every length and the blur take that scale.
  static ui.Image _render(
    ui.Image art, {
    required double width,
    required double height,
    required double softTop,
    required double dpr,
  }) {
    final scale = dpr / 4;
    final pixelWidth = math.max(1, (width * scale).ceil());
    final pixelHeight = math.max(1, ((height - softTop) * scale).ceil());
    final soft = Rect.fromLTWH(
      0,
      0,
      pixelWidth.toDouble(),
      pixelHeight.toDouble(),
    );
    // The cover laid out as the sharp one, which starts above this image.
    final cover = Rect.fromLTWH(
      0,
      -softTop * scale,
      pixelWidth.toDouble(),
      width * scale,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..saveLayer(soft, Paint())
      ..clipRect(soft)
      // Longer down than across: the cover's last rows run on as streaks.
      ..saveLayer(
        soft,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: width * 0.06 * scale,
            sigmaY: width * 0.11 * scale,
            tileMode: TileMode.clamp,
          ),
      )
      ..clipRect(soft);
    void paintCover() => paintImage(
      canvas: canvas,
      rect: cover,
      image: art,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
    );
    paintCover();
    // Below its edge the cover goes on as its own reflection, so the blur
    // has the edge's colours on both sides and no seam shows there.
    canvas
      ..save()
      ..translate(0, 2 * cover.bottom)
      ..scale(1, -1);
    paintCover();
    canvas
      ..restore()
      ..restore()
      // Comes in over the sharp cover and is whole from its edge on.
      ..drawRect(
        soft,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(0, cover.bottom),
            const [Color(0x00000000), Color(0xff000000)],
          ),
      )
      ..restore();
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(pixelWidth, pixelHeight);
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = width / MornyeMixBanner.aspectRatio;
    final softTop = width * MornyeAlbumPick.softStart;
    final info = _art;
    final art = info?.image;
    if (info != null && art != null) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final inputs = (art, width, dpr);
      if (_soft == null || _softArt != art || _softDpr != dpr) {
        _resizeSettle?.cancel();
        _dropSoft();
        final soft = _soft = (
          image: _render(
            art,
            width: width,
            height: height,
            softTop: softTop,
            dpr: dpr,
          ),
          inputs: inputs,
        );
        _softArt = art;
        _softWidth = width;
        _softDpr = dpr;
        if (_dim == null) _measure(soft, info);
      } else if (_softWidth != width) {
        // Stretch the existing soft blur while desktop window width moves;
        // re-render at exact width once resize settles.
        _resizeSettle?.cancel();
        _resizeSettle = Timer(_resizeSettleDelay, _settleResize);
      } else {
        _resizeSettle?.cancel();
      }
    }
    final soft = _soft;
    final dim = _dim;
    final fade = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 200), Curves.easeOut),
    );
    final textTheme = Theme.of(context).textTheme;
    // Pointer layouts use a compact caption.
    final captionSize = isDesktopPlatform ? 12.0 : null;
    return RepaintBoundary(
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: _bare)),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: width,
                child: Center(
                  child: AppIcon(
                    Icons.album_outlined,
                    size: width * 0.24,
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
              ),
              // The cover shows once its soft copy and the dim are known,
              // so nothing under the caption changes after it is there.
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: art != null && soft != null && dim != null ? 1 : 0,
                  duration: fade.duration,
                  curve: fade.curve,
                  child: art == null || soft == null
                      ? null
                      : Stack(
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              height: width,
                              child: RawImage(
                                image: art,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              top: softTop,
                              bottom: 0,
                              child: RawImage(
                                image: soft.image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.low,
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              top: softTop,
                              bottom: 0,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    // Whole from the cover's edge, where
                                    // the caption starts.
                                    stops: [
                                      0,
                                      (width - softTop) / (height - softTop),
                                    ],
                                    colors: [
                                      Colors.black.withValues(alpha: 0),
                                      Colors.black.withValues(alpha: dim ?? 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              PositionedDirectional(
                start: 16,
                end: 16,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.eyebrow,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: captionSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        fontSize: captionSize,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (widget.subtitle.isNotEmpty)
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: captionSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
