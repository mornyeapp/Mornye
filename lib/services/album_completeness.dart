import 'package:mornye/services/library_shadow_sql.dart';

const incompleteAlbumFilter = 'incomplete-album';
const unknownAlbumCompletenessFilter = 'unknown-album-completeness';

bool isAlbumCompletenessFilter(String? filter) =>
    filter == incompleteAlbumFilter || filter == unknownAlbumCompletenessFilter;

/// Combine downloaded and scanned music without counting the same stored file
/// twice. Retained rows on disconnected sources make the assessment unknown.
/// [shadowSnapshot] reads the stored-file matches from [libraryShadowTable].
String albumInventorySql({
  required bool includeLocal,
  bool shadowSnapshot = false,
}) {
  const sameStoredFile = '''
    SELECT 1 FROM library_path_keys lpk
    JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
    WHERE lpk.item_id = l.id
  ''';
  final historyUnavailable = !includeLocal
      ? '0'
      : shadowSnapshot
      ? '''EXISTS (
          SELECT 1 FROM $libraryShadowTable shadow
          JOIN library l ON l.id = shadow.item_id
          JOIN library_sources source ON source.id = l.source_id
          WHERE shadow.history_id = h.id
            AND source.enabled = 1 AND source.available = 0
        )'''
      : '''EXISTS (
          SELECT 1 FROM library l JOIN library_sources source ON source.id = l.source_id
          WHERE source.enabled = 1 AND source.available = 0
            AND EXISTS ($sameStoredFile AND hpk.item_id = h.id)
        )''';
  final notShadowed = shadowSnapshot
      ? libraryNotShadowedSql('l', snapshot: true)
      : 'NOT EXISTS ($sameStoredFile)';
  return '''
    SELECT h.album_key, LOWER(TRIM(h.track_name)) AS title,
      h.track_number, h.total_tracks, h.disc_number, h.total_discs,
      $historyUnavailable AS unavailable
    FROM history_db.history h
    ${includeLocal ? '''
    UNION ALL
    SELECT l.album_key, LOWER(TRIM(l.track_name)) AS title,
      l.track_number, l.total_tracks, l.disc_number, l.total_discs,
      CASE WHEN source.available = 0 THEN 1 ELSE 0 END AS unavailable
    FROM library l LEFT JOIN library_sources source ON source.id = l.source_id
    WHERE COALESCE(source.enabled, 1) = 1 AND $notShadowed
    ''' : ''}
  ''';
}

class AlbumCompleteness {
  final String status;
  final int present;
  final int? expected;

  const AlbumCompleteness({
    required this.status,
    required this.present,
    this.expected,
  });

  static AlbumCompleteness? fromRow(Map<String, dynamic> row) {
    final status = row['album_completeness'] as String?;
    if (status == null) return null;
    return AlbumCompleteness(
      status: status,
      present: (row['album_present_tracks'] as num?)?.toInt() ?? 0,
      expected: (row['album_expected_tracks'] as num?)?.toInt(),
    );
  }

  String get badge => status == 'unknown'
      ? '?'
      : expected == null
      ? '$present/?'
      : '$present/$expected';
}

/// Assess the full inventory, never the subset matching a search or quality
/// filter. Input columns: album_key, title, track_number, total_tracks,
/// disc_number, total_discs, unavailable. Equal multi-disc totals can mean
/// album-wide or per-disc totals; do not guess which convention the tags use.
String albumCompletenessSql(String tracksSql) =>
    '''
  WITH tracks AS ($tracksSql),
  slots AS (
    SELECT album_key, COALESCE(NULLIF(disc_number, 0), 1) AS disc,
      track_number, COUNT(DISTINCT title) AS titles
    FROM tracks
    GROUP BY album_key, disc, track_number
  ),
  discs AS (
    SELECT t.album_key, COALESCE(NULLIF(t.disc_number, 0), 1) AS disc,
      COUNT(DISTINCT CASE WHEN t.track_number > 0 THEN t.track_number END) AS present,
      MAX(t.total_tracks) AS expected,
      MIN(CASE WHEN t.total_discs > 0 THEN t.total_discs END) AS min_discs,
      MAX(t.total_discs) AS max_discs,
      MAX(CASE WHEN COALESCE(t.track_number, 0) <= 0
        OR COALESCE(t.disc_number, 0) < 0
        OR COALESCE(t.total_tracks, 0) < 0 OR COALESCE(t.total_discs, 0) < 0
        OR (COALESCE(t.disc_number, 0) = 0 AND t.total_discs > 1)
        OR COALESCE(t.unavailable, 0) != 0 THEN 1 ELSE 0 END) AS invalid,
      MAX(t.track_number) AS last_track,
      MIN(CASE WHEN t.total_tracks > 0 THEN t.total_tracks END) AS min_expected,
      MAX(s.titles) AS slot_titles
    FROM tracks t JOIN slots s ON s.album_key = t.album_key
      AND s.disc = COALESCE(NULLIF(t.disc_number, 0), 1)
      AND s.track_number IS t.track_number
    GROUP BY t.album_key, disc
  ),
  albums AS (
    SELECT album_key, SUM(present) AS present, SUM(expected) AS expected_sum,
      MIN(expected) AS min_expected, MAX(expected) AS max_expected,
      MIN(min_discs) AS min_discs, MAX(max_discs) AS max_discs,
      COUNT(*) AS seen_discs, MIN(disc) AS first_disc, MAX(disc) AS last_disc,
      MAX(CASE WHEN invalid = 1 OR slot_titles > 1
        OR COALESCE(expected, 0) <= 0 OR min_expected != expected
        OR last_track > expected THEN 1 ELSE 0 END) AS invalid
    FROM discs GROUP BY album_key
  ),
  assessed AS (
    SELECT *, CASE
      WHEN invalid = 1 OR first_disc < 1
        OR (max_discs > 0 AND (min_discs != max_discs OR last_disc > max_discs))
        THEN 1 ELSE 0 END AS uncertain,
      CASE WHEN last_disc = 1 AND COALESCE(max_discs, 1) <= 1 THEN expected_sum
        WHEN max_discs = seen_discs AND min_expected != max_expected
          THEN expected_sum ELSE NULL END AS expected,
      CASE WHEN max_discs > seen_discs THEN 1 ELSE 0 END AS missing_disc
    FROM albums
  )
  SELECT album_key, present AS album_present_tracks,
    CASE WHEN uncertain = 0 THEN expected END AS album_expected_tracks,
    CASE WHEN uncertain = 1 THEN 'unknown'
      WHEN missing_disc = 1 THEN 'incomplete'
      WHEN expected IS NOT NULL AND present < expected THEN 'incomplete'
      WHEN expected IS NOT NULL AND present = expected THEN 'complete'
      WHEN expected IS NULL AND present < max_expected THEN 'incomplete'
      ELSE 'unknown' END AS album_completeness
  FROM assessed
''';
