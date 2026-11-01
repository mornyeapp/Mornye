part of 'home_tab.dart';

const _homeShelfLimit = 10;
const _homeShelfCoverSize = 120.0;
const _homeMixCoverSize = 152.0;

typedef HomeRecentlyAdded = ({List<UnifiedLibraryItem> items, int trackCount});

/// The newest downloaded and scanned tracks, with the Library's track count
/// for the shortcut at the end of the shelf. A reload that finds the same
/// songs keeps the same list, so Home does not rebuild for it.
final homeRecentlyAddedProvider = FutureProvider.autoDispose<HomeRecentlyAdded>(
  (ref) async {
    final includeLocal = ref.watch(
      settingsProvider.select((s) => s.localLibraryEnabled),
    );
    // Reload when a download lands or a scan rebuilds the index. Downloads
    // in a batch arrive coalesced, at most one revision a second.
    ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
    if (includeLocal) ref.watch(localLibraryIndexRevisionProvider);
    final memo = ref.read(_homeShelfMemoProvider);
    final (rows, counts) = await (
      LibraryDatabase.instance.getQueueTrackPage(
        QueueLibraryDbQuery(includeLocal: includeLocal, limit: _homeShelfLimit),
      ),
      // The Library tab's badges count the same Library; one count serves
      // both.
      ref.watch(
        libraryCountsProvider(
          LibraryCountsRequest.all(localLibraryEnabled: includeLocal),
        ).future,
      ),
    ).wait;
    final last = memo.recentlyAdded;
    if (last != null && _sameQueueRows(last.rows, rows)) {
      return (items: last.items, trackCount: counts.allTrackCount);
    }
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
    memo.recentlyAdded = (rows: rows, items: items);
    return (items: items, trackCount: counts.allTrackCount);
  },
);

bool _sameQueueRows(
  List<Map<String, dynamic>> first,
  List<Map<String, dynamic>> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final (a, b) = (first[index], second[index]);
    if (a['source'] != b['source'] ||
        !mapEquals(a['item'] as Map?, b['item'] as Map?)) {
      return false;
    }
  }
  return true;
}

typedef HomeRepeatTrack = ({ListeningTrack track, UnifiedLibraryItem? item});

/// Candidates read from the statistics at a time; most shelves fill from
/// the first page.
const _homeRepeatPage = 40;

/// The most played files of the last four weeks, matched to their current
/// Library entry. Statistics keep the artwork seen at play time, which may
/// since have been evicted from a cache or rescanned away.
final homeOnRepeatProvider = FutureProvider.autoDispose<List<HomeRepeatTrack>>((
  ref,
) async {
  // A track that ends may have just earned a play. One that starts after
  // none, such as a restored session's, follows no play.
  ref.listen(currentMediaItemProvider.select((s) => s.value?.id), (
    previous,
    _,
  ) {
    if (previous != null) ref.invalidateSelf();
  });
  // A deleted download or a rescan can remove a track from the shelf.
  final historyVersion = ref.watch(
    downloadHistoryProvider.select((s) => s.loadedIndexVersion),
  );
  final localRevision = ref.watch(localLibraryIndexRevisionProvider);
  final includeLocal = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  final history = ref.read(downloadHistoryProvider.notifier);
  final memo = ref.read(_homeShelfMemoProvider);
  // Library matches hold until the Library changes, so a new track only
  // reads the statistics again.
  final library = (historyVersion, localRevision, includeLocal);
  if (memo.repeatLibrary != library) {
    // A new map, so a load still running for the old Library keeps its own.
    memo
      ..repeatLibrary = library
      ..repeatMatches = {};
  }
  final matches = memo.repeatMatches;
  await listeningRecorder.flush();
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day - 27);
  final end = DateTime(now.year, now.month, now.day + 1);
  final tracks = <HomeRepeatTrack>[];
  for (var offset = 0; ; offset += _homeRepeatPage) {
    // Played files and network songs only: remote sources cannot be
    // replayed from their recorded key.
    final totals = await ListeningStatisticsStore.instance.loadReplayableTracks(
      start,
      end,
      limit: _homeRepeatPage,
      offset: offset,
    );
    // Matched in rounds of the songs still missing, so no more songs are
    // looked up than one at a time would.
    var next = 0;
    while (tracks.length < _homeShelfLimit && next < totals.length) {
      final round = totals
          .skip(next)
          .take(_homeShelfLimit - tracks.length)
          .toList();
      next += round.length;
      tracks.addAll(
        await _homeRepeatTracks(
          round,
          history: history,
          includeLocal: includeLocal,
          matches: matches,
        ),
      );
    }
    if (tracks.length == _homeShelfLimit || totals.length < _homeRepeatPage) {
      break;
    }
  }
  final last = memo.onRepeat;
  if (last != null && _sameRepeatTracks(last, tracks)) return last;
  return memo.onRepeat = tracks;
});

/// A played key's Library entry: a download or a scanned file, or none.
/// [hidden] is a scanned file while Local Library is off.
typedef _HomeRepeatMatch = ({UnifiedLibraryItem? item, bool hidden});

