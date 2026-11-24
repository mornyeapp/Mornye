part of 'home_tab.dart';

/// A page a Home section title opens: its shelves one under another, at
/// Home's margins.
class _HomeShelfPage extends StatelessWidget {
  const _HomeShelfPage({required this.title, required this.sections});

  final String title;
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        AppSliverHeader.page(title: title),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, section) in sections.indexed) ...[
                  if (index > 0) const SizedBox(height: 28),
                  section,
                ],
              ],
            ),
          ),
        ),
        const NavBarSliverSpacer(),
      ],
    ),
  );
}

/// Top Picks for You kind by kind: the day's mixes, the Library's albums,
/// new albums by favorite artists and the feed's picks, a shelf each.
class _HomeTopPicksPage extends ConsumerWidget {
  const _HomeTopPicksPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inset = 16 + homeContentInset(context);
    // As on Home: mixes need the built-in player, releases a network.
    final mixes = ref.watch(playerUiEnabledProvider)
        ? ref.watch(libraryMixesProvider.select((s) => s.value)) ??
              const <LibraryMixView>[]
        : const <LibraryMixView>[];
    final albums =
        ref.watch(homeLibraryAlbumsProvider.select((s) => s.value)) ??
        const <LibraryBrowseEntry>[];
    final offline = ref.watch(
      homeOfflineProvider.select((s) => s.value ?? false),
    );
    final releases = offline
        ? const <WeeklyRelease>[]
        : ref.watch(homeNewReleasesProvider.select((s) => s.value)) ??
              const <WeeklyRelease>[];
    final feed = _homeFeedPicks(
      ref.watch(homeTopPicksProvider.select((s) => s.value)) ??
          const <ExploreItem>[],
      releases,
    );
    final source = ref.watch(homeTopPicksExtensionProvider) ?? '';
    final sourceName = ref.watch(
      extensionProvider.select(
        (s) => s.extensions
            .where((extension) => extension.id == source)
            .firstOrNull
            ?.displayName,
      ),
    );
    // A slow device keeps its frames for scrolling.
    final drift = !ref.watch(lowEndDeviceProvider);
    Widget shelf(
      String title,
      List<_TopPick> picks, {
      VoidCallback? onShowAll,
    }) => _HomeSection(
      title: title,
      inset: inset,
      shelf: true,
      onShowAll: onShowAll,
      child: _HomeTopPicksShelf(picks: picks, inset: inset + 8, drift: drift),
    );

    return _HomeShelfPage(
      title: l10n.homeTopPicks,
      sections: [
        if (mixes.isNotEmpty)
          shelf(l10n.homeMadeForYou, [
            for (final view in mixes) _MixPick(view),
          ]),
        if (albums.isNotEmpty)
          shelf(l10n.homeFromYourLibrary, [
            for (final album in albums) _LibraryAlbumPick(album),
          ]),
        if (releases.isNotEmpty)
          shelf(
            l10n.weeklyReleases,
            [for (final release in releases) _ReleasePick(release)],
            onShowAll: () => pushPage<void>(
              context,
              (_) => const WeeklyReleasesScreen(days: homeReleaseDays),
            ),
          ),
        if (feed.isNotEmpty)
          shelf(
            sourceName == null || sourceName.trim().isEmpty
                ? l10n.homeFromSource(source)
                : l10n.homeFromSource(sourceName),
            feed,
          ),
      ],
    );
  }
}

/// Recommended for you: the day's songs, then songs like the Library's own
/// in each of its main genres. A song shows on one shelf only.
class _HomeRecommendedPage extends ConsumerWidget {
  const _HomeRecommendedPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inset = 16 + homeContentInset(context);
    final shelfInset = context.isMornye ? inset + 8 : inset;
    final daily =
        ref.watch(homeRecommendationsProvider.select((s) => s.value)) ??
        const <Track>[];
    // The genre mixes name the genres the Library holds most; like the
    // mixes, they need the built-in player.
    final genres = [
      if (ref.watch(playerUiEnabledProvider))
        for (final view
            in ref.watch(libraryMixesProvider.select((s) => s.value)) ??
                const <LibraryMixView>[])
          if (view.mix.kind == LibraryMixKind.genre) view.mix,
    ];
    final loads = {
      for (final mix in genres)
        mix.key: ref.watch(homeGenreRecommendationsProvider(mix.key)),
    };
    final shelves = {
      for (final (key, tracks) in homeRecommendationShelvesApart([
        for (final mix in genres)
          if (loads[mix.key]?.value case final tracks?) (mix.key, tracks),
      ], shown: daily))
        key: tracks,
    };

    return _HomeShelfPage(
      title: l10n.homeRecommendedForYou,
      sections: [
        if (daily.isNotEmpty)
          _HomeSection(
            title: l10n.homeRecommendedFromLibrary,
            inset: inset,
            shelf: true,
            child: _HomeRecommendationsShelf(tracks: daily, inset: shelfInset),
          ),
        for (final mix in genres)
          if (shelves[mix.key] case final tracks?)
            _HomeSection(
              title: mix.label,
              inset: inset,
              shelf: true,
              child: _HomeRecommendationsShelf(
                tracks: tracks,
                inset: shelfInset,
                learns: false,
              ),
            )
          else if (loads[mix.key]?.isLoading ?? false)
            _HomeSection(
              title: mix.label,
              inset: inset,
              shelf: true,
              child: _HomeShelfSkeleton(inset: shelfInset),
            ),
      ],
    );
  }
}

/// A shelf of songs still loading, in the shape of its tiles.
class _HomeShelfSkeleton extends StatelessWidget {
  const _HomeShelfSkeleton({required this.inset});

  final double inset;

  @override
  Widget build(BuildContext context) {
    final radius = _homeShelfRadiusOf(context);
    return ExcludeSemantics(
      child: ShimmerLoading(
        child: _HomeShelfSize(
          inset: inset,
          builder: (context, coverSize) => _HomeShelf(
            inset: inset,
            coverSize: coverSize,
            itemCount: 6,
            itemBuilder: (context, _) => SizedBox(
              width: coverSize,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(
                    width: coverSize,
                    height: coverSize,
                    borderRadius: radius,
                  ),
                  const SizedBox(height: 12),
                  SkeletonBox(
                    width: coverSize * 0.7,
                    height: 12,
                    borderRadius: 4,
                  ),
                  const SizedBox(height: 8),
                  SkeletonBox(
                    width: coverSize * 0.45,
                    height: 10,
                    borderRadius: 4,
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
