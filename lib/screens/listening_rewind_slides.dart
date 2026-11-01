part of 'listening_rewind_screen.dart';

/// Colors of one slide. Material cycles through the tonal containers;
/// Mornye stays dark over blurred artwork.
class _RewindPalette {
  const _RewindPalette(this.background, this.foreground, this.accent);

  factory _RewindPalette.of(
    BuildContext context,
    int index,
    ListeningRewind rewind,
  ) {
    if (context.isMornye) {
      return _RewindPalette(
        Colors.black,
        Colors.white,
        Theme.of(context).colorScheme.primary,
      );
    }
    final c = Theme.of(context).colorScheme;
    final pairs = [
      (c.primaryContainer, c.onPrimaryContainer, c.primary),
      (c.tertiaryContainer, c.onTertiaryContainer, c.tertiary),
      (c.secondaryContainer, c.onSecondaryContainer, c.secondary),
      (c.primary, c.onPrimary, c.primaryContainer),
      (c.tertiary, c.onTertiary, c.tertiaryContainer),
      (c.surfaceContainerHighest, c.onSurface, c.primary),
    ];
    final (background, foreground, accent) = pairs[index % pairs.length];
    return _RewindPalette(background, foreground, accent);
  }

  final Color background;
  final Color foreground;
  final Color accent;
}

class _RewindSlide extends StatelessWidget {
  const _RewindSlide({
    required this.slide,
    required this.rewind,
    required this.period,
    required this.palette,
  });

  final _Slide slide;
  final ListeningRewind rewind;
  final ListeningRewindPeriod period;
  final _RewindPalette palette;

