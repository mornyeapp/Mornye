part of 'home_tab.dart';

const _homeShelfLimit = 10;
const _homeShelfCoverSize = 120.0;
const _homeMixCoverSize = 152.0;

/// The newest downloaded and scanned tracks, with the Library's track count
/// for the shortcut at the end of the shelf.
final _homeRecentlyAddedProvider =
    FutureProvider.autoDispose<
      ({List<UnifiedLibraryItem> items, int trackCount})
    >((ref) async {
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      // Reload when a download lands or a scan rebuilds the index.
      ref.watch(downloadHistoryProvider.select((s) => s.items.length));
      ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      final database = LibraryDatabase.instance;
      final rows = await database.getQueueTrackPage(
        QueueLibraryDbQuery(includeLocal: includeLocal, limit: _homeShelfLimit),
      );
      final counts = await database.getQueueCounts(
        QueueLibraryDbQuery(includeLocal: includeLocal),
      );
      final items = <UnifiedLibraryItem>[];
      for (final row in rows) {
        final json = Map<String, dynamic>.from(row['item'] as Map);
        switch (row['source']) {
          case 'local':
            items.add(
              UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem.fromJson(json),
              ),
            );
          case 'downloaded':
            items.add(
              UnifiedLibraryItem.fromDownloadHistory(
                DownloadHistoryItem.fromJson(json),
              ),
            );
        }
      }
      return (items: items, trackCount: counts.allTrackCount);
    });

typedef _HomeRepeatTrack = ({ListeningTrack track, UnifiedLibraryItem? item});

/// The most played files of the last four weeks, matched to their current
/// Library entry. Statistics keep the artwork seen at play time, which may
/// since have been evicted from a cache or rescanned away.
final _homeOnRepeatProvider =
    FutureProvider.autoDispose<List<_HomeRepeatTrack>>((ref) async {
      // A new track means the previous one may have just earned a play.
      ref.watch(currentMediaItemProvider.select((s) => s.value?.id));
      // A deleted download or a rescan can remove a track from the shelf.
      ref.watch(downloadHistoryProvider.select((s) => s.items.length));
      ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      await listeningRecorder.flush();
      final now = DateTime.now();
      final summary = await ListeningStatisticsStore.instance.load(
        DateTime(now.year, now.month, now.day - 27),
        DateTime(now.year, now.month, now.day + 1),
      );
      final history = ref.read(downloadHistoryProvider.notifier);
      final database = LibraryDatabase.instance;
      final tracks = <_HomeRepeatTrack>[];
      for (final total in summary.tracks) {
        if (tracks.length == _homeShelfLimit) break;
        final key = total.track.key;
        // Remote sources cannot be replayed from their recorded key.
        if (total.plays <= 0 ||
            key.startsWith('http://') ||
            key.startsWith('https://')) {
          continue;
        }
        final downloaded = await history.getByFilePathAsync(key);
        if (downloaded != null) {
          tracks.add((
            track: total.track,
            item: UnifiedLibraryItem.fromDownloadHistory(downloaded),
          ));
          continue;
        }
        final ids = await database.getPhysicalFileIds([key]);
        // With Local Library off its songs stay off Home as well.
        if (ids.isNotEmpty && !includeLocal) continue;
        final row = ids.isEmpty ? null : await database.getById(ids.first);
        if (row != null) {
          tracks.add((
            track: total.track,
            item: UnifiedLibraryItem.fromLocalLibrary(
              LocalLibraryItem.fromJson(row),
            ),
          ));
          continue;
        }
        // Files played from outside the Library stay while they still exist.
        if (await fileExists(key)) tracks.add((track: total.track, item: null));
      }
      return tracks;
    });

/// The prompt under the Home greeting, picked again on each launch.
class _HomeTagline extends StatelessWidget {
  const _HomeTagline();

