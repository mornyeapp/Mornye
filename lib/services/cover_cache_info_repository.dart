import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The cover cache index in the file format of flutter_cache_manager's
/// [JsonCacheInfoRepository], so older and newer builds read each other's
/// index.
///
/// The file is read in a worker isolate. Lookups go by key, each row keeps
/// its encoded JSON until it changes, and the file is saved [saveDelay] after
/// an insert, delete or content update, or [touchSaveDelay] after a change of
/// only the last-used time. [flush] and [close] save pending changes at once.
/// Nothing is saved unless the file was read or found missing.
class CoverCacheInfoRepository extends CacheInfoRepository {
  /// [encodeRow] encodes one index row and [runInWorker] runs the read off
  /// the UI isolate; tests count calls through the first and fail the second.
  CoverCacheInfoRepository(
    this._resolveFile, {
    this.saveDelay = const Duration(seconds: 1),
    this.touchSaveDelay = const Duration(seconds: 30),
    String Function(Map<String, dynamic> row) encodeRow = jsonEncode,
    Future<T> Function<T>(FutureOr<T> Function() computation) runInWorker =
        Isolate.run,
  }) : _encodeRow = encodeRow,
       _runInWorker = runInWorker;

  final Future<File> Function() _resolveFile;
  final Duration saveDelay;
  final Duration touchSaveDelay;
  final String Function(Map<String, dynamic> row) _encodeRow;
  final Future<T> Function<T>(FutureOr<T> Function() computation) _runInWorker;

  _Index _index = _Index();
  File? _file;
  int _connections = 0;
  Completer<bool>? _opened;
  bool _dirty = false;
  Timer? _saveTimer;
  bool _saveTimerIsShort = false;
  Future<void> _writes = Future<void>.value();

  @override
  Future<bool> open() async {
    _connections++;
    final opened = _opened ??= Completer<bool>();
    if (_connections != 1) return opened.future;
    await _load();
    opened.complete(true);
    return true;
  }

  @override
  Future<CacheObject?> get(String key) async => _index.objects[key];

  @override
  Future<List<CacheObject>> getAllObjects() async =>
      _index.objects.values.toList();

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    if (cacheObject.id != null) {
      throw ArgumentError("Inserted objects shouldn't have an existing id.");
    }
    return _put(cacheObject.copyWith(id: _index.lastId + 1), setTouchedToNow);
  }

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    if (cacheObject.id == null) {
      throw ArgumentError('Updated objects should have an existing id.');
    }
    _put(cacheObject, setTouchedToNow);
    return 1;
  }

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) {
    return cacheObject.id == null ? insert(cacheObject) : update(cacheObject);
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async {
    if (_index.objects.length <= capacity) return [];
    final allSorted = _index.objects.values.toList()
      ..sort((c1, c2) => c1.touched!.compareTo(c2.touched!));
    return allSorted.getRange(0, allSorted.length - capacity).toList();
  }

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async {
    final oldestTimestamp = DateTime.now().subtract(maxAge);
    return _index.objects.values
        .where((element) => element.touched!.isBefore(oldestTimestamp))
        .toList();
  }

  @override
  Future<int> delete(int id) async {
    if (!_index.remove(id)) return 0;
    _scheduleSave(short: true);
    return 1;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    var deleted = 0;
    for (final id in ids) {
      if (_index.remove(id)) deleted++;
    }
    if (deleted > 0) _scheduleSave(short: true);
    return deleted;
  }

  @override
  Future<bool> close() async {
    _connections--;
    if (_connections == 0) _opened = null;
    await flush();
    return _connections == 0;
  }

  /// Saves pending changes now; completes once they are on disk.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_dirty) _writes = _writes.then((_) => _write());
    return _writes;
  }

  @override
  Future<void> deleteDataFile() async {
    final file = await _resolveFile();
    if (await file.exists()) {
      await file.delete();
    }
    final tempFile = File('${file.path}.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }

  @override
  Future<bool> exists() async {
    final file = await _resolveFile();
    return file.exists();
  }

  Future<void> _load() async {
    await _writes;
    _index = _Index();
    _file = null;
    final File file;
    try {
      file = await _resolveFile();
      await file.parent.create(recursive: true);
    } on Object catch (error) {
      // Without the file, changes stay in memory: a later save would replace
      // an index this session never read.
      debugPrint('CoverCacheInfoRepository: Index unavailable: $error');
      return;
    }
    final path = file.path;
    _IndexFile read;
    try {
      read = await _runInWorker(() => _readIndexFile(path));
    } on Object {
      // A worker that cannot start must not cost the index.
      read = _readIndexFile(path);
    }
    // An unreadable file stays as it is; changes stay in memory.
    if (read.index case final index?) {
      _file = file;
      _index = index;
    }
    final error = read.error;
    if (error != null) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: read.stack,
          library: 'flutter cache manager',
          context: ErrorDescription(
            'Thrown when reading the file containing cache info. '
            'The cached files cannot be used by the cache manager anymore.',
          ),
        ),
      );
    }
  }

  CacheObject _put(CacheObject cacheObject, bool setTouchedToNow) {
    final id = cacheObject.id!;
    final row = cacheObject.toMap(setTouchedToNow: setTouchedToNow);
    final stored = CacheObject.fromMap(row);
    final change = _changeOf(_index.rows[id], row);
    _index.set(
      stored,
      row,
      change == _RowChange.none ? _index.encodedRows[id] : null,
    );
    if (change != _RowChange.none) {
      _scheduleSave(short: change == _RowChange.content);
    }
    return stored;
  }

  static _RowChange _changeOf(
    Map<String, dynamic>? previous,
    Map<String, dynamic> next,
  ) {
    if (previous == null || previous.length != next.length) {
      return _RowChange.content;
    }
    var touched = false;
    for (final MapEntry(:key, :value) in next.entries) {
      if (!previous.containsKey(key)) return _RowChange.content;
      if (previous[key] == value) continue;
      if (key != CacheObject.columnTouched) return _RowChange.content;
      touched = true;
    }
    return touched ? _RowChange.touch : _RowChange.none;
  }

  void _scheduleSave({required bool short}) {
    _dirty = true;
    if (_saveTimer != null && (_saveTimerIsShort || !short)) return;
    _saveTimer?.cancel();
    _saveTimerIsShort = short;
    _saveTimer = Timer(short ? saveDelay : touchSaveDelay, () {
      _saveTimer = null;
      unawaited(flush());
    });
  }

  Future<void> _write() async {
    final file = _file;
    if (!_dirty || file == null) return;
    _dirty = false;
    final encodedRows = _index.encodedRows;
    final content = BytesBuilder(copy: false)..addByte(0x5b);
    var first = true;
    for (final MapEntry(:key, :value) in _index.rows.entries) {
      if (!first) content.addByte(0x2c);
      first = false;
      content.add(encodedRows[key] ??= utf8.encode(_encodeRow(value)));
    }
    content.addByte(0x5d);
    try {
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsBytes(content.takeBytes(), flush: true);
      await tempFile.rename(file.path);
    } on Object catch (e, stacktrace) {
      // Keep the changes dirty so a later change or close retries the write.
      _dirty = true;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stacktrace,
          library: 'flutter cache manager',
          context: ErrorDescription(
            'Thrown when writing the file containing cache info. '
            'The cache info could not be persisted and may be lost when the '
            'app is closed.',
          ),
        ),
      );
    }
  }
}

