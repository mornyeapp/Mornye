import 'dart:convert';
import 'dart:math';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/suggestion_outcomes.dart'
    show suggestionSongKey;
import 'package:mornye/utils/artist_utils.dart' show splitArtistTagValues;

/// How many recommended songs Home shows.
const homeRecommendationCount = 12;

/// How many a day's request keeps: more than shown, since songs leave the
/// shelf as they join the Library.
const homeRecommendationKept = 20;

/// The most songs of one artist the taste order puts ahead of every other
/// artist's next song.
const homeRecommendationPerArtist = 3;

/// How well a recommended song fits the listener, higher fitting better;
/// null when nothing learned can place it.
typedef HomeRecommendationFit = double? Function(Track track);

/// What an artist credited beside others counts for, against the song's
/// own artist.
const _creditWeight = 0.7;

/// The fit of songs at [at] by [preference], what Autoplay learned the
/// listener keeps playing, and [taste], their lasting taste. Each gives
/// -1 to 1 and they add up. Null when neither knows anything yet, so the
/// extension's order stays.
HomeRecommendationFit? homeRecommendationFit({
  AutoplayPreferenceModel? preference,
  AutoplayTasteProfile? taste,
  required DateTime at,
}) {
  final learned = preference != null && preference.observations > 0
      ? preference
      : null;
  if (learned == null && taste == null) return null;
  // As Autoplay's ranking does: the model counts fully after 20 songs.
  final confidence = learned == null
      ? 0.0
      : min(1.0, learned.observations / 20);
  return (track) {
    final artists = {
      track.artistName.trim(),
      ...splitArtistTagValues(track.artistName),
    }.where((artist) => artist.isNotEmpty).toList();
    double? preferred;
    if (learned != null) {
      // The song's own artist, else the first credited one it has heard.
      for (final (index, artist) in artists.indexed) {
        if (learned.artistEvidence(artist) < 1) continue;
        final probability = learned.preference(
          AutoplayLearningTrack(
            source: '',
            title: track.name,
            artist: artist,
            album: track.albumName,
            genre: track.genre ?? '',
            duration: track.duration > 0
                ? Duration(seconds: track.duration)
                : null,
          ),
          at: at,
        );
        preferred =
            confidence *
            2 *
            (probability - 0.5) *
            (index == 0 ? 1 : _creditWeight);
        break;
      }
    }
    final lasting = taste?.fit(track.artistName, track.name);
    if (preferred == null && lasting == null) return null;
    return (preferred ?? 0) + (lasting ?? 0);
  };
}

/// [fit] of each of [tracks], all null without one.
List<double?> homeRecommendationFits(
  List<Track> tracks,
  HomeRecommendationFit? fit,
) => [for (final track in tracks) fit?.call(track)];

/// [tracks] (in the extension's order) in the order of [fits], one per
/// track. Songs of unknown fit keep their places and ties keep the
/// extension's order; past [perArtist] songs of one artist, the next waits
/// until every artist has had as many turns. All unknown is the extension's
/// order.
List<Track> orderHomeRecommendations(
  List<Track> tracks,
  List<double?> fits, {
  int perArtist = homeRecommendationPerArtist,
}) {
  assert(fits.length == tracks.length);
  bool known(int index) =>
      index < fits.length && (fits[index]?.isFinite ?? false);
  if (!Iterable<int>.generate(tracks.length).any(known)) {
    return List.of(tracks);
  }
  final ranked =
      [
        for (var index = 0; index < tracks.length; index++)
          if (known(index)) index,
      ]..sort((a, b) {
        final order = fits[b]!.compareTo(fits[a]!);
        return order != 0 ? order : a.compareTo(b);
      });
  var next = 0;
  final ordered = [
    for (var index = 0; index < tracks.length; index++)
      known(index) ? tracks[ranked[next++]] : tracks[index],
  ];
  // Each song's turn among its artist's, by the first credited artist.
  final turns = <String, int>{};
  final rounds = <int>[];
  for (final track in ordered) {
    final artist =
        splitArtistTagValues(track.artistName).firstOrNull?.toLowerCase() ?? '';
    final turn = turns[artist] ?? 0;
    turns[artist] = turn + 1;
    rounds.add(artist.isEmpty ? 0 : turn ~/ perArtist);
  }
  final positions = List.generate(ordered.length, (index) => index)
    ..sort((a, b) {
      final order = rounds[a].compareTo(rounds[b]);
      return order != 0 ? order : a.compareTo(b);
    });
  return [for (final index in positions) ordered[index]];
}

