import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('ReEnrichUndo');

/// What a song held before its latest re-enrich, for the tags, cover and
/// lyrics that re-enrich wrote.
class ReEnrichUndoState {
  const ReEnrichUndoState({
    required this.source,
    required this.savedAt,
    this.tags = const {},
    this.cover,
    this.coverAdded = false,
    this.lrc,
    this.batch,
  });

  factory ReEnrichUndoState.fromJson(Map<String, dynamic> json) =>
      ReEnrichUndoState(
        source: json['source'] as String,
        savedAt: DateTime.parse(json['savedAt'] as String),
        tags: {
          for (final entry in (json['tags'] as Map? ?? const {}).entries)
            entry.key.toString(): entry.value?.toString() ?? '',
        },
        cover: json['cover'] as String?,
        coverAdded: json['coverAdded'] == true,
        lrc: json['lrc'] as String?,
        batch: json['batch'] as String?,
      );

  /// The song's file, as re-enrich wrote it.
  final String source;
  final DateTime savedAt;

  /// Metadata editor keys with the values to write back. An empty value
  /// clears a tag that re-enrich filled.
  final Map<String, String> tags;

  /// The stored name of the cover the song had, when re-enrich replaced it.
  final String? cover;

  /// Re-enrich wrote a cover where the song had none. A cover cannot be
  /// removed from a file, so undo leaves that one in place.
  final bool coverAdded;

  /// The `.lrc` text next to the song before re-enrich wrote it, empty when
  /// there was none, or null when undo leaves the sidecar as it is.
  final String? lrc;

  /// The re-enrich run that saved this state.
  final String? batch;

  ReEnrichUndoState _withCover(String cover) => ReEnrichUndoState(
    source: source,
    savedAt: savedAt,
    tags: tags,
    cover: cover,
    coverAdded: coverAdded,
    lrc: lrc,
    batch: batch,
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'savedAt': savedAt.toIso8601String(),
    'tags': tags,
    'cover': ?cover,
    if (coverAdded) 'coverAdded': true,
    'lrc': ?lrc,
    'batch': ?batch,
  };
}

class _Saved {
  const _Saved(this.savedAt, this.bytes, this.cover);

  final DateTime savedAt;
  final int bytes;
  final String? cover;
}

