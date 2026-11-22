import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/home_recommendations.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('HomeRecommendations');

const _cacheKey = 'home_recommendations_v1';

/// How many songs of each kind recommendations start from.
const _seedsPerKind = 15;

/// Reads the songs recommendations start from: the most played of the last
/// four weeks, the newest in the Library and the loved ones.
final homeRecommendationSeedsProvider =
    Provider<Future<List<Track>> Function()>(
      (ref) => () async {
        final settings = ref.read(settingsProvider);
        final now = DateTime.now();
        final (played, added) = await (
          settings.listeningStatisticsEnabled
              ? ListeningStatisticsStore.instance.loadReplayableTracks(
                  DateTime(now.year, now.month, now.day - 27),
                  DateTime(now.year, now.month, now.day + 1),
                  limit: _seedsPerKind,
                )
              : Future.value(const <ListeningTotal>[]),
          LibraryDatabase.instance.getQueueTrackPage(
            QueueLibraryDbQuery(
              includeLocal: settings.localLibraryEnabled,
              limit: _seedsPerKind,
            ),
          ),
        ).wait;
        return homeRecommendationPool(
          mostPlayed: [
            for (final total in played)
              Track(
                id: '',
                name: total.track.title,
                artistName: total.track.artist,
                albumName: total.track.album,
                duration: 0,
                source: 'local',
              ),
          ],
          added: [for (final row in added) ?_libraryTrack(row)],
          loved: [
            for (final entry
                in ref
                    .read(libraryCollectionsProvider)
                    .loved
                    .take(_seedsPerKind))
              _seed(entry.track),
          ],
        );
      },
    );

Track? _libraryTrack(Map<String, dynamic> row) {
  final json = Map<String, dynamic>.from(row['item'] as Map);
  return switch (row['source']) {
    'local' => _seed(
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem.fromJson(json),
      ).toTrack(),
    ),
    'downloaded' => _seed(
      UnifiedLibraryItem.fromDownloadHistory(
        DownloadHistoryItem.fromJson(json),
      ).toTrack(),
    ),
    _ => null,
  };
}

/// A file's own ID may be its path, which no extension has a use for.
Track _seed(Track track) =>
    track.source == 'local' ? track.copyWith(id: '') : track;

/// Drops the songs already in the Library from a list.
final homeRecommendationFilterProvider =
    Provider<Future<List<Track>> Function(List<Track> tracks)>(
      (ref) => (tracks) async {
        if (tracks.isEmpty) return const [];
        final local = ref.read(settingsProvider).localLibraryEnabled
            ? await ref
                  .read(localLibraryProvider.notifier)
                  .findExistingBatchAsync([
                    for (final track in tracks)
                      LocalLibraryBatchLookupRequest(
                        isrc: track.isrc,
                        trackName: track.name,
                        artistName: track.artistName,
                      ),
                  ])
            : null;
        final candidates = <Track>[];
        for (final (index, track) in tracks.indexed) {
          if (local != null && local[index] != null) continue;
          candidates.add(track);
        }
        if (candidates.isEmpty) return const [];
        final historyHits = await ref
            .read(downloadHistoryProvider.notifier)
            .hasExistingBatchAsync([
              for (final track in candidates)
                HistoryLookupRequest(
                  spotifyId: track.id,
                  isrc: track.isrc,
                  trackName: track.name,
                  artistName: track.artistName,
                ),
            ]);
        return [
          for (var i = 0; i < candidates.length; i++)
            if (!historyHits[i]) candidates[i],
        ];
      },
    );

/// Songs outside the Library like the ones a person plays, adds and loves,
/// asked from an extension once a day and kept for that day. A failed
/// request falls back on the last day's songs.
final homeRecommendationsProvider = FutureProvider<List<Track>>((ref) async {
  if (!ref.watch(settingsProvider.select((s) => s.homeRecommendations))) {
    return const [];
  }
  final ready = ref.watch(extensionProvider.select((s) => s.isInitialized));
  // A song that joins the Library leaves the shelf. Avoid forcing both Library
  // databases open on Frame 1 before extensions finish starting.
  if (ready) {
    watchLibrarySongs(ref);
  }
  ref.watch(extensionProvider.select(collectionSuggestionSourceKey));
  final outsideLibrary = ref.watch(homeRecommendationFilterProvider);
  final readSeeds = ref.watch(homeRecommendationSeedsProvider);

  Future<List<Track>> shown(List<Track> tracks) async => (await outsideLibrary(
    tracks,
  )).take(homeRecommendationCount).toList(growable: false);

  final prefs = await SharedPreferences.getInstance();
  final cached = HomeRecommendationCache.decode(prefs.getString(_cacheKey));
  // Before extensions start, the last songs show rather than none.
  if (!ready) return shown(cached?.tracks ?? const []);

  final extensions = ref.read(extensionProvider);
  final usable =
      cached != null &&
      extensions.extensions.any(
        (extension) =>
            extension.id == cached.extensionId &&
            extension.enabled &&
            (extension.hasRelatedTracks || extension.hasMetadataProvider),
      );
  final day = listeningDay(DateTime.now());
  if (usable && cached.day == day) return shown(cached.tracks);

  final pool = await readSeeds();
  final round = homeRecommendationRound(day);
  final source = collectionSuggestionSource(
    extensions,
    collectionSuggestionSeeds(pool, round: round),
  );
  if (pool.isEmpty || source == null) return const [];

  // Searches by artist swallow their failures: none answered is a failure.
  var answered = false;
  List<Track>? tracks;
  try {
    final suggestions = await loadCollectionSuggestions(
      tracks: pool,
      source: source,
      round: round,
      limit: homeRecommendationKept,
      related: (extensionId, seeds, limit) async {
        final results = await PlatformBridge.getExtensionRelatedTracks(
          extensionId,
          seeds,
          limit: limit,
        );
        answered = true;
        return results;
      },
      search: (extensionId, query) async {
        final results = await PlatformBridge.searchTracksWithMetadataProvider(
          extensionId,
          query,
          limit: 15,
        );
        answered = true;
        return results;
      },
    );
    if (answered) tracks = suggestions.tracks;
  } on Object catch (error, stack) {
    _log.w('Could not read Home recommendations: $error\n$stack');
  }
  if (tracks == null) {
    if (usable) return shown(cached.tracks);
    // Startup cancels extension reads under way: failing with an Exception,
    // not an Error, has Riverpod try again in a moment.
    throw Exception('Home has no recommendations yet');
  }
  await prefs.setString(
    _cacheKey,
    HomeRecommendationCache(
      day: day,
      extensionId: source.extensionId,
      tracks: tracks,
    ).encode(),
  );
  return shown(tracks);
});
