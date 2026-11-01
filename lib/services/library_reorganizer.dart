import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/mime_utils.dart';

final _log = AppLogger('LibraryReorganizer');

/// One stored file that does not match the current folder/filename rules.
///
/// Relative directories always use `/` regardless of platform, matching the
/// form the download pipeline produces for both SAF and local storage.
class LibraryReorganizationMove {
  const LibraryReorganizationMove({
    required this.historyIds,
    required this.trackName,
    required this.sourcePath,
    required this.sourceRelativeDir,
    required this.sourceFileName,
    required this.targetRelativeDir,
    required this.targetFileName,
  });

  /// Every download history row that points at [sourcePath]. Empty for a
  /// file known only from the Local Library scan.
  final List<String> historyIds;
  final String trackName;

  /// Local file path, or a `content://` URI in SAF mode.
  final String sourcePath;
  final String sourceRelativeDir;
  final String sourceFileName;
  final String targetRelativeDir;
  final String targetFileName;

  String get sourceDisplayPath =>
      joinRelativeLibraryPath(sourceRelativeDir, sourceFileName);
  String get targetDisplayPath =>
      joinRelativeLibraryPath(targetRelativeDir, targetFileName);

  LibraryReorganizationMove withTargetFileName(String fileName) =>
      LibraryReorganizationMove(
        historyIds: historyIds,
        trackName: trackName,
        sourcePath: sourcePath,
        sourceRelativeDir: sourceRelativeDir,
        sourceFileName: sourceFileName,
        targetRelativeDir: targetRelativeDir,
        targetFileName: fileName,
      );
}

class LibraryReorganizationPlan {
  const LibraryReorganizationPlan({
    required this.root,
    required this.safMode,
    required this.moves,
    this.alreadyOrganized = 0,
    this.outsideDownloadFolder = 0,
    this.missing = 0,
    this.untagged = 0,
    this.keepsPlaylistFolders = false,
    this.dropsPlaylistFolders = false,
  });

  /// Download folder path, or the SAF tree URI in SAF mode.
  final String root;
  final bool safMode;
  final List<LibraryReorganizationMove> moves;
  final int alreadyOrganized;

  /// Tracks stored somewhere other than the current download folder,
  /// downloads or scanned files. The rules are relative to that folder, so
  /// these are left alone.
  final int outsideDownloadFolder;
  final int missing;

  /// Scanned files without an artist tag. The rules would only file them
  /// under "Unknown", so they are left alone.
  final int untagged;

  /// The folder rule needs the source playlist, which history does not keep;
  /// files stay in their current folder and only the filename rule applies.
  final bool keepsPlaylistFolders;

  /// "Create playlist folder" is on, but the source playlist is unknown, so
  /// tracks are placed as if they had been downloaded on their own.
  final bool dropsPlaylistFolders;

  bool get isEmpty => moves.isEmpty;
}

class LibraryReorganizationResult {
  const LibraryReorganizationResult({
    this.moved = 0,
    this.failed = 0,
    this.missing = 0,
    this.cancelled = false,
  });

  final int moved;
  final int failed;
  final int missing;
  final bool cancelled;
}

String joinRelativeLibraryPath(String dir, String name) =>
    dir.isEmpty ? name : '$dir/$name';

/// Collapses separators and drops empty, `.` and `..` segments.
String normalizeRelativeLibraryDir(String value) => value
    .replaceAll('\\', '/')
    .split('/')
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty && part != '.' && part != '..')
    .join('/');

/// `Song.flac` → `Song (2).flac`.
String numberedLibraryFileName(String fileName, int number) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return '$fileName ($number)';
  return '${fileName.substring(0, dot)} ($number)${fileName.substring(dot)}';
}

/// The sidecar lyrics name the download pipeline writes next to [fileName].
String lyricsSidecarName(String fileName) {
  final replaced = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '.lrc');
  return replaced == fileName ? '$fileName.lrc' : replaced;
}

/// Gives every planned target a name that no other planned target and no
/// file that stays in place already uses. Comparison ignores case because
/// Android shared storage, Windows and macOS do.
List<LibraryReorganizationMove> resolveLibraryReorganizationConflicts(
  List<LibraryReorganizationMove> moves, {
  Iterable<String> occupied = const [],
}) {
  String key(String dir, String name) =>
      joinRelativeLibraryPath(dir, name).toLowerCase();
  final claimed = {for (final path in occupied) path.toLowerCase()};
  final resolved = <LibraryReorganizationMove>[];
  for (final move in moves) {
    var name = move.targetFileName;
    var number = 2;
    while (claimed.contains(key(move.targetRelativeDir, name))) {
      name = numberedLibraryFileName(move.targetFileName, number++);
    }
    claimed.add(key(move.targetRelativeDir, name));
    resolved.add(
      name == move.targetFileName ? move : move.withTargetFileName(name),
    );
  }
  return resolved;
}

