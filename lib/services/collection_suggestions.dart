import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';

/// Songs suggested under an album, single or playlist and how they were
/// found.
class CollectionSuggestions {
  const CollectionSuggestions({required this.tracks, required this.related});

  static const empty = CollectionSuggestions(tracks: [], related: false);

  final List<Track> tracks;

  /// From an extension's `getRelatedTracks`; false for songs searched by
  /// the collection's artists.
  final bool related;
}

/// Where suggestions come from: an extension that suggests related songs,
/// else a metadata provider searched by the collection's artists.
class CollectionSuggestionSource {
  const CollectionSuggestionSource({
    required this.extensionId,
    required this.related,
  });

  final String extensionId;
  final bool related;
}

/// How many songs a collection shows as suggestions.
const collectionSuggestionCount = 10;

/// How many collection songs a request starts from. Extensions make about
/// one request per seed (a few send megabytes each), and a refresh moves on
/// to other seeds.
const collectionSuggestionSeedCount = 3;

/// The extension to ask for suggestions like [seeds]: an enabled one with
/// `relatedTracks`, preferring the one most seeds came from (it can use
/// their IDs instead of looking them up), then the metadata provider order.
/// Without one, the first enabled metadata provider searches by artist.
CollectionSuggestionSource? collectionSuggestionSource(
  ExtensionState state,
  List<Track> seeds,
) {
  final enabled = [
    for (final extension in state.extensions)
      if (extension.enabled) extension,
  ];
  int rank(Extension extension) {
    final index = state.metadataProviderPriority.indexOf(extension.id);
    return index < 0 ? state.metadataProviderPriority.length : index;
  }

  final related = enabled.where((e) => e.hasRelatedTracks).toList()
    ..sort((a, b) {
      int from(Extension extension) =>
          seeds.where((seed) => seed.source == extension.id).length;
      final bySeeds = from(b).compareTo(from(a));
      return bySeeds != 0 ? bySeeds : rank(a).compareTo(rank(b));
    });
  if (related.isNotEmpty) {
    return CollectionSuggestionSource(
      extensionId: related.first.id,
      related: true,
    );
  }
  final search = enabled.where((e) => e.hasMetadataProvider).toList()
    ..sort((a, b) => rank(a).compareTo(rank(b)));
  if (search.isEmpty) return null;
  return CollectionSuggestionSource(
    extensionId: search.first.id,
    related: false,
  );
}

/// The extension IDs [collectionSuggestionSource] chooses between, so a
/// change of anything else in [state] keeps loaded suggestions.
String collectionSuggestionSourceKey(ExtensionState state) => [
  for (final extension in state.extensions)
    if (extension.enabled &&
        (extension.hasRelatedTracks || extension.hasMetadataProvider))
      '${extension.id}:${extension.hasRelatedTracks}',
  ...state.metadataProviderPriority,
].join(',');

/// Up to [count] of [tracks] (most important first) to start from, one per
/// artist while others remain. [round] moves on to later songs, so a
/// refresh suggests from another part of the collection.
List<Track> collectionSuggestionSeeds(
  List<Track> tracks, {
  int round = 0,
  int count = collectionSuggestionSeedCount,
}) {
  if (tracks.isEmpty) return const [];
  final start = (round * count) % tracks.length;
  final rotated = [...tracks.skip(start), ...tracks.take(start)];
  final seeds = <Track>[];
  final artists = <String>{};
  for (final track in rotated) {
    if (seeds.length == count) break;
    if (artists.add(_artistKey(track.artistName))) seeds.add(track);
  }
  for (final track in rotated) {
    if (seeds.length == count) break;
    if (!seeds.contains(track)) seeds.add(track);
  }
  return seeds;
}

/// A seed as `getRelatedTracks` takes it.
Map<String, dynamic> collectionSuggestionSeedJson(Track track) => {
  'id': track.id,
  'name': track.name,
  'artists': track.artistName,
  'album_name': track.albumName,
  'isrc': track.isrc,
  'duration_ms': track.duration * 1000,
  'provider_id': track.source,
};

