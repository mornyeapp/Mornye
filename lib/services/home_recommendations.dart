import 'dart:convert';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/collection_suggestions.dart';

/// How many recommended songs Home shows.
const homeRecommendationCount = 12;

/// How many a day's request keeps: more than shown, since songs leave the
/// shelf as they join the Library.
const homeRecommendationKept = 20;

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
