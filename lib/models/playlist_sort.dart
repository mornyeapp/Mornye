import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';

/// Available sorting modes for user and catalog playlists.
enum PlaylistSortMode {
  custom,
  dateAddedDesc,
  dateAddedAsc,
  titleAsc,
  titleDesc,
  artistAsc,
  artistDesc,
  albumAsc,
  albumDesc,
  durationAsc,
  durationDesc,
}

/// Helper comparison for case-insensitive and empty-last string sorting.
int _compareStrings(String? a, String? b, {bool ascending = true}) {
  final strA = (a ?? '').trim();
  final strB = (b ?? '').trim();
  if (strA.isEmpty && strB.isNotEmpty) return 1;
  if (strA.isNotEmpty && strB.isEmpty) return -1;
  if (strA.isEmpty && strB.isEmpty) return 0;
  final result = strA.toLowerCase().compareTo(strB.toLowerCase());
  return ascending ? result : -result;
}

/// Returns a new list of [CollectionTrackEntry] sorted according to [mode].
List<CollectionTrackEntry> sortCollectionTrackEntries(
  List<CollectionTrackEntry> entries,
  PlaylistSortMode mode,
) {
  if (mode == PlaylistSortMode.custom || entries.length <= 1) {
    return List.of(entries);
  }

  // Preserve stable initial positions in case comparison returns 0
  final indexed = [
    for (var i = 0; i < entries.length; i++) (index: i, entry: entries[i]),
  ];

  indexed.sort((a, b) {
    final entryA = a.entry;
    final entryB = b.entry;
    var cmp = 0;

    switch (mode) {
      case PlaylistSortMode.custom:
        cmp = 0;
      case PlaylistSortMode.dateAddedDesc:
        cmp = entryB.addedAt.compareTo(entryA.addedAt);
      case PlaylistSortMode.dateAddedAsc:
        cmp = entryA.addedAt.compareTo(entryB.addedAt);
      case PlaylistSortMode.titleAsc:
        cmp = _compareStrings(entryA.track.name, entryB.track.name, ascending: true);
      case PlaylistSortMode.titleDesc:
        cmp = _compareStrings(entryA.track.name, entryB.track.name, ascending: false);
      case PlaylistSortMode.artistAsc:
        cmp = _compareStrings(entryA.track.artistName, entryB.track.artistName, ascending: true);
      case PlaylistSortMode.artistDesc:
        cmp = _compareStrings(entryA.track.artistName, entryB.track.artistName, ascending: false);
      case PlaylistSortMode.albumAsc:
        cmp = _compareStrings(entryA.track.albumName, entryB.track.albumName, ascending: true);
      case PlaylistSortMode.albumDesc:
        cmp = _compareStrings(entryA.track.albumName, entryB.track.albumName, ascending: false);
      case PlaylistSortMode.durationAsc:
        cmp = entryA.track.duration.compareTo(entryB.track.duration);
      case PlaylistSortMode.durationDesc:
        cmp = entryB.track.duration.compareTo(entryA.track.duration);
    }

    if (cmp != 0) return cmp;
    return a.index.compareTo(b.index);
  });

  return [for (final item in indexed) item.entry];
}

/// Returns a new list of [Track] sorted according to [mode].
List<Track> sortTracksByMode(
  List<Track> tracks,
  PlaylistSortMode mode,
) {
  if (mode == PlaylistSortMode.custom || tracks.length <= 1) {
    return List.of(tracks);
  }

  final indexed = [
    for (var i = 0; i < tracks.length; i++) (index: i, track: tracks[i]),
  ];

  indexed.sort((a, b) {
    final trackA = a.track;
    final trackB = b.track;
    var cmp = 0;

    switch (mode) {
      case PlaylistSortMode.custom:
        cmp = 0;
      case PlaylistSortMode.dateAddedDesc:
        cmp = _compareStrings(trackB.releaseDate, trackA.releaseDate, ascending: true);
      case PlaylistSortMode.dateAddedAsc:
        cmp = _compareStrings(trackA.releaseDate, trackB.releaseDate, ascending: true);
      case PlaylistSortMode.titleAsc:
        cmp = _compareStrings(trackA.name, trackB.name, ascending: true);
      case PlaylistSortMode.titleDesc:
        cmp = _compareStrings(trackA.name, trackB.name, ascending: false);
      case PlaylistSortMode.artistAsc:
        cmp = _compareStrings(trackA.artistName, trackB.artistName, ascending: true);
      case PlaylistSortMode.artistDesc:
        cmp = _compareStrings(trackA.artistName, trackB.artistName, ascending: false);
      case PlaylistSortMode.albumAsc:
        cmp = _compareStrings(trackA.albumName, trackB.albumName, ascending: true);
      case PlaylistSortMode.albumDesc:
        cmp = _compareStrings(trackA.albumName, trackB.albumName, ascending: false);
      case PlaylistSortMode.durationAsc:
        cmp = trackA.duration.compareTo(trackB.duration);
      case PlaylistSortMode.durationDesc:
        cmp = trackB.duration.compareTo(trackA.duration);
    }

    if (cmp != 0) return cmp;
    return a.index.compareTo(b.index);
  });

  return [for (final item in indexed) item.track];
}