/// [candidates] without songs already in [collection] or repeated, at most
/// [limit].
List<Track> filterCollectionSuggestions(
  Iterable<Track> candidates,
  Iterable<Track> collection, {
  int limit = collectionSuggestionCount,
}) {
  final seen = <String>{};
  for (final track in collection) {
    seen.addAll(_trackKeys(track));
  }
  final result = <Track>[];
  for (final track in candidates) {
    if (result.length == limit) break;
    if (track.name.trim().isEmpty) continue;
    final keys = _trackKeys(track);
    if (keys.any(seen.contains)) continue;
    seen.addAll(keys);
    result.add(track);
  }
  return result;
}

/// Takes one song from each list in turn, so no artist's search fills the
/// suggestions.
List<T> interleaveSuggestions<T>(List<List<T>> lists) {
  final result = <T>[];
  for (var i = 0; lists.any((list) => i < list.length); i++) {
    for (final list in lists) {
      if (i < list.length) result.add(list[i]);
    }
  }
  return result;
}

/// The artists [seeds] were searched by when no extension suggests related
/// songs: each distinct first artist once, in seed order.
List<String> collectionSuggestionArtists(List<Track> seeds) {
  final keys = <String>{};
  return [
    for (final seed in seeds)
      if (_primaryArtist(seed.artistName) case final artist
          when artist.isNotEmpty && keys.add(artist.toLowerCase()))
        artist,
  ];
}

/// Loads suggestions for [tracks] (most important first) from [source].
/// [related] asks an extension for songs like the seeds; [search] finds
/// songs by an artist.
Future<CollectionSuggestions> loadCollectionSuggestions({
  required List<Track> tracks,
  required CollectionSuggestionSource source,
  required int round,
  required Future<List<Map<String, dynamic>>> Function(
    String extensionId,
    List<Map<String, dynamic>> seeds,
    int limit,
  )
  related,
  required Future<List<Map<String, dynamic>>> Function(
    String extensionId,
    String query,
  )
  search,
}) async {
  final seeds = collectionSuggestionSeeds(tracks, round: round);
  if (seeds.isEmpty) return CollectionSuggestions.empty;
  // Ask for more than shown: some are already in the collection.
  const asked = collectionSuggestionCount * 3;
  if (source.related) {
    final results = await related(source.extensionId, [
      for (final seed in seeds) collectionSuggestionSeedJson(seed),
    ], asked);
    return CollectionSuggestions(
      tracks: filterCollectionSuggestions(
        results.map((map) => Track.fromBackendMap(map)),
        tracks,
      ),
      related: true,
    );
  }
  final artists = collectionSuggestionArtists(seeds).take(3).toList();
  final lists = await Future.wait([
    for (final artist in artists)
      search(source.extensionId, artist).then(
        (results) => [
          for (final map in results)
            if (Track.fromBackendMap(map) case final track
                when _artistKey(
                  track.artistName,
                ).contains(artist.toLowerCase()))
              track,
        ],
        onError: (Object _) => <Track>[],
      ),
  ]);
  return CollectionSuggestions(
    tracks: filterCollectionSuggestions(interleaveSuggestions(lists), tracks),
    related: false,
  );
}

String _primaryArtist(String artists) => artists
    .split(RegExp(r'\s*(?:,|;|&| feat\.? | ft\.? | x )\s*'))
    .first
    .trim();

String _artistKey(String artists) => artists.trim().toLowerCase();

String _titleKey(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'\s*[(\[].*?[)\]]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// What identifies [track] across sources: its ISRC, and its title with its
/// first artist.
List<String> _trackKeys(Track track) => [
  if (track.isrc?.trim() case final isrc? when isrc.isNotEmpty)
    'isrc:${isrc.toUpperCase()}',
  'name:${_titleKey(track.name)}|${_primaryArtist(track.artistName).toLowerCase()}',
];