typedef UpdateHistoryFilePath =
    Future<bool> Function(
      String id,
      String newFilePath, {
      String? newSafFileName,
      String? newSafRelativeDir,
      required String expectedFilePath,
    });

/// Storage Access Framework operations, injectable for tests.
class LibraryReorganizerSafOps {
  const LibraryReorganizerSafOps({
    required this.copyToTemp,
    required this.createUnique,
    required this.delete,
    required this.resolve,
  });

  static const platform = LibraryReorganizerSafOps(
    copyToTemp: PlatformBridge.copyContentUriToTemp,
    createUnique: _createUniqueSafFile,
    delete: PlatformBridge.safDelete,
    resolve: _resolveSafFile,
  );

  final Future<String?> Function(String uri) copyToTemp;
  final Future<({String uri, String fileName})?> Function({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  })
  createUnique;
  final Future<bool> Function(String uri) delete;

  /// URI of [fileName] inside [relativeDir], or null when absent.
  final Future<String?> Function({
    required String treeUri,
    required String relativeDir,
    required String fileName,
  })
  resolve;

  static Future<({String uri, String fileName})?> _createUniqueSafFile({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) async {
    final result = await PlatformBridge.createUniqueSafFileFromPath(
      treeUri: treeUri,
      relativeDir: relativeDir,
      fileName: fileName,
      mimeType: mimeType,
      srcPath: srcPath,
    );
    final uri = (result['uri'] as String? ?? '').trim();
    final name = (result['file_name'] as String? ?? '').trim();
    if (uri.isEmpty) return null;
    return (uri: uri, fileName: name.isEmpty ? fileName : name);
  }

  static Future<String?> _resolveSafFile({
    required String treeUri,
    required String relativeDir,
    required String fileName,
  }) async {
    final resolved = await PlatformBridge.resolveSafFile(
      treeUri: treeUri,
      relativeDir: relativeDir,
      fileName: fileName,
    );
    final uri = (resolved['uri'] as String? ?? '').trim();
    return uri.isEmpty ? null : uri;
  }
}

enum _Outcome { moved, failed, missing }

String _audioMimeType(String fileName) =>
    fileName.toLowerCase().endsWith('.opus')
    ? 'audio/ogg'
    : audioMimeTypeForPath(fileName);

/// Moves stored tracks to the paths in a [LibraryReorganizationPlan] and
/// points the download history and Local Library rows at the new locations.
/// A file is only reported as moved once the row that knows it was updated;
/// otherwise a local move is undone.
class LibraryReorganizer {
  LibraryReorganizer({
    UpdateHistoryFilePath? updateHistoryPath,
    Future<bool> Function(String oldPath, String newPath)? relinkLibraryPath,
    this.saf = LibraryReorganizerSafOps.platform,
  }) : updateHistoryPath = updateHistoryPath ?? _updateHistoryPath,
       relinkLibraryPath =
           relinkLibraryPath ?? LibraryDatabase.instance.relinkMovedFile;

  final UpdateHistoryFilePath updateHistoryPath;

  /// Points a scanned Local Library row at the file's new path; false when
  /// no row had the old path.
  final Future<bool> Function(String oldPath, String newPath) relinkLibraryPath;
  final LibraryReorganizerSafOps saf;

  static Future<bool> _updateHistoryPath(
    String id,
    String newFilePath, {
    String? newSafFileName,
    String? newSafRelativeDir,
    required String expectedFilePath,
  }) => HistoryDatabase.instance.updateFilePath(
    id,
    newFilePath,
    newSafFileName: newSafFileName,
    newSafRelativeDir: newSafRelativeDir,
    expectedFilePath: expectedFilePath,
  );

