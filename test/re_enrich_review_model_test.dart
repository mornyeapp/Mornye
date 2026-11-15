import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';

LocalLibraryItem _song({bool hasLyrics = false}) => LocalLibraryItem(
  id: 'song',
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: '/music/song.flac',
  coverPath: '/covers/song.jpg',
  scannedAt: DateTime(2026),
  trackNumber: 3,
  totalTracks: 10,
  releaseDate: '2012',
  hasLyrics: hasLyrics,
);

BatchReEnrichPreview _preview() {
  final metadata = <String, dynamic>{
    'track_name': 'Song (Remastered)',
    'album_name': 'Greatest Hits',
    'release_date': '2020-01-01',
    'track_number': 7,
    'total_tracks': 20,
    'cover_url': 'https://example.invalid/cover.jpg',
    'header_video': 'https://example.invalid/motion.m3u8',
    'spotify_id': 'provider-a:track-1',
    'duration_ms': 180000,
  };
  return BatchReEnrichPreview(
    item: _song(hasLyrics: true),
    updateFields: ReEnrichFields.all,
    enrichedMetadata: metadata,
    changes: buildReEnrichMetadataChanges(
      _song(hasLyrics: true),
      metadata,
      ReEnrichFields.all,
    ),
  );
}

void main() {
  group('downgrade defaults', () {
    const cover = ReEnrichMetadataChange(
      field: 'cover_url',
      oldValue: '/covers/song.jpg',
      newValue: 'https://example.invalid/cover.jpg',
    );

    test('a smaller new cover is a downgrade', () {
      expect(
        reEnrichChangeIsDowngrade(
          cover,
          currentCover: (width: 3000, height: 3000),
          newCover: (width: 640, height: 640),
        ),
        isTrue,
      );
    });

    test('a larger or equal cover, or unknown sizes, are not', () {
      expect(
        reEnrichChangeIsDowngrade(
          cover,
          currentCover: (width: 640, height: 640),
          newCover: (width: 1400, height: 1400),
        ),
        isFalse,
      );
      expect(
        reEnrichChangeIsDowngrade(
          cover,
          currentCover: (width: 1000, height: 1000),
          newCover: (width: 1000, height: 1000),
        ),
        isFalse,
      );
      expect(
        reEnrichChangeIsDowngrade(cover, newCover: (width: 640, height: 640)),
        isFalse,
      );
      expect(reEnrichChangeIsDowngrade(cover), isFalse);
    });

    test('an empty value over one the song has is a downgrade', () {
      expect(
        reEnrichChangeIsDowngrade(
          const ReEnrichMetadataChange(
            field: 'genre',
            oldValue: 'Rock',
            newValue: ' ',
          ),
        ),
        isTrue,
      );
      expect(
        reEnrichChangeIsDowngrade(
          const ReEnrichMetadataChange(
            field: 'genre',
            oldValue: '',
            newValue: 'Rock',
          ),
        ),
        isFalse,
      );
      expect(
        reEnrichChangeIsDowngrade(
          const ReEnrichMetadataChange(
            field: 'album_name',
            oldValue: 'Album',
            newValue: 'Greatest Hits',
          ),
        ),
        isFalse,
      );
    });
  });

  test('the diff lists only fields that change, with the lyrics state', () {
    final preview = _preview();
    expect(
      [for (final change in preview.changes) change.field],
      [
        'track_name',
        'album_name',
        'track_number',
        'total_tracks',
        'release_date',
        'cover_url',
        'header_video',
        'lyrics',
      ],
    );
    final album = preview.changes.firstWhere((c) => c.field == 'album_name');
    expect(album.oldValue, 'Album');
    expect(album.newValue, 'Greatest Hits');
    expect(
      preview.changes.last.oldValue,
      reEnrichHasLyricsValue,
      reason: 'the song has lyrics',
    );
    final withoutLyrics = buildReEnrichMetadataChanges(
      _song(),
      const {},
      const [ReEnrichFields.lyrics],
    );
    expect(withoutLyrics.single.oldValue, isEmpty);
  });

  group('selecting', () {
    test('writes only the chosen fields and keeps the identity', () {
      final selected = _preview().selecting({
        'track_name',
        'track_number',
        'cover_url',
      });
      expect(
        [for (final c in selected.changes) c.field],
        ['track_name', 'track_number', 'cover_url'],
      );
      expect(selected.updateFields, ['track_name', 'track_number', 'cover']);
      expect(selected.enrichedMetadata, {
        'track_name': 'Song (Remastered)',
        'track_number': 7,
        'cover_url': 'https://example.invalid/cover.jpg',
        'spotify_id': 'provider-a:track-1',
        'duration_ms': 180000,
      });
    });

    test('motion artwork alone leaves nothing to write to the file', () {
      final selected = _preview().selecting({'header_video'});
      expect(selected.updateFields, isEmpty);
      expect(
        selected.enrichedMetadata['header_video'],
        'https://example.invalid/motion.m3u8',
      );
      expect(selected.changes.single.field, 'header_video');
    });

    test('lyrics map to the lyrics field', () {
      final selected = _preview().selecting({'lyrics'});
      expect(selected.updateFields, [ReEnrichFields.lyrics]);
      expect(selected.enrichedMetadata.containsKey('album_name'), isFalse);
    });

    test('choosing nothing leaves no changes', () {
      expect(_preview().selecting(const {}).changes, isEmpty);
    });
  });
}
