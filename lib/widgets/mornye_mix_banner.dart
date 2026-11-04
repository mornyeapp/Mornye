import 'dart:math' as math;

import 'package:flutter/material.dart';

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

/// The title's size for a banner [width]: as large as the longest word allows
/// on one line, so a line never breaks inside a word.
double mornyeBannerTitleSize(String title, double width) {
  final longest = title
      .split(RegExp(r'\s+'))
      .fold<int>(1, (length, word) => math.max(length, word.length));
  return math.min(width * 0.2, (width - 40) / (longest * 0.58));
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
  });

  /// Picks the palette and where its blooms sit; see [mornyeBannerSeed].
  final int seed;
  final String title;
  final String eyebrow;
  final String subtitle;
  final double width;

  static const aspectRatio = 3 / 4;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final logoWidth = width * 0.3;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: SizedBox(
        width: width,
        height: width / aspectRatio,
        child: CustomPaint(
          painter: _BannerPainter(seed),
          child: Stack(
            children: [
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
  const _BannerPainter(this.seed);

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final palette = _palettes[seed % _palettes.length];
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.start, palette.end],
        ).createShader(rect),
    );
    // The seed's upper bits place the blooms, apart from the palette's choice.
    final drift = ((seed >> 8) & 0xff) / 255;
    final lean = ((seed >> 16) & 0xff) / 255;
    void bloom(Offset center, double radius, Color color, double strength) {
      final circle = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: strength),
              color.withValues(alpha: strength * 0.62),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.52, 1],
          ).createShader(circle),
      );
    }

    bloom(
      Offset(
        size.width * (0.55 + 0.4 * drift),
        size.height * (0.12 + 0.28 * lean),
      ),
      size.width * 0.86,
      palette.glow,
      0.9,
    );
    bloom(
      Offset(
        size.width * (0.05 + 0.4 * lean),
        size.height * (0.82 + 0.14 * drift),
      ),
      size.width * 0.96,
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
    canvas.drawRect(
      caption,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.26),
          ],
        ).createShader(caption),
    );
  }

  @override
  bool shouldRepaint(_BannerPainter oldDelegate) => oldDelegate.seed != seed;
}
