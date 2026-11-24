part of 'home_tab.dart';

const _homeShelfLimit = 10;
const _homeShelfCoverSize = 120.0;
const _homeMixCoverSize = 152.0;
const _homeDesktopShelfCoverSize = 168.0;
const _homeDesktopMixCoverSize = 192.0;
const _homeMornyeShelfGap = 16.0;

/// The pane width from which the Material desktop Home sets Continue
/// listening and Shortcuts side by side.
const _homeDesktopColumnsMinWidth = 720.0;

/// Whether Home lays out for a pointer and a wide pane rather than a phone:
/// the Material desktop app. The Mornye style keeps its own Home.
bool _homeDesktop(BuildContext context) =>
    isDesktopPlatform && !context.isMornye;

double _homeShelfCoverSizeOf(BuildContext context) =>
    _homeDesktop(context) ? _homeDesktopShelfCoverSize : _homeShelfCoverSize;

double _homeMixCoverSizeOf(BuildContext context) =>
    _homeDesktop(context) ? _homeDesktopMixCoverSize : _homeMixCoverSize;

double _homeShelfRadiusOf(BuildContext context) => context.isMornye ? 10 : 20;

bool _homeCompactText(BuildContext context) =>
    context.isMornye && isDesktopPlatform;

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
    final items = _homeLibraryItemsOf(rows);
    memo.recentlyAdded = (rows: rows, items: items);
    return (items: items, trackCount: counts.allTrackCount);
  },
);

/// The Library songs a page of queue rows holds, downloads and scanned
/// files alike.
List<UnifiedLibraryItem> _homeLibraryItemsOf(List<Map<String, dynamic>> rows) {
  final items = <UnifiedLibraryItem>[];
  for (final row in rows) {
    final json = Map<String, dynamic>.from(row['item'] as Map);
    switch (row['source']) {
      case 'local':
        items.add(
          UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(json)),
        );
      case 'downloaded':
        items.add(
          UnifiedLibraryItem.fromDownloadHistory(
            DownloadHistoryItem.fromJson(json),
          ),
        );
    }
  }
  return items;
}

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
  final memo = ref.read(_homeShelfMemoProvider);
  final tracks = await _homeReplayableTracks(ref, limit: _homeShelfLimit);
  final last = memo.onRepeat;
  if (last != null && _sameRepeatTracks(last, tracks)) return last;
  return memo.onRepeat = tracks;
});

/// One song per recently played album, ordered by the latest listening day.
final homeRecentlyPlayedProvider =
    FutureProvider.autoDispose<List<HomeRepeatTrack>>((ref) async {
      final memo = ref.read(_homeShelfMemoProvider);
      final played = await _homeReplayableTracks(
        ref,
        limit: _homeShelfLimit * 3,
        latestFirst: true,
      );
      final albums = <String>{};
      final tracks = [
        for (final entry in played)
          if (albums.add(
            entry.track.album.isEmpty
                ? entry.track.key
                : '${entry.track.artist}/${entry.track.album}',
          ))
            entry,
      ].take(_homeShelfLimit).toList();
      final last = memo.recentlyPlayed;
      if (last != null && _sameRepeatTracks(last, tracks)) return last;
      return memo.recentlyPlayed = tracks;
    });

/// Albums read for the day's picks; a larger Library moves the window daily.
const _homeAlbumPool = 300;

/// Where the day's window starts among [albumCount] albums.
@visibleForTesting
int homeLibraryAlbumPoolOffset(int albumCount, String day) =>
    albumCount <= _homeAlbumPool
    ? 0
    : stableTextHash(day) % (albumCount - _homeAlbumPool + 1);

/// The day's albums from [pool]. Each album has its own place in the day's
/// order, so a Library change swaps a cover instead of the whole shelf.
@visibleForTesting
List<LibraryBrowseEntry> homeLibraryAlbumPicks(
  List<LibraryBrowseEntry> pool, {
  required String day,
  int limit = _homeShelfLimit,
}) {
  final order = {
    for (final album in pool)
      if (album.name.trim().isNotEmpty)
        album: stableTextHash('$day|${album.source}|${album.key}'),
  };
  final albums = order.keys.toList()
    ..sort((a, b) {
      final byOrder = order[a]!.compareTo(order[b]!);
      return byOrder != 0 ? byOrder : a.key.compareTo(b.key);
    });
  return albums.take(limit).toList();
}

/// Albums of the Library, picked anew each day. Home shows them in On
/// repeat's place while listening is not recorded.
final homeLibraryAlbumsProvider =
    FutureProvider.autoDispose<List<LibraryBrowseEntry>>((ref) async {
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      if (includeLocal) ref.watch(localLibraryIndexRevisionProvider);
      final memo = ref.read(_homeShelfMemoProvider);
      final counts = await ref.watch(
        libraryCountsProvider(
          LibraryCountsRequest.all(localLibraryEnabled: includeLocal),
        ).future,
      );
      final day = listeningDay(DateTime.now());
      final page = await LibraryDatabase.instance.getQueueAlbumPageResult(
        QueueLibraryDbQuery(
          includeLocal: includeLocal,
          sortMode: 'a-z',
          limit: _homeAlbumPool,
          offset: homeLibraryAlbumPoolOffset(counts.albumCount, day),
        ),
      );
      final albums = homeLibraryAlbumPicks([
        for (final row in page.rows)
          LibraryBrowseEntry.fromRow(row, isArtist: false),
      ], day: day);
      final last = memo.libraryAlbums;
      if (last != null && _sameAlbums(last, albums)) return last;
      return memo.libraryAlbums = albums;
    });

bool _sameAlbums(List<LibraryBrowseEntry> a, List<LibraryBrowseEntry> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    final one = a[index], other = b[index];
    if (one.source != other.source ||
        one.key != other.key ||
        one.name != other.name ||
        one.artist != other.artist ||
        one.cover != other.cover ||
        one.samplePath != other.samplePath) {
      return false;
    }
  }
  return true;
}

/// Up to [limit] played songs of the last four weeks that can be played
/// again, matched to the Library. Reloads with what changes them; without
/// [followPlays] a song that ends is not one of those.
Future<List<HomeRepeatTrack>> _homeReplayableTracks(
  Ref ref, {
  required int limit,
  bool latestFirst = false,
  bool followPlays = true,
}) async {
  // Turning the record off hides what it already holds, without clearing it.
  if (!ref.watch(
    settingsProvider.select((s) => s.listeningStatisticsEnabled),
  )) {
    return const [];
  }
  // A track that ends may have just earned a play. One that starts after
  // none, such as a restored session's, follows no play.
  if (followPlays) {
    ref.listen(currentMediaItemProvider.select((s) => s.value?.id), (
      previous,
      _,
    ) {
      if (previous != null) ref.invalidateSelf();
    });
  }
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
      latestFirst: latestFirst,
    );
    // Matched in rounds of the songs still missing, so no more songs are
    // looked up than one at a time would.
    var next = 0;
    while (tracks.length < limit && next < totals.length) {
      final round = totals.skip(next).take(limit - tracks.length).toList();
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
    if (tracks.length == limit || totals.length < _homeRepeatPage) break;
  }
  return tracks;
}

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
  List<HomeRepeatTrack>? recentlyPlayed;
  List<LibraryBrowseEntry>? libraryAlbums;
  List<UnifiedLibraryItem>? quickSongs;
}

final _homeShelfMemoProvider = Provider<_HomeShelfMemo>(
  (ref) => _HomeShelfMemo(),
);

