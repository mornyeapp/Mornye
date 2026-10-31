import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// Android reads query results row by row through a cursor window of about
/// 2 MB (less on some devices) and fails on a row that does not fit. Text
/// that can grow past this many bytes is read in pieces of this size.
const longTextPieceBytes = 524288;

/// Selects [column] as [alias] only when it fits one piece (else null), and
/// its size in bytes as `<alias>_bytes`, so no row returned is too long.
String selectShortText(String column, String alias) =>
    'CASE WHEN length(CAST($column AS BLOB)) <= $longTextPieceBytes '
    'THEN $column END AS $alias, '
    'length(CAST($column AS BLOB)) AS ${alias}_bytes';

/// The first row of [table] with [columns] and `<jsonColumn>_bytes`, and
/// [json], which gives [jsonColumn] decoded (null for NULL) or throws its
/// decode error. Text that fits one piece comes in the same single read and
/// decodes when [json] is called; longer text is read in pieces and decoded
/// on another isolate.
Future<({Map<String, Object?> row, Object? Function() json})?> readJsonTextRow(
  DatabaseExecutor db, {
  required String table,
  required String jsonColumn,
  required List<String> columns,
}) async {
  final rows = await db.rawQuery(
    'SELECT ${[...columns, 'rowid AS long_text_rowid', selectShortText(jsonColumn, jsonColumn)].join(', ')} '
    'FROM $table LIMIT 1',
  );
  if (rows.isEmpty) return null;
  final row = rows.single;
  final text = row[jsonColumn] as String?;
  if (text != null || (row['${jsonColumn}_bytes'] as int? ?? 0) == 0) {
    return (row: row, json: () => text == null ? null : jsonDecode(text));
  }
  final long = await readLongTextRow(
    db,
    table: table,
    rowid: row['long_text_rowid'] as int,
    textColumn: jsonColumn,
    columns: [
      ...columns,
      'length(CAST($jsonColumn AS BLOB)) AS ${jsonColumn}_bytes',
    ],
    decode: _tryJsonDecode,
  );
  if (long == null) return null;
  final (longRow, (value, error)) = long;
  return (
    row: longRow,
    json: () {
      if (error != null) throw error;
      return value;
    },
  );
}

(Object?, FormatException?) _tryJsonDecode(String text) {
  try {
    return (jsonDecode(text), null);
  } on FormatException catch (error) {
    return (null, error);
  }
}

/// Reads [columns] and the long [textColumn] of the row of [table] with
/// [rowid] in one transaction, the text in pieces, and returns the columns
/// with [decode] of the text, decoded on another isolate. Null when the row
/// is gone.
Future<(Map<String, Object?>, T)?> readLongTextRow<T>(
  DatabaseExecutor db, {
  required String table,
  required int rowid,
  required String textColumn,
  List<String> columns = const [],
  required T Function(String text) decode,
}) async {
  Future<(Map<String, Object?>, Uint8List, String)?> read(
    DatabaseExecutor txn,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT ${[...columns, 'length(CAST($textColumn AS BLOB)) AS long_text_bytes'].join(', ')} '
      'FROM $table WHERE rowid = ?',
      [rowid],
    );
    if (rows.isEmpty) return null;
    final length = rows.single['long_text_bytes'] as int? ?? 0;
    final text = BytesBuilder(copy: false);
    for (var start = 1; start <= length; start += longTextPieceBytes) {
      final piece = await txn.rawQuery(
        'SELECT substr(CAST($textColumn AS BLOB), ?, $longTextPieceBytes) '
        'AS piece FROM $table WHERE rowid = ?',
        [start, rowid],
      );
      text.add(piece.single['piece'] as Uint8List);
    }
    final encoding = await txn.rawQuery('PRAGMA encoding');
    return (
      rows.single,
      text.takeBytes(),
      encoding.single.values.single as String,
    );
  }

  final stored = db is Database ? await db.transaction(read) : await read(db);
  if (stored == null) return null;
  final (row, bytes, encoding) = stored;
  return (row, await _decodeElsewhere(bytes, encoding, decode));
}

Future<T> _decodeElsewhere<T>(
  Uint8List bytes,
  String encoding,
  T Function(String text) decode,
) async {
  T run() => decode(_decodeText(bytes, encoding));
  try {
    return await Isolate.run(run);
  } on IsolateSpawnException {
    return run();
  }
}

/// [bytes] of text read as a BLOB, which SQLite gives in the database
/// encoding.
String _decodeText(Uint8List bytes, String encoding) {
  if (encoding == 'UTF-8') return utf8.decode(bytes, allowMalformed: true);
  final data = ByteData.sublistView(bytes);
  final endian = encoding == 'UTF-16be' ? Endian.big : Endian.little;
  return String.fromCharCodes([
    for (var i = 0; i + 1 < bytes.length; i += 2) data.getUint16(i, endian),
  ]);
}
