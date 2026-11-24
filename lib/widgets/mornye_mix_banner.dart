import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/desktop_platform.dart';

const mornyeLockupAsset =
    'assets/brand/logo/png/mornye-lockup-horizontal-white@1x.png';

/// The colors of one banner: the wash, and the two blooms that move across it.
class _BannerPalette {
  const _BannerPalette(this.start, this.end, this.glow, this.depth);

  final Color start;
  final Color end;
  final Color glow;
  final Color depth;
}

const _palettes = [
  // Amber.
  _BannerPalette(
    Color(0xfff7a823),
    Color(0xffdf5f12),
    Color(0xffffdc55),
    Color(0xffb8320c),
  ),
  // Rose.
  _BannerPalette(
    Color(0xfff0507a),
    Color(0xffae1450),
    Color(0xffffa08f),
    Color(0xff6b1258),
  ),
  // Violet.
  _BannerPalette(
    Color(0xff7a5cf0),
    Color(0xff3a219e),
    Color(0xffc993ff),
    Color(0xff1f1566),
  ),
  // Ocean.
  _BannerPalette(
    Color(0xff1f9fe0),
    Color(0xff0d50b4),
    Color(0xff82e4f2),
    Color(0xff0b2e7c),
  ),
  // Teal, near the brand's own.
  _BannerPalette(
    Color(0xff1cae9c),
    Color(0xff0f6569),
    Color(0xff58d6c0),
    Color(0xff1e4e4f),
  ),
  // Ember.
  _BannerPalette(
    Color(0xffee4a3a),
    Color(0xff9c1d22),
    Color(0xffffa45c),
    Color(0xff5e1030),
  ),
];

