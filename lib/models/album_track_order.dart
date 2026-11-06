import 'dart:collection';

/// Names a song across the Library's album pages and listening statistics,
/// which give the same song different ids.
String albumTrackRankKey(String trackName) => trackName.trim().toLowerCase();

/// Ranks for [AlbumTrackOrder]: the most played song first, unplayed songs
/// after every played one.
Map<String, int> albumTrackPlayRanks(Map<String, int> plays) => {
  for (final MapEntry(:key, :value) in plays.entries)
    albumTrackRankKey(key): -value,
};

/// Ranks for [AlbumTrackOrder] from a chosen order. Songs it does not name,
/// such as ones added later, follow it.
Map<String, int> albumTrackCustomRanks(List<String> keys) => {
  for (var i = 0; i < keys.length; i++) keys[i]: i - keys.length,
};

/// Album order shared by playback, metadata navigation, and disc sections.
/// Missing disc tags belong to disc 1; missing track tags use 999.
///
/// With [ranks], from [albumTrackPlayRanks] or [albumTrackCustomRanks], songs
/// sort by rank instead, in one section: a rank cuts across discs. Lower
/// ranks come first, unranked songs count as 0, and ties keep album order.
class AlbumTrackOrder<T> {
  final List<T> tracks;
  final Map<int, List<T>> discGroups;
  final List<int> discNumbers;

  AlbumTrackOrder._(this.tracks, this.discGroups, this.discNumbers);

  factory AlbumTrackOrder(
    Iterable<T> items, {
    required int? Function(T) discNumber,
    required int? Function(T) trackNumber,
    required String Function(T) trackName,
    Map<String, int>? ranks,
  }) {
    int rank(T track) => ranks?[albumTrackRankKey(trackName(track))] ?? 0;
    final tracks = items.toList();
    tracks.sort((a, b) {
      final ranked = rank(a).compareTo(rank(b));
      if (ranked != 0) return ranked;
      final disc = (discNumber(a) ?? 1).compareTo(discNumber(b) ?? 1);
      if (disc != 0) return disc;
      final number = (trackNumber(a) ?? 999).compareTo(trackNumber(b) ?? 999);
      return number != 0 ? number : trackName(a).compareTo(trackName(b));
    });
    final discGroups = <int, List<T>>{};
    for (final track in tracks) {
      final disc = ranks == null ? discNumber(track) ?? 1 : 1;
      discGroups.putIfAbsent(disc, () => []).add(track);
    }
    return AlbumTrackOrder._(
      UnmodifiableListView(tracks),
      UnmodifiableMapView({
        for (final entry in discGroups.entries)
          entry.key: UnmodifiableListView(entry.value),
      }),
      UnmodifiableListView(discGroups.keys.toList()..sort()),
    );
  }
}
