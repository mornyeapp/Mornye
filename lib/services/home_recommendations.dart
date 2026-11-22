import 'dart:convert';
import 'dart:math';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/collection_suggestions.dart';
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
        tracks: [
          for (final track in tracks)
            if (track is Map<String, dynamic>) Track.fromJson(track),
        ],
      );
    } on Object {
      return null;
    }
  }
}