  /// The slide's content only; [_RewindBackdrop] paints the shared, moving
  /// background behind every slide.
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          // Room for the progress bar above and the share button below.
          padding: const EdgeInsets.fromLTRB(28, 64, 28, 88),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              primary: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: palette.foreground),
                  child: IconTheme.merge(
                    data: IconThemeData(color: palette.foreground),
                    child: _content(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _content(BuildContext context) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final number = NumberFormat.decimalPattern(locale);
    final shortDate = DateFormat.MMMd(locale);
    final minutes = rewind.minutes;
    String minutesOf(int milliseconds) =>
        l10n.listeningStatsMinutes((milliseconds / 60000).round());
    final tracks = rewind.summary.tracks;
    final artwork = rewind.summary.artistArtwork;
    final yearDetails = rewind.year;
    final yearLabel = '${rewind.range.start.year}';
    String monthName(int month) => DateFormat.MMMM(
      locale,
    ).format(DateTime(rewind.range.start.year, month));

    switch (slide) {
      case _Slide.intro:
        if (yearDetails != null) {
          return _Column(
            center: true,
            children: [
              _Eyebrow(l10n.listeningRewindYearEyebrow),
              _Headline(
                l10n.listeningRewindYearTitle(yearLabel),
                size: _Size.huge,
              ),
              _Body(l10n.listeningRewindYearIntroBody),
            ],
          );
        }
        return _Column(
          center: true,
          children: [
            _Eyebrow(listeningRewindPeriodLabel(context, period)),
            _Headline(l10n.listeningRewindIntroTitle, size: _Size.huge),
            _Body(
              l10n.listeningRewindIntroBody(
                shortDate.format(rewind.range.start),
                shortDate.format(rewind.range.lastDay),
              ),
            ),
          ],
        );
      case _Slide.yearNumbers:
        return _Column(
          children: [
            _Headline(l10n.listeningRewindNumbersTitle),
            _StatGrid(
              stats: [
                (tracks.length, l10n.listeningRewindSongsLabel),
                (rewind.topArtists.length, l10n.listeningRewindArtistsLabel),
                (rewind.topAlbums.length, l10n.listeningRewindAlbumsLabel),
                (rewind.activeDays, l10n.listeningRewindDaysLabel),
              ],
              format: number.format,
            ),
            // "0% of your days" reads as a mistake, so tiny shares stay out.
            if (rewind.activeDayShare >= 1)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _Pill(
                  l10n.listeningRewindDaysShare(rewind.activeDayShare),
                  color: palette.foreground,
                ),
              ),
          ],
        );
      case _Slide.months:
        final biggest = rewind.biggestMonth!;
        return _Column(
          children: [
            _Headline(l10n.listeningRewindMonthsTitle),
            _MonthChart(
              milliseconds: rewind.monthlyMilliseconds,
              highlight: biggest,
              year: rewind.range.start.year,
              accent: palette.foreground,
            ),
            _Body(l10n.listeningRewindBiggestMonth(monthName(biggest))),
          ],
        );
      case _Slide.monthlyArtists:
        final months = yearDetails!.monthlyTopArtists.keys.toList()..sort();
        return _Column(
          children: [
            _Headline(l10n.listeningRewindMonthlyArtistsTitle),
            _MonthArtists(
              months: [
                for (final month in months)
                  (
                    DateFormat.MMM(
                      locale,
                    ).format(DateTime(rewind.range.start.year, month)),
                    yearDetails.monthlyTopArtists[month]!,
                  ),
              ],
              artwork: artwork,
            ),
          ],
        );
      case _Slide.loyal:
        final name = yearDetails!.loyalArtist!;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindLoyalTitle),
            _Artwork(uri: artwork[name], size: 200, artist: true),
            _Headline(name, size: _Size.large),
            _Pill(
              l10n.listeningRewindLoyalBody(yearDetails.loyalArtistDays),
              color: palette.foreground,
            ),
          ],
        );
      case _Slide.firstSong:
        final first = yearDetails!.firstPlay!;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindFirstSongTitle),
            _Artwork(uri: first.track.artwork, size: 220),
            _Headline(first.track.title, size: _Size.large),
            _Body(first.track.artist),
            _Pill(
              l10n.listeningRewindFirstSongBody(shortDate.format(first.day)),
              color: palette.foreground,
            ),
          ],
        );
      case _Slide.minutes:
        final change = rewind.changePercent;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindMinutesTitle),
            _CountUp(value: minutes, format: number.format),
            _Headline(l10n.listeningRewindMinutesUnit(minutes)),
            if (minutes >= 60)
              _Body(l10n.listeningRewindHours((minutes / 60).round())),
            if (change != null)
              _Pill(
                change.abs() < 5
                    ? l10n.listeningRewindSame
                    : change > 0
                    ? l10n.listeningRewindMore(change)
                    : l10n.listeningRewindLess(change.abs()),
                color: palette.foreground,
              ),
            _Body(
              l10n.listeningStatsTotals(
                rewind.summary.plays,
                tracks.length,
                rewind.summary.days.length,
              ),
            ),
          ],
        );
      case _Slide.topArtist:
        final top = rewind.topArtists.first;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindTopArtistTitle),
            _Artwork(uri: artwork[top.key], size: 220, artist: true),
            _Headline(top.key, size: _Size.large),
            _Body(
              '${minutesOf(top.value)} · '
              '${l10n.listeningRewindArtistShare(rewind.topArtistShare)}',
            ),
          ],
        );
      case _Slide.artists:
        return _Column(
          children: [
            _Headline(l10n.listeningRewindArtistsTitle),
            for (final (index, artist) in rewind.topArtists.take(5).indexed)
              _RankedRow(
                rank: index + 1,
                artwork: _Artwork(
                  uri: artwork[artist.key],
                  size: 56,
                  artist: true,
                ),
                title: artist.key,
                subtitle: minutesOf(artist.value),
              ),
          ],
        );
      case _Slide.topTrack:
        final top = tracks.first;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindTopTrackTitle),
            _Artwork(uri: top.track.artwork, size: 240),
            _Headline(top.track.title, size: _Size.large),
            _Body(top.track.artist),
            _Pill(
              '${l10n.listeningRewindPlays(top.plays)} · '
              '${minutesOf(top.milliseconds)}',
              color: palette.foreground,
            ),
          ],
        );
      case _Slide.tracks:
        return _Column(
          children: [
            _Headline(l10n.listeningRewindTracksTitle),
            for (final (index, total) in tracks.take(5).indexed)
              _RankedRow(
                rank: index + 1,
                artwork: _Artwork(uri: total.track.artwork, size: 56),
                title: total.track.title,
                subtitle: total.track.artist,
              ),
          ],
        );
      case _Slide.album:
        final album = rewind.topAlbums.first;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindTopAlbumTitle),
            _Artwork(uri: album.artwork, size: 240),
            _Headline(album.album, size: _Size.large),
            _Body('${album.artist} · ${minutesOf(album.milliseconds)}'),
          ],
        );
      case _Slide.discoveries:
        final count = rewind.newArtists.length;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindNewArtistsTitle),
            _CountUp(value: count, format: number.format),
            _Body(l10n.listeningRewindNewArtistsBody(count)),
            for (final name in rewind.newArtists.take(3))
              _RankedRow(
                artwork: _Artwork(uri: artwork[name], size: 48, artist: true),
                title: name,
                subtitle: minutesOf(rewind.summary.artists[name] ?? 0),
              ),
          ],
        );
      case _Slide.rhythm:
        final weekday = rewind.favoriteWeekday;
        return _Column(
          children: [
            _Headline(l10n.listeningRewindRhythmTitle),
            _Fact(
              label: l10n.listeningRewindPeakDay,
              value: shortDate.format(rewind.peakDay!),
              detail: minutesOf(rewind.peakDayMilliseconds),
            ),
            if (weekday != null)
              _Fact(
                label: l10n.listeningRewindFavoriteDay,
                // 1 January 2024 was a Monday.
                value: DateFormat.EEEE(
                  locale,
                ).format(DateTime(2024, 1, weekday)),
              ),
            _Fact(
              label: l10n.listeningRewindStreak,
              value: l10n.listeningRewindStreakDays(rewind.longestStreak),
            ),
          ],
        );
      case _Slide.replay:
        final replay = rewind.replay!;
        return _Column(
          center: true,
          children: [
            _Eyebrow(l10n.listeningRewindReplayTitle),
            _Artwork(uri: replay.track.artwork, size: 220),
            _Headline(replay.track.title, size: _Size.large),
            _Body(replay.track.artist),
            _Pill(
              l10n.listeningRewindReplayBody(
                replay.plays,
                shortDate.format(replay.day),
              ),
              color: palette.foreground,
            ),
          ],
        );
      case _Slide.outro:
        final biggestMonth = rewind.biggestMonth;
        return _Column(
          children: [
            _Headline(
              yearDetails != null
                  ? l10n.listeningRewindYearOutroTitle(yearLabel)
                  : l10n.listeningRewindOutroTitle,
              size: _Size.large,
            ),
            _Body(
              yearDetails != null
                  ? l10n.listeningRewindYearOutroBody
                  : l10n.listeningRewindOutroBody,
            ),
            _Fact(
              label: l10n.listeningRewindMinutesTitle,
              value:
                  '${number.format(minutes)} '
                  '${l10n.listeningRewindMinutesUnit(minutes)}',
            ),
            if (rewind.topArtists.isNotEmpty)
              _Fact(
                label: l10n.listeningRewindTopArtistTitle,
                value: rewind.topArtists.first.key,
              ),
            if (tracks.isNotEmpty)
              _Fact(
                label: l10n.listeningRewindTopTrackTitle,
                value: tracks.first.track.title,
              ),
            if (yearDetails != null && biggestMonth != null)
              _Fact(
                label: l10n.listeningRewindBiggestMonthLabel,
                value: monthName(biggestMonth),
              ),
            if (rewind.longestStreak > 1)
              _Fact(
                label: l10n.listeningRewindStreak,
                value: l10n.listeningRewindStreakDays(rewind.longestStreak),
              ),
          ],
        );
    }
  }
}