/// Everything under the Home header. Sections without content leave no gap
/// behind.
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
    final mornye = context.isMornye;
    // Without a listening record the day's albums take On repeat's place.
    // Mornye's Top Picks offer the first of them either way.
    final recordsListening =
        showPlayer &&
        ref.watch(settingsProvider.select((s) => s.listeningStatisticsEnabled));
    final layout = ref.watch(settingsProvider.select((s) => s.homeLayout));
    // Read only while shown: the day's picks are a query of their own.
    final quickSongs = showPlayer && layout.shows(HomeSection.quickPlay)
        ? ref.watch(homeQuickSongsProvider.select((s) => s.value)) ??
              const <UnifiedLibraryItem>[]
        : const <UnifiedLibraryItem>[];
    // Shelves that need the internet step aside without a network.
    final offline = ref.watch(
      homeOfflineProvider.select((s) => s.value ?? false),
    );

    final showContinue =
        (hasMediaItem || hasResume) &&
        ref.watch(settingsProvider.select((s) => s.homeContinueListening));

    // On Material phones and tablets the pins sit among the Shortcuts, so
    // the section stays while either is left.
    final hasShortcuts =
        !mornye && _HomeShortcuts.hasContent(ref, pins: !_homeDesktop(context));
    // The desktop top holds Continue listening and Shortcuts, so it stands
    // where the person put the first of the two.
    final order = layout.sections;
    final desktopTop =
        showContinue &&
            order.indexOf(HomeSection.continueListening) <
                order.indexOf(HomeSection.shortcuts)
        ? HomeSection.continueListening
        : HomeSection.shortcuts;

    // A shelf's value, noted among [loads] as read.
    T? shelf<T>(
      Set<ProviderListenable<AsyncValue<Object?>>> loads,
      ProviderListenable<AsyncValue<T>> provider,
    ) {
      loads.add(provider);
      return ref.watch(provider.select((s) => s.value));
    }

    bool answered(ProviderListenable<AsyncValue<Object?>> provider) =>
        ref.watch(provider.select((s) => s.hasValue || s.hasError));

    // What each section has to show now, before the person's order and
    // their hidden sections apply. Only the sections [reads] names load
    // their shelves, which go into [loads].
    Map<HomeSection, Widget> shelves(
      bool Function(HomeSection section) reads,
      Set<ProviderListenable<AsyncValue<Object?>>> loads,
    ) {
      final recentlyAdded = reads(HomeSection.recentlyAdded)
          ? shelf(loads, homeRecentlyAddedProvider)
          : null;
      // What was heard and the mixes built from it belong to the built-in
      // player; with another app playing, Home keeps to the Library.
      final onRepeat = showPlayer && reads(HomeSection.onRepeat)
          ? shelf(loads, homeOnRepeatProvider) ?? const <HomeRepeatTrack>[]
          : const <HomeRepeatTrack>[];
      final dayAlbums =
          mornye && reads(HomeSection.topPicks) ||
              !recordsListening && reads(HomeSection.onRepeat)
          ? shelf(loads, homeLibraryAlbumsProvider) ??
                const <LibraryBrowseEntry>[]
          : const <LibraryBrowseEntry>[];
      // Hidden Top Picks leave their albums to From your Library.
      final pickedAlbums = mornye && layout.shows(HomeSection.topPicks)
          ? dayAlbums.take(_homeTopPickLibraryAlbums).toList()
          : const <LibraryBrowseEntry>[];
      final libraryAlbums = recordsListening
          ? const <LibraryBrowseEntry>[]
          : dayAlbums.skip(pickedAlbums.length).toList();
      final mixes = showPlayer && !mornye && reads(HomeSection.mixes)
          ? shelf(loads, libraryMixesProvider)
          : null;
      final newReleases =
          reads(HomeSection.newReleases) ||
              mornye && reads(HomeSection.topPicks)
          ? shelf(loads, homeNewReleasesProvider) ?? const <WeeklyRelease>[]
          : const <WeeklyRelease>[];
      final recommended = reads(HomeSection.recommended)
          ? shelf(loads, homeRecommendationsProvider) ?? const <Track>[]
          : const <Track>[];

      // Shown or not, played albums keep the Continue listening card away.
      final readsRecentlyPlayed =
          mornye &&
          showPlayer &&
          (reads(HomeSection.recentlyPlayed) || showContinue);
      final recentlyPlayed = readsRecentlyPlayed
          ? shelf(loads, homeRecentlyPlayedProvider) ??
                const <HomeRepeatTrack>[]
          : const <HomeRepeatTrack>[];
      // The card only stands in once nothing was played: while the shelf
      // loads, it would show and then give way to Recently Played.
      final recentlyPlayedLoading =
          readsRecentlyPlayed && !answered(homeRecentlyPlayedProvider);
      final pickedReleases = mornye && !offline
          ? newReleases.take(_homeTopPickReleases).toList()
          : const <WeeklyRelease>[];
      final readsTopPicks = mornye && reads(HomeSection.topPicks);
      if (readsTopPicks) {
        loads.addAll([
          homeTopPicksProvider,
          if (showPlayer) libraryMixesProvider,
        ]);
      }
      final hasTopPicks =
          readsTopPicks &&
          (pickedAlbums.isNotEmpty ||
              pickedReleases.isNotEmpty ||
              _HomeTopPicksSection.hasPicks(ref, mixes: showPlayer));
      final readsUnfinished = reads(HomeSection.unfinished);
      if (readsUnfinished) {
        loads.addAll([
          homeIncompleteAlbumCountProvider,
          homeRecognizedMissingProvider,
        ]);
      }
      return <HomeSection, Widget>{
        if (_HomeDownloadsSection.hasContent(ref))
          HomeSection.downloads: _HomeDownloadsSection(inset: inset),
        if (hasTopPicks)
          HomeSection.topPicks: _HomeTopPicksSection(
            inset: inset,
            mixes: showPlayer,
            libraryAlbums: pickedAlbums,
            releases: pickedReleases,
          ),
        // The desktop top holds both; without Shortcuts the card stands alone.
        if (_homeDesktop(context) &&
            hasShortcuts &&
            layout.shows(HomeSection.shortcuts))
          desktopTop: _HomeDesktopTop(inset: inset, showContinue: showContinue)
        else ...{
          if (recentlyPlayed.isNotEmpty)
            HomeSection.recentlyPlayed: _HomeSection(
              title: l10n.homeRecentlyPlayed,
              inset: inset,
              shelf: true,
              onShowAll: () => pushPage<void>(
                context,
                (_) => const ListeningStatisticsScreen(),
              ),
              child: _HomeRecentlyPlayedShelf(
                tracks: recentlyPlayed,
                inset: inset + 8,
              ),
            )
          else if (showContinue && !recentlyPlayedLoading)
            HomeSection.continueListening: _HomeSection(
              title: l10n.homeContinueListening,
              inset: inset,
              child: const _HomeContinueListeningCard(),
            ),
          // Mornye exposes these tools in the player and Settings.
          if (hasShortcuts)
            HomeSection.shortcuts: _HomeSection(
              title: l10n.homeShortcuts,
              inset: inset,
              child: const _HomeShortcuts(),
            ),
        },
        if (quickSongs.isNotEmpty)
          HomeSection.quickPlay: _HomeSection(
            title: l10n.homeQuickPlay,
            inset: inset,
            shelf: true,
            child: _HomeQuickPlay(
              songs: quickSongs,
              inset: mornye ? inset + 8 : inset,
            ),
          ),
        // On Material phones and tablets the pins sit among the Shortcuts.
        if ((mornye || _homeDesktop(context)) &&
            _HomePinsSection.hasContent(ref))
          HomeSection.pins: _HomePinsSection(inset: inset),
        if (_HomeLinkSection.hasContent(ref))
          HomeSection.link: _HomeLinkSection(inset: inset),
        if (_HomeHiResSection.hasContent(ref))
          HomeSection.hiRes: _HomeHiResSection(inset: inset),
        // Built after startup settles when nothing is cached: the sections'
        // size animation opens its space rather than letting it jump in.
        if (!mornye && mixes != null && mixes.isNotEmpty)
          HomeSection.mixes: _HomeSection(
            title: l10n.homeMixesForYou,
            inset: inset,
            shelf: true,
            child: _HomeMixesShelf(mixes: mixes, inset: inset),
          ),
        if (recentlyAdded != null && recentlyAdded.items.isNotEmpty)
          HomeSection.recentlyAdded: _HomeSection(
            title: l10n.homeRecentlyAdded,
            inset: inset,
            shelf: true,
            child: _HomeRecentlyAddedShelf(
              items: recentlyAdded.items,
              trackCount: recentlyAdded.trackCount,
              inset: mornye ? inset + 8 : inset,
            ),
          ),
        if (readsUnfinished && _HomeUnfinishedSection.hasContent(ref))
          HomeSection.unfinished: _HomeUnfinishedSection(inset: inset),
        if (recommended.isNotEmpty && !offline)
          HomeSection.recommended: _HomeSection(
            title: l10n.homeRecommendedForYou,
            inset: inset,
            shelf: true,
            onShowAll: () =>
                pushPage<void>(context, (_) => const _HomeRecommendedPage()),
            child: _HomeRecommendationsShelf(
              tracks: recommended,
              inset: mornye ? inset + 8 : inset,
            ),
          ),
        if (newReleases.isNotEmpty && !offline)
          HomeSection.newReleases: _HomeSection(
            title: l10n.weeklyReleases,
            inset: inset,
            shelf: true,
            onShowAll: () => pushPage<void>(
              context,
              (_) => const WeeklyReleasesScreen(days: homeReleaseDays),
            ),
            child: _HomeNewReleasesShelf(
              releases: newReleases,
              inset: mornye ? inset + 8 : inset,
            ),
          ),
        if (onRepeat.isNotEmpty)
          HomeSection.onRepeat: _HomeSection(
            title: l10n.homeOnRepeat,
            inset: inset,
            shelf: true,
            child: _HomeOnRepeatShelf(
              tracks: onRepeat,
              inset: mornye ? inset + 8 : inset,
            ),
          )
        else if (libraryAlbums.isNotEmpty)
          HomeSection.onRepeat: _HomeSection(
            title: l10n.homeFromYourLibrary,
            inset: inset,
            shelf: true,
            child: _HomeLibraryAlbumsShelf(
              albums: libraryAlbums,
              inset: mornye ? inset + 8 : inset,
            ),
          ),
      };
    }

    final shownLoads = <ProviderListenable<AsyncValue<Object?>>>{};
    var built = shelves(layout.shows, shownLoads);
    // An empty Library with nothing played leaves Home without shelves (the
    // Material Home keeps its Shortcuts): say so, and lead to Search, once
    // the Library shelves have answered. Hidden sections do not count: a
    // Home the person emptied is not a Library with nothing in it.
    var bare =
        !showContinue && built.keys.every(_homeStandingSections.contains);
    var settled = false;
    if (bare && answered(homeRecentlyAddedProvider)) {
      // Hidden shelves load only now, to tell those two apart.
      final loads = <ProviderListenable<AsyncValue<Object?>>>{};
      built = shelves((_) => true, loads);
      bare = built.keys.every(_homeStandingSections.contains);
      // A shelf that only now loads answers first, or the message flashes.
      settled =
          bare &&
          loads.difference(shownLoads).every(answered) &&
          !(mornye && showPlayer && !answered(homeRecentlyPlayedProvider));
    }
    final sections = [
      for (final section in order)
        if (layout.shows(section)) ?built[section],
    ];

    Widget? nothingYet;
    if (settled) {
      nothingYet = ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height * (mornye ? 0.5 : 0.3),
        ),
        child: EmptyState(
          icon: Icons.music_note,
          title: l10n.homeNothingYetTitle,
          message: l10n.homeNothingYetMessage,
          action: ExpressiveButton(
            onPressed: () => ShellNavigationService.requestTab(ShellTab.search),
            icon: const Icon(Icons.search),
            child: Text(l10n.homeFindMusic),
          ),
        ),
      );
      if (mornye && sections.isEmpty) return nothingYet;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, section) in sections.indexed) ...[
            if (index > 0) const SizedBox(height: 28),
            section,
          ],
          ?nothingYet,
          // Nothing to arrange while Home has nothing: Find music leads.
          if (!bare) ...[const SizedBox(height: 28), const _HomeEditButton()],
        ],
      ),
    );
  }
}