/// The most songs recommendations start from.
const homeRecommendationPoolSize = 45;

/// The songs a person's recommendations start from: the most played, the
/// newest in the Library and the loved ones in turn, each once. Songs
/// without a title or an artist cannot be looked up and are left out.
List<Track> homeRecommendationPool({
  List<Track> mostPlayed = const [],
  List<Track> added = const [],
  List<Track> loved = const [],
}) => filterCollectionSuggestions(
  interleaveSuggestions([
    mostPlayed,
    added,
    loved,
  ]).where((track) => track.artistName.trim().isNotEmpty),
  const [],
  limit: homeRecommendationPoolSize,
);

/// The seed round of [day] (`yyyy-mm-dd`): each day starts from other songs
/// of the pool.
int homeRecommendationRound(String day) {
  final date = DateTime.tryParse('${day}T00:00:00Z');
  return date == null ? 0 : date.difference(DateTime.utc(2020)).inDays;
}

/// Whether [day] keeps the extension's order though the songs have a fit:
/// one day in four, so how well the fit tells what the listener acts on is
/// measured where a song's place owes nothing to it.
bool homeRecommendationControlDay(String day) =>
    homeRecommendationRound(day) % 4 == 0;

/// Where the shelf's order is stored.
const homeRecommendationOrderKey = 'home_recommendation_order_v1';

/// The key a recommended song is ordered and logged under.
int homeRecommendationKey(Track track) =>
    suggestionSongKey(track.artistName, track.name);

/// The order the shelf shows its songs in, decided once for a set of songs
/// so it does not move between launches: their keys in that order, and the
/// fit of each song that has one.
class HomeRecommendationOrder {
  const HomeRecommendationOrder({required this.keys, this.fits = const {}});

  /// [ordered] as the order of [tracks], whose fits are [fits] one by one.
  factory HomeRecommendationOrder.of(
    List<Track> ordered,
    List<Track> tracks,
    List<double?> fits,
  ) => HomeRecommendationOrder(
    keys: [for (final track in ordered) homeRecommendationKey(track)],
    fits: {
      for (final (index, track) in tracks.indexed)
        if (fits[index] case final fit? when fit.isFinite)
          homeRecommendationKey(track): fit,
    },
  );

  final List<int> keys;
  final Map<int, double> fits;

  /// Whether every one of [tracks] has its place.
  bool covers(List<Track> tracks) {
    final known = keys.toSet();
    return tracks.every(
      (track) => known.contains(homeRecommendationKey(track)),
    );
  }

  /// [tracks] in this order. A song without a place goes last.
  List<Track> apply(List<Track> tracks) {
    final places = <int, int>{};
    for (final (index, key) in keys.indexed) {
      places.putIfAbsent(key, () => index);
    }
    int place(int index) =>
        places[homeRecommendationKey(tracks[index])] ?? keys.length;
    final indexes = List.generate(tracks.length, (index) => index)
      ..sort((a, b) {
        final order = place(a).compareTo(place(b));
        return order != 0 ? order : a.compareTo(b);
      });
    return [for (final index in indexes) tracks[index]];
  }

  String encode() => jsonEncode({
    'keys': keys,
    'fits': {for (final entry in fits.entries) '${entry.key}': entry.value},
  });

