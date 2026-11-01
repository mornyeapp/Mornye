import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/utils/artist_album_sort.dart';

ArtistAlbum _album(String id, String date) => ArtistAlbum(
  id: id,
  name: id,
  releaseDate: date,
  totalTracks: 1,
  albumType: 'album',
  artists: 'Example Artist',
);

void main() {
  test('orders full and partial release dates without changing the input', () {
    final albums = [
      _album('old', '1999'),
      _album('same-year-early', '2026-01-01'),
      _album('month-only', '2026-08'),
      _album('year-only', '2025'),
      _album('same-year-late', '2026-10-27'),
      _album('timestamp', '2026-10-28T00:00:00Z'),
    ];
    final original = [...albums];
    final sorted = sortArtistAlbumsNewestFirst(List.unmodifiable(albums));
    expect(sorted.map((album) => album.id), [
      'timestamp',
      'same-year-late',
      'month-only',
      'same-year-early',
      'year-only',
      'old',
    ]);
    expect(albums, original);
  });

  test('ties keep provider order, including absent or invalid dates', () {
    final albums = [
      _album('undated-first', ''),
      _album('same-first', '2026'),
      _album('invalid-month', '2026-13'),
      _album('same-second', '2026-01-01'),
      _album('invalid-day', '2026-02-30'),
      _album('unknown', 'unknown'),
      _album('invalid-zero', '0000'),
      _album('invalid-time', '2026-10-27Tinvalid'),
      _album('leap-day', '2024-02-29'),
    ];
    expect(sortArtistAlbumsNewestFirst(albums).map((album) => album.id), [
      'same-first',
      'same-second',
      'leap-day',
      'undated-first',
      'invalid-month',
      'invalid-day',
      'unknown',
      'invalid-zero',
      'invalid-time',
    ]);
  });

  test('an empty catalog stays empty', () {
    expect(sortArtistAlbumsNewestFirst(const []), isEmpty);
  });
}