/// One previous state per song, in app storage. The states saved longest
/// ago leave first once more than [maxSongs] are kept or they take more than
/// [maxBytes]. Songs sharing a cover, such as an album's, store it once.
class ReEnrichUndoStore {
  ReEnrichUndoStore({
    Future<Directory> Function()? directory,
    this.maxSongs = 2000,
    this.maxBytes = 200 * 1024 * 1024,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  static final instance = ReEnrichUndoStore();

  final Future<Directory> Function() _directory;
  final int maxSongs;
  final int maxBytes;

  /// State file names to what they hold, loaded on the first save.
  Map<String, _Saved>? _index;
  final Map<String, int> _coverBytes = {};

  /// The last queued task, while any is unfinished. An idle store starts a
  /// task at once instead of chaining it to an old, finished future.
  Future<void>? _tail;
  int _queued = 0;

  Future<T> _serial<T>(Future<T> Function() task) {
    final previous = _queued == 0 ? null : _tail;
    _queued++;
    final result = previous == null
        ? Future.sync(task)
        : previous.then((_) => task());
    _tail = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _queued--);
    return result;
  }

  Future<String> get _root async =>
      p.join((await _directory()).path, 'reenrich_undo');

  static String _key(String source) {
    final path = source.startsWith('EXISTS:') ? source.substring(7) : source;
    return sha1.convert(utf8.encode(path)).toString();
  }

  Future<File> _stateFile(String key) async =>
      File(p.join(await _root, 'songs', '$key.json'));

  Future<File> _coverFile(String name) async =>
      File(p.join(await _root, 'covers', name));

  /// The state saved for [source], or null when there is none.
  Future<ReEnrichUndoState?> read(String source) => _serial(() async {
    try {
      final file = await _stateFile(_key(source));
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      return ReEnrichUndoState.fromJson(json as Map<String, dynamic>);
    } catch (error) {
      _log.w('Ignoring a saved re-enrich state: ${error.runtimeType}');
      return null;
    }
  });

  Future<bool> contains(String source) async => await read(source) != null;

  /// The previous cover saved with [state], or null when it has none.
  Future<String?> coverPath(ReEnrichUndoState state) async {
    final name = state.cover;
    if (name == null) return null;
    final file = await _coverFile(name);
    return await file.exists() ? file.path : null;
  }

  /// Saves [state] in place of the song's earlier one, keeping a copy of
  /// [coverFile] as the cover it had.
  Future<void> save(ReEnrichUndoState state, {String? coverFile}) =>
      _serial(() async {
        final index = await _loadIndex();
        var saved = state;
        if (coverFile != null) {
          final bytes = await File(coverFile).readAsBytes();
          final name = '${sha1.convert(bytes)}${_imageExtension(bytes)}';
          final target = await _coverFile(name);
          if (!await target.exists()) {
            await _writeAtomically(target, bytes);
          }
          _coverBytes[name] = bytes.length;
          saved = state._withCover(name);
        }
        final key = _key(state.source);
        final json = utf8.encode(jsonEncode(saved.toJson()));
        await _writeAtomically(await _stateFile(key), json);
        final previous = index[key];
        index[key] = _Saved(saved.savedAt, json.length, saved.cover);
        await _dropUnusedCover(previous?.cover);
        final oldest = index.entries.where((entry) => entry.key != key).toList()
          ..sort((a, b) => a.value.savedAt.compareTo(b.value.savedAt));
        for (final entry in oldest) {
          if (index.length <= maxSongs && _totalBytes <= maxBytes) break;
          await _delete(entry.key);
        }
      });

  /// Forgets the state saved for [source].
  Future<void> remove(String source) => _serial(() async {
    await _loadIndex();
    await _delete(_key(source));
  });

  int get _totalBytes =>
      _index!.values.fold(0, (total, saved) => total + saved.bytes) +
      _coverBytes.values.fold(0, (total, bytes) => total + bytes);

  Future<void> _delete(String key) async {
    final removed = _index!.remove(key);
    try {
      final file = await _stateFile(key);
      if (await file.exists()) await file.delete();
    } catch (error) {
      _log.w('Could not delete a re-enrich state: ${error.runtimeType}');
    }
    await _dropUnusedCover(removed?.cover);
  }

  Future<void> _dropUnusedCover(String? name) async {
    if (name == null || _index!.values.any((saved) => saved.cover == name)) {
      return;
    }
    _coverBytes.remove(name);
    try {
      final file = await _coverFile(name);
      if (await file.exists()) await file.delete();
    } catch (error) {
      _log.w('Could not delete a re-enrich cover: ${error.runtimeType}');
    }
  }

  Future<Map<String, _Saved>> _loadIndex() async {
    if (_index case final index?) return index;
    final index = <String, _Saved>{};
    final root = await _root;
    final songs = Directory(p.join(root, 'songs'));
    if (await songs.exists()) {
      await for (final entry in songs.list()) {
        if (entry is! File) continue;
        try {
          if (p.extension(entry.path) != '.json') throw const FormatException();
          final bytes = await entry.readAsBytes();
          final state = ReEnrichUndoState.fromJson(
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          );
          index[p.basenameWithoutExtension(entry.path)] = _Saved(
            state.savedAt,
            bytes.length,
            state.cover,
          );
        } catch (_) {
          // An interrupted save or an unreadable state cannot be restored.
          await entry.delete().catchError((_) => entry);
        }
      }
    }
    final referenced = {for (final saved in index.values) ?saved.cover};
    final covers = Directory(p.join(root, 'covers'));
    if (await covers.exists()) {
      await for (final entry in covers.list()) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (referenced.contains(name)) {
          _coverBytes[name] = await entry.length();
        } else {
          await entry.delete().catchError((_) => entry);
        }
      }
    }
    return _index = index;
  }

  static Future<void> _writeAtomically(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final draft = File('${file.path}.tmp');
    await draft.writeAsBytes(bytes, flush: true);
    await draft.rename(file.path);
  }

  static String _imageExtension(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return '.jpg';
  }
}