enum _RowChange { none, touch, content }

/// Rows by id in file order, with their encoded JSON, and objects by key.
class _Index {
  final Map<int, Map<String, dynamic>> rows = {};
  final Map<int, Uint8List> encodedRows = {};
  final Map<String, CacheObject> objects = {};
  final Map<int, String> keys = {};
  int lastId = 0;

  void set(CacheObject object, Map<String, dynamic> row, Uint8List? json) {
    final id = object.id!;
    rows[id] = row;
    if (json == null) {
      encodedRows.remove(id);
    } else {
      encodedRows[id] = json;
    }
    final previous = objects[object.key];
    if (previous != null && previous.id != id) keys.remove(previous.id);
    final previousKey = keys[id];
    if (previousKey != null && previousKey != object.key) {
      objects.remove(previousKey);
    }
    objects[object.key] = object;
    keys[id] = object.key;
    if (id > lastId) lastId = id;
  }

  bool remove(int id) {
    final key = keys.remove(id);
    if (key == null) return false;
    objects.remove(key);
    rows.remove(id);
    encodedRows.remove(id);
    return true;
  }
}

class _IndexFile {
  const _IndexFile(_Index this.index, [this.error, this.stack]);

  const _IndexFile.unreadable(this.error, this.stack) : index = null;

  /// Null when the file could not be read at all.
  final _Index? index;
  final Object? error;
  final StackTrace? stack;
}

/// Runs in a worker isolate, or inline if none can start. Keeps the rows read
/// before a bad one, as [JsonCacheInfoRepository] does; a file that could
/// not be read at all is unreadable, not empty.
_IndexFile _readIndexFile(String path) {
  final file = File(path);
  final Uint8List bytes;
  try {
    if (!file.existsSync()) return _IndexFile(_Index());
    bytes = file.readAsBytesSync();
  } on Object catch (error, stack) {
    return _IndexFile.unreadable(error, StackTrace.fromString('$stack'));
  }
  final index = _Index();
  try {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      // The error File.readAsStringSync reports for the same bytes.
      throw FileSystemException(
        "Failed to decode data using encoding 'utf-8'",
        path,
      );
    }
    final json = jsonDecode(text) as List<dynamic>;
    for (final element in json) {
      if (element is! Map<String, dynamic>) continue;
      index.set(
        CacheObject.fromMap(element),
        element,
        utf8.encode(jsonEncode(element)),
      );
    }
    return _IndexFile(index);
  } on Object catch (error, stack) {
    return _IndexFile(index, error, StackTrace.fromString(stack.toString()));
  }
}
