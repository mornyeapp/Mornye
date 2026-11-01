import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/library_file_sizes.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/library_format_filters.dart';

String confirmedMissingLyricsSqlPredicate({
  required String hasLyricsExpr,
  required String lyricsKnownExpr,
}) => '($lyricsKnownExpr) AND COALESCE($hasLyricsExpr, 0) = 0';

String missingReplayGainSqlPredicate({required String hasReplayGainExpr}) =>
    'COALESCE($hasReplayGainExpr, 0) = 0';

class _QueueOrderTerm {
  final String column;
  final bool descending;

  const _QueueOrderTerm(this.column, {this.descending = false});
}

/// Queue reads against an already opened library with history attached.
class LibraryQueueStore {
  final Database _db;
  final bool historyFts;
  final bool localFts;

  /// Whether the connection holds a current [sqlite.libraryShadowTable].
  final bool shadowSnapshot;

  const LibraryQueueStore(
    this._db, {
    required this.historyFts,
    required this.localFts,
    this.shadowSnapshot = false,
  });

  /// The Library row is not shadowed by a downloaded History file.
  String _notShadowedByHistory(String alias) =>
      sqlite.libraryNotShadowedSql(alias, snapshot: shadowSnapshot);

  Future<QueueLibraryDbPage> trackPage(QueueLibraryDbQuery request) =>
      _queuePage(
        request,
        _queueOrderTerms(request.sortMode, 'sort_track', 'id'),
        _queueTrackUnionSql,
        _queueTrackRowToJson,
      );

  Future<QueueLibraryDbPage> albumPage(QueueLibraryDbQuery request) =>
      _queuePage(
        request,
        _queueOrderTerms(
          switch (request.sortMode) {
            'album-asc' => 'a-z',
            'album-desc' => 'z-a',
            final sortMode => sortMode,
          },
          'sort_album',
          'album_key',
        ),
        _queueAlbumUnionSql,
        (row) => row,
      );

  Future<QueueLibraryDbPage> _queuePage(
    QueueLibraryDbQuery request,
    List<_QueueOrderTerm> orderTerms,
    String Function(
      QueueLibraryDbQuery request,
      List<Object?> args, {
      required List<_QueueOrderTerm> orderTerms,
      required bool usesCursor,
    })
    unionSql,
    Map<String, dynamic> Function(Map<String, dynamic> row) mapRow,
  ) async {
    final args = <Object?>[];
    final usesCursor =
        request.cursor != null &&
        request.cursor!.values.length == orderTerms.length;
    final union = unionSql(
      request,
      args,
      orderTerms: orderTerms,
      usesCursor: usesCursor,
    );
    final rows = await _db.rawQuery(
      '''
      SELECT *
      FROM ($union)
      ORDER BY ${_queueOrderBy(orderTerms)}
      LIMIT ? ${usesCursor ? '' : 'OFFSET ?'}
      ''',
      [...args, request.limit, if (!usesCursor) request.offset],
    );
    return QueueLibraryDbPage(
      rows: rows.map(mapRow).toList(growable: false),
      nextCursor: _queueCursorFromRow(rows.lastOrNull, orderTerms),
    );
  }

  /// Every Library file for the Folders index: downloads, then the scanned
  /// files no download shadows, the set the Songs page lists.
  Future<List<Map<String, Object?>>> directoryEntries({
    required bool includeLocal,
  }) => _db.rawQuery('''
    SELECT
      'downloaded' AS source,
      h.id,
      h.file_path,
      h.cover_url AS cover,
      h.disc_number,
      h.track_number,
      h.download_tree_uri,
      h.saf_relative_dir,
      h.saf_file_name
    FROM history_db.history h
    WHERE COALESCE(h.file_path, '') != ''
    ${includeLocal ? '''
    UNION ALL
    SELECT
      'local' AS source,
      l.id,
      l.file_path,
      l.cover_path AS cover,
      l.disc_number,
      l.track_number,
      NULL AS download_tree_uri,
      NULL AS saf_relative_dir,
      NULL AS saf_file_name
    FROM ${LibrarySchema.visibleView} l
    WHERE COALESCE(l.file_path, '') != '' AND ${_notShadowedByHistory('l')}
    ''' : ''}
  ''');

  /// The path and duration in seconds of every Library song, the same set
  /// as [directoryEntries], for analyzing how each sounds.
  Future<List<Map<String, Object?>>> songFiles() => _db.rawQuery('''
    SELECT 'downloaded' AS source, h.file_path, h.duration
    FROM history_db.history h
    WHERE COALESCE(h.file_path, '') != ''
    UNION ALL
    SELECT 'local' AS source, l.file_path, l.duration
    FROM ${LibrarySchema.visibleView} l
    WHERE COALESCE(l.file_path, '') != '' AND ${_notShadowedByHistory('l')}
  ''');

