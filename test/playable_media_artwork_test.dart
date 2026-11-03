import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  LocalLibraryItem song(String? cover) => LocalLibraryItem(
    id: 'song',
    trackName: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: 'network://source/Album/song.flac',
    coverPath: cover,
    scannedAt: DateTime(2026),
  );

  test('scanned network artwork remains fetchable in the player queue', () {
    const reference = 'network://source/Album/cover.jpg';
    final media = playableFromLocal(song(reference));
    expect(media.coverReference, reference);
    final item = media.toMediaItem();
    expect(item.artUri, isNull);
    expect(item.extras?['artworkRef'], reference);
    expect(normalizeArtUri(reference), reference);
  });

  test('scanned artwork keeps existing URIs and escapes local paths once', () {
    const path = '/music/covers/cover #1.jpg';
    final fileUri = Uri.file(path).toString();
    for (final (input, expected) in [
      (path, fileUri),
      (fileUri, fileUri),
      (' $fileUri ', fileUri),
      ('https://example.test/cover.jpg', 'https://example.test/cover.jpg'),
      (
        'content://example.documents/cover',
        'content://example.documents/cover',
      ),
      ('', null),
      ('   ', null),
      (null, null),
    ]) {
      final media = playableFromLocal(song(input));
      expect(media.artUri, expected);
      expect(media.toMediaItem().artUri?.toString(), expected);
    }
  });
}