/// Sections that show without any music: with only these, Home still says
/// there is nothing yet.
const _homeStandingSections = {
  HomeSection.downloads,
  HomeSection.shortcuts,
  HomeSection.link,
};

/// The way from the end of Home to the page that arranges it.
class _HomeEditButton extends StatelessWidget {
  const _HomeEditButton();

  @override
  Widget build(BuildContext context) => Center(
    child: ExpressiveButton(
      text: true,
      onPressed: () => pushPage<void>(context, (_) => const HomeLayoutPage()),
      icon: const Icon(Icons.tune),
      child: Text(context.l10n.homeEdit),
    ),
  );
}

/// Continue listening and Shortcuts on the Material desktop Home: side by
/// side at one height once the pane is wide enough, the shortcuts as a list
/// beside the player and as one row without it.
class _HomeDesktopTop extends StatelessWidget {
  const _HomeDesktopTop({required this.inset, required this.showContinue});

  final double inset;
  final bool showContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!showContinue) {
      return _HomeSection(
        title: l10n.homeShortcuts,
        inset: inset,
        child: const _HomeShortcuts(layout: _HomeShortcutsLayout.row),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth - 2 * inset < _homeDesktopColumnsMinWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HomeSection(
                title: l10n.homeContinueListening,
                inset: inset,
                child: const _HomeContinueListeningCard(),
              ),
              const SizedBox(height: 28),
              _HomeSection(
                title: l10n.homeShortcuts,
                inset: inset,
                child: const _HomeShortcuts(layout: _HomeShortcutsLayout.row),
              ),
            ],
          );
        }
        // Four shortcut rows of at least 56dp each set the shared height.
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final height = math.max(240.0, 4 * 56 * textScale + 3 * 4);
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _HomeSection(
                  title: l10n.homeContinueListening,
                  inset: 0,
                  child: SizedBox(
                    height: height,
                    child: const _HomeContinueListeningCard(hero: true),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 2,
                child: _HomeSection(
                  title: l10n.homeShortcuts,
                  inset: 0,
                  child: SizedBox(
                    height: height,
                    child: const _HomeShortcuts(
                      layout: _HomeShortcutsLayout.list,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.inset,
    required this.child,
    this.shelf = false,
    this.onShowAll,
  });

  final String title;
  final double inset;
  final Widget child;

  /// Shelves scroll edge to edge and pad their own items.
  final bool shelf;

  /// Makes the title a navigation action, marked with a chevron.
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final heading = Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: colorScheme.onSurface,
        fontSize: _homeCompactText(context) ? 15 : null,
        fontWeight: FontWeight.w600,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(inset + 8, 0, inset + 8, 12),
          child: Semantics(
            header: true,
            child: onShowAll == null
                ? heading
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onShowAll,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: heading),
                            const SizedBox(width: 4),
                            AppIcon.adaptive(
                              Icons.chevron_right,
                              size: 15,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
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
  const _HomeContinueListeningCard({this.hero = false});

  /// The desktop card beside Shortcuts: the cover fills its height, the
  /// title sits above, and the progress and play button run along the
  /// bottom.
  final bool hero;

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
    final album = mediaItem.album ?? '';
    final hero = widget.hero;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // Mornye uses a neutral surface for the resume card.
    final neutral = context.isMornye;
    final onContainer = neutral
        ? colorScheme.onSurface
        : colorScheme.onPrimaryContainer;
    final dimmed = neutral
        ? colorScheme.onSurfaceVariant
        : colorScheme.onPrimaryContainer.withValues(alpha: 0.8);
    final playColor = colorScheme.primary;
    final onPlayColor = colorScheme.onPrimary;

    Widget artwork(double extent) => PlayerArtwork(
      // A network cover not stored yet shows once fetched.
      artUri:
          mediaItem.artUri?.toString() ??
          mediaItem.extras?['artworkRef']?.toString(),
      colorScheme: colorScheme,
      cacheWidth: (extent * devicePixelRatio).round(),
      iconSize: 32,
    );

    final title = Text(
      mediaItem.title,
      maxLines: hero ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: (hero ? textTheme.headlineSmall : textTheme.titleLarge)?.copyWith(
        color: onContainer,
      ),
    );
    final artistLine = Text(
      artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (hero ? textTheme.titleMedium : textTheme.bodyMedium)?.copyWith(
        color: dimmed,
      ),
    );
    final progress = _HomeContinueListeningProgress(
      duration: mediaItem.duration ?? Duration.zero,
      savedPosition: current == null ? resume?.position : null,
    );
    final playButton = Tooltip(
      message: isPlaying ? context.l10n.actionPause : context.l10n.tooltipPlay,
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
            // Round like the mini player's play button, so the same action
            // keeps the same shape across screens.
            child: Ink(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: playColor,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isLoading
                    ? AppLoadingIndicator(size: 24, color: onPlayColor)
                    : Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 28,
                        color: onPlayColor,
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    final Widget content;
    if (hero) {
      content = Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      artwork(constraints.maxHeight),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 8, 4, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      artistLine,
                    ],
                    if (album.isNotEmpty && album != mediaItem.title)
                      Text(
                        album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(color: dimmed),
                      ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(child: progress),
                        const SizedBox(width: 16),
                        playButton,
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      content = Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 16, 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: SizedBox.square(
                dimension: _coverSize,
                child: artwork(_coverSize),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  if (artist.isNotEmpty) artistLine,
                  const SizedBox(height: 12),
                  progress,
                ],
              ),
            ),
            const SizedBox(width: 12),
            playButton,
          ],
        ),
      );
    }

    return Material(
      color: neutral
          ? colorScheme.surfaceContainerHigh
          : colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isLoading
            ? null
            : current == null
            ? () => _resume(openPlayer: true)
            : _openPlayer,
        child: content,
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
    final neutral = context.isMornye;
    final durationMs = duration.inMilliseconds;
    final visible = TickerMode.valuesOf(context).enabled;
    final Duration position =
        savedPosition ??
        (visible
            ? ref.watch(playbackPositionProvider)
            : ref.read(playbackPositionProvider));
    final positionMs = position.inMilliseconds;
    final progress = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    // Repaints on every position tick without repainting the sections.
    return RepaintBoundary(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: AppProgressIndicator.linear(
            value: progress,
            minHeight: 4,
            wavy: false,
            color: neutral ? colorScheme.onSurface : colorScheme.primary,
            trackColor:
                (neutral
                        ? colorScheme.onSurface
                        : colorScheme.onPrimaryContainer)
                    .withValues(alpha: 0.16),
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
    this.coverSize,
  });

  final double inset;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Null for the platform's shelf cover size.
  final double? coverSize;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final coverSize = this.coverSize ?? _homeShelfCoverSizeOf(context);
    return SizedBox(
      height: coverSize + 52 * textScale,
      child: DesktopScrollArrows(
        builder: (context, controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: inset),
          itemCount: itemCount,
          separatorBuilder: (_, _) =>
              SizedBox(width: context.isMornye ? _homeMornyeShelfGap : 12),
          itemBuilder: itemBuilder,
        ),
      ),
    );
  }
}

