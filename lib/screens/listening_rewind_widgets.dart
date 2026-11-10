part of 'listening_rewind_screen.dart';

/// Slide content with a staggered spring entrance.
class _Column extends StatelessWidget {
  const _Column({required this.children, this.center = false});

  final List<Widget> children;
  final bool center;

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
    textAlign: center ? TextAlign.center : TextAlign.start,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.stretch,
      children: [
        for (final (index, child) in children.indexed)
          _Reveal(
            order: index,
            child: Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 16),
              child: child,
            ),
          ),
      ],
    ),
  );
}

class _Reveal extends StatelessWidget {
  const _Reveal({required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final motion = AppMotion.spatial(
      context,
      AppMotionSpec(
        reduced ? Duration.zero : const Duration(milliseconds: 420),
        Curves.easeOutCubic,
      ),
    );
    if (motion.duration == Duration.zero) return child;
    const stagger = Duration(milliseconds: 90);
    final total = motion.duration + stagger * order;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(
        stagger.inMicroseconds * order / total.inMicroseconds,
        1,
        curve: motion.curve,
      ),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 28 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _CountUp extends StatelessWidget {
  const _CountUp({required this.value, required this.format, this.fontSize});

  final int value;
  final String Function(num) format;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final primary = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(
        begin: reduced ? value.toDouble() : 0,
        end: value.toDouble(),
      ),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 1400),
      curve: Curves.easeOutCubic,
      builder: (context, current, _) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          format(current.round()),
          style: Theme.of(context).textTheme.displayLarge?.copyWith(
            fontSize: fontSize ?? 96,
            height: 1,
            fontWeight: FontWeight.w900,
            letterSpacing: -2,
            color: DefaultTextStyle.of(context).style.color,
            shadows: [
              Shadow(color: primary.withValues(alpha: 0.35), blurRadius: 28),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Size { regular, large, huge }

class _Headline extends StatelessWidget {
  const _Headline(this.text, {this.size = _Size.regular});

  final String text;
  final _Size size;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final style = switch (size) {
      _Size.regular => textTheme.headlineMedium,
      _Size.large => textTheme.headlineLarge,
      _Size.huge => textTheme.displayMedium,
    };
    return Text(
      text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: style?.copyWith(
        fontWeight: FontWeight.w800,
        color: DefaultTextStyle.of(context).style.color,
      ),
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: DefaultTextStyle.of(context).style.color?.withValues(alpha: 0.8),
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: DefaultTextStyle.of(context).style.color?.withValues(alpha: 0.85),
    ),
  );
}

/// A short highlighted statement. A tinted pill rather than a card.
class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: color.withValues(alpha: 0.14),
      shape: const StadiumBorder(),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: DefaultTextStyle.of(context).style.color,
        ),
      ),
    ),
  );
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.uri, required this.size, this.artist = false});

  final String? uri;
  final double size;
  final bool artist;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final image = SizedBox.square(
      dimension: size,
      child: uri == null
          ? ColoredBox(
              color: colors.surfaceContainerHighest,
              child: AppIcon(
                artist ? Icons.person : Icons.music_note,
                size: size * 0.4,
                color: colors.onSurfaceVariant,
              ),
            )
          : PlayerArtwork(
              artUri: uri,
              colorScheme: colors,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
              iconSize: size * 0.4,
            ),
    );
    if (artist) return AppShapeClip(kind: AppShapes.artist, child: image);
    final radius = context.isMornye
        ? size * 0.06
        : size >= 120
        ? 28.0
        : 12.0;
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}

class _RankedRow extends StatelessWidget {
  const _RankedRow({
    required this.artwork,
    required this.title,
    required this.subtitle,
    this.rank,
  });

  final int? rank;
  final Widget artwork;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final color = DefaultTextStyle.of(context).style.color;
    final isTop3 = rank != null && rank! <= 3;
    final podiumBadge = switch (rank) {
      1 => const Color(0xffffd700), // Gold
      2 => const Color(0xffdcdcdc), // Silver
      3 => const Color(0xffcd7f32), // Bronze
      _ => null,
    };

