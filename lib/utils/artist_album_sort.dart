import 'package:mornye/providers/track_provider.dart';

final _releaseDatePattern = RegExp(
  r'^(\d{4})(?:-(\d{2})(?:-(\d{2})(?:T.*)?)?)?$',
);

/// Keep provider order for matching dates and put undated releases last.
List<ArtistAlbum> sortArtistAlbumsNewestFirst(Iterable<ArtistAlbum> albums) {
  final dated = [
    for (final (index, album) in albums.indexed)
      (album: album, date: _releaseDateKey(album.releaseDate), index: index),
  ];
  dated.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    return byDate != 0 ? byDate : a.index.compareTo(b.index);
  });
  return [for (final entry in dated) entry.album];
}

int _releaseDateKey(String raw) {
  final value = raw.trim();
  final match = _releaseDatePattern.firstMatch(value);
  if (match == null ||
      (value.length > 10 && DateTime.tryParse(value) == null)) {
    return 0;
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2] ?? '1');
  final day = int.parse(match[3] ?? '1');
  final date = DateTime.utc(year, month, day);
  if (year == 0 ||
      date.year != year ||
      date.month != month ||
      date.day != day) {
    return 0;
  }
  return year * 10000 + month * 100 + day;
}