/// Hands [builder] the shelf cover size, fitting about six covers across a
/// Mornye desktop pane.
class _HomeShelfSize extends StatelessWidget {
  const _HomeShelfSize({required this.inset, required this.builder});

  final double inset;
  final Widget Function(BuildContext context, double coverSize) builder;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      return builder(context, _homeShelfCoverSizeOf(context));
    }
    if (!isDesktopPlatform) return builder(context, 160);
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = constraints.maxWidth - 2 * inset;
        final perPane = (content + _homeMornyeShelfGap) / 6.1;
        return builder(
          context,
          (perPane - _homeMornyeShelfGap).clamp(130.0, 280.0),
        );
      },
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
    this.onLongPress,
    this.coverAction,
    this.size,
  });

  final Widget cover;
  final String title;
  final String subtitle;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// A button in the cover's bottom start corner, its own target beside
  /// the tile's.
  final Widget? coverAction;

  /// Null for the platform's shelf cover size.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final size = this.size ?? _homeShelfCoverSizeOf(context);
    final radius = _homeShelfRadiusOf(context);
    final compactText = _homeCompactText(context);
    final tile = Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: SizedBox.square(dimension: size, child: cover),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontSize: compactText ? 13 : null,
                  fontWeight: compactText ? FontWeight.w400 : null,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: compactText ? 13 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final coverAction = this.coverAction;
    if (coverAction == null) return tile;
    return Stack(
      children: [
        tile,
        PositionedDirectional(
          start: 0,
          top: 0,
          width: size,
          height: size,
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: coverAction,
            ),
          ),
        ),
      ],
    );
  }
}

/// Songs outside the Library like the person's own.
class _HomeRecommendationsShelf extends StatelessWidget {
  const _HomeRecommendationsShelf({
    required this.tracks,
    required this.inset,
    this.learns = true,
  });

  final List<Track> tracks;
  final double inset;

  /// Whether learning logs the songs: only the day's shelf, in Home's order.
  final bool learns;

  @override
  Widget build(BuildContext context) => _HomeShelfSize(
    inset: inset,
    builder: (context, coverSize) => _HomeShelf(
      inset: inset,
      coverSize: coverSize,
      itemCount: tracks.length,
      itemBuilder: (context, index) => _HomeRecommendationTile(
        track: tracks[index],
        rank: learns ? index : null,
        size: coverSize,
      ),
    ),
  );
}

/// A recommended song. A tap downloads it and a long press opens its
/// actions, as on search results; the button on the cover plays its preview.
/// Learning logs that it showed at [rank] and what the listener did with it;
/// without a rank, nothing.
class _HomeRecommendationTile extends ConsumerStatefulWidget {
  const _HomeRecommendationTile({
    required this.track,
    required this.rank,
    required this.size,
  });

  final Track track;
  final int? rank;
  final double size;

  @override
  ConsumerState<_HomeRecommendationTile> createState() =>
      _HomeRecommendationTileState();
}

