import 'package:shared_preferences/shared_preferences.dart';
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

/// Map of common accented/diacritic characters to their base equivalents.
const _diacritics = <String, String>{
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ğ': 'g',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ł': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ș': 's',
  'ť': 't',
  'ț': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
  'æ': 'ae',
  'œ': 'oe',
  'ß': 'ss',
};

final _combiningMarksRegex = RegExp(r'[\u0300-\u036f]');

String _normalizeForSort(String text) {
  final stripped = text.toLowerCase().replaceAll(_combiningMarksRegex, '');
  final buffer = StringBuffer();
  for (final char in stripped.runes) {
    final str = String.fromCharCode(char);
    buffer.write(_diacritics[str] ?? str);
  }
  return buffer.toString();
}

/// Helper comparison for case-insensitive, diacritic-tolerant, and empty-last string sorting.
int _compareStrings(String? a, String? b, {bool ascending = true}) {
  final strA = (a ?? '').trim();
  final strB = (b ?? '').trim();
  if (strA.isEmpty && strB.isNotEmpty) return 1;
  if (strA.isNotEmpty && strB.isEmpty) return -1;
  if (strA.isEmpty && strB.isEmpty) return 0;
  final normA = _normalizeForSort(strA);
  final normB = _normalizeForSort(strB);
  var result = normA.compareTo(normB);
  if (result == 0) {
    result = strA.toLowerCase().compareTo(strB.toLowerCase());
  }
  if (result == 0) {
    result = strA.compareTo(strB);
  }
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
        cmp = _compareStrings(
          entryA.track.name,
          entryB.track.name,
          ascending: true,
        );
      case PlaylistSortMode.titleDesc:
        cmp = _compareStrings(
          entryA.track.name,
          entryB.track.name,
          ascending: false,
        );
      case PlaylistSortMode.artistAsc:
        cmp = _compareStrings(
          entryA.track.artistName,
          entryB.track.artistName,
          ascending: true,
        );
      case PlaylistSortMode.artistDesc:
        cmp = _compareStrings(
          entryA.track.artistName,
          entryB.track.artistName,
          ascending: false,
        );
      case PlaylistSortMode.albumAsc:
        cmp = _compareStrings(
          entryA.track.albumName,
          entryB.track.albumName,
          ascending: true,
        );
      case PlaylistSortMode.albumDesc:
        cmp = _compareStrings(
          entryA.track.albumName,
          entryB.track.albumName,
          ascending: false,
        );
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
List<Track> sortTracksByMode(List<Track> tracks, PlaylistSortMode mode) {
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
        cmp = _compareStrings(
          trackB.releaseDate,
          trackA.releaseDate,
          ascending: true,
        );
      case PlaylistSortMode.dateAddedAsc:
        cmp = _compareStrings(
          trackA.releaseDate,
          trackB.releaseDate,
          ascending: true,
        );
      case PlaylistSortMode.titleAsc:
        cmp = _compareStrings(trackA.name, trackB.name, ascending: true);
      case PlaylistSortMode.titleDesc:
        cmp = _compareStrings(trackA.name, trackB.name, ascending: false);
      case PlaylistSortMode.artistAsc:
        cmp = _compareStrings(
          trackA.artistName,
          trackB.artistName,
          ascending: true,
        );
      case PlaylistSortMode.artistDesc:
        cmp = _compareStrings(
          trackA.artistName,
          trackB.artistName,
          ascending: false,
        );
      case PlaylistSortMode.albumAsc:
        cmp = _compareStrings(
          trackA.albumName,
          trackB.albumName,
          ascending: true,
        );
      case PlaylistSortMode.albumDesc:
        cmp = _compareStrings(
          trackA.albumName,
          trackB.albumName,
          ascending: false,
        );
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

/// Helper for persisting and retrieving playlist sorting modes.
class PlaylistSortStorage {
  static const _prefix = 'mornye_playlist_sort_';

  static String storageKey(String playlistKey) => '$_prefix$playlistKey';

  static Future<PlaylistSortMode> getSortMode(
    String playlistKey, {
    SharedPreferences? prefs,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final name = p.getString(storageKey(playlistKey));
    if (name == null) return PlaylistSortMode.custom;
    for (final mode in PlaylistSortMode.values) {
      if (mode.name == name) return mode;
    }
    return PlaylistSortMode.custom;
  }

  static Future<void> setSortMode(
    String playlistKey,
    PlaylistSortMode mode, {
    SharedPreferences? prefs,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final key = storageKey(playlistKey);
    if (mode == PlaylistSortMode.custom) {
      await p.remove(key);
    } else {
      await p.setString(key, mode.name);
    }
  }
}