/// Artwork the Mornye backdrop shows behind [slide].
String? _slideArtwork(_Slide slide, ListeningRewind rewind) => switch (slide) {
  _Slide.topArtist ||
  _Slide.artists ||
  _Slide.monthlyArtists ||
  _Slide.discoveries =>
    rewind.summary.artistArtwork[rewind.topArtists.first.key],
  _Slide.loyal => rewind.summary.artistArtwork[rewind.year?.loyalArtist],
  _Slide.firstSong => rewind.year?.firstPlay?.track.artwork,
  _Slide.album => rewind.topAlbums.first.artwork,
  _Slide.replay => rewind.replay?.track.artwork,
  _ => rewind.summary.tracks.firstOrNull?.track.artwork,
};

/// One background behind every slide, so colors blend while swiping.
///
/// Material floats large expressive shapes that drift, turn and follow the
/// swipe. Mornye cross-fades the slides' blurred artwork while it slowly
/// zooms. Reduced motion keeps the shapes and artwork still.
///
/// The drift advances on the 30 Hz decorative clock. Each artwork blurs once
/// into a quarter-resolution image that the zoom and cross-fade then move;
/// [capturing] blurs it live so a shared image keeps the full blur.
class _RewindBackdrop extends StatefulWidget {
  const _RewindBackdrop({
    required this.pages,
    required this.palettes,
    required this.artworks,
    this.capturing = false,
  });

  final PageController pages;
  final List<_RewindPalette> palettes;
  final List<String?> artworks;
  final bool capturing;