  @override
  Widget build(BuildContext context) => Text(
    homeTagline(context.l10n),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// Everything under the search bar on the Material Home. Sections without
/// content leave no gap behind.
class _HomeSections extends ConsumerWidget {
  const _HomeSections({required this.inset});

  /// Horizontal page margin, wider on tablets.
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final hasMediaItem = ref.watch(
      currentMediaItemProvider.select((s) => s.value != null),
    );
    final hasResume = ref.watch(playbackResumeProvider).value != null;
    final recentlyAdded = ref.watch(_homeRecentlyAddedProvider).value;
    final onRepeat = ref.watch(_homeOnRepeatProvider).value ?? const [];
    final mixes = ref.watch(libraryMixesProvider).value ?? const [];

    final sections = <Widget>[
      if (hasMediaItem || hasResume)
        _HomeSection(
          title: l10n.homeContinueListening,
          inset: inset,
          child: const _HomeContinueListeningCard(),
        ),
      _HomeSection(
        title: l10n.homeShortcuts,
        inset: inset,
        child: const _HomeShortcuts(),
      ),
      // Built after startup settles when nothing is cached: the sections'
      // size animation opens its space rather than letting it jump in.
      if (mixes.isNotEmpty)
        _HomeSection(
          title: l10n.homeMixesForYou,
          inset: inset,
          shelf: true,
          child: _HomeMixesShelf(mixes: mixes, inset: inset),
        ),
      if (recentlyAdded != null && recentlyAdded.items.isNotEmpty)
        _HomeSection(
          title: l10n.homeRecentlyAdded,
          inset: inset,
          shelf: true,
          child: _HomeRecentlyAddedShelf(
            items: recentlyAdded.items,
            trackCount: recentlyAdded.trackCount,
            inset: inset,
          ),
        ),
      if (onRepeat.isNotEmpty)
        _HomeSection(
          title: l10n.homeOnRepeat,
          inset: inset,
          shelf: true,
          child: _HomeOnRepeatShelf(tracks: onRepeat, inset: inset),
        ),
    ];

    return Padding(
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
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.inset,
    required this.child,
    this.shelf = false,
  });

  final String title;
  final double inset;
  final Widget child;

  /// Shelves scroll edge to edge and pad their own items.
  final bool shelf;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(inset + 8, 0, inset + 8, 12),
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (shelf)
          child
        else
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: child,
          ),
      ],
    );
  }
}

/// The active track or the last dismissed session, with its saved progress.
class _HomeContinueListeningCard extends ConsumerStatefulWidget {
  const _HomeContinueListeningCard();

  @override
  ConsumerState<_HomeContinueListeningCard> createState() =>
      _HomeContinueListeningCardState();
}

