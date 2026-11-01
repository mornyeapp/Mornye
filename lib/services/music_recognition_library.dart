import 'package:mornye/models/recognized_song.dart';

/// A playable file in Mornye for a recognized song.
class RecognitionLibraryMatch {
  const RecognitionLibraryMatch({
    required this.path,
    required this.title,
    required this.artist,
    this.album = '',
    this.coverUrl = '',
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final String coverUrl;
}

/// Downloads and the local library, as lookups that only return files that
/// still exist.
abstract interface class RecognitionLibrary {
  Future<RecognitionLibraryMatch?> byIsrc(String isrc);

  /// [title] and [artist] are compared case-insensitively as whole values.
  Future<RecognitionLibraryMatch?> byTitleArtist(String title, String artist);
}

/// Finds a recognized song in Mornye: by ISRC first, then by title and
/// artist, loosening each to its plain form.
Future<RecognitionLibraryMatch?> findRecognizedSong(
  RecognizedSong song,
  RecognitionLibrary library,
) async {
  final isrc = song.isrc?.trim().toUpperCase() ?? '';
  if (isrc.isNotEmpty) {
    final match = await library.byIsrc(isrc);
    if (match != null) return match;
  }
  for (final (title, artist) in recognitionLookupPairs(
    song.title,
    song.artist,
  )) {
    final match = await library.byTitleArtist(title, artist);
    if (match != null) return match;
  }
  return null;
}

/// Title and artist pairs to try, exact first. The service writes featured
/// artists into the title ("Song (feat. B)") and joins credits ("A & B"),
/// where a library often keeps only the song name and the main artist.
List<(String, String)> recognitionLookupPairs(String title, String artist) {
  final titles = _distinct([title.trim(), _plainTitle(title)]);
  final artists = _distinct([artist.trim(), _mainArtist(artist)]);
  return [
    for (final artistName in artists)
      for (final titleName in titles) (titleName, artistName),
  ];
}

final _bracketed = RegExp(r'\s*[\(\[][^\)\]]*[\)\]]');
final _featuring = RegExp(
  r'\s+(?:feat\.?|ft\.?|featuring|with)\s+.*$',
  caseSensitive: false,
);
final _credits = RegExp(
  r'\s*(?:&|,|\+|\s(?:feat\.?|ft\.?|featuring|x)\s)\s*',
  caseSensitive: false,
);

String _plainTitle(String title) =>
    title.replaceAll(_bracketed, '').replaceFirst(_featuring, '').trim();

String _mainArtist(String artist) => artist.split(_credits).first.trim();

List<String> _distinct(List<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value.isNotEmpty && seen.add(value.toLowerCase())) value,
  ];
}
