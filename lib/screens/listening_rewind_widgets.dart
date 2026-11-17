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
    // Each part rises on the default spatial spring after its own delay and
    // fades in on the effects spring over the same clock; reduced motion
    // shows it at once.
    const still = AppMotionSpec(Duration.zero, Curves.linear);
    final rise = AppMotion.spatial(
      context,
      still,
      mornye: MornyeMotion.standard,
    );
    if (rise.duration == Duration.zero) return child;
    final fade = AppMotion.effects(
      context,
      still,
      mornye: MornyeMotion.effects,
    );
    const stagger = Duration(milliseconds: 90);
    final delay = stagger * order;
    final span = rise.duration > fade.duration ? rise.duration : fade.duration;
    final total = delay + span;
    double progress(double elapsed, Duration length) =>
        (elapsed / length.inMicroseconds).clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: total.inMicroseconds.toDouble()),
      duration: total,
      builder: (context, time, child) {
        final elapsed = time - delay.inMicroseconds;
        final moved = rise.curve.transform(progress(elapsed, rise.duration));
        final opacity = fade.curve.transform(progress(elapsed, fade.duration));
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, 28 * (1 - moved)),
            child: child,
          ),
        );
      },
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
            fontWeight: FontWeight.w800,
            color: DefaultTextStyle.of(context).style.color,
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
    return Row(
      children: [
        if (rank case final rank?)
          SizedBox(
            width: 40,
            child: Text(
              '$rank',
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: color?.withValues(alpha: 0.55),
              ),
            ),
          ),
        artwork,
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
    // Each bar grows on the slow spatial spring, which stops at its height,
    // one month after another; reduced motion draws them grown.
    final grow = AppMotion.spatialSlow(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
      mornye: MornyeMotion.slow,
    );
    final reduced = grow.duration == Duration.zero;
    const barStagger = Duration(milliseconds: 60);
    Duration barLength(int month) =>
        reduced ? Duration.zero : barStagger * month + grow.duration;
    Curve barCurve(int month) => reduced
        ? Curves.linear
        : Interval(
            (barStagger * month).inMicroseconds /
                barLength(month).inMicroseconds,
            1,
            curve: grow.curve,
          );
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
                        // Bars grow from the baseline, January first.
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: reduced ? 1 : 0, end: 1),
                          duration: barLength(month),
                          curve: barCurve(month),
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
