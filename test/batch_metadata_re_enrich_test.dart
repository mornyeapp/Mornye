import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';

LocalLibraryItem _item({
  String? albumArtist,
  String? isrc,
  String? genre,
  String? coverPath = '/music/cover.jpg',
}) {
  return LocalLibraryItem(
    id: 'track-1',
    trackName: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    albumArtist: albumArtist,
    filePath: '/music/song.flac',
    coverPath: coverPath,
    scannedAt: DateTime(2026),
    isrc: isrc,
    trackNumber: 1,
    totalTracks: 10,
    discNumber: 1,
    totalDiscs: 1,
    duration: 180,
    releaseDate: '2026-01-02',
    genre: genre,
  );
}

void main() {
  test('motion-only cover refresh remains available for batch review', () {
    final changes = buildReEnrichMetadataChanges(
      _item(),
      {'header_video': 'https://example.invalid/motion.m3u8'},
      [ReEnrichFields.cover],
    );
    expect(changes.single.field, 'header_video');
    expect(
      buildReEnrichMetadataChanges(
        _item(),
        {'header_video': 'https://example.invalid/motion.m3u8'},
        ['isrc'],
      ),
      isEmpty,
    );
  });
  test(
    'missing mode returns granular keys and preserves populated neighbors',
    () {
      final fields = missingReEnrichFields(_item());

      expect(fields, containsAll(<String>['album_artist', 'isrc', 'genre']));
      expect(fields, isNot(contains('basic_tags')));
      expect(fields, isNot(contains('track_name')));
      expect(fields, isNot(contains('release_date')));
      expect(fields, isNot(contains('cover')));
    },
  );

  test('ISRC-only mode never selects the full release-info group', () {
    final fields = const ReEnrichFieldSelection(
      mode: ReEnrichBatchMode.isrcOnly,
    ).updateFieldsFor(_item());

    expect(fields, const ['isrc']);
  });

  test('manual mode only exposes shared-value fields', () {
    expect(manualBatchMetadataFields, containsAll(['album_name', 'genre']));
    expect(manualBatchMetadataFields, isNot(contains('track_name')));
    expect(manualBatchMetadataFields, isNot(contains('track_number')));
    expect(manualBatchMetadataFields, isNot(contains('isrc')));
  });

  test('manual values build a per-track review without an online lookup', () {
    final selection = const ReEnrichFieldSelection(
      mode: ReEnrichBatchMode.manualValues,
      manualValues: {'album_name': ' New Album ', 'genre': 'Rock'},
    );

    expect(selection.updateFieldsFor(_item()), ['album_name', 'genre']);
    final preview = buildManualBatchReEnrichPreview(_item(), selection);

    expect(preview, isNotNull);
    expect(preview!.enrichedMetadata['album_name'], 'New Album');
    expect(preview.changes.map((change) => change.field), [
      'album_name',
      'genre',
    ]);

    final request = buildBatchReEnrichRequest(
      item: preview.item,
      settings: const AppSettings(),
      updateFields: preview.updateFields,
      resolvedMetadata: preview.enrichedMetadata,
    );
    expect(request['search_online'], isFalse);
    expect(request['album_name'], 'New Album');
    expect(request['genre'], 'Rock');
  });

  test('manual preview omits unchanged and empty values', () {
    final preview = buildManualBatchReEnrichPreview(
      _item(genre: 'Rock'),
      const ReEnrichFieldSelection(
        mode: ReEnrichBatchMode.manualValues,
        manualValues: {'album_name': 'Album', 'genre': 'Rock', 'label': '   '},
      ),
    );

    expect(preview, isNull);
  });

  test('manual mode rejects unsafe per-track identifiers', () {
    final selection = const ReEnrichFieldSelection(
      mode: ReEnrichBatchMode.manualValues,
      manualValues: {'isrc': 'USAAA2600001', 'track_name': 'Same title'},
    );

    expect(selection.updateFieldsFor(_item()), isEmpty);
    expect(buildManualBatchReEnrichPreview(_item(), selection), isNull);
  });

  test('resolved preview metadata is reused without another online search', () {
    final request = buildBatchReEnrichRequest(
      item: _item(),
      settings: const AppSettings(embeddedCoverMaxDimension: 1000),
      updateFields: const ['isrc'],
      sourceTrackId: 'original-id',
      resolvedMetadata: const {
        'isrc': 'USRC17607839',
        'spotify_id': 'resolved-id',
      },
    );

    expect(request['search_online'], isFalse);
    expect(request['update_fields'], const ['isrc']);
    expect(request['isrc'], 'USRC17607839');
    expect(request['spotify_id'], 'resolved-id');
    expect(request['cover_max_dimension'], 1000);
  });

  test('empty preview identity cannot discard the original track ID', () {
    final request = buildBatchReEnrichRequest(
      item: _item(),
      settings: const AppSettings(),
      updateFields: const [ReEnrichFields.lyrics],
      sourceTrackId: 'original-id',
      resolvedMetadata: const {'spotify_id': ''},
    );

    expect(request['spotify_id'], 'original-id');
    expect(request['search_online'], isFalse);
  });

  test('review only includes values that would actually change', () {
    final changes = buildReEnrichMetadataChanges(
      _item(isrc: 'OLD'),
      const {'track_name': 'Song', 'artist_name': 'Artist', 'isrc': 'NEW'},
      const ['isrc'],
    );

    expect(changes, hasLength(1));
    expect(changes.single.field, 'isrc');
    expect(changes.single.oldValue, 'OLD');
    expect(changes.single.newValue, 'NEW');
  });
}