  static HomeRecommendationOrder? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      if (json is! Map) return null;
      final keys = json['keys'], fits = json['fits'];
      if (keys is! List || fits is! Map) return null;
      return HomeRecommendationOrder(
        keys: [
          for (final key in keys)
            if (key is int) key,
        ],
        fits: {
          for (final entry in fits.entries)
            if ((int.tryParse('${entry.key}'), entry.value) case (
              final key?,
              final num fit,
            ) when fit.isFinite)
              key: fit.toDouble(),
        },
      );
    } on Object {
      return null;
    }
  }
}

/// A day's recommendations as stored, with the extension they came from.
class HomeRecommendationCache {
  const HomeRecommendationCache({
    required this.day,
    required this.extensionId,
    required this.tracks,
  });

  final String day;
  final String extensionId;
  final List<Track> tracks;

  String encode() => jsonEncode({
    'day': day,
    'extensionId': extensionId,
    'tracks': [for (final track in tracks) track.toJson()],
  });

  static HomeRecommendationCache? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      if (json is! Map) return null;
      final day = json['day'], extensionId = json['extensionId'];
      final tracks = json['tracks'];
      if (day is! String || extensionId is! String || tracks is! List) {
        return null;
      }
      return HomeRecommendationCache(
        day: day,
        extensionId: extensionId,
        tracks: _tracksOf(tracks),
      );
    } on Object {
      return null;
    }
  }
}

List<Track> _tracksOf(List<dynamic> json) => [
  for (final track in json)
    if (track is Map<String, dynamic>) Track.fromJson(track),
];

/// The most songs of one genre its recommendations start from.
const homeGenreRecommendationPoolSize = 30;

/// The songs a genre's recommendations start from: the genre mix's songs in
/// its order, each once. Songs without a title or an artist cannot be looked
/// up and are left out.
List<Track> homeGenreRecommendationPool(List<Track> songs) =>
    filterCollectionSuggestions(
      songs.where((track) => track.artistName.trim().isNotEmpty),
      const [],
      limit: homeGenreRecommendationPoolSize,
    );

/// [shelves] with each song only on the first shelf that has it and on none
/// when [shown] has it. Shelves left without songs go.
List<(K, List<Track>)> homeRecommendationShelvesApart<K>(
  List<(K, List<Track>)> shelves, {
  Iterable<Track> shown = const [],
}) {
  final seen = {for (final track in shown) homeRecommendationKey(track)};
  final apart = <(K, List<Track>)>[];
  for (final (key, tracks) in shelves) {
    final kept = [
      for (final track in tracks)
        if (seen.add(homeRecommendationKey(track))) track,
    ];
    if (kept.isNotEmpty) apart.add((key, kept));
  }
  return apart;
}

/// A day's recommendations of each genre as stored, by genre family, with
/// the extension they came from.
class HomeGenreRecommendationCache {
  const HomeGenreRecommendationCache({
    required this.day,
    required this.extensionId,
    required this.genres,
  });

  final String day;
  final String extensionId;
  final Map<String, List<Track>> genres;

  /// This cache with [tracks] for [genre]. Another day or extension starts
  /// the cache over.
  HomeGenreRecommendationCache put({
    required String day,
    required String extensionId,
    required String genre,
    required List<Track> tracks,
  }) => HomeGenreRecommendationCache(
    day: day,
    extensionId: extensionId,
    genres: {
      if (this.day == day && this.extensionId == extensionId) ...genres,
      genre: tracks,
    },
  );

  String encode() => jsonEncode({
    'day': day,
    'extensionId': extensionId,
    'genres': {
      for (final MapEntry(:key, :value) in genres.entries)
        key: [for (final track in value) track.toJson()],
    },
  });

  static HomeGenreRecommendationCache? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      if (json is! Map) return null;
      final day = json['day'], extensionId = json['extensionId'];
      final genres = json['genres'];
      if (day is! String || extensionId is! String || genres is! Map) {
        return null;
      }
      return HomeGenreRecommendationCache(
        day: day,
        extensionId: extensionId,
        genres: {
          for (final MapEntry(:key, :value) in genres.entries)
            if ((key, value) case (
              final String genre,
              final List<dynamic> tracks,
            ))
              genre: _tracksOf(tracks),
        },
      );
    } on Object {
      return null;
    }
  }
}