  @override
  State<_RewindBackdrop> createState() => _RewindBackdropState();
}

class _RewindBackdropState extends State<_RewindBackdrop> {
  final _ambient = DecorativePhase(const Duration(seconds: 24));
  // One instance per artwork keeps its settled blur across the drift ticks.
  final _artwork = <String, Widget>{};
  ColorScheme? _artworkColors;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _ambient.stop();
    } else {
      _ambient.start();
    }
    final colors = Theme.of(context).colorScheme;
    if (colors != _artworkColors) {
      _artworkColors = colors;
      _artwork.clear();
    }
  }

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  double get _page {
    final pages = widget.pages;
    if (pages.hasClients && pages.position.haveDimensions) {
      return pages.page ?? 0;
    }
    return pages.initialPage.toDouble();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.pages, _ambient]),
        builder: (context, _) {
          final last = widget.palettes.length - 1;
          final page = _page.clamp(0.0, last.toDouble());
          final from = page.floor();
          final to = math.min(from + 1, last);
          final blend = page - from;
          final t = _ambient.value * 2 * math.pi;
          return context.isMornye
              ? _mornye(from, to, blend, t)
              : _material(from, to, blend, page, t);
        },
      ),
    ),
  );

  Widget _material(int from, int to, double blend, double page, double t) {
    final a = widget.palettes[from];
    final b = widget.palettes[to];
    final foreground = Color.lerp(a.foreground, b.foreground, blend)!;
    final accent = Color.lerp(a.accent, b.accent, blend)!;
    // Each shape drifts on its own orbit, turns slowly, and leans into the
    // swipe so the background feels continuous across slides.
    Widget shape({
      required M3EShapeKind kind,
      required double size,
      required Alignment alignment,
      required Offset orbit,
      required double speed,
      required double spin,
      required Color color,
    }) => Align(
      alignment: alignment,
      child: Transform.translate(
        offset: Offset(
          math.sin(t * speed) * orbit.dx - page * size * 0.12,
          math.cos(t * speed) * orbit.dy,
        ),
        child: Transform.rotate(
          angle: t * spin + page * 0.5,
          child: Transform.scale(
            scale: 1 + 0.05 * math.sin(t * speed * 2),
            child: AppShapeBadge(
              kind: kind,
              size: size,
              color: color,
              child: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    return ColoredBox(
      color: Color.lerp(a.background, b.background, blend)!,
      child: Stack(
        fit: StackFit.expand,
        children: [
          shape(
            kind: AppShapes.badge,
            size: 340,
            alignment: const Alignment(1.6, -1.1),
            orbit: const Offset(18, 14),
            speed: 1,
            spin: 0.25,
            color: foreground.withValues(alpha: 0.07),
          ),
          shape(
            kind: AppShapes.brand,
            size: 260,
            alignment: const Alignment(-1.7, 1.15),
            orbit: const Offset(14, 20),
            speed: 1.3,
            spin: -0.2,
            color: foreground.withValues(alpha: 0.07),
          ),
          shape(
            kind: AppShapes.artist,
            size: 96,
            alignment: const Alignment(0.95, 0.72),
            orbit: const Offset(10, 16),
            speed: 2,
            spin: 0.6,
            color: accent.withValues(alpha: 0.35),
          ),
          shape(
            kind: AppShapes.badge,
            size: 56,
            alignment: const Alignment(-0.85, -0.55),
            orbit: const Offset(12, 8),
            speed: 1.7,
            spin: -0.8,
            color: accent.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }

  Widget _mornye(int from, int to, double blend, double t) {
    Widget artwork(String? uri, double opacity) => uri == null || opacity <= 0
        ? const SizedBox.shrink()
        : Opacity(
            key: ValueKey(uri),
            opacity: opacity,
            child: Transform.scale(
              // A slow Ken Burns drift.
              scale: 1.15 + 0.06 * math.sin(t),
              child: SettledBlur(
                sigma: 48,
                resolution: widget.capturing ? 1 : 0.25,
                child: _artwork[uri] ??= PlayerArtwork(
                  artUri: uri,
                  colorScheme: Theme.of(context).colorScheme,
                  cacheWidth: 200,
                ),
              ),
            ),
          );
    final current = widget.artworks[from];
    final next = widget.artworks[to];
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (current == next)
            artwork(current, 1)
          else ...[
            artwork(current, 1 - blend),
            artwork(next, blend),
          ],
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0.8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
