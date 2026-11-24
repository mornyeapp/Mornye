import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart'
    show libraryMixesProvider, libraryMixesStartupProvider;
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/home_recommendations.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_mixes.dart' show LibraryMixKind;
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('HomeRecommendations');

const _cacheKey = 'home_recommendations_v1';

/// How many songs of each kind recommendations start from.
const _seedsPerKind = 15;

/// How long the shelf waits on what learning knows before it keeps the
/// extension's order.
const _fitTimeout = Duration(seconds: 20);

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

/// What Home shows of [homeRecommendationCandidatesProvider]: its first
/// songs, in the order stored for them. With learning off that is the
/// extension's order.
final homeRecommendationsProvider = FutureProvider<List<Track>>((ref) async {
  final tracks = await ref.watch(homeRecommendationCandidatesProvider.future);
  List<Track> first(List<Track> songs) => ref
      .read(_shownRecommendationsProvider)
      .keep(songs.take(homeRecommendationCount).toList(growable: false));
  final learning = ref.watch(
    settingsProvider.select(
      (s) => s.autoplayPersonalization && s.usesBuiltInPlayer,
    ),
  );
  if (tracks.isEmpty || !learning) return first(tracks);

  final prefs = await SharedPreferences.getInstance();
  var order = HomeRecommendationOrder.decode(
    prefs.getString(homeRecommendationOrderKey),
  );
  if (order == null || !order.covers(tracks)) {
    // New songs wait for their fit, so the shelf takes its order once; the
    // songs before them stay up meanwhile.
    final fit = await ref.watch(homeRecommendationFitProvider.future);
    final fits = homeRecommendationFits(tracks, fit);
    final byFit =
        fit != null &&
        await ref.watch(homeRecommendationOrdersByFitProvider.future);
    order = HomeRecommendationOrder.of(
      byFit ? orderHomeRecommendations(tracks, fits) : tracks,
      tracks,
      fits,
    );
    await prefs.setString(homeRecommendationOrderKey, order.encode());
  }
  final fits = order.fits;
  if (fits.isNotEmpty) {
    // What the outcome log keeps of a song beside where it shows.
    ref
        .read(musicPlayerRuntimeProvider)
        .suggestionOutcomes
        .placeRecommendations({
          for (final (index, track) in tracks.indexed)
            homeRecommendationKey(track): (
              sourceRank: index,
              fit: fits[homeRecommendationKey(track)],
            ),
        });
  }
  return first(order.apply(tracks));
});

/// The shelf's last list. A reload that finds the same songs returns it, so
/// Home does not rebuild for every finished download.
class _ShownRecommendations {
  List<Track>? _tracks;
  String? _encoded;

  List<Track> keep(List<Track> tracks) {
    final String encoded;
    try {
      encoded = jsonEncode(tracks);
    } catch (_) {
      _encoded = null;
      return _tracks = tracks;
    }
    if (_tracks != null && encoded == _encoded) return _tracks!;
    _encoded = encoded;
    return _tracks = tracks;
  }
}

final _shownRecommendationsProvider = Provider<_ShownRecommendations>(
  (ref) => _ShownRecommendations(),
);

/// Forgets the shelf's stored order, as resetting learning forgets what it
/// came from.
Future<void> forgetHomeRecommendationOrder() async =>
    (await SharedPreferences.getInstance()).remove(homeRecommendationOrderKey);

/// Whether today's shelf takes the order of its songs' fits: not on a
/// control day, and not once the outcomes say the fit does not tell what
/// the listener acts on.
final homeRecommendationOrdersByFitProvider = FutureProvider<bool>((ref) async {
  if (homeRecommendationControlDay(listeningDay(DateTime.now()))) return false;
  final outcomes = ref.read(musicPlayerRuntimeProvider).suggestionOutcomes;
  await outcomes.refresh();
  return outcomes.summary.value?.fit.helps ?? true;
});

/// How well recommended songs fit the listener, from what Autoplay learned.
/// Null, so the extension's order stays, while learning is off and before
/// the models know enough. Read once startup has settled.
final homeRecommendationFitProvider = FutureProvider<HomeRecommendationFit?>((
  ref,
) async {
  if (!ref.watch(settingsProvider.select((s) => s.autoplayPersonalization))) {
    return null;
  }
  // The lasting taste reads the taste log: not before startup settles, as
  // the Library mixes wait.
  if (!ref.watch(libraryMixesStartupProvider)) {
    return Completer<HomeRecommendationFit?>().future;
  }
  final runtime = ref.read(musicPlayerRuntimeProvider);
  final learning = runtime.personalization;
  if (!learning.enabled) return null;
  try {
    return await () async {
      await learning.ensureLoaded();
      final taste = await runtime.taste.profile();
      return homeRecommendationFit(
        preference: learning.rankingSnapshot,
        taste: taste,
        at: DateTime.now(),
      );
    }().timeout(_fitTimeout);
  } on Object catch (error) {
    _log.w('Could not read the fit of Home recommendations: $error');
    return null;
  }
});