  Future<LibraryReorganizationResult> run(
    LibraryReorganizationPlan plan, {
    void Function(int done, LibraryReorganizationMove move)? onProgress,
    bool Function()? isCancelled,
  }) async {
    var moved = 0;
    var failed = 0;
    var missing = 0;
    var cancelled = false;
    final vacatedDirs = <String>{};

    for (var i = 0; i < plan.moves.length; i++) {
      if (isCancelled?.call() == true) {
        cancelled = true;
        break;
      }
      final move = plan.moves[i];
      onProgress?.call(i + 1, move);
      try {
        final outcome = plan.safMode
            ? await _moveSaf(plan.root, move)
            : await _moveLocal(plan.root, move, vacatedDirs);
        switch (outcome) {
          case _Outcome.moved:
            moved++;
          case _Outcome.failed:
            failed++;
          case _Outcome.missing:
            missing++;
        }
      } catch (error, stackTrace) {
        failed++;
        _log.e(
          'Failed to move ${move.sourceDisplayPath} → '
          '${move.targetDisplayPath}: $error',
          error,
          stackTrace,
        );
      }
    }

    if (!plan.safMode) {
      await _removeEmptyDirectories(plan.root, vacatedDirs);
    }
    _log.i(
      'Reorganized library: moved=$moved failed=$failed missing=$missing '
      'cancelled=$cancelled',
    );
    return LibraryReorganizationResult(
      moved: moved,
      failed: failed,
      missing: missing,
      cancelled: cancelled,
    );
  }

  /// Updates the rows that know [move]'s file. Download history is the
  /// record for downloads; the Local Library row is the record for a file
  /// found only by a scan. Returns whether that record now has [newPath].
  Future<bool> _recordNewPath(
    LibraryReorganizationMove move,
    String newPath, {
    String? safFileName,
    String? safRelativeDir,
  }) async {
    if (move.historyIds.isEmpty) {
      try {
        return await relinkLibraryPath(move.sourcePath, newPath);
      } catch (e) {
        _log.w('Could not update library row for ${move.sourcePath}: $e');
        return false;
      }
    }
    var recorded = false;
    for (final id in move.historyIds) {
      try {
        final updated = await updateHistoryPath(
          id,
          newPath,
          newSafFileName: safFileName,
          newSafRelativeDir: safRelativeDir,
          expectedFilePath: move.sourcePath,
        );
        recorded = recorded || updated;
      } catch (e) {
        _log.w('Could not update history row $id: $e');
      }
    }
    if (recorded) {
      // A download can also have a scanned row; keep it pointing at the file.
      try {
        await relinkLibraryPath(move.sourcePath, newPath);
      } catch (e) {
        _log.w('Could not update library row for ${move.sourcePath}: $e');
      }
    }
    return recorded;
  }

  // ---------------------------------------------------------------------------
  // Local storage
  // ---------------------------------------------------------------------------

  Future<_Outcome> _moveLocal(
    String root,
    LibraryReorganizationMove move,
    Set<String> vacatedDirs,
  ) async {
    final source = File(move.sourcePath);
    if (!await source.exists()) return _Outcome.missing;

    final targetDir = p.joinAll([
      root,
      ...move.targetRelativeDir.split('/').where((part) => part.isNotEmpty),
    ]);
    await Directory(targetDir).create(recursive: true);

    var targetPath = p.join(targetDir, move.targetFileName);
    final caseOnlyRename =
        p.normalize(targetPath).toLowerCase() ==
        p.normalize(source.path).toLowerCase();
    if (!caseOnlyRename) {
      targetPath = await _firstFreeLocalPath(targetPath);
    }

    final newPath = await _renameOrCopy(source, targetPath);
    final oldLyrics = File(
      p.join(
        p.dirname(source.path),
        lyricsSidecarName(p.basename(source.path)),
      ),
    );
    final newLyricsPath = p.join(
      p.dirname(newPath),
      lyricsSidecarName(p.basename(newPath)),
    );
    String? movedLyricsPath;
    try {
      if (await oldLyrics.exists() && !await File(newLyricsPath).exists()) {
        movedLyricsPath = await _renameOrCopy(oldLyrics, newLyricsPath);
      }
    } catch (e) {
      _log.w('Could not move lyrics sidecar for ${move.sourcePath}: $e');
    }

    if (!await _recordNewPath(move, newPath)) {
      // The row changed underneath us; put everything back so the stored
      // path stays valid.
      _log.w('Library changed while moving ${move.sourcePath}; reverting');
      try {
        await _renameOrCopy(File(newPath), source.path);
        if (movedLyricsPath != null) {
          await _renameOrCopy(File(movedLyricsPath), oldLyrics.path);
        }
      } catch (e) {
        _log.e('Could not revert move of ${move.sourcePath}: $e');
      }
      // Drop the destination folders created for this file if now empty.
      vacatedDirs.add(p.dirname(newPath));
      return _Outcome.failed;
    }

    vacatedDirs.add(p.dirname(source.path));
    return _Outcome.moved;
  }

