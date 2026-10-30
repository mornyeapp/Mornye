import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/sqlite_helpers.dart'
    show libraryNotShadowedSql, libraryShadowTable;

enum LibrarySearchKind { songs, albums, artists, playlists }

/// Each word must match, but words can occur in different metadata fields and
/// in any order. Punctuation is a separator, never a SQL/FTS operator.
class LibrarySearchQuery {
  LibrarySearchQuery(String text)
    : text = text.trim().toLowerCase(),
      terms = RegExp(r'[\p{L}\p{N}]+', unicode: true)
          .allMatches(text.toLowerCase())
          .map((match) => match.group(0)!)
          .toSet()
          .toList(growable: false);

  final String text;
  final List<String> terms;

  bool matches(String value) {
    final normalized = value.toLowerCase();
    return terms.isNotEmpty && terms.every(normalized.contains);
  }

  int rank(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == text) return 0;
    if (normalized.startsWith(text)) return 1;
    if (normalized.contains(text)) return 2;
    return 3;
  }

  String predicate(
    String column,
    List<Object?> args, {
    String? rowId,
    String? ftsTable,
    String? ftsContentTable,
  }) {
    if (terms.isEmpty) return '0';
    final indexed = ftsTable == null
        ? const <String>[]
        : terms.where((term) => term.runes.length >= 3).toList();
    final predicates = <String>[];
    if (indexed.isNotEmpty) {
      final tableName = ftsTable!.split('.').last;
      final matches = 'SELECT rowid FROM $ftsTable WHERE $tableName MATCH ?';
      predicates.add(
        '$rowId IN (${ftsContentTable == null ? matches : 'SELECT id FROM $ftsContentTable WHERE rowid IN ($matches)'})',
      );
      args.add(indexed.map((term) => '"$term"').join(' AND '));
    }
    for (final term in terms) {
      if (indexed.contains(term)) continue;
      predicates.add("$column LIKE ? ESCAPE '\\'");
      args.add('%$term%');
    }
    return predicates.join(' AND ');
  }

  String orderBy(String column, List<Object?> args) {
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    args.addAll([text, '$escaped%', '%$escaped%']);
    return '''CASE WHEN $column = ? THEN 0
      WHEN $column LIKE ? ESCAPE '\\' THEN 1
      WHEN $column LIKE ? ESCAPE '\\' THEN 2 ELSE 3 END''';
  }
}

class LibrarySearchHit {
  const LibrarySearchHit({
    required this.kind,
    required this.id,
    required this.title,
    this.artist = '',
    this.source = '',
    this.cover,
    this.samplePath = '',
    this.trackCount = 0,
  });

  final LibrarySearchKind kind;
  final String id;
  final String title;
  final String artist;
  final String source;
  final String? cover;
  final String samplePath;
  final int trackCount;

  factory LibrarySearchHit.fromRow(
    LibrarySearchKind kind,
    Map<String, Object?> row,
  ) => LibrarySearchHit(
    kind: kind,
    id: row['id'] as String,
    title: row['title'] as String? ?? '',
    artist: row['artist'] as String? ?? '',
    source: row['source'] as String? ?? '',
    cover: row['cover'] as String?,
    samplePath: row['sample_path'] as String? ?? '',
    trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
  );
}

/// Runs bounded, ranked searches in SQLite instead of copying the Library into
/// Dart. The caller supplies the Library connection with history_db attached.
class LibrarySearchStore {
  const LibrarySearchStore(
    this.db, {
    required this.historyFts,
    required this.localFts,
    this.shadowSnapshot = false,
  });

  final DatabaseExecutor db;
  final bool historyFts;
  final bool localFts;

  /// Whether the connection holds a current [libraryShadowTable].
  final bool shadowSnapshot;

  Future<List<LibrarySearchHit>> search({
    required String query,
    required LibrarySearchKind kind,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async {
    final search = LibrarySearchQuery(query);
    if (search.terms.isEmpty || kind == LibrarySearchKind.playlists) return [];
    final args = <Object?>[];
    final parts = <String>[];
    for (final local in [false, if (includeLocal) true]) {
      final alias = local ? 'l' : 'h';
      final source = local ? 'local' : 'downloaded';
      final table = local ? 'library_visible' : 'history_db.history';
      final artist = local ? 'album_artist_norm' : 'sort_album_artist';
      final album = local ? 'album_name_norm' : 'sort_album';
      final title = local ? 'track_name_norm' : 'sort_track';
      final where = <String>[
        if (local) libraryNotShadowedSql('l', snapshot: shadowSnapshot),
      ];
      final column = switch (kind) {
        LibrarySearchKind.songs => '$alias.search_text',
        LibrarySearchKind.albums => "$alias.$album || ' ' || $alias.$artist",
        LibrarySearchKind.artists => '$alias.$artist',
        LibrarySearchKind.playlists => throw StateError('Not a track index'),
      };
      where.add(
        search.predicate(
          column,
          args,
          // Views do not expose their underlying table's implicit rowid.
          rowId: local ? '$alias.id' : '$alias.rowid',
          ftsContentTable: local ? 'library' : null,
          ftsTable: kind != LibrarySearchKind.songs
              ? null
              : local
              ? (localFts ? 'library_search_fts' : null)
              : (historyFts ? 'history_db.history_search_fts' : null),
        ),
      );
      parts.add('''
        SELECT '$source' AS source, $alias.id, $alias.track_name AS title,
          $alias.artist_name AS artist, $alias.album_name AS album,
          COALESCE(NULLIF($alias.album_artist, ''), $alias.artist_name) AS album_artist,
          $alias.album_key, $alias.$title AS title_key,
          $alias.$album AS album_sort, $alias.$artist AS artist_key,
          ${local ? '$alias.cover_path' : '$alias.cover_url'} AS cover,
          $alias.file_path AS sample_path
        FROM $table $alias WHERE ${where.join(' AND ')}
      ''');
    }
    final rows = '(${parts.join(' UNION ALL ')})';
    // Album predicates use only album-level fields, preserving full track
    // counts. Keep downloaded/local albums separate, as their detail screens
    // resolve tracks from different stores. Artists merge both sources.
    final select = switch (kind) {
      LibrarySearchKind.songs => 'SELECT *, 1 AS track_count FROM $rows',
      LibrarySearchKind.albums =>
        '''
        SELECT source, album_key AS id, MIN(album) AS title,
          MIN(album_artist) AS artist, MAX(NULLIF(cover, '')) AS cover,
          MAX(sample_path) AS sample_path, COUNT(*) AS track_count,
          MIN(album_sort) AS title_key
        FROM $rows WHERE album_sort != '' GROUP BY source, album_key''',
      LibrarySearchKind.artists =>
        '''
        SELECT '' AS source, artist_key AS id, MIN(album_artist) AS title,
          MIN(album_artist) AS artist, MAX(NULLIF(cover, '')) AS cover,
          MAX(sample_path) AS sample_path, COUNT(*) AS track_count,
          artist_key AS title_key
        FROM $rows WHERE artist_key != '' GROUP BY artist_key''',
      LibrarySearchKind.playlists => throw StateError('Not a track index'),
    };
    final rank = search.orderBy('title_key', args);
    final result = await db.rawQuery(
      '''
      SELECT * FROM ($select)
      ORDER BY $rank, title_key, artist, source, id
      LIMIT ? OFFSET ?
    ''',
      [...args, limit, offset],
    );
    return result.map((row) => LibrarySearchHit.fromRow(kind, row)).toList();
  }
}