class _HomeRecommendationTileState
    extends ConsumerState<_HomeRecommendationTile> {
  SuggestionOutcomes get _outcomes =>
      ref.read(musicPlayerRuntimeProvider).suggestionOutcomes;

  @override
  void initState() {
    super.initState();
    _shown();
  }

  @override
  void didUpdateWidget(_HomeRecommendationTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track != widget.track || oldWidget.rank != widget.rank) {
      _shown();
    }
  }

  void _shown() {
    final rank = widget.rank;
    if (rank == null) return;
    _outcomes.recommendationShown(
      artist: widget.track.artistName,
      title: widget.track.name,
      rank: rank,
    );
  }

  void _acted(SuggestionAction action) {
    if (widget.rank == null) return;
    _outcomes.recommendationActed(
      artist: widget.track.artistName,
      title: widget.track.name,
      action: action,
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track, size = widget.size;
    void showOptions({Offset? position}) =>
        TrackCollectionQuickActions.showTrackOptionsSheet(
          context,
          ref,
          track,
          position: position,
          onAction: _acted,
        );
    return DesktopContextMenuRegion(
      onContextMenu: (position) => showOptions(position: position),
      child: _HomeShelfTile(
        size: size,
        title: track.name,
        subtitle: track.artistName,
        semanticLabel:
            '${context.l10n.dialogDownload}: '
            '${track.name}, ${track.artistName}',
        cover: PlayerArtwork(
          artUri: track.coverUrl,
          colorScheme: Theme.of(context).colorScheme,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          iconSize: 32,
        ),
        coverAction: PreviewButton(
          track: track,
          size: 28,
          dense: isDesktopPlatform,
          overArtwork: true,
          onPreview: () => _acted(SuggestionAction.previewed),
        ),
        onTap: () {
          _acted(SuggestionAction.downloaded);
          downloadSingleTrack(context, ref, track);
        },
        onLongPress: showOptions,
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
    return _HomeShelfSize(
      inset: inset,
      builder: (context, coverSize) {
        final rawCacheWidth =
            (coverSize * MediaQuery.devicePixelRatioOf(context)).round();
        final cacheWidth = ((rawCacheWidth + 63) ~/ 64) * 64;
        return _HomeShelf(
          inset: inset,
          coverSize: coverSize,
          itemCount: items.length + 1,
          itemBuilder: (context, index) {
            if (index == items.length) {
              return _HomeLibraryTile(trackCount: trackCount, size: coverSize);
            }
            final item = items[index];
            return _HomeShelfTile(
              size: coverSize,
              title: item.trackName,
              subtitle: item.artistName,
              semanticLabel: context.l10n.a11yOpenTrackByArtist(
                item.trackName,
                item.artistName,
              ),
              cover: _homeLibraryCover(
                item,
                colorScheme,
                coverSize,
                cacheWidth,
              ),
              onTap: () => _homePlayLibraryItems(context, ref, items, index),
            );
          },
        );
      },
    );
  }
}

/// Plays [items] from the one at [index], or with an external player opens
/// that song's file in the other app.
Future<void> _homePlayLibraryItems(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
  int index,
) async {
  final media = <PlayableMedia>[];
  final paths = <String>[];
  var initialIndex = 0;
  for (final (i, item) in items.indexed) {
    final playable = _homePlayableFromLibrary(item);
    if (playable == null || playable.source.trim().isEmpty) continue;
    if (i == index) initialIndex = media.length;
    media.add(playable);
    paths.add(item.filePath);
  }
  if (media.isEmpty) return;
  try {
    await ref
        .read(playbackProvider.notifier)
        .playMediaQueue(
          media,
          startIndex: initialIndex,
          externalPath: paths[initialIndex],
        );
  } catch (e) {
    if (context.mounted) showCannotOpenFileSnackBar(context, e);
  }
}

/// The favorite artists' latest albums and singles, newest first.
class _HomeNewReleasesShelf extends StatelessWidget {
  const _HomeNewReleasesShelf({required this.releases, required this.inset});

  final List<WeeklyRelease> releases;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _HomeShelfSize(
      inset: inset,
      builder: (context, coverSize) {
        final rawCacheWidth =
            (coverSize * MediaQuery.devicePixelRatioOf(context)).round();
        final cacheWidth = ((rawCacheWidth + 63) ~/ 64) * 64;
        return _HomeShelf(
          inset: inset,
          coverSize: coverSize,
          itemCount: releases.length,
          itemBuilder: (context, index) {
            final release = releases[index];
            return _HomeShelfTile(
              size: coverSize,
              title: release.name,
              subtitle: release.artist,
              semanticLabel: context.l10n.a11yOpenAlbum(release.name),
              cover: PlayerArtwork(
                artUri: release.coverUrl,
                colorScheme: colorScheme,
                cacheWidth: cacheWidth,
                iconSize: 32,
              ),
              onTap: () => navigateToAlbum(
                context,
                albumName: release.name,
                albumId: release.id,
                artistName: release.artist,
                coverUrl: release.coverUrl,
                extensionId: release.providerId,
              ),
            );
          },
        );
      },
    );
  }
}

/// A Library track's own artwork: a download's embedded cover with its
/// online cover as fallback, or a scanned file's extracted thumbnail.
Widget _homeLibraryCover(
  UnifiedLibraryItem item,
  ColorScheme colorScheme,
  double size,
  int cacheWidth,
) {
  final history = item.historyItem;
  if (history != null) {
    return _DownloadedOrRemoteCover(
      downloadedFilePath: history.filePath,
      imageUrl: history.coverUrl,
      width: size,
      height: size,
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
  const _HomeLibraryTile({required this.trackCount, required this.size});

  final int trackCount;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_homeShelfRadiusOf(context)),
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
    return _HomeShelfSize(
      inset: inset,
      builder: (context, coverSize) {
        final rawCacheWidth =
            (coverSize * MediaQuery.devicePixelRatioOf(context)).round();
        final cacheWidth = ((rawCacheWidth + 63) ~/ 64) * 64;
        return _HomeShelf(
          inset: inset,
          coverSize: coverSize,
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final (:track, :item) = tracks[index];
            return _HomeShelfTile(
              size: coverSize,
              title: track.title,
              subtitle: track.artist,
              semanticLabel: context.l10n.a11yOpenTrackByArtist(
                track.title,
                track.artist,
              ),
              cover: item != null
                  ? _homeLibraryCover(item, colorScheme, coverSize, cacheWidth)
                  : PlayerArtwork(
                      artUri: track.artwork,
                      colorScheme: colorScheme,
                      cacheWidth: cacheWidth,
                      iconSize: 32,
                    ),
              onTap: () => _homePlayRepeatTracks(ref, tracks, index),
            );
          },
        );
      },
    );
  }
}

/// Recently played tracks displayed as large covers named by album.
/// Choosing one plays from that song.
class _HomeRecentlyPlayedShelf extends ConsumerWidget {
  const _HomeRecentlyPlayedShelf({required this.tracks, required this.inset});

  final List<HomeRepeatTrack> tracks;
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    return _HomeShelfSize(
      inset: inset,
      builder: (context, coverSize) {
        final rawCacheWidth =
            (coverSize * MediaQuery.devicePixelRatioOf(context)).round();
        final cacheWidth = ((rawCacheWidth + 63) ~/ 64) * 64;
        return _HomeShelf(
          inset: inset,
          coverSize: coverSize,
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final (:track, :item) = tracks[index];
            final title = track.album.isEmpty ? track.title : track.album;
            return _HomeShelfTile(
              size: coverSize,
              title: title,
              subtitle: track.artist,
              semanticLabel: context.l10n.a11yOpenTrackByArtist(
                title,
                track.artist,
              ),
              cover: item != null
                  ? _homeLibraryCover(item, colorScheme, coverSize, cacheWidth)
                  : PlayerArtwork(
                      artUri: track.artwork,
                      colorScheme: colorScheme,
                      cacheWidth: cacheWidth,
                      iconSize: 32,
                    ),
              onTap: () => _homePlayRepeatTracks(ref, tracks, index),
            );
          },
        );
      },
    );
  }
}

/// Library albums as covers named by album. Choosing one opens the album.
class _HomeLibraryAlbumsShelf extends StatelessWidget {
  const _HomeLibraryAlbumsShelf({required this.albums, required this.inset});

  final List<LibraryBrowseEntry> albums;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _HomeShelfSize(
      inset: inset,
      builder: (context, coverSize) {
        final rawCacheWidth =
            (coverSize * MediaQuery.devicePixelRatioOf(context)).round();
        final cacheWidth = ((rawCacheWidth + 63) ~/ 64) * 64;
        return _HomeShelf(
          inset: inset,
          coverSize: coverSize,
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final album = albums[index];
            return _HomeShelfTile(
              size: coverSize,
              title: album.name,
              subtitle: album.artist,
              semanticLabel: context.l10n.a11yOpenAlbum(album.name),
              cover: album.source == 'local'
                  ? LocalLibraryArtworkBuilder(
                      coverPath: album.cover,
                      filePath: album.samplePath,
                      builder: (context, cover) => PlayerArtwork(
                        artUri: cover,
                        colorScheme: colorScheme,
                        cacheWidth: cacheWidth,
                        iconSize: 32,
                      ),
                    )
                  : _DownloadedOrRemoteCover(
                      downloadedFilePath: album.samplePath,
                      imageUrl: album.cover,
                      width: coverSize,
                      height: coverSize,
                      borderRadius: BorderRadius.zero,
                      fallbackIcon: Icons.album_outlined,
                      fallbackIconSize: 32,
                      colorScheme: colorScheme,
                    ),
              onTap: () => _openHomeLibraryAlbum(context, album),
            );
          },
        );
      },
    );
  }
}

void _openHomeLibraryAlbum(BuildContext context, LibraryBrowseEntry album) {
  pushPage<void>(
    context,
    (_) => album.source == 'local'
        ? LocalAlbumScreen(
            albumName: album.name,
            artistName: album.artist,
            coverPath: album.cover,
            loadTracks: () async => [
              for (final row
                  in await LibraryDatabase.instance
                      .getQueueLocalAlbumTracksByKey(album.key))
                LocalLibraryItem.fromJson(row),
            ],
          )
        : DownloadedAlbumScreen(
            albumName: album.name,
            artistName: album.artist,
            coverUrl: album.cover,
          ),
  );
}