class _HomeContinueListeningCardState
    extends ConsumerState<_HomeContinueListeningCard> {
  static const _coverSize = 96.0;
  bool _resuming = false;

  void _openPlayer() {
    if (isDesktopPlatform) {
      openDesktopNowPlaying();
    } else {
      Navigator.of(
        context,
        rootNavigator: true,
      ).push(NowPlayingRoute(child: const NowPlayingScreen()));
    }
  }

  Future<void> _resume({bool openPlayer = false}) async {
    if (_resuming) return;
    setState(() => _resuming = true);
    try {
      final resumed = await ref
          .read(musicPlayerControllerProvider)
          .resumeSavedSession();
      if (!mounted) return;
      ref.invalidate(playbackResumeProvider);
      if (resumed && openPlayer) _openPlayer();
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(currentMediaItemProvider).value;
    final resume = ref.watch(playbackResumeProvider).value;
    final mediaItem = current ?? resume?.media.toMediaItem();
    if (mediaItem == null) return const SizedBox.shrink();

    final isPlaying = current != null && ref.watch(playbackPlayingProvider);
    final isLoading =
        _resuming || (current != null && ref.watch(playbackLoadingProvider));
    final controller = ref.read(musicPlayerControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final artist = mediaItem.artist ?? '';

    return Material(
      color: colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isLoading
            ? null
            : current == null
            ? () => _resume(openPlayer: true)
            : _openPlayer,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 16, 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox.square(
                  dimension: _coverSize,
                  child: PlayerArtwork(
                    artUri: mediaItem.artUri?.toString(),
                    colorScheme: colorScheme,
                    cacheWidth:
                        (_coverSize * MediaQuery.devicePixelRatioOf(context))
                            .round(),
                    iconSize: 32,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mediaItem.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleLarge?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    if (artist.isNotEmpty)
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onPrimaryContainer.withValues(
                            alpha: 0.8,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    _HomeContinueListeningProgress(
                      duration: mediaItem.duration ?? Duration.zero,
                      savedPosition: current == null ? resume?.position : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: isPlaying
                    ? context.l10n.actionPause
                    : context.l10n.tooltipPlay,
                child: Semantics(
                  button: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: isLoading
                          ? null
                          : current == null
                          ? _resume
                          : () => controller.togglePlayPause(isPlaying),
                      // Round like the mini player's play button, so the
                      // same action keeps the same shape across screens.
                      child: Ink(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: isLoading
                              ? AppLoadingIndicator(
                                  size: 24,
                                  color: colorScheme.onPrimary,
                                )
                              : Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  size: 28,
                                  color: colorScheme.onPrimary,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Follows position ticks on its own so the card above does not rebuild on
/// every one.
class _HomeContinueListeningProgress extends ConsumerWidget {
  const _HomeContinueListeningProgress({
    required this.duration,
    this.savedPosition,
  });

  final Duration duration;
  final Duration? savedPosition;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final durationMs = duration.inMilliseconds;
    final Duration position =
        savedPosition ?? ref.watch(playbackPositionProvider);
    final positionMs = position.inMilliseconds;
    final progress = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress,
        minHeight: 4,
        color: colorScheme.primary,
        backgroundColor: colorScheme.onPrimaryContainer.withValues(alpha: 0.16),
      ),
    );
  }
}

/// A horizontal row of cover tiles that scrolls past the page margin.
class _HomeShelf extends StatelessWidget {
  const _HomeShelf({
    required this.inset,
    required this.itemCount,
    required this.itemBuilder,
    this.coverSize = _homeShelfCoverSize,
  });

  final double inset;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double coverSize;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(
      height: coverSize + 52 * textScale,
      child: DesktopScrollArrows(
        builder: (context, controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: inset),
          itemCount: itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: itemBuilder,
        ),
      ),
    );
  }
}

class _HomeShelfTile extends StatelessWidget {
  const _HomeShelfTile({
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.semanticLabel,
    required this.onTap,
    this.size = _homeShelfCoverSize,
  });

  final Widget cover;
  final String title;
  final String subtitle;
  final String semanticLabel;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox.square(dimension: size, child: cover),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeRecentlyAddedShelf extends ConsumerWidget {
  const _HomeRecentlyAddedShelf({
    required this.items,
    required this.trackCount,
    required this.inset,
  });

  final List<UnifiedLibraryItem> items;
  final int trackCount;
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final cacheWidth =
        (_homeShelfCoverSize * MediaQuery.devicePixelRatioOf(context)).round();
    return _HomeShelf(
      inset: inset,
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == items.length) {
          return _HomeLibraryTile(trackCount: trackCount);
        }
        final item = items[index];
        return _HomeShelfTile(
          title: item.trackName,
          subtitle: item.artistName,
          semanticLabel: context.l10n.a11yOpenTrackByArtist(
            item.trackName,
            item.artistName,
          ),
          cover: _homeLibraryCover(item, colorScheme, cacheWidth),
          onTap: () => _play(ref, index),
        );
      },
    );
  }

  void _play(WidgetRef ref, int index) {
    final media = <PlayableMedia>[];
    var initialIndex = 0;
    for (final (i, item) in items.indexed) {
      final playable = _homePlayableFromLibrary(item);
      if (playable == null || playable.source.trim().isEmpty) continue;
      if (i == index) initialIndex = media.length;
      media.add(playable);
    }
    if (media.isEmpty) return;
    ref
        .read(musicPlayerControllerProvider)
        .playAll(media, initialIndex: initialIndex);
  }
}

/// A Library track's own artwork: a download's embedded cover with its
/// online cover as fallback, or a scanned file's extracted thumbnail.
Widget _homeLibraryCover(
  UnifiedLibraryItem item,
  ColorScheme colorScheme,
  int cacheWidth,
) {
  final history = item.historyItem;
  if (history != null) {
    return _DownloadedOrRemoteCover(
      downloadedFilePath: history.filePath,
      imageUrl: history.coverUrl,
      width: _homeShelfCoverSize,
      height: _homeShelfCoverSize,
      borderRadius: BorderRadius.zero,
      fallbackIcon: Icons.music_note,
      fallbackIconSize: 32,
      colorScheme: colorScheme,
    );
  }
  return PlayerArtwork(
    artUri: item.localCoverPath,
    colorScheme: colorScheme,
    cacheWidth: cacheWidth,
    iconSize: 32,
  );
}

PlayableMedia? _homePlayableFromLibrary(UnifiedLibraryItem item) =>
    switch (item) {
      UnifiedLibraryItem(:final historyItem?) => playableFromHistory(
        historyItem,
      ),
      UnifiedLibraryItem(:final localItem?) => playableFromLocal(localItem),
      _ => null,
    };

/// Ends the Recently added shelf with a way into the whole Library.
class _HomeLibraryTile extends StatelessWidget {
  const _HomeLibraryTile({required this.trackCount});

  final int trackCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox.square(
        dimension: _homeShelfCoverSize,
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => ShellNavigationService.requestTab(ShellTab.library),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _HomeIconBadge(
                    icon: Icons.library_music,
                    color: colorScheme.secondaryContainer,
                    onColor: colorScheme.onSecondaryContainer,
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.navLibrary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelLarge?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        context.l10n.tracksCount(trackCount),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
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

class _HomeOnRepeatShelf extends ConsumerWidget {
  const _HomeOnRepeatShelf({required this.tracks, required this.inset});

  final List<_HomeRepeatTrack> tracks;
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final cacheWidth =
        (_homeShelfCoverSize * MediaQuery.devicePixelRatioOf(context)).round();
    return _HomeShelf(
      inset: inset,
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final (:track, :item) = tracks[index];
        return _HomeShelfTile(
          title: track.title,
          subtitle: track.artist,
          semanticLabel: context.l10n.a11yOpenTrackByArtist(
            track.title,
            track.artist,
          ),
          cover: item != null
              ? _homeLibraryCover(item, colorScheme, cacheWidth)
              : PlayerArtwork(
                  artUri: track.artwork,
                  colorScheme: colorScheme,
                  cacheWidth: cacheWidth,
                  iconSize: 32,
                ),
          onTap: () => ref.read(musicPlayerControllerProvider).playAll([
            for (final (:track, :item) in tracks)
              (item == null ? null : _homePlayableFromLibrary(item)) ??
                  PlayableMedia(
                    id: track.key,
                    source: track.key,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    artUri: track.artwork,
                  ),
          ], initialIndex: index),
        );
      },
    );
  }
}

/// The day's mixes of the Library's own songs, larger than the other
/// shelves' covers so the four-album collages stay legible.
class _HomeMixesShelf extends StatelessWidget {
  const _HomeMixesShelf({required this.mixes, required this.inset});

  final List<LibraryMixView> mixes;
  final double inset;

  @override
  Widget build(BuildContext context) {
    return _HomeShelf(
      inset: inset,
      coverSize: _homeMixCoverSize,
      itemCount: mixes.length,
      itemBuilder: (context, index) {
        final view = mixes[index];
        final title = libraryMixTitle(context.l10n, view.mix);
        final subtitle = libraryMixSubtitle(context.l10n, view.mix);
        return _HomeShelfTile(
          size: _homeMixCoverSize,
          title: title,
          subtitle: subtitle,
          semanticLabel: subtitle.isEmpty ? title : '$title, $subtitle',
          cover: LibraryMixCover(items: view.items, size: _homeMixCoverSize),
          onTap: () =>
              pushPage<void>(context, (_) => LibraryMixScreen(view: view)),
        );
      },
    );
  }
}

/// Quick ways into player tools that otherwise sit a few screens deep.
class _HomeShortcuts extends ConsumerWidget {
  const _HomeShortcuts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    void open(Widget screen) => pushPage<void>(context, (_) => screen);

    // Shuffle is the one emphasized action; the other tools share a neutral
    // tile so color marks importance rather than varying per tile.
    final tiles = [
      _HomeShortcutTile(
        label: l10n.nowPlayingShuffleLibrary,
        icon: Icons.shuffle,
        container: colorScheme.primaryContainer,
        onContainer: colorScheme.onPrimaryContainer,
        badge: colorScheme.primary,
        onBadge: colorScheme.onPrimary,
        onTap: () => _shuffle(context, ref),
      ),
      _HomeShortcutTile(
        label: l10n.equalizerTitle,
        icon: Icons.graphic_eq,
        container: colorScheme.surfaceContainerHigh,
        onContainer: colorScheme.onSurface,
        badge: colorScheme.secondaryContainer,
        onBadge: colorScheme.onSecondaryContainer,
        onTap: () => open(const EqualizerScreen()),
      ),
      _HomeShortcutTile(
        label: l10n.listeningStats,
        icon: Icons.insights,
        container: colorScheme.surfaceContainerHigh,
        onContainer: colorScheme.onSurface,
        badge: colorScheme.secondaryContainer,
        onBadge: colorScheme.onSecondaryContainer,
        onTap: () => open(const ListeningStatisticsScreen()),
      ),
      _HomeShortcutTile(
        label: l10n.networkStorage,
        icon: Icons.lan_outlined,
        container: colorScheme.surfaceContainerHigh,
        onContainer: colorScheme.onSurface,
        badge: colorScheme.secondaryContainer,
        onBadge: colorScheme.onSecondaryContainer,
        onTap: () => open(const NetworkStorageScreen()),
      ),
    ];

    return Column(
      children: [
        for (var row = 0; row < tiles.length; row += 2) ...[
          if (row > 0) const SizedBox(height: 8),
          // A label that wraps keeps its neighbor the same height.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tiles[row]),
                const SizedBox(width: 8),
                Expanded(child: tiles[row + 1]),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _shuffle(BuildContext context, WidgetRef ref) async {
    final shuffled = await ref
        .read(musicPlayerControllerProvider)
        .shuffleLibrary();
    if (shuffled || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.nowPlayingLibraryEmpty)),
    );
  }
}

class _HomeShortcutTile extends StatelessWidget {
  const _HomeShortcutTile({
    required this.label,
    required this.icon,
    required this.container,
    required this.onContainer,
    required this.badge,
    required this.onBadge,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color container;
  final Color onContainer;
  final Color badge;
  final Color onBadge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: container,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HomeIconBadge(icon: icon, color: badge, onColor: onBadge),
              const SizedBox(height: 16),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: onContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular icon container shared by the Home tiles. Interactive tiles keep
/// one plain shape; abstract shapes stay on artwork and decorative moments.
class _HomeIconBadge extends StatelessWidget {
  const _HomeIconBadge({
    required this.icon,
    required this.color,
    required this.onColor,
  });

  final IconData icon;
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: SizedBox.square(
      dimension: 40,
      child: Icon(icon, size: 20, color: onColor),
    ),
  );
}