  /// One page of the metadata Home mixes group songs by, over the same set
  /// as [directoryEntries]: only the columns ranking, decades and the New
  /// Additions mix read, so a large Library arrives in small rows. Pages of
  /// [source] ('downloaded' or 'local') run by id after [afterId], so each
  /// seeks its primary key; downloads, then scanned files, each by id, is
  /// the order of the whole set.
  Future<List<Map<String, Object?>>> mixSongs({
    required String source,
    String? afterId,
    required int limit,
  }) {
    final after = afterId == null ? '' : 'AND song.id > ?';
    final sql = switch (source) {
      'downloaded' =>
        '''
        SELECT 'downloaded' AS source, song.id, song.file_path,
          song.track_name, song.artist_name, song.album_name, song.genre,
          song.duration, song.release_date, song.downloaded_at AS added_at,
          NULL AS file_mod_time
        FROM history_db.history song
        WHERE COALESCE(song.file_path, '') != '' $after
        ''',
      'local' =>
        '''
        SELECT 'local' AS source, song.id, song.file_path, song.track_name,
          song.artist_name, song.album_name, song.genre, song.duration,
          song.release_date, song.scanned_at AS added_at, song.file_mod_time
        FROM ${LibrarySchema.visibleView} song
        WHERE COALESCE(song.file_path, '') != ''
          AND ${_notShadowedByHistory('song')} $after
        ''',
      _ => throw ArgumentError.value(source, 'source'),
    };
    return _db.rawQuery('$sql ORDER BY song.id LIMIT ?', [?afterId, limit]);
  }

  Future<QueueLibraryCounts> counts(QueueLibraryDbQuery request) async {
    final fastCounts = await _getUnfilteredQueueCounts(request);
    if (fastCounts != null) return fastCounts;
    final parts = <String>[];
    final args = <Object?>[];

    if (request.source != 'local') {
      final where = <String>[];
      _appendQueueHistoryFilters(where, args, request);
      parts.add('''
        SELECT
          COUNT(*) AS all_count,
          COUNT(DISTINCT CASE WHEN grouped.track_count > ${isAlbumCompletenessFilter(request.metadata) ? 0 : 1} THEN h.album_key END) AS album_count,
          COALESCE(SUM(CASE WHEN grouped.track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM history_db.history h
        JOIN (
          SELECT album_key, COUNT(*) AS track_count
          FROM history_db.history
          GROUP BY album_key
        ) grouped ON grouped.album_key = h.album_key
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ''');
    }

    if (request.includeLocal && request.source != 'downloaded') {
      final where = <String>[_notShadowedByHistory('l')];
      _appendQueueLocalFilters(where, args, request);
      parts.add('''
        SELECT
          COUNT(*) AS all_count,
          COUNT(DISTINCT CASE WHEN grouped.track_count > ${isAlbumCompletenessFilter(request.metadata) ? 0 : 1} THEN l.album_key END) AS album_count,
          COALESCE(SUM(CASE WHEN grouped.track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM ${LibrarySchema.visibleView} l
        JOIN (
          SELECT album_key, COUNT(*) AS track_count
          FROM ${LibrarySchema.visibleView} candidate
          WHERE ${_notShadowedByHistory('candidate')}
          GROUP BY album_key
        ) grouped ON grouped.album_key = l.album_key
        WHERE ${where.join(' AND ')}
      ''');
    }
    return _sumQueueCounts(parts, const [
      'all_count',
      'single_count',
      'album_count',
    ], args);
  }