/// A Library album's cover for a card that draws it itself: a scanned
/// album's stored picture, or a download's embedded cover with its online
/// cover as fallback.
class _LibraryAlbumArt extends StatelessWidget {
  const _LibraryAlbumArt({required this.album, required this.builder});

  final LibraryBrowseEntry album;
  final Widget Function(BuildContext context, String? artUri) builder;

  @override
  Widget build(BuildContext context) => album.source == 'local'
      ? LocalLibraryArtworkBuilder(
          coverPath: album.cover,
          filePath: album.samplePath,
          builder: builder,
        )
      : _DownloadedCoverSource(
          downloadedFilePath: album.samplePath,
          remoteUrl: album.cover,
          builder: (context, embedded) =>
              builder(context, embedded ?? album.cover),
        );
}

void _homePlayRepeatTracks(
  WidgetRef ref,
  List<HomeRepeatTrack> tracks,
  int index,
) => ref.read(musicPlayerControllerProvider).playAll([
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
], initialIndex: index);

/// The day's mixes of the Library's own songs, larger than the other
/// shelves' covers so the four-album collages stay legible.
class _HomeMixesShelf extends StatelessWidget {
  const _HomeMixesShelf({required this.mixes, required this.inset});

  final List<LibraryMixView> mixes;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final coverSize = _homeMixCoverSizeOf(context);
    return _HomeShelf(
      inset: inset,
      coverSize: coverSize,
      itemCount: mixes.length,
      itemBuilder: (context, index) {
        final view = mixes[index];
        final title = libraryMixTitle(context.l10n, view.mix);
        final subtitle = libraryMixSubtitle(context.l10n, view.mix);
        return _HomeShelfTile(
          size: coverSize,
          title: title,
          subtitle: subtitle,
          semanticLabel: subtitle.isEmpty ? title : '$title, $subtitle',
          cover: LibraryMixCover(items: view.items, size: coverSize),
          onTap: () =>
              pushPage<void>(context, (_) => LibraryMixScreen(view: view)),
        );
      },
    );
  }
}

/// The most Library albums and new releases Mornye's Top Picks offer.
const _homeTopPickLibraryAlbums = 3;
const _homeTopPickReleases = 2;

/// The items of [lists] by turns, one of each list a round, until all are
/// taken. A shelf built so shows every kind of card early.
@visibleForTesting
List<T> homeTakeByTurns<T>(List<List<T>> lists) {
  final longest = lists.fold(
    0,
    (length, list) => math.max(length, list.length),
  );
  return [
    for (var index = 0; index < longest; index++)
      for (final list in lists)
        if (index < list.length) list[index],
  ];
}

/// One card of Top Picks.
sealed class _TopPick {
  const _TopPick();
}

final class _MixPick extends _TopPick {
  const _MixPick(this.view);

  final LibraryMixView view;
}

final class _PlaylistPick extends _TopPick {
  const _PlaylistPick(this.item);

  final ExploreItem item;
}

/// An album of the Library, offered again.
final class _LibraryAlbumPick extends _TopPick {
  const _LibraryAlbumPick(this.album);

  final LibraryBrowseEntry album;
}

/// A new album by a favorite artist.
final class _ReleasePick extends _TopPick {
  const _ReleasePick(this.release);

  final WeeklyRelease release;
}

/// An album of the extension's feed.
final class _FeedAlbumPick extends _TopPick {
  const _FeedAlbumPick(this.item);

  final ExploreItem item;
}

/// The feed's albums and playlists in its order. A new album of [releases]
/// the feed has too is offered once, as a release.
List<_TopPick> _homeFeedPicks(
  List<ExploreItem> feed,
  List<WeeklyRelease> releases, {
  bool albums = true,
  bool playlists = true,
}) => [
  for (final item in feed)
    if (item.type != 'album') ...[
      if (playlists) _PlaylistPick(item),
    ] else if (albums &&
        !releases.any(
          (release) =>
              release.id == item.id && release.providerId == item.providerId,
        ))
      _FeedAlbumPick(item),
];

/// Home's Top Picks: a mix, then another pick, by turns, the other picks an
/// album and a playlist by turns.
List<_TopPick> _homeTopPicksOrder({
  required List<LibraryMixView> mixes,
  required List<ExploreItem> feed,
  required List<LibraryBrowseEntry> libraryAlbums,
  required List<WeeklyRelease> releases,
}) => homeTakeByTurns<_TopPick>([
  [for (final view in mixes) _MixPick(view)],
  homeTakeByTurns<_TopPick>([
    homeTakeByTurns<_TopPick>([
      [for (final release in releases) _ReleasePick(release)],
      [for (final album in libraryAlbums) _LibraryAlbumPick(album)],
      _homeFeedPicks(feed, releases, playlists: false),
    ]),
    _homeFeedPicks(feed, releases, albums: false),
  ]),
]);

/// Mornye's first shelf: tall cards, a little over three to the pane on
/// desktop and one with its neighbor peeking on phones. Mixes and playlists
/// are banners drawn here, whose color fields move; albums show their cover.
class _HomeTopPicksShelf extends StatefulWidget {
  const _HomeTopPicksShelf({
    required this.picks,
    required this.inset,
    required this.drift,
  });

  /// The cards in their order.
  final List<_TopPick> picks;
  final double inset;

  /// Whether the banners' color fields move.
  final bool drift;

  @override
  State<_HomeTopPicksShelf> createState() => _HomeTopPicksShelfState();
}

class _HomeTopPicksShelfState extends State<_HomeTopPicksShelf> {
  static const _gap = 16.0;

  /// One loop that every banner's field flows through.
  final _drift = DecorativePhase(const Duration(seconds: 30));
  bool _motion = false;
  bool _onScreen = true;