/// Songs outside the Library like the ones a person plays, adds and loves,
/// asked from an extension once a day and kept for that day, in the
/// extension's order. A failed request falls back on the last day's songs.
final homeRecommendationCandidatesProvider = FutureProvider<List<Track>>((
  ref,
) async {
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

  Future<List<Track>> shown(List<Track> tracks) => outsideLibrary(tracks);

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

  final tracks = await _askRecommendations(
    pool,
    source,
    round: round,
    limit: homeRecommendationKept,
  );
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

/// Songs like [pool] from [source], or null when no request answered.
Future<List<Track>?> _askRecommendations(
  List<Track> pool,
  CollectionSuggestionSource source, {
  required int round,
  required int limit,
}) async {
  // Searches by artist swallow their failures: none answered is a failure.
  var answered = false;
  try {
    final suggestions = await loadCollectionSuggestions(
      tracks: pool,
      source: source,
      round: round,
      limit: limit,
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
    return answered ? suggestions.tracks : null;
  } on Object catch (error, stack) {
    _log.w('Could not read Home recommendations: $error\n$stack');
    return null;
  }
}

const _genreCacheKey = 'home_genre_recommendations_v1';

/// Genre shelves load together; their cache writes go one after another.
Future<void> _genreCacheWrites = Future.value();

/// Songs outside the Library like the Library's songs of the genre family
/// [genre] (a genre mix's key), for the Recommended page. Asked once a day
/// per genre and kept for that day; a failed or empty answer falls back on
/// the last day's songs of that genre, else none, and is not kept.
final homeGenreRecommendationsProvider = FutureProvider.autoDispose
    .family<List<Track>, String>((ref, genre) async {
      if (!ref.watch(settingsProvider.select((s) => s.homeRecommendations)) ||
          !ref.watch(extensionProvider.select((s) => s.isInitialized))) {
        return const [];
      }
      watchLibrarySongs(ref);
      ref.watch(extensionProvider.select(collectionSuggestionSourceKey));
      final outsideLibrary = ref.watch(homeRecommendationFilterProvider);
      final mixes = await ref.watch(libraryMixesProvider.future);
      final mix = mixes
          .where(
            (view) =>
                view.mix.kind == LibraryMixKind.genre && view.mix.key == genre,
          )
          .firstOrNull;
      if (mix == null) return const [];

      final extensions = ref.read(extensionProvider);
      final prefs = await SharedPreferences.getInstance();
      final cached = HomeGenreRecommendationCache.decode(
        prefs.getString(_genreCacheKey),
      );
      final last =
          cached != null &&
              extensions.extensions.any(
                (extension) =>
                    extension.id == cached.extensionId &&
                    extension.enabled &&
                    (extension.hasRelatedTracks ||
                        extension.hasMetadataProvider),
              )
          ? cached.genres[genre]
          : null;
      final day = listeningDay(DateTime.now());
      if (last != null && cached!.day == day) return outsideLibrary(last);

      final pool = homeGenreRecommendationPool([
        for (final item in mix.items) _seed(item.toTrack()),
      ]);
      final round = homeRecommendationRound(day);
      final source = collectionSuggestionSource(
        extensions,
        collectionSuggestionSeeds(pool, round: round),
      );
      if (pool.isEmpty || source == null) return const [];
      final tracks = await _askRecommendations(
        pool,
        source,
        round: round,
        limit: homeRecommendationCount,
      );
      // No answer, or none found, is asked again when the page next opens.
      if (tracks == null || tracks.isEmpty) {
        return last == null ? const [] : outsideLibrary(last);
      }
      await (_genreCacheWrites = _genreCacheWrites
          .then((_) async {
            final stored =
                HomeGenreRecommendationCache.decode(
                  prefs.getString(_genreCacheKey),
                ) ??
                HomeGenreRecommendationCache(
                  day: day,
                  extensionId: source.extensionId,
                  genres: const {},
                );
            await prefs.setString(
              _genreCacheKey,
              stored
                  .put(
                    day: day,
                    extensionId: source.extensionId,
                    genre: genre,
                    tracks: tracks,
                  )
                  .encode(),
            );
          })
          .catchError((Object error) {
            _log.w('Could not store genre recommendations: $error');
          }));
      return outsideLibrary(tracks);
    });