/// [totals] that can still play, in order, matched to their Library entry
/// as a download first, then as a scanned file. All lookups of a round run
/// together; [matches] keeps them while the Library stays the same.
Future<List<HomeRepeatTrack>> _homeRepeatTracks(
  List<ListeningTotal> totals, {
  required DownloadHistoryNotifier history,
  required bool includeLocal,
  required Map<String, _HomeRepeatMatch> matches,
}) async {
  final missing = [
    for (final total in totals)
      if (!matches.containsKey(total.track.key)) total.track.key,
  ];
  if (missing.isNotEmpty) {
    final database = LibraryDatabase.instance;
    final downloads = await Future.wait([
      for (final key in missing) history.getByFilePathAsync(key),
    ]);
    final scannedKeys = [
      for (final (index, key) in missing.indexed)
        if (downloads[index] == null) key,
    ];
    final scannedIds = await Future.wait([
      for (final key in scannedKeys) database.getPhysicalFileIds([key]),
    ]);
    // With Local Library off its songs stay off Home as well.
    final rows = includeLocal
        ? {
            for (final row in await database.getByIds([
              for (final ids in scannedIds)
                if (ids.isNotEmpty) ids.first,
            ]))
              row['id']: row,
          }
        : const <Object?, Map<String, dynamic>>{};
    for (final (index, key) in missing.indexed) {
      if (downloads[index] case final downloaded?) {
        matches[key] = (
          item: UnifiedLibraryItem.fromDownloadHistory(downloaded),
          hidden: false,
        );
      }
    }
    for (final (index, key) in scannedKeys.indexed) {
      final ids = scannedIds[index];
      final row = ids.isEmpty ? null : rows[ids.first];
      matches[key] = (
        item: row == null
            ? null
            : UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem.fromJson(row),
              ),
        hidden: ids.isNotEmpty && !includeLocal,
      );
    }
  }
  // Files played from outside the Library stay while they still exist,
  // checked each time since they can go at any moment.
  final outside = [
    for (final total in totals)
      if (matches[total.track.key] case (item: null, hidden: false))
        total.track.key,
  ];
  final present = await Future.wait(outside.map(fileExists));
  final exists = {
    for (final (index, key) in outside.indexed) key: present[index],
  };
  return [
    for (final total in totals)
      if (matches[total.track.key]! case (
        :final item,
        :final hidden,
      ) when !hidden && (item != null || exists[total.track.key]!))
        (track: total.track, item: item),
  ];
}

bool _sameRepeatTracks(
  List<HomeRepeatTrack> first,
  List<HomeRepeatTrack> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final (a, b) = (first[index], second[index]);
    if (a.track.key != b.track.key ||
        a.track.title != b.track.title ||
        a.track.artist != b.track.artist ||
        a.track.album != b.track.album ||
        a.track.artwork != b.track.artwork ||
        !_sameLibraryItem(a.item, b.item)) {
      return false;
    }
  }
  return true;
}

bool _sameLibraryItem(UnifiedLibraryItem? first, UnifiedLibraryItem? second) =>
    identical(first, second) ||
    first != null &&
        second != null &&
        mapEquals(first.historyItem?.toJson(), second.historyItem?.toJson()) &&
        mapEquals(first.localItem?.toJson(), second.localItem?.toJson());

/// What the Home shelves read last, kept for the app's lifetime, so a reload
/// that finds the same songs returns the same value.
class _HomeShelfMemo {
  ({List<Map<String, dynamic>> rows, List<UnifiedLibraryItem> items})?
  recentlyAdded;
  (int, int, bool)? repeatLibrary;
  Map<String, _HomeRepeatMatch> repeatMatches = {};
  List<HomeRepeatTrack>? onRepeat;
}

final _homeShelfMemoProvider = Provider<_HomeShelfMemo>(
  (ref) => _HomeShelfMemo(),
);

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
    final showPlayer = ref.watch(playerUiEnabledProvider);
    final hasMediaItem =
        showPlayer &&
        ref.watch(currentMediaItemProvider.select((s) => s.value != null));
    // Only values: a reload's loading state shows the previous one.
    final hasResume =
        showPlayer &&
        ref.watch(playbackResumeProvider.select((s) => s.value != null));
    final recentlyAdded = ref.watch(
      homeRecentlyAddedProvider.select((s) => s.value),
    );
    final onRepeat =
        ref.watch(homeOnRepeatProvider.select((s) => s.value)) ?? const [];
    final mixes =
        ref.watch(libraryMixesProvider.select((s) => s.value)) ?? const [];

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
                    // A network cover not stored yet shows once fetched.
                    artUri:
                        mediaItem.artUri?.toString() ??
                        mediaItem.extras?['artworkRef']?.toString(),
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
    // Repaints on every position tick without repainting the sections.
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 4,
          color: colorScheme.primary,
          backgroundColor: colorScheme.onPrimaryContainer.withValues(
            alpha: 0.16,
          ),
        ),
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

  final List<HomeRepeatTrack> tracks;
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