  Future<String> _firstFreeLocalPath(String path) async {
    if (!await _exists(path)) return path;
    final dir = p.dirname(path);
    final name = p.basename(path);
    for (var number = 2; ; number++) {
      final candidate = p.join(dir, numberedLibraryFileName(name, number));
      if (!await _exists(candidate)) return candidate;
    }
  }

  Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// `rename` fails across volumes, so fall back to copy + delete there.
  Future<String> _renameOrCopy(File source, String targetPath) async {
    try {
      return (await source.rename(targetPath)).path;
    } on FileSystemException {
      final copy = await source.copy(targetPath);
      try {
        await source.delete();
      } catch (_) {
        try {
          await copy.delete();
        } catch (_) {}
        rethrow;
      }
      return copy.path;
    }
  }

  /// Deletes folders emptied by the move, walking up but never past [root].
  Future<void> _removeEmptyDirectories(String root, Set<String> dirs) async {
    final normalizedRoot = p.normalize(root);
    // Deepest first so parents are checked after their children.
    final ordered = dirs.map(p.normalize).toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final start in ordered) {
      var current = start;
      while (p.isWithin(normalizedRoot, current)) {
        final dir = Directory(current);
        try {
          if (!await dir.exists()) {
            current = p.dirname(current);
            continue;
          }
          if (!await dir.list(followLinks: false).isEmpty) break;
          await dir.delete();
        } catch (e) {
          _log.d('Leaving folder $current in place: $e');
          break;
        }
        current = p.dirname(current);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Storage Access Framework (Android)
  // ---------------------------------------------------------------------------

  Future<_Outcome> _moveSaf(
    String treeUri,
    LibraryReorganizationMove move,
  ) async {
    String? publishedName;
    // SAF has no portable move, so the file is published at its new
    // location from a temporary copy; the original is deleted only after
    // the new document exists.
    final replacer = DownloadSafFileReplacer(
      copyToTemp: saf.copyToTemp,
      deleteSource: (uri) async {
        if (!await saf.delete(uri)) {
          _log.w('Moved SAF file but could not delete the original: $uri');
        }
      },
      publish:
          ({
            required treeUri,
            required relativeDir,
            required fileName,
            required srcPath,
            required avoidOverwrite,
            required preservedSuffix,
            collisionCleanFileName,
            collisionVariantFileName,
          }) => saf.createUnique(
            treeUri: treeUri,
            relativeDir: relativeDir,
            fileName: fileName,
            mimeType: _audioMimeType(fileName),
            srcPath: srcPath,
          ),
    );
    final newUri = await replacer.replace(
      uri: move.sourcePath,
      treeUri: treeUri,
      relativeDir: move.targetRelativeDir,
      avoidOverwrite: true,
      op: (tempPath, _) async => (tempPath, move.targetFileName),
      onPublishedFileName: (name) => publishedName = name,
    );
    if (newUri == null) return _Outcome.failed;
    final newName = publishedName ?? move.targetFileName;

    await _moveSafLyrics(treeUri, move, newName);

    if (!await _recordNewPath(
      move,
      newUri,
      safFileName: newName,
      safRelativeDir: move.targetRelativeDir,
    )) {
      _log.w(
        'Library changed while moving ${move.sourcePath}; the file now lives '
        'at ${joinRelativeLibraryPath(move.targetRelativeDir, newName)}',
      );
      return _Outcome.failed;
    }
    return _Outcome.moved;
  }

  Future<void> _moveSafLyrics(
    String treeUri,
    LibraryReorganizationMove move,
    String newAudioName,
  ) async {
    String? tempPath;
    try {
      final oldUri = await saf.resolve(
        treeUri: treeUri,
        relativeDir: move.sourceRelativeDir,
        fileName: lyricsSidecarName(move.sourceFileName),
      );
      if (oldUri == null) return;
      tempPath = await saf.copyToTemp(oldUri);
      if (tempPath == null) return;
      final created = await saf.createUnique(
        treeUri: treeUri,
        relativeDir: move.targetRelativeDir,
        fileName: lyricsSidecarName(newAudioName),
        mimeType: 'application/octet-stream',
        srcPath: tempPath,
      );
      if (created != null) await saf.delete(oldUri);
    } catch (e) {
      _log.w('Could not move lyrics sidecar for ${move.sourcePath}: $e');
    } finally {
      if (tempPath != null) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
      }
    }
  }
}