  // A tab switch or a motion setting only starts or stops the drift; the
  // shelf is made from the widget alone and keeps its cards.
  Widget? _built;
  _HomeTopPicksShelf? _builtFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncDrift();
  }

  @override
  void didUpdateWidget(_HomeTopPicksShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drift != widget.drift || oldWidget.picks != widget.picks) {
      _syncDrift();
    }
  }

  /// The fields stand still on another tab, under reduced motion, while the
  /// page has scrolled the shelf away and on a shelf of albums only.
  void _syncDrift() {
    final banners = widget.picks.any(
      (pick) => pick is _MixPick || pick is _PlaylistPick,
    );
    if (widget.drift && _motion && _onScreen && banners) {
      _drift.start();
    } else {
      _drift.stop();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _builtFor = null;
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  /// One card: its art under a round clip, pressed as a whole.
  Widget _card({
    required String label,
    required Widget child,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            child,
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mixes and playlists share the banner, so they read as Mornye's own
  /// whichever service a playlist came from.
  Widget _banner({
    required int seed,
    required String title,
    required String eyebrow,
    required String subtitle,
    required double width,
    required VoidCallback onTap,
  }) => _card(
    label: subtitle.isEmpty ? title : '$title, $subtitle',
    onTap: onTap,
    child: MornyeMixBanner(
      seed: seed,
      title: title,
      eyebrow: eyebrow,
      subtitle: subtitle,
      width: width,
      drift: widget.drift ? _drift : null,
    ),
  );

  Widget _pick(BuildContext context, _TopPick pick, int? seed, double width) {
    final l10n = context.l10n;
    switch (pick) {
      case _MixPick(:final view):
        return _banner(
          seed: seed!,
          title: libraryMixTitle(l10n, view.mix),
          eyebrow: l10n.homeMadeForYou,
          subtitle: libraryMixSubtitle(l10n, view.mix),
          width: width,
          onTap: () =>
              pushPage<void>(context, (_) => LibraryMixScreen(view: view)),
        );
      case _PlaylistPick(:final item):
        return _banner(
          seed: seed!,
          title: item.name,
          eyebrow: l10n.collectionPlaylist,
          subtitle: item.artists.isNotEmpty
              ? item.artists
              : item.description ?? '',
          width: width,
          onTap: () => pushPage<void>(
            context,
            (_) => ExtensionPlaylistScreen(
              extensionId: item.providerId ?? '',
              playlistId: item.id,
              playlistName: item.name,
              coverUrl: item.coverUrl,
            ),
          ),
        );
      case _LibraryAlbumPick(:final album):
        return _card(
          label: l10n.a11yOpenAlbum(album.name),
          onTap: () => _openHomeLibraryAlbum(context, album),
          child: _LibraryAlbumArt(
            album: album,
            builder: (context, artUri) => MornyeAlbumPick(
              artUri: artUri,
              title: album.name,
              eyebrow: l10n.homeFromYourLibrary,
              subtitle: album.artist,
              width: width,
            ),
          ),
        );
      case _ReleasePick(:final release):
        return _card(
          label: l10n.a11yOpenAlbum(release.name),
          onTap: () => navigateToAlbum(
            context,
            albumName: release.name,
            albumId: release.id,
            artistName: release.artist,
            coverUrl: release.coverUrl,
            extensionId: release.providerId,
          ),
          child: MornyeAlbumPick(
            artUri: release.coverUrl,
            title: release.name,
            eyebrow: l10n.homeNewRelease,
            subtitle: release.artist,
            width: width,
          ),
        );
      case _FeedAlbumPick(:final item):
        return _card(
          label: l10n.a11yOpenAlbum(item.name),
          onTap: () => pushPage<void>(
            context,
            (_) => ExtensionAlbumScreen(
              extensionId: item.providerId ?? '',
              albumId: item.id,
              albumName: item.name,
              coverUrl: item.coverUrl,
            ),
          ),
          child: MornyeAlbumPick(
            artUri: item.coverUrl,
            title: item.name,
            eyebrow: l10n.recentTypeAlbum,
            subtitle: item.artists,
            width: width,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final built = _built;
    if (built != null && identical(_builtFor, widget)) return built;
    _builtFor = widget;
    return _built = _build();
  }

  Widget _build() {
    final order = widget.picks;
    // Banners beside each other never share a palette, with or without an
    // album between them.
    final seeds = mornyeBannerSeeds([
      for (final pick in order)
        if (pick case _MixPick(:final view))
          '${view.mix.kind.name}/${view.mix.key}'
        else if (pick case _PlaylistPick(:final item))
          'playlist/${item.providerId}/${item.id}',
    ]);
    var banners = 0;
    final seedOf = [
      for (final pick in order)
        pick is _MixPick || pick is _PlaylistPick ? seeds[banners++] : null,
    ];
    return OnScreenListener(
      onChanged: (onScreen) {
        _onScreen = onScreen;
        _syncDrift();
      },
      child: _shelf(order, seedOf),
    );
  }

  Widget _shelf(List<_TopPick> order, List<int?> seedOf) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = widget.inset;
        final content = constraints.maxWidth - 2 * inset;
        final width = isDesktopPlatform
            ? ((content + _gap) / 4.6 - _gap).clamp(180.0, 320.0)
            : math.min(content - 44, 280.0);
        return SizedBox(
          height: width / MornyeMixBanner.aspectRatio,
          child: DesktopScrollArrows(
            builder: (context, controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: inset),
              itemCount: order.length,
              separatorBuilder: (_, _) => const SizedBox(width: _gap),
              itemBuilder: (context, index) =>
                  _pick(context, order[index], seedOf[index], width),
            ),
          ),
        );
      },
    );
  }
}

/// Mornye's first section: the day's mixes, with albums and the extension's
/// playlists between them.
class _HomeTopPicksSection extends ConsumerWidget {
  const _HomeTopPicksSection({
    required this.inset,
    required this.mixes,
    required this.libraryAlbums,
    required this.releases,
  });

  final double inset;

  /// Whether the day's mixes lead the shelf; they need the built-in player.
  final bool mixes;

  /// The Library's albums and the favorite artists' new ones offered today.
  final List<LibraryBrowseEntry> libraryAlbums;
  final List<WeeklyRelease> releases;

  static bool hasPicks(WidgetRef ref, {required bool mixes}) =>
      (mixes &&
          ref.watch(
            libraryMixesProvider.select((s) => s.value?.isNotEmpty ?? false),
          )) ||
      ref.watch(
        homeTopPicksProvider.select((s) => s.value?.isNotEmpty ?? false),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) => _HomeSection(
    title: context.l10n.homeTopPicks,
    inset: inset,
    shelf: true,
    onShowAll: () => pushPage<void>(context, (_) => const _HomeTopPicksPage()),
    child: _HomeTopPicksShelf(
      picks: _homeTopPicksOrder(
        mixes: mixes
            ? ref.watch(libraryMixesProvider.select((s) => s.value)) ?? const []
            : const [],
        feed:
            ref.watch(homeTopPicksProvider.select((s) => s.value)) ?? const [],
        libraryAlbums: libraryAlbums,
        releases: releases,
      ),
      inset: inset + 8,
      // A slow device keeps its frames for scrolling.
      drift: !ref.watch(lowEndDeviceProvider),
    ),
  );
}

enum _HomeShortcutsLayout {
  /// Two columns of tall tiles, on phones and tablets.
  grid,

  /// One connected list that fills the height it is given, beside the
  /// desktop Continue listening card.
  list,

  /// One row of short tiles across the desktop pane.
  row,
}

/// Quick ways into tools and collections that otherwise sit a few screens
/// deep. The user picks them, down to none: a long press or right-click on
/// a tile opens its menu.
class _HomeShortcuts extends ConsumerWidget {
  const _HomeShortcuts({this.layout = _HomeShortcutsLayout.grid});

  final _HomeShortcutsLayout layout;

  /// Whether a shortcut is left, or with [pins] a pin that sits among them.
  static bool hasContent(WidgetRef ref, {required bool pins}) {
    final player = ref.watch(playerUiEnabledProvider);
    final some = ref.watch(
      settingsProvider.select(
        (s) => HomeShortcut.resolve(s.homeShortcuts, player: player).isNotEmpty,
      ),
    );
    return some || (pins && _HomePinsSection.hasContent(ref));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final player = ref.watch(playerUiEnabledProvider);
    final shortcuts = HomeShortcut.resolve(
      ref.watch(settingsProvider.select((s) => s.homeShortcuts)),
      player: player,
    );

    // The first shortcut is the one emphasized action; the others share a
    // neutral tile so color marks importance rather than varying per tile.
    // Mornye keeps all shortcut tiles neutral.
    final emphasized = context.isMornye ? -1 : 0;
    final tiles = [
      for (final (index, shortcut) in shortcuts.indexed)
        if (_entry(context, ref, shortcut) case final entry)
          _HomeShortcutTile(
            label: entry.label,
            icon: entry.icon,
            container: index == emphasized
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHigh,
            onContainer: index == emphasized
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurface,
            badge: index == emphasized
                ? colorScheme.primary
                : colorScheme.secondaryContainer,
            onBadge: index == emphasized
                ? colorScheme.onPrimary
                : colorScheme.onSecondaryContainer,
            onTap: entry.onTap,
            onMenu: (position) =>
                _showMenu(context, ref, shortcuts, index, position, player),
            layout: layout,
            position: (index: index, count: shortcuts.length),
          ),
      // Pins follow in the grid; the desktop gives them their own section.
      if (layout == _HomeShortcutsLayout.grid)
        for (final pin in ref.watch(homePinsProvider))
          _HomePinShortcutTile(
            pin: pin,
            layout: layout,
            // The way back to a shortcut once the last one was removed.
            more: () => [?_addAction(context, ref, shortcuts, player)],
          ),
    ];

    switch (layout) {
      case _HomeShortcutsLayout.list:
        // Each row keeps a quarter of the height, so fewer rows end early
        // rather than stretch.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var slot = 0; slot < HomeShortcut.slotCount; slot++) ...[
              if (slot > 0) const SizedBox(height: 4),
              Expanded(
                child: slot < tiles.length
                    ? tiles[slot]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        );
      case _HomeShortcutsLayout.row:
        // A label that wraps keeps its neighbors the same height.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, tile) in tiles.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(child: tile),
              ],
            ],
          ),
        );
      case _HomeShortcutsLayout.grid:
        break;
    }

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
                Expanded(
                  child: row + 1 < tiles.length
                      ? tiles[row + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  ({String label, IconData icon, VoidCallback onTap}) _entry(
    BuildContext context,
    WidgetRef ref,
    HomeShortcut shortcut,
  ) {
    final l10n = context.l10n;
    void open(Widget screen) => pushPage<void>(context, (_) => screen);
    return switch (shortcut) {
      HomeShortcut.shuffle => (
        label: l10n.nowPlayingShuffleLibrary,
        icon: Icons.shuffle,
        onTap: () => _shuffle(context, ref),
      ),
      HomeShortcut.equalizer => (
        label: l10n.equalizerTitle,
        icon: Icons.graphic_eq,
        onTap: () => open(const EqualizerScreen()),
      ),
      HomeShortcut.listeningStats => (
        label: l10n.listeningStats,
        icon: Icons.insights,
        onTap: () => open(const ListeningStatisticsScreen()),
      ),
      HomeShortcut.networkStorage => (
        label: l10n.networkStorage,
        icon: Icons.lan_outlined,
        onTap: () => open(const NetworkStorageScreen()),
      ),
      HomeShortcut.loved => (
        label: l10n.collectionLoved,
        icon: Icons.favorite_border,
        onTap: () => open(
          const LibraryTracksFolderScreen(mode: LibraryTracksFolderMode.loved),
        ),
      ),
      HomeShortcut.wishlist => (
        label: l10n.collectionWishlist,
        icon: Icons.add_circle_outline,
        onTap: () => open(
          const LibraryTracksFolderScreen(
            mode: LibraryTracksFolderMode.wishlist,
          ),
        ),
      ),
      HomeShortcut.favoriteArtists => (
        label: l10n.collectionFavoriteArtists,
        icon: Icons.person_outline,
        onTap: () => open(const FavoriteArtistsScreen()),
      ),
      HomeShortcut.newReleases => (
        label: l10n.weeklyReleases,
        icon: Icons.new_releases_outlined,
        onTap: () => open(const WeeklyReleasesScreen(days: homeReleaseDays)),
      ),
      // Pairing opens the other side's settings: the computer from a
      // phone, the phone from a computer.
      HomeShortcut.link when isDesktopPlatform => (
        label: l10n.linkDesktopSettingsTitle,
        icon: Icons.phone_android,
        onTap: () => open(const LinkDesktopSettingsPage()),
      ),
      HomeShortcut.link => (
        label: l10n.linkSettingsTitle,
        icon: Icons.devices,
        onTap: () => open(const LinkSettingsPage()),
      ),
    };
  }

  void _showMenu(
    BuildContext context,
    WidgetRef ref,
    List<HomeShortcut> shortcuts,
    int slot,
    Offset position,
    bool player,
  ) {
    final l10n = context.l10n;
    // Read up front: the layout can rebuild this widget while the menu or
    // the sheet is open.
    final settings = ref.read(settingsProvider.notifier);
    final defaults = HomeShortcut.resolve(const [], player: player);
    final choices = [
      for (final shortcut in HomeShortcut.available(player: player))
        if (_entry(context, ref, shortcut) case final entry)
          AppChoice(shortcut, entry.icon, entry.label),
    ];
    showContextMenu(
      context,
      position: position,
      groups: [
        [
          ContextMenuAction(
            icon: Icons.swap_horiz,
            label: l10n.homeShortcutChange,
            onSelected: () {
              if (!context.mounted) return;
              showAppChoiceSheet<HomeShortcut>(
                context: context,
                title: l10n.homeShortcutChange,
                subtitle: l10n.homeShortcutChangeSubtitle,
                selected: shortcuts[slot],
                choices: choices,
                onSelected: (picked) => settings.setHomeShortcuts(
                  HomeShortcut.place(shortcuts, slot, picked),
                ),
              );
            },
          ),
          ?_addAction(context, ref, shortcuts, player),
          ContextMenuAction(
            icon: Icons.remove_circle_outline,
            label: l10n.homeShortcutRemove,
            onSelected: () =>
                settings.setHomeShortcuts([...shortcuts]..removeAt(slot)),
          ),
        ],
        [
          ContextMenuAction(
            icon: Icons.restart_alt,
            label: l10n.homeShortcutsReset,
            onSelected: listEquals(shortcuts, defaults)
                ? null
                : () => settings.setHomeShortcuts(HomeShortcut.defaults),
          ),
        ],
      ],
    );
  }

  /// "Add shortcut", while a slot is empty and a shortcut is left to add.
  ContextMenuAction? _addAction(
    BuildContext context,
    WidgetRef ref,
    List<HomeShortcut> shortcuts,
    bool player,
  ) {
    if (shortcuts.length >= HomeShortcut.slotCount) return null;
    final l10n = context.l10n;
    final settings = ref.read(settingsProvider.notifier);
    final choices = [
      for (final shortcut in HomeShortcut.available(player: player))
        if (!shortcuts.contains(shortcut))
          if (_entry(context, ref, shortcut) case final entry)
            AppChoice<HomeShortcut?>(shortcut, entry.icon, entry.label),
    ];
    if (choices.isEmpty) return null;
    return ContextMenuAction(
      icon: Icons.add,
      label: l10n.homeShortcutAdd,
      onSelected: () {
        if (!context.mounted) return;
        showAppChoiceSheet<HomeShortcut?>(
          context: context,
          title: l10n.homeShortcutAdd,
          selected: null,
          choices: choices,
          onSelected: (picked) {
            if (picked == null) return;
            settings.setHomeShortcuts([...shortcuts, picked]);
          },
        );
      },
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
    required this.onMenu,
    required this.layout,
    required this.position,
    this.leading,
  });

  final String label;
  final IconData icon;

  /// Stands in for the icon badge: a pin's cover.
  final Widget? leading;
  final Color container;
  final Color onContainer;
  final Color badge;
  final Color onBadge;
  final VoidCallback onTap;

  /// Opens the tile's menu at a global position: where a right-click
  /// landed, or the tile's center for a long press or the menu key.
  final ValueChanged<Offset> onMenu;
  final _HomeShortcutsLayout layout;

  /// Where the tile sits among the shortcuts, for the list's corners.
  final ({int index, int count}) position;

  @override
  Widget build(BuildContext context) {
    final badgeWidget =
        leading ?? _HomeIconBadge(icon: icon, color: badge, onColor: onBadge);
    final text = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(color: onContainer),
    );
    final BorderRadius radius;
    final Widget content;
    switch (layout) {
      case _HomeShortcutsLayout.grid:
        radius = BorderRadius.circular(24);
        content = Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [badgeWidget, const SizedBox(height: 16), text],
          ),
        );
      case _HomeShortcutsLayout.list:
        // One connected group: large outer corners, small inner ones.
        const outer = Radius.circular(24);
        const inner = Radius.circular(6);
        final first = position.index == 0;
        final last = position.index == position.count - 1;
        radius = BorderRadius.vertical(
          top: first ? outer : inner,
          bottom: last ? outer : inner,
        );
        content = Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 16, 8),
          child: Row(
            children: [
              badgeWidget,
              const SizedBox(width: 16),
              Expanded(child: text),
              const SizedBox(width: 8),
              AppIcon.adaptive(
                Icons.chevron_right,
                size: 20,
                color: onContainer.withValues(alpha: 0.7),
              ),
            ],
          ),
        );
      case _HomeShortcutsLayout.row:
        radius = BorderRadius.circular(24);
        content = Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              badgeWidget,
              const SizedBox(width: 12),
              Expanded(child: text),
            ],
          ),
        );
    }
    return DesktopContextMenuRegion(
      onContextMenu: onMenu,
      child: Material(
        color: container,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: () {
            final origin = contextMenuOriginOf(context);
            if (origin != null) onMenu(origin);
          },
          child: content,
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
