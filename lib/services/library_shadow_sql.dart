/// TEMP pairs of a Library row and the History row whose path keys match it:
/// the scanned files a download already holds. `LibraryShadowSnapshot` in
/// sqlite_helpers.dart keeps it on the Library connection.
const libraryShadowTable = 'temp.library_shadowed';

/// The Library row [alias] is not shadowed by a downloaded History file.
/// [snapshot] reads [libraryShadowTable] instead of probing every path key
/// of the row; both select the same rows.
String libraryNotShadowedSql(String alias, {bool snapshot = false}) => snapshot
    ? '''
  NOT EXISTS (
    SELECT 1 FROM $libraryShadowTable shadow WHERE shadow.item_id = $alias.id
  )'''
    : '''
  NOT EXISTS (
    SELECT 1
    FROM library_path_keys lpk
    JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
    WHERE lpk.item_id = $alias.id
    UNION ALL
    SELECT 1 FROM history_db.history offline
    WHERE offline.origin_file_path = $alias.file_path
  )''';