/// A stable number for [key]: `String.hashCode` is free to change between
/// runs, and a mix should keep its banner from one day to the next.
int mornyeBannerSeed(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// The seeds for a shelf of [keys]: each keeps its own unless the banner beside
/// it landed on the same palette, so neighbors never match.
List<int> mornyeBannerSeeds(Iterable<String> keys) {
  final seeds = <int>[];
  for (final key in keys) {
    var seed = mornyeBannerSeed(key);
    if (seeds.isNotEmpty &&
        seed % _palettes.length == seeds.last % _palettes.length) {
      seed++;
    }
    seeds.add(seed);
  }
  return seeds;
}

final _mornyeBannerWhitespace = RegExp(r'\s+');

/// The title's size for a banner [width]: as large as the longest word allows
/// on one line, so a line never breaks inside a word, and the whole title in
/// its three lines, words wrapping short of each line's end.
double mornyeBannerTitleSize(String title, double width) {
  final longest = title
      .split(_mornyeBannerWhitespace)
      .fold<int>(1, (length, word) => math.max(length, word.length));
  final line = (width - 40) / 0.58;
  return math.max(
    11.0,
    [width * 0.17, line / longest, line * 2.4 / title.length].reduce(math.min),
  );
}

/// The art of a Top Pick: a soft color field, the mix's name set large, and
/// the Mornye lockup in the top trailing corner.
class MornyeMixBanner extends StatelessWidget {
  const MornyeMixBanner({
    super.key,
    required this.seed,
    required this.title,
    required this.eyebrow,
    required this.subtitle,
    required this.width,
    this.drift,
  });

  /// Picks the palette and where its blooms sit; see [mornyeBannerSeed].
  final int seed;
  final String title;
  final String eyebrow;
  final String subtitle;
  final double width;

  /// A looping phase in `[0, 1)` the field flows through: its blooms wander
  /// and its wash leans. Without one the field is still.
  final ValueListenable<double>? drift;

  static const aspectRatio = 3 / 4;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final logoWidth = width * 0.3;
    // Pointer layouts use a compact caption.
    final captionSize = isDesktopPlatform ? 12.0 : null;
    return RepaintBoundary(
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: SizedBox(
          width: width,
          height: width / aspectRatio,
          child: Stack(
            children: [
              // A layer of its own: the drift repaints the field, not the
              // text over it.
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _BannerPainter(seed, drift)),
                ),
              ),
              PositionedDirectional(
                top: 16,
                end: 16,
                child: ExcludeSemantics(
                  child: Image.asset(
                    mornyeLockupAsset,
                    width: logoWidth,
                    cacheWidth: (logoWidth * pixelRatio).round(),
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Center(
                    child: Text(
                      title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: textTheme.displaySmall?.copyWith(
                        color: Colors.white,
                        fontSize: mornyeBannerTitleSize(title, width),
                        fontWeight: FontWeight.w700,
                        height: 1.04,
                        letterSpacing: -0.6,
                      ),
                    ),
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
                      eyebrow,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: captionSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
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

class _BannerPainter extends CustomPainter {
  const _BannerPainter(this.seed, this.phase) : super(repaint: phase);

  final int seed;
  final ValueListenable<double>? phase;

  /// A value that swings between [low] and [high], [turns] times so far,
  /// from [rest]: where it is when the loop starts.
  static double _swing(double low, double high, double rest, double turns) {
    final middle = (low + high) / 2, reach = (high - low) / 2;
    final start = math.asin(((rest - middle) / reach).clamp(-1.0, 1.0));
    return middle + reach * math.sin(start + 2 * math.pi * turns);
  }

  static final _paint = Paint();
  static final _captionGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Colors.black.withValues(alpha: 0),
      Colors.black.withValues(alpha: 0.26),
    ],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final palette = _palettes[seed % _palettes.length];
    final rect = Offset.zero & size;
    // Every swing starts where the still banner has it, so a field at rest
    // is the banner as drawn still.
    final loop = phase?.value ?? 0;
    final way = (seed >> 3).isEven ? 1.0 : -1.0;
    final breath = math.sin(2 * math.pi * loop);
    _paint.shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [palette.start, palette.end],
      transform: GradientRotation(way * 0.5 * breath),
    ).createShader(rect);
    canvas.drawRect(rect, _paint);
    // The seed's upper bits place the blooms, apart from the palette's choice.
    final drift = ((seed >> 8) & 0xff) / 255;
    final lean = ((seed >> 16) & 0xff) / 255;
    void bloom(Offset center, double radius, Color color, double strength) {
      final circle = Rect.fromCircle(center: center, radius: radius);
      _paint.shader = RadialGradient(
        colors: [
          color.withValues(alpha: strength),
          color.withValues(alpha: strength * 0.62),
          color.withValues(alpha: 0),
        ],
        stops: const [0, 0.52, 1],
      ).createShader(circle);
      canvas.drawRect(rect, _paint);
    }

    // The light bloom keeps to the top, clear of the white title.
    bloom(
      Offset(
        size.width * _swing(0.15, 0.95, 0.55 + 0.4 * drift, way * 2 * loop),
        size.height * _swing(0.1, 0.42, 0.12 + 0.28 * lean, way * 3 * loop),
      ),
      size.width * 0.86 * (1 + 0.12 * breath),
      palette.glow,
      0.9,
    );
    bloom(
      Offset(
        size.width * _swing(0.05, 0.85, 0.05 + 0.4 * lean, -way * 2 * loop),
        size.height * _swing(0.56, 0.96, 0.82 + 0.14 * drift, -way * 3 * loop),
      ),
      size.width * 0.96 * (1 - 0.1 * breath),
      palette.depth,
      0.82,
    );
    // Keeps the small caption legible on the brightest blooms.
    final caption = Rect.fromLTRB(
      0,
      size.height * 0.68,
      size.width,
      size.height,
    );
    _paint.shader = _captionGradient.createShader(caption);
    canvas.drawRect(caption, _paint);
  }

  @override
  bool shouldRepaint(_BannerPainter oldDelegate) =>
      oldDelegate.seed != seed || oldDelegate.phase != phase;
}