  /// Sums per-source count rows. [columns] only sets the SELECT order; the
  /// result is read by name.
  Future<QueueLibraryCounts> _sumQueueCounts(
    List<String> parts,
    List<String> columns, [
    List<Object?>? args,
  ]) async {
    if (parts.isEmpty) {
      return const QueueLibraryCounts(
        allTrackCount: 0,
        albumCount: 0,
        singleTrackCount: 0,
      );
    }
    final rows = await _db.rawQuery('''
      SELECT ${columns.map((column) => 'COALESCE(SUM($column), 0) AS $column').join(', ')}
      FROM (${parts.join(' UNION ALL ')})
    ''', args);
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return QueueLibraryCounts(
      allTrackCount: (row['all_count'] as num?)?.toInt() ?? 0,
      albumCount: (row['album_count'] as num?)?.toInt() ?? 0,
      singleTrackCount: (row['single_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// The default Library badges do not need a row-by-row join against album
  /// counts. Aggregate the covering album-key indexes directly and reserve the
  /// more expensive filtered query for active search/quality/metadata filters.
  Future<QueueLibraryCounts?> _getUnfilteredQueueCounts(
    QueueLibraryDbQuery request,
  ) async {
    if (sqlite.normalizeLookupText(request.searchQuery).isNotEmpty ||
        request.excludeNetwork ||
        request.albumArtist != null ||
        request.quality != null ||
        request.format != null ||
        request.metadata != null) {
      return null;
    }
    final source = request.source;
    if (source != null && source != 'downloaded' && source != 'local') {
      return null;
    }

    final parts = <String>[];
    if (source != 'local') {
      parts.add('''
        SELECT
          COALESCE(SUM(track_count), 0) AS all_count,
          COALESCE(SUM(CASE WHEN track_count > 1 THEN 1 ELSE 0 END), 0) AS album_count,
          COALESCE(SUM(CASE WHEN track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM (
          SELECT album_key, COUNT(*) AS track_count
          FROM history_db.history
          GROUP BY album_key
        )
      ''');
    }
    if (request.includeLocal && source != 'downloaded') {
      parts.add('''
        SELECT
          COALESCE(SUM(track_count), 0) AS all_count,
          COALESCE(SUM(CASE WHEN track_count > 1 THEN 1 ELSE 0 END), 0) AS album_count,
          COALESCE(SUM(CASE WHEN track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM (
          SELECT l.album_key, COUNT(*) AS track_count
          FROM ${LibrarySchema.visibleView} l
          WHERE ${_notShadowedByHistory('l')}
          GROUP BY l.album_key
        )
      ''');
    }
    return _sumQueueCounts(parts, const [
      'all_count',
      'album_count',
      'single_count',
    ]);
  }

  /// Album artists across downloaded and scanned music, without loading tracks
  /// into Dart. Scanned paths already represented by downloads are excluded.
  Future<List<Map<String, dynamic>>> artistPage(
    QueueLibraryDbQuery request,
  ) async {
    final parts = <String>[
      '''
        SELECT sort_album_artist AS artist_key,
          COALESCE(NULLIF(album_artist, ''), artist_name) AS artist_name,
          cover_url, NULL AS cover_path, file_path AS sample_file_path
        FROM history_db.history
      ''',
      if (request.includeLocal)
        '''
          SELECT album_artist_norm AS artist_key,
            COALESCE(NULLIF(album_artist, ''), artist_name) AS artist_name,
            NULL AS cover_url, cover_path, file_path AS sample_file_path
          FROM ${LibrarySchema.visibleView} l
          WHERE ${_notShadowedByHistory('l')}
        ''',
    ];
    final search = sqlite.normalizeLookupText(request.searchQuery);
    return _db.rawQuery(
      '''
      SELECT artist_key, MIN(artist_name) AS artist_name,
        MAX(NULLIF(cover_url, '')) AS cover_url,
        MAX(NULLIF(cover_path, '')) AS cover_path,
        MAX(sample_file_path) AS sample_file_path,
        COUNT(*) AS track_count
      FROM (${parts.join(' UNION ALL ')})
      WHERE artist_key != '' ${search.isEmpty ? '' : "AND artist_key LIKE ? ESCAPE '\\'"}
      GROUP BY artist_key
      ORDER BY artist_key
      LIMIT ? OFFSET ?
    ''',
      [
        if (search.isNotEmpty) '%${_escapeLikePattern(search)}%',
        request.limit,
        request.offset,
      ],
    );
  }

  String _escapeLikePattern(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  String _queueTrackUnionSql(
    QueueLibraryDbQuery request,
    List<Object?> args, {
    required List<_QueueOrderTerm> orderTerms,
    required bool usesCursor,
  }) {
    final parts = <String>[];
    if (request.source != 'local') {
      final where = <String>[];
      _appendQueueHistoryFilters(where, args, request);
      if (request.filterMode == 'singles') {
        where.add('''
          h.album_key IN (
            SELECT album_key
            FROM history_db.history
            GROUP BY album_key
            HAVING COUNT(*) = 1
          )
          ''');
      }
      final selectSql =
          '''
        SELECT
          'downloaded' AS queue_source,
          'dl_' || h.id AS unified_id,
          h.id,
          h.track_name,
          h.artist_name,
          h.album_name,
          h.album_artist,
          h.cover_url,
          h.file_path,
          h.storage_mode,
          h.download_tree_uri,
          h.saf_relative_dir,
          h.saf_file_name,
          h.saf_repaired,
          h.service,
          h.downloaded_at,
          h.isrc,
          h.spotify_id,
          h.track_number,
          h.total_tracks,
          h.disc_number,
          h.total_discs,
          h.duration,
          h.release_date,
          h.quality,
          h.bit_depth,
          h.sample_rate,
          h.genre,
          h.composer,
          h.label,
          h.copyright,
          NULL AS cover_path,
          NULL AS scanned_at,
          NULL AS file_mod_time,
          h.bitrate,
          h.format,
          h.has_replaygain,
          h.replaygain_metadata_scan_version,
          h.sort_track,
          h.sort_artist,
          h.sort_album,
          h.sort_genre,
          h.sort_release,
          h.sort_added
          ${_trackSizeColumns(request.sortMode)}
        FROM history_db.history h
        ${_sizeJoin(request.sortMode, 'history_db', 'h')}
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
        ''';
      parts.add(
        _boundedQueuePart(
          selectSql,
          request,
          args,
          orderTerms,
          usesCursor: usesCursor,
        ),
      );
    }

    if (request.includeLocal && request.source != 'downloaded') {
      final where = <String>[_notShadowedByHistory('l')];
      _appendQueueLocalFilters(where, args, request);
      if (request.filterMode == 'singles') {
        where.add('''
          l.album_key IN (
            SELECT album_key
            FROM ${LibrarySchema.visibleView} candidate
            WHERE ${_notShadowedByHistory('candidate')}
            GROUP BY album_key
            HAVING COUNT(*) = 1
          )
          ''');
      }
      final selectSql =
          '''
        SELECT
          'local' AS queue_source,
          'local_' || l.id AS unified_id,
          l.id,
          l.track_name,
          l.artist_name,
          l.album_name,
          l.album_artist,
          NULL AS cover_url,
          l.file_path,
          NULL AS storage_mode,
          NULL AS download_tree_uri,
          NULL AS saf_relative_dir,
          NULL AS saf_file_name,
          0 AS saf_repaired,
          'local' AS service,
          NULL AS downloaded_at,
          l.isrc,
          NULL AS spotify_id,
          l.track_number,
          l.total_tracks,
          l.disc_number,
          l.total_discs,
          l.duration,
          l.release_date,
          NULL AS quality,
          l.bit_depth,
          l.sample_rate,
          l.genre,
          l.composer,
          l.label,
          l.copyright,
          l.cover_path,
          l.scanned_at,
          l.file_mod_time,
          l.bitrate,
          l.format,
          l.has_replaygain,
          CASE WHEN l.audio_metadata_scan_version >= $libraryAudioMetadataScanVersion
            THEN 1 ELSE 0 END AS replaygain_metadata_scan_version,
          l.track_name_norm AS sort_track,
          l.artist_name_norm AS sort_artist,
          l.album_name_norm AS sort_album,
          l.sort_genre,
          l.sort_release,
          l.sort_added
          ${_trackSizeColumns(request.sortMode)}
        FROM ${LibrarySchema.visibleView} l
        ${_sizeJoin(request.sortMode, 'main', 'l')}
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
        ''';
      parts.add(
        _boundedQueuePart(
          selectSql,
          request,
          args,
          orderTerms,
          usesCursor: usesCursor,
        ),
      );
    }

    if (parts.isEmpty) {
      return '''
        SELECT
          NULL AS queue_source,
          NULL AS unified_id,
          NULL AS id,
          NULL AS track_name,
          NULL AS artist_name,
          NULL AS album_name,
          NULL AS album_artist,
          NULL AS cover_url,
          NULL AS file_path,
          NULL AS storage_mode,
          NULL AS download_tree_uri,
          NULL AS saf_relative_dir,
          NULL AS saf_file_name,
          NULL AS saf_repaired,
          NULL AS service,
          NULL AS downloaded_at,
          NULL AS isrc,
          NULL AS spotify_id,
          NULL AS track_number,
          NULL AS total_tracks,
          NULL AS disc_number,
          NULL AS total_discs,
          NULL AS duration,
          NULL AS release_date,
          NULL AS quality,
          NULL AS bit_depth,
          NULL AS sample_rate,
          NULL AS genre,
          NULL AS composer,
          NULL AS label,
          NULL AS copyright,
          NULL AS cover_path,
          NULL AS scanned_at,
          NULL AS file_mod_time,
          NULL AS bitrate,
          NULL AS format,
          NULL AS has_replaygain,
          NULL AS replaygain_metadata_scan_version,
          NULL AS sort_track,
          NULL AS sort_artist,
          NULL AS sort_album,
          NULL AS sort_genre,
          NULL AS sort_release,
          NULL AS sort_added
          ${isLibrarySizeSort(request.sortMode) ? ', NULL AS file_size_bytes, 1 AS sort_size_unknown, 0 AS sort_size' : ''}
        WHERE 0
      ''';
    }
    return parts.join(' UNION ALL ');
  }

  String _queueAlbumUnionSql(
    QueueLibraryDbQuery request,
    List<Object?> args, {
    required List<_QueueOrderTerm> orderTerms,
    required bool usesCursor,
  }) {
    final unfiltered =
        sqlite.normalizeLookupText(request.searchQuery).isEmpty &&
        !request.excludeNetwork &&
        request.albumArtist == null &&
        request.quality == null &&
        request.format == null &&
        request.metadata == null;
    final assessesCompleteness = isAlbumCompletenessFilter(request.metadata);
    final minimumTracks =
        request.includeSingleTrackAlbums || assessesCompleteness ? 0 : 1;
    final completenessSql = assessesCompleteness
        ? albumCompletenessSql(
            albumInventorySql(
              includeLocal: request.includeLocal,
              shadowSnapshot: shadowSnapshot,
            ),
          )
        : null;
    final completenessColumns = assessesCompleteness
        ? 'ac.album_completeness, ac.album_present_tracks, ac.album_expected_tracks,'
        : 'NULL AS album_completeness, NULL AS album_present_tracks, NULL AS album_expected_tracks,';
    final parts = <String>[];
    if (request.source != 'local') {
      final albumKey = unfiltered ? 'h.album_key' : 'c.album_key';
      final albums = <String>[];
      if (!unfiltered) {
        _appendQueueHistoryFilters(
          albums,
          args,
          request,
          albumCompleteness: false,
        );
      }
      final where = <String>[];
      _appendQueueHistoryFilters(
        where,
        args,
        request,
        hasCompletenessJoin: assessesCompleteness,
      );
      final selectSql =
          '''
        SELECT
          'downloaded' AS queue_source,
          $albumKey AS album_key,
          MIN(h.album_name) AS album_name,
          COALESCE(NULLIF(MIN(h.album_artist), ''), MIN(h.artist_name)) AS artist_name,
          MAX(CASE WHEN h.cover_url IS NOT NULL AND h.cover_url != '' THEN h.cover_url END) AS cover_url,
          NULL AS cover_path,
          MAX(h.file_path) AS sample_file_path,
          COUNT(*) AS track_count,
          $completenessColumns
          ${unfiltered ? 'MAX(COALESCE(h.sort_added, 0))' : 'c.latest_added'} AS sort_added,
          MIN(COALESCE(h.sort_album, '')) AS sort_album,
          MIN(COALESCE(h.sort_album_artist, '')) AS sort_artist,
          COALESCE(MAX(h.release_date), '') AS sort_release,
          COALESCE(MAX(h.sort_genre), '') AS sort_genre
          ${_albumSizeColumns(request.sortMode)}
        FROM history_db.history h
        ${_sizeJoin(request.sortMode, 'history_db', 'h')}
        ${unfiltered ? '' : '''JOIN (
          SELECT
            album_key,
            COUNT(*) AS track_count,
            MAX(COALESCE(sort_added, 0)) AS latest_added
          FROM history_db.history
          ${_albumKeysIn('history_db.history', 'h', albums)}
          GROUP BY album_key
          HAVING COUNT(*) > $minimumTracks
        ) c
          ON c.album_key = h.album_key'''}
        ${assessesCompleteness ? 'JOIN ($completenessSql) ac ON ac.album_key = h.album_key' : ''}
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
        GROUP BY $albumKey
        ${unfiltered ? 'HAVING $albumKey IS NOT NULL AND COUNT(*) > $minimumTracks' : ''}
        ''';
      parts.add(
        _boundedQueuePart(
          selectSql,
          request,
          args,
          orderTerms,
          usesCursor: usesCursor,
        ),
      );
    }

    if (request.includeLocal && request.source != 'downloaded') {
      final albumKey = unfiltered ? 'l.album_key' : 'c.album_key';
      final albums = <String>[];
      if (!unfiltered) {
        _appendQueueLocalFilters(
          albums,
          args,
          request,
          albumCompleteness: false,
        );
      }
      final where = <String>[_notShadowedByHistory('l')];
      _appendQueueLocalFilters(
        where,
        args,
        request,
        hasCompletenessJoin: assessesCompleteness,
      );
      final selectSql =
          '''
        SELECT
          'local' AS queue_source,
          $albumKey AS album_key,
          MIN(l.album_name) AS album_name,
          COALESCE(NULLIF(MIN(l.album_artist), ''), MIN(l.artist_name)) AS artist_name,
          NULL AS cover_url,
          MAX(CASE WHEN l.cover_path IS NOT NULL AND l.cover_path != '' THEN l.cover_path END) AS cover_path,
          MAX(l.file_path) AS sample_file_path,
          COUNT(*) AS track_count,
          $completenessColumns
          ${unfiltered ? 'MAX(COALESCE(l.sort_added, 0))' : 'c.latest_added'} AS sort_added,
          MIN(l.album_name_norm) AS sort_album,
          MIN(l.album_artist_norm) AS sort_artist,
          COALESCE(MAX(l.release_date), '') AS sort_release,
          COALESCE(MAX(l.sort_genre), '') AS sort_genre
          ${_albumSizeColumns(request.sortMode)}
        FROM ${LibrarySchema.visibleView} l
        ${_sizeJoin(request.sortMode, 'main', 'l')}
        ${unfiltered ? '' : '''JOIN (
          SELECT
            album_key,
            COUNT(*) AS track_count,
            MAX(COALESCE(sort_added, 0)) AS latest_added
          FROM ${LibrarySchema.visibleView} candidate
          WHERE ${_notShadowedByHistory('candidate')}
          ${_albumKeysIn('library', 'l', albums, and: true)}
          GROUP BY album_key
          HAVING COUNT(*) > $minimumTracks
        ) c ON c.album_key = l.album_key'''}
        ${assessesCompleteness ? 'JOIN ($completenessSql) ac ON ac.album_key = l.album_key' : ''}
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
        GROUP BY $albumKey
        ${unfiltered ? 'HAVING $albumKey IS NOT NULL AND COUNT(*) > $minimumTracks' : ''}
        ''';
      parts.add(
        _boundedQueuePart(
          selectSql,
          request,
          args,
          orderTerms,
          usesCursor: usesCursor,
        ),
      );
    }

    if (parts.isEmpty) {
      return '''
        SELECT
          NULL AS queue_source,
          NULL AS album_key,
          NULL AS album_name,
          NULL AS artist_name,
          NULL AS cover_url,
          NULL AS cover_path,
          NULL AS sample_file_path,
          NULL AS track_count,
          NULL AS album_completeness,
          NULL AS album_present_tracks,
          NULL AS album_expected_tracks,
          NULL AS sort_added,
          NULL AS sort_album,
          NULL AS sort_artist,
          NULL AS sort_release,
          NULL AS sort_genre
          ${isLibrarySizeSort(request.sortMode) ? ', 1 AS sort_size_unknown, 0 AS sort_size' : ''}
        WHERE 0
      ''';
    }
    return parts.join(' UNION ALL ');
  }

  /// Limits a per-album aggregate to the albums of the rows [where] keeps,
  /// so a filtered album page aggregates only those albums. The aggregate
  /// is joined on `album_key`, so any superset of those albums gives the
  /// same rows.
  String _albumKeysIn(
    String table,
    String alias,
    List<String> where, {
    bool and = false,
  }) => where.isEmpty
      ? ''
      : '${and ? 'AND' : 'WHERE'} album_key IN ('
            'SELECT $alias.album_key FROM $table $alias '
            'WHERE ${where.join(' AND ')})';

  /// [albumCompleteness] false leaves out the album completeness filter.
  void _appendQueueHistoryFilters(
    List<String> where,
    List<Object?> args,
    QueueLibraryDbQuery request, {
    bool hasCompletenessJoin = false,
    bool albumCompleteness = true,
  }) {
    if (albumCompleteness) {
      _appendAlbumCompletenessFilter(
        where,
        request,
        albumKey: 'h.album_key',
        hasJoin: hasCompletenessJoin,
      );
    }
    if (request.albumArtist != null) {
      where.add('h.sort_album_artist = ?');
      args.add(sqlite.normalizeLookupText(request.albumArtist));
    }
    final query = sqlite.normalizeLookupText(request.searchQuery);
    if (query.isNotEmpty) {
      final ftsQuery = sqlite.ftsPhraseSearchQuery(query);
      if (historyFts && ftsQuery != null) {
        where.add('''
          h.rowid IN (
            SELECT rowid
            FROM history_db.history_search_fts
            WHERE history_search_fts MATCH ?
          )
          ''');
        args.add(ftsQuery);
      } else {
        final like = '%${_escapeLikePattern(query)}%';
        where.add("h.search_text LIKE ? ESCAPE '\\'");
        args.add(like);
      }
    }
    _appendQueueCommonFilters(
      where,
      args,
      request,
      filePathExpr: 'h.file_path',
      formatExpr: 'h.format',
      qualityExpr: 'h.quality',
      bitDepthExpr: 'h.bit_depth',
      artistExpr: 'h.artist_name',
      albumArtistExpr: 'h.album_artist',
      releaseDateExpr: 'h.release_date',
      genreExpr: 'h.genre',
      trackNumberExpr: 'h.track_number',
      discNumberExpr: 'h.disc_number',
      isrcExpr: 'h.isrc',
      labelExpr: 'h.label',
      hasLyricsExpr: 'h.has_lyrics',
      lyricsKnownExpr: 'COALESCE(h.lyrics_metadata_scan_version, 0) >= 1',
      hasReplayGainExpr: 'h.has_replaygain',
    );
  }

  void _appendQueueLocalFilters(
    List<String> where,
    List<Object?> args,
    QueueLibraryDbQuery request, {
    bool hasCompletenessJoin = false,
    bool albumCompleteness = true,
  }) {
    if (albumCompleteness) {
      _appendAlbumCompletenessFilter(
        where,
        request,
        albumKey: 'l.album_key',
        hasJoin: hasCompletenessJoin,
      );
    }
    if (request.albumArtist != null) {
      where.add('l.album_artist_norm = ?');
      args.add(sqlite.normalizeLookupText(request.albumArtist));
    }
    final query = sqlite.normalizeLookupText(request.searchQuery);
    if (query.isNotEmpty) {
      final ftsQuery = sqlite.ftsPhraseSearchQuery(query);
      if (localFts && ftsQuery != null) {
        where.add('''
          l.id IN (
            SELECT id FROM library WHERE rowid IN (
              SELECT rowid
              FROM library_search_fts
              WHERE library_search_fts MATCH ?
            )
          )
          ''');
        args.add(ftsQuery);
      } else {
        final like = '%${_escapeLikePattern(query)}%';
        where.add("l.search_text LIKE ? ESCAPE '\\'");
        args.add(like);
      }
    }
    _appendQueueCommonFilters(
      where,
      args,
      request,
      filePathExpr: 'l.file_path',
      formatExpr: 'l.format',
      qualityExpr: 'NULL',
      bitDepthExpr: 'l.bit_depth',
      artistExpr: 'l.artist_name',
      albumArtistExpr: 'l.album_artist',
      releaseDateExpr: 'l.release_date',
      genreExpr: 'l.genre',
      trackNumberExpr: 'l.track_number',
      discNumberExpr: 'l.disc_number',
      isrcExpr: 'l.isrc',
      labelExpr: 'l.label',
      hasLyricsExpr: 'l.has_lyrics',
      lyricsKnownExpr:
          'COALESCE(l.audio_metadata_scan_version, 0) >= $libraryLyricsMetadataScanVersion',
      hasReplayGainExpr: 'l.has_replaygain',
    );
  }

  void _appendAlbumCompletenessFilter(
    List<String> where,
    QueueLibraryDbQuery request, {
    required String albumKey,
    required bool hasJoin,
  }) {
    if (!isAlbumCompletenessFilter(request.metadata)) return;
    final status = request.metadata == incompleteAlbumFilter
        ? 'incomplete'
        : 'unknown';
    if (hasJoin) {
      where.add("ac.album_completeness = '$status'");
      return;
    }
    final assessment = albumCompletenessSql(
      albumInventorySql(
        includeLocal: request.includeLocal,
        shadowSnapshot: shadowSnapshot,
      ),
    );
    where.add(
      "$albumKey IN (SELECT album_key FROM ($assessment) WHERE album_completeness = '$status')",
    );
  }

  void _appendQueueCommonFilters(
    List<String> where,
    List<Object?> args,
    QueueLibraryDbQuery request, {
    required String filePathExpr,
    required String? formatExpr,
    required String qualityExpr,
    required String bitDepthExpr,
    required String artistExpr,
    required String albumArtistExpr,
    required String releaseDateExpr,
    required String genreExpr,
    required String trackNumberExpr,
    required String discNumberExpr,
    required String isrcExpr,
    required String labelExpr,
    required String hasLyricsExpr,
    required String lyricsKnownExpr,
    required String hasReplayGainExpr,
  }) {
    if (request.excludeNetwork) {
      where.add("COALESCE($filePathExpr, '') NOT LIKE 'network://%'");
    }
    final quality = request.quality?.trim().toLowerCase();
    if (quality != null && quality.isNotEmpty) {
      final isHiRes =
          '(COALESCE($bitDepthExpr, 0) >= 24 OR LOWER(COALESCE($qualityExpr, \'\')) LIKE \'24%\')';
      final isCd =
          '(COALESCE($bitDepthExpr, 0) = 16 OR LOWER(COALESCE($qualityExpr, \'\')) LIKE \'16%\')';
      switch (quality) {
        case 'hires':
          where.add(isHiRes);
          break;
        case 'cd':
          where.add(isCd);
          break;
        case 'lossy':
          where.add('NOT ($isHiRes OR $isCd)');
          break;
      }
    }

    final format = request.format?.trim().toLowerCase();
    if (format != null && format.isNotEmpty) {
      final aliases = libraryFormatFilterAliases[format] ?? [format];
      final matches = <String>[];
      if (formatExpr != null) {
        matches.add(
          'LOWER(REPLACE(TRIM(COALESCE($formatExpr, \'\')), \'-\', \'_\')) '
          'IN (${List.filled(aliases.length, '?').join(', ')})',
        );
        args.addAll(aliases);
      }
      for (final alias in aliases) {
        matches.add("LOWER($filePathExpr) LIKE ? ESCAPE '\\'");
        args.add('%.${_escapeLikePattern(alias)}');
      }
      where.add('(${matches.join(' OR ')})');
    }

    final metadata = request.metadata?.trim();
    if (metadata == null || metadata.isEmpty) return;
    final hasArtist = 'TRIM(COALESCE($artistExpr, \'\')) != \'\'';
    final hasAlbumArtist = 'TRIM(COALESCE($albumArtistExpr, \'\')) != \'\'';
    final hasReleaseDate =
        'TRIM(COALESCE($releaseDateExpr, \'\')) GLOB \'*[0-9][0-9][0-9][0-9]*\'';
    final hasGenre = 'TRIM(COALESCE($genreExpr, \'\')) != \'\'';
    final hasTrackNumber = 'COALESCE($trackNumberExpr, 0) > 0';
    final hasDiscNumber = 'COALESCE($discNumberExpr, 0) > 0';
    final hasLabel = 'TRIM(COALESCE($labelExpr, \'\')) != \'\'';
    final normalizedIsrc =
        'REPLACE(REPLACE(UPPER(TRIM(COALESCE($isrcExpr, \'\'))), \'-\', \'\'), \' \', \'\')';
    final hasIncorrectIsrc =
        'TRIM(COALESCE($isrcExpr, \'\')) != \'\' AND LENGTH($normalizedIsrc) != 12';
    final isComplete =
        '($hasArtist AND $hasAlbumArtist AND $hasReleaseDate AND $hasGenre AND $hasTrackNumber AND $hasDiscNumber AND $hasLabel AND NOT ($hasIncorrectIsrc))';

    switch (metadata) {
      case 'complete':
        where.add(isComplete);
        break;
      case 'missing-any':
        where.add('NOT $isComplete');
        break;
      case 'missing-year':
        where.add('NOT ($hasReleaseDate)');
        break;
      case 'missing-genre':
        where.add('NOT ($hasGenre)');
        break;
      case 'missing-album-artist':
        where.add('NOT ($hasAlbumArtist)');
        break;
      case 'missing-track-number':
        where.add('NOT ($hasTrackNumber)');
        break;
      case 'missing-disc-number':
        where.add('NOT ($hasDiscNumber)');
        break;
      case 'missing-artist':
        where.add('NOT ($hasArtist)');
        break;
      case 'incorrect-isrc-format':
        where.add('($hasIncorrectIsrc)');
        break;
      case 'missing-isrc':
        where.add('TRIM(COALESCE($isrcExpr, \'\')) = \'\'');
        break;
      case 'missing-label':
        where.add('NOT ($hasLabel)');
        break;
      case 'missing-lyrics':
        // A default false value on legacy rows means "not scanned yet", not
        // "confirmed missing". Only show files whose lyrics probe completed.
        where.add(
          confirmedMissingLyricsSqlPredicate(
            hasLyricsExpr: hasLyricsExpr,
            lyricsKnownExpr: lyricsKnownExpr,
          ),
        );
        break;
      case 'has-replaygain':
        where.add('COALESCE($hasReplayGainExpr, 0) != 0');
        break;
      case 'missing-replaygain':
        // Include legacy rows without indexed ReplayGain as candidates until
        // a metadata refresh confirms their tags. Requiring a new scan version
        // hides the entire older collection before it has been rescanned.
        where.add(
          missingReplayGainSqlPredicate(hasReplayGainExpr: hasReplayGainExpr),
        );
        break;
    }
  }

  String _boundedQueuePart(
    String selectSql,
    QueueLibraryDbQuery request,
    List<Object?> args,
    List<_QueueOrderTerm> orderTerms, {
    required bool usesCursor,
  }) {
    final cursorPredicate = usesCursor
        ? _queueCursorPredicate(request.cursor, orderTerms, args)
        : '';
    final branchLimit = usesCursor
        ? request.limit
        : request.limit + request.offset;
    args.add(branchLimit);
    final branchOrder = orderTerms
        .where((term) => term.column != 'queue_source')
        .toList(growable: false);
    return '''
      SELECT * FROM (
        SELECT *
        FROM ($selectSql)
        ${cursorPredicate.isEmpty ? '' : 'WHERE $cursorPredicate'}
        ORDER BY ${_queueOrderBy(branchOrder)}
        LIMIT ?
      )
    ''';
  }

  String _sizeJoin(String sortMode, String schema, String alias) =>
      isLibrarySizeSort(sortMode)
      ? 'LEFT JOIN $schema.track_file_sizes file_sizes ON file_sizes.item_id = $alias.id'
      : '';

  String _trackSizeColumns(String sortMode) => isLibrarySizeSort(sortMode)
      ? ', file_sizes.size_bytes AS file_size_bytes, '
            '(file_sizes.size_bytes IS NULL) AS sort_size_unknown, '
            'COALESCE(file_sizes.size_bytes, 0) AS sort_size'
      : '';

  String _albumSizeColumns(String sortMode) => isLibrarySizeSort(sortMode)
      ? ', (COUNT(file_sizes.size_bytes) < COUNT(*)) AS sort_size_unknown, '
            'COALESCE(SUM(file_sizes.size_bytes), 0) AS sort_size'
      : '';

  /// Leading sort terms, then [nameColumn], the source and [keyColumn] as the
  /// unique tie-breakers that keyset cursors seek on.
  List<_QueueOrderTerm> _queueOrderTerms(
    String sortMode,
    String nameColumn,
    String keyColumn,
  ) {
    final name = _QueueOrderTerm(nameColumn);
    return [
      ...switch (sortMode) {
        'size-asc' || 'size-desc' => [
          const _QueueOrderTerm('sort_size_unknown'),
          _QueueOrderTerm('sort_size', descending: sortMode == 'size-desc'),
          name,
        ],
        'a-z' || 'z-a' => [
          _QueueOrderTerm(nameColumn, descending: sortMode == 'z-a'),
          _QueueOrderTerm('sort_artist', descending: sortMode == 'z-a'),
        ],
        'oldest' => [const _QueueOrderTerm('sort_added'), name],
        'artist-asc' || 'artist-desc' => [
          _QueueOrderTerm('sort_artist', descending: sortMode == 'artist-desc'),
          name,
        ],
        'album-asc' || 'album-desc' => [
          _QueueOrderTerm('sort_album', descending: sortMode == 'album-desc'),
          name,
        ],
        'release-oldest' || 'release-newest' => [
          _QueueOrderTerm(
            'sort_release',
            descending: sortMode == 'release-newest',
          ),
          name,
        ],
        'genre-asc' || 'genre-desc' => [
          _QueueOrderTerm('sort_genre', descending: sortMode == 'genre-desc'),
          name,
        ],
        _ => [const _QueueOrderTerm('sort_added', descending: true), name],
      },
      const _QueueOrderTerm('queue_source'),
      _QueueOrderTerm(keyColumn),
    ];
  }

  String _queueOrderBy(List<_QueueOrderTerm> terms) => terms
      .map((term) => '${term.column} ${term.descending ? 'DESC' : 'ASC'}')
      .join(', ');

  String _queueCursorPredicate(
    QueueLibraryDbCursor? cursor,
    List<_QueueOrderTerm> terms,
    List<Object?> args,
  ) {
    if (cursor == null || cursor.values.length != terms.length) return '';
    final clauses = <String>[];
    final first = terms.first;
    final coarseOperator = first.descending ? '<=' : '>=';
    args.add(cursor.values.first);
    for (var i = 0; i < terms.length; i++) {
      final comparisons = <String>[];
      for (var j = 0; j < i; j++) {
        comparisons.add('${terms[j].column} = ?');
        args.add(cursor.values[j]);
      }
      comparisons.add(
        '${terms[i].column} ${terms[i].descending ? '<' : '>'} ?',
      );
      args.add(cursor.values[i]);
      clauses.add('(${comparisons.join(' AND ')})');
    }
    return '(${first.column} $coarseOperator ?) AND (${clauses.join(' OR ')})';
  }

  QueueLibraryDbCursor? _queueCursorFromRow(
    Map<String, dynamic>? row,
    List<_QueueOrderTerm> terms,
  ) {
    if (row == null) return null;
    final values = <Object>[];
    for (final term in terms) {
      final value = row[term.column];
      if (value is! Object) return null;
      values.add(value);
    }
    return QueueLibraryDbCursor(List<Object>.unmodifiable(values));
  }

  Map<String, dynamic> _queueTrackRowToJson(Map<String, dynamic> row) {
    final source = row['queue_source'] as String? ?? '';
    final item = <String, dynamic>{
      'id': row['id'],
      'trackName': row['track_name'],
      'artistName': row['artist_name'],
      'albumName': row['album_name'],
      'albumArtist': row['album_artist'],
      'filePath': row['file_path'],
      'fileSize': row['file_size_bytes'],
      'isrc': row['isrc'],
      'trackNumber': row['track_number'],
      'totalTracks': row['total_tracks'],
      'discNumber': row['disc_number'],
      'totalDiscs': row['total_discs'],
      'duration': row['duration'],
      'releaseDate': row['release_date'],
      'bitDepth': row['bit_depth'],
      'sampleRate': row['sample_rate'],
      'bitrate': row['bitrate'],
      'format': row['format'],
      'hasReplayGain':
          row['has_replaygain'] == 1 || row['has_replaygain'] == true,
      'genre': row['genre'],
      'composer': row['composer'],
      'label': row['label'],
      'copyright': row['copyright'],
      if (source == 'local') ...{
        'coverPath': row['cover_path'],
        'scannedAt': row['scanned_at'],
        'fileModTime': row['file_mod_time'],
      } else ...{
        'coverUrl': row['cover_url'],
        'storageMode': row['storage_mode'],
        'downloadTreeUri': row['download_tree_uri'],
        'safRelativeDir': row['saf_relative_dir'],
        'safFileName': row['saf_file_name'],
        'safRepaired': row['saf_repaired'] == 1 || row['saf_repaired'] == true,
        'service': row['service'],
        'downloadedAt': row['downloaded_at'],
        'spotifyId': row['spotify_id'],
        'quality': row['quality'],
        'replayGainMetadataScanVersion':
            row['replaygain_metadata_scan_version'] ?? 0,
      },
    };
    return {'source': source, 'item': item};
  }
}
