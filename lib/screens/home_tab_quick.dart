part of 'home_tab.dart';

/// Songs in Quick play: three rows of three.
const _homeQuickSongCount = 9;

/// Songs one stretch of the Library gives the day's picks.
const _homeQuickSongStretch = 30;

/// The page width from which Quick play is a shelf rather than a grid.
const _homeQuickGridMaxWidth = 600.0;

/// The stretches of a Library of [trackCount] songs the day's picks are
/// read from: all of a small one, else three places that move daily.
@visibleForTesting
List<({int offset, int limit})> homeQuickSongStretches(
  int trackCount,
  String day,
) {
  const whole = 3 * _homeQuickSongStretch;
  if (trackCount <= whole) return const [(offset: 0, limit: whole)];
  final starts = trackCount - _homeQuickSongStretch + 1;
  return [
    for (var stretch = 0; stretch < 3; stretch++)
      (
        offset: stableTextHash('$day|$stretch') % starts,
        limit: _homeQuickSongStretch,
      ),
  ];
}

/// Up to [limit] songs for Quick play: [played] first, then [pool] in the
/// day's order, one song per album while albums are left. Each song has its
/// own place in that order, so a Library change swaps a tile, not the grid.
@visibleForTesting
List<UnifiedLibraryItem> homeQuickSongPicks({
  required List<UnifiedLibraryItem> played,
  required List<UnifiedLibraryItem> pool,
  required String day,
  int limit = _homeQuickSongCount,
}) {
  String album(UnifiedLibraryItem song) => song.albumName.trim().isEmpty
      ? song.filePath
      : '${song.artistName}/${song.albumName}'.toLowerCase();
  final picks = <String, UnifiedLibraryItem>{};
  for (final song in played) {
    if (picks.length == limit) break;
    picks.putIfAbsent(song.filePath, () => song);
  }
  final order = {
    for (final song in pool)
      if (!picks.containsKey(song.filePath))
        song.filePath: stableTextHash('$day|${song.id}'),
  };
  final rest =
      [
        for (final song in pool)
          if (order.containsKey(song.filePath)) song,
      ]..sort((a, b) {
        final byOrder = order[a.filePath]!.compareTo(order[b.filePath]!);
        return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
      });
  final albums = {for (final song in picks.values) album(song)};
  final repeats = <UnifiedLibraryItem>[];
  for (final song in rest) {
    if (picks.length == limit) break;
    if (picks.containsKey(song.filePath)) continue;
    if (albums.add(album(song))) {
      picks[song.filePath] = song;
    } else {
      repeats.add(song);
    }
  }
  for (final song in repeats) {
    if (picks.length == limit) break;
    picks.putIfAbsent(song.filePath, () => song);
  }
  return picks.values.toList();
}

/// The songs of Quick play: the Library's most played of the last four
/// weeks, then the day's picks from the Library. Read once per Library
/// state, so a song that earns a play does not move the tiles under a
/// finger.
final homeQuickSongsProvider =
    FutureProvider.autoDispose<List<UnifiedLibraryItem>>((ref) async {
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      final memo = ref.read(_homeShelfMemoProvider);
      // Songs played from outside the Library come back without an entry.
      final played = [
        for (final (track: _, :item) in await _homeReplayableTracks(
          ref,
          limit: 2 * _homeQuickSongCount,
          followPlays: false,
        ))
          ?item,
      ];
      var pool = const <UnifiedLibraryItem>[];
      if (played.length < _homeQuickSongCount) {
        final counts = await ref.watch(
          libraryCountsProvider(
            LibraryCountsRequest.all(localLibraryEnabled: includeLocal),
          ).future,
        );
        final day = listeningDay(DateTime.now());
        final pages = await Future.wait([
          for (final (:offset, :limit) in homeQuickSongStretches(
            counts.allTrackCount,
            day,
          ))
            LibraryDatabase.instance.getQueueTrackPage(
              QueueLibraryDbQuery(
                includeLocal: includeLocal,
                limit: limit,
                offset: offset,
              ),
            ),
        ]);
        pool = [for (final rows in pages) ..._homeLibraryItemsOf(rows)];
      }
      final songs = homeQuickSongPicks(
        played: played,
        pool: pool,
        day: listeningDay(DateTime.now()),
      );
      final last = memo.quickSongs;
      if (last != null && _sameLibraryItems(last, songs)) return last;
      return memo.quickSongs = songs;
    });

bool _sameLibraryItems(
  List<UnifiedLibraryItem> first,
  List<UnifiedLibraryItem> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (!_sameLibraryItem(first[index], second[index])) return false;
  }
  return true;
}

/// Library songs one tap from playing: three across on a phone, a shelf
/// where the page is wide. A tap plays the song with the others after it.
class _HomeQuickPlay extends ConsumerWidget {
  const _HomeQuickPlay({required this.songs, required this.inset});

  final List<UnifiedLibraryItem> songs;
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    Widget tile(int index, double size, {required bool artist}) {
      final song = songs[index];
      return _HomeShelfTile(
        size: size,
        title: song.trackName,
        subtitle: artist ? song.artistName : null,
        semanticLabel: context.l10n.a11yOpenTrackByArtist(
          song.trackName,
          song.artistName,
        ),
        cover: _homeLibraryCover(
          song,
          colorScheme,
          size,
          (size * pixelRatio).round(),
        ),
        onTap: () => _homePlayLibraryItems(context, ref, songs, index),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _homeQuickGridMaxWidth) {
          return _HomeShelfSize(
            inset: inset,
            builder: (context, coverSize) => _HomeShelf(
              inset: inset,
              coverSize: coverSize,
              itemCount: songs.length,
              itemBuilder: (context, index) =>
                  tile(index, coverSize, artist: true),
            ),
          );
        }
        final gap = context.isMornye ? _homeMornyeShelfGap : 12.0;
        final size = ((constraints.maxWidth - 2 * inset - 2 * gap) / 3)
            .floorToDouble();
        return Padding(
          key: const ValueKey('home-quick-play-grid'),
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var row = 0; row < songs.length; row += 3) ...[
                if (row > 0) const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (
                      var index = row;
                      index < row + 3 && index < songs.length;
                      index++
                    ) ...[
                      if (index > row) SizedBox(width: gap),
                      tile(index, size, artist: false),
                    ],
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
