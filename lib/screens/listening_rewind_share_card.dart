part of 'listening_rewind_screen.dart';

/// The card's layout size. Its image is three times this: the 1080 x 1920
/// story format.
const rewindShareCardSize = Size(360, 640);
const _shareCardPixelRatio = 3.0;
const _shareCardRowHeight = 40.0;

/// A period's listening time, top artists and top songs on one image. Its
/// layout ignores the device, so every phone and computer makes the same card.
class RewindShareCard extends StatelessWidget {
  const RewindShareCard({
    super.key,
    required this.rewind,
    required this.period,
    this.coverColor,
  });

  final ListeningRewind rewind;
  final ListeningRewindPeriod period;

  /// The top song's cover color, which tints the background.
  final Color? coverColor;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toString();
    final number = NumberFormat.decimalPattern(locale);
    final artwork = rewind.summary.artistArtwork;
    final artists = rewind.topArtists.take(5).toList(growable: false);
    final tracks = rewind.summary.tracks.take(5).toList(growable: false);
    final tint = coverColor ?? Theme.of(context).colorScheme.primary;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        devicePixelRatio: _shareCardPixelRatio,
        textScaler: TextScaler.noScaling,
      ),
      child: SizedBox.fromSize(
        size: rewindShareCardSize,
        child: DecoratedBox(
          // Both stops stay dark, so white text reads over any cover.
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(tint, Colors.black, 0.5)!,
                Color.lerp(tint, Colors.black, 0.85)!,
              ],
            ),
          ),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.listeningRewindIntroTitle} · '
                    '${listeningRewindPeriodLabel(context, period)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                  // One line, however long the number and its unit get.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: number.format(rewind.minutes),
                            style: textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          TextSpan(
                            text:
                                ' ${l10n.listeningRewindMinutesUnit(rewind.minutes)}',
                            style: textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                    ),
                  ),
                  if (artists.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ShareCardHeading(l10n.listeningStatsTopArtists),
                    for (final (index, artist) in artists.indexed)
                      _ShareCardRow(
                        rank: index + 1,
                        artwork: _Artwork(
                          uri: artwork[artist.key],
                          size: 32,
                          artist: true,
                        ),
                        title: artist.key,
                        subtitle: l10n.listeningStatsMinutes(
                          (artist.value / 60000).round(),
                        ),
                      ),
                  ],
                  if (tracks.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ShareCardHeading(l10n.listeningStatsTopTracks),
                    for (final (index, total) in tracks.indexed)
                      _ShareCardRow(
                        rank: index + 1,
                        artwork: _Artwork(uri: total.track.artwork, size: 32),
                        title: total.track.title,
                        subtitle: total.track.artist,
                      ),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      Image.asset(
                        'assets/images/logo-transparent.png',
                        width: 22,
                        height: 22,
                        color: Colors.white,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.appName,
                        style: textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareCardHeading extends StatelessWidget {
  const _ShareCardHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),
  );
}

class _ShareCardRow extends StatelessWidget {
  const _ShareCardRow({
    required this.rank,
    required this.artwork,
    required this.title,
    required this.subtitle,
  });

  final int rank;
  final Widget artwork;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final muted = Colors.white.withValues(alpha: 0.75);
    return SizedBox(
      height: _shareCardRowHeight,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$rank',
              style: textTheme.labelLarge?.copyWith(color: muted),
            ),
          ),
          artwork,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Previews the card and shares it. Pops with true to share the visible slide
/// instead, which the story captures itself.
class _RewindShareSheet extends StatefulWidget {
  const _RewindShareSheet({required this.rewind, required this.period});

  final ListeningRewind rewind;
  final ListeningRewindPeriod period;

  @override
  State<_RewindShareSheet> createState() => _RewindShareSheetState();
}

class _RewindShareSheetState extends State<_RewindShareSheet> {
  final _cardKey = GlobalKey();
  final _shareButtonKey = GlobalKey();
  var _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final button = _shareButtonKey.currentContext?.findRenderObject();
    final origin = button is RenderBox && button.hasSize
        ? button.localToGlobal(Offset.zero) & button.size
        : null;
    setState(() => _sharing = true);
    try {
      // A cover color can still be waiting for paint when Share is tapped.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final file = await captureBoundaryToPngFile(
        _cardKey,
        pixelRatio: _shareCardPixelRatio,
        fileName: 'mornye_rewind_card.png',
      );
      if (file == null) throw StateError('Card could not be captured');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: l10n.listeningRewindIntroTitle,
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.listeningRewindShareError)),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final previewHeight = math.min(
      MediaQuery.sizeOf(context).height * 0.6,
      rewindShareCardSize.height,
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: previewHeight,
              width: previewHeight * rewindShareCardSize.aspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: FittedBox(
                  child: CoverSourceColorBuilder(
                    imageSource:
                        widget.rewind.summary.tracks.firstOrNull?.track.artwork,
                    builder: (context, coverColor) => RepaintBoundary(
                      key: _cardKey,
                      child: RewindShareCard(
                        rewind: widget.rewind,
                        period: widget.period,
                        coverColor: coverColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            AppActionButton(
              key: _shareButtonKey,
              onPressed: _sharing ? null : _share,
              icon: const Icon(Icons.share),
              label: Text(l10n.listeningRewindShareCard),
            ),
            const SizedBox(height: 8),
            AppActionButton(
              tonal: true,
              onPressed: _sharing
                  ? null
                  : () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.image_outlined),
              label: Text(l10n.listeningRewindShareSlide),
            ),
          ],
        ),
      ),
    );
  }
}