    final rowContent = Row(
      children: [
        if (rank case final rank?) ...[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: podiumBadge != null
                  ? podiumBadge.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.08),
              border: Border.all(
                color: podiumBadge != null
                    ? podiumBadge.withValues(alpha: 0.85)
                    : Colors.white.withValues(alpha: 0.18),
                width: podiumBadge != null ? 1.5 : 1.0,
              ),
              boxShadow: podiumBadge != null
                  ? [
                      BoxShadow(
                        color: podiumBadge.withValues(alpha: 0.35),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '$rank',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: podiumBadge ?? color?.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        artwork,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: color?.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isTop3
            ? (podiumBadge?.withValues(alpha: 0.08) ??
                  Colors.white.withValues(alpha: 0.06))
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isTop3
              ? (podiumBadge?.withValues(alpha: 0.28) ??
                    Colors.white.withValues(alpha: 0.12))
              : Colors.white.withValues(alpha: 0.08),
          width: isTop3 ? 1.2 : 0.8,
        ),
      ),
      child: rowContent,
    );
  }
}

/// Big counted-up figures in a two-column grid.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats, required this.format});

  final List<(int, String)> stats;
  final String Function(num) format;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final color = DefaultTextStyle.of(context).style.color;
    Widget stat((int, String) entry) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CountUp(value: entry.$1, format: format, fontSize: 56),
        Text(
          entry.$2,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: color?.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
    return Column(
      children: [
        for (var i = 0; i < stats.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: stat(stats[i])),
              const SizedBox(width: 16),
              Expanded(
                child: i + 1 < stats.length
                    ? stat(stats[i + 1])
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Twelve bars of monthly listening; [highlight] stands out at full color.
class _MonthChart extends StatelessWidget {
  const _MonthChart({
    required this.milliseconds,
    required this.highlight,
    required this.year,
    required this.accent,
  });

  final Map<int, int> milliseconds;
  final int highlight;
  final int year;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    // Stand-alone narrow month names (J, F, M...).
    final narrow = DateFormat('LLLLL', locale);
    final peak = milliseconds.values.fold(0, math.max);
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: accent.withValues(alpha: 0.8),
    );
    final reduced = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: 180,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var month = 1; month <= 12; month++) ...[
              if (month > 1) const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        // Bars grow from the baseline, the peak month last.
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: reduced ? 1 : 0, end: 1),
                          duration: reduced
                              ? Duration.zero
                              : Duration(milliseconds: 600 + month * 60),
                          curve: Curves.easeOutCubic,
                          builder: (context, t, _) => FractionallySizedBox(
                            heightFactor:
                                peak <= 0 || (milliseconds[month] ?? 0) <= 0
                                ? 0
                                : math.max(
                                        0.04,
                                        (milliseconds[month] ?? 0) / peak,
                                      ) *
                                      t,
                            child: DecoratedBox(
                              decoration: ShapeDecoration(
                                color: month == highlight
                                    ? accent
                                    : accent.withValues(alpha: 0.3),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const SizedBox(width: double.infinity),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      narrow.format(DateTime(year, month)),
                      style: labelStyle,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Each month beside the artist heard longest that month, in two columns.
class _MonthArtists extends StatelessWidget {
  const _MonthArtists({required this.months, required this.artwork});

  /// Short month name and artist, in calendar order.
  final List<(String, String)> months;
  final Map<String, String> artwork;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final color = DefaultTextStyle.of(context).style.color;
    Widget row((String, String) entry) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _Artwork(uri: artwork[entry.$2], size: 36, artist: true),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.$1,
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color?.withValues(alpha: 0.7),
                  ),
                ),
                Text(
                  entry.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final half = (months.length / 2).ceil();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(children: [for (final e in months.take(half)) row(e)]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(children: [for (final e in months.skip(half)) row(e)]),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final color = DefaultTextStyle.of(context).style.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.labelLarge?.copyWith(
            color: color?.withValues(alpha: 0.75),
          ),
        ),
        Text(
          detail == null ? value : '$value · $detail',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}
