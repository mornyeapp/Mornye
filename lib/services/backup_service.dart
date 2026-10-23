import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_native_snapshot.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/native_platform_name.dart';

typedef BackupHistoryPageLoader =
    Future<List<Map<String, dynamic>>> Function(int limit, int offset);

Future<void> _writeBackupMetadataInBackground(
  String path,
  Map<String, dynamic> metadata,
  String? collectionsJson,
) => Isolate.run(() {
  if (collectionsJson == null) {
    File(path).writeAsStringSync(jsonEncode(metadata), flush: true);
    return;
  }
  // The collections exporter already encoded this trusted object on its
  // worker. Passing the immutable string avoids cloning its full map graph
  // onto another worker. Write it directly, preserving metadata key order.
  final output = File(path).openSync(mode: FileMode.write);
  final buffer = StringBuffer();
  try {
    buffer.write('{');
    var first = true;
    for (final entry in metadata.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer
        ..write(jsonEncode(entry.key))
        ..write(':');
      if (entry.key != 'data') {
        buffer.write(jsonEncode(entry.value));
        continue;
      }
      final data = entry.value as Map<String, dynamic>;
      buffer.write('{');
      var firstData = true;
      for (final field in data.entries) {
        if (!firstData) buffer.write(',');
        firstData = false;
        buffer
          ..write(jsonEncode(field.key))
          ..write(':');
        if (field.key == 'collections') {
          output.writeStringSync(buffer.toString());
          buffer.clear();
          output.writeStringSync(collectionsJson);
        } else {
          buffer.write(jsonEncode(field.value));
        }
      }
      buffer.write('}');
    }
    buffer.write('}');
    output
      ..writeStringSync(buffer.toString())
      ..flushSync();
  } finally {
    output.closeSync();
  }
});

/// Parsed contents of a backup file. ZIP backups keep large history and cover
/// payloads on disk until restore consumes them.
class BackupBundle {
  final int formatVersion;
  final String appVersion;
  final DateTime? createdAt;
  final Map<String, dynamic>? settings;
  final UserProfile? profile;
  final List<Map<String, dynamic>> history;
  final Map<String, dynamic> collections;
  final Map<String, dynamic> playlistCovers;
  final Map<String, dynamic> extensions;
  final bool hasHistory;
  final String? _historyNdjsonPath;
  final int? _historyCount;
  final String? _temporaryDirectoryPath;

  const BackupBundle({
    required this.formatVersion,
    required this.appVersion,
    required this.createdAt,
    required this.settings,
    required this.history,
    required this.collections,
    required this.playlistCovers,
    required this.extensions,
    this.profile,
    this.hasHistory = true,
    String? historyNdjsonPath,
    int? historyCount,
    String? temporaryDirectoryPath,
  }) : _historyNdjsonPath = historyNdjsonPath,
       _historyCount = historyCount,
       _temporaryDirectoryPath = temporaryDirectoryPath;

  bool get hasSettings => settings != null && settings!.isNotEmpty;
  bool get hasCollections => collections.isNotEmpty;
  int get historyCount => _historyCount ?? history.length;

  Stream<Map<String, dynamic>> streamHistory() async* {
    if (_historyNdjsonPath == null) {
      yield* Stream.fromIterable(history);
      return;
    }
    await for (final line in File(
      _historyNdjsonPath,
    ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is Map) yield Map<String, dynamic>.from(decoded);
    }
  }

  Future<void> cleanup() async {
    final path = _temporaryDirectoryPath;
    if (path == null || path.isEmpty) return;
    try {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {}
  }

  int _collectionListCount(String key) {
    final value = collections[key];
    return value is List ? value.length : 0;
  }

  int get likedCount => _collectionListCount('loved');
  int get wishlistCount => _collectionListCount('wishlist');
  int get playlistCount => _collectionListCount('playlists');
  int get favoriteArtistCount => _collectionListCount('favoriteArtists');

  int get extensionCount {
    final items = extensions['items'];
    return items is List ? items.length : 0;
  }

  bool get hasExtensions => extensionCount > 0;
}

class BackupService {
  static final _log = AppLogger('BackupService');

  static const String magic = 'mornye-backup';
  static const String _legacyMagic = 'spotiflac-backup';
  // V3 permits omitted categories. Older readers reject it instead of treating
  // an omitted history as an empty history and clearing existing downloads.
  static const int formatVersion = 3;
  static const String fileExtension = 'sflb';
  static const int _historyPageSize = 500;
  static const int _maxMetadataBytes = 8 << 20;
  static const int _maxHistoryBytes = 512 << 20;
  static const int _maxCoverBytes = 20 << 20;
  static const int _maxAllCoversBytes = 256 << 20;
  static const int _maxProfilePhotoBytes = 2 << 20;
  static const String _profilePhotoEntry = 'profile/avatar.png';

  static Future<File> writeBackupArchive({
    required Map<String, dynamic>? settings,
    required BackupHistoryPageLoader loadHistoryPage,
    required Map<String, dynamic> collections,
    String? collectionsJson,
    required Map<String, Map<String, String>> playlistCoverFiles,
    required Map<String, dynamic> extensions,
    Directory? outputDirectory,
    Directory? temporaryDirectory,
    bool includeHistory = true,
    UserProfile? profile,
  }) async {
    if (collectionsJson != null && collections.isNotEmpty) {
      throw ArgumentError('Provide collections as a map or encoded JSON');
    }
    final output = await _newBackupFile(outputDirectory);
    final tempRoot = temporaryDirectory ?? await getTemporaryDirectory();
    final staging = await Directory(
      p.join(
        tempRoot.path,
        'mornye_backup_${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create(recursive: true);
    final historyFile = File(p.join(staging.path, 'history.ndjson'));
    final metadataFile = File(p.join(staging.path, 'metadata.json'));
    final partFile = File('${output.path}.part');

    try {
      var historyCount = 0;
      if (includeHistory && PlatformBridge.supportsCoreBackend) {
        final database = await HistoryDatabase.instance.database;
        historyCount = await exportNativeHistory(database, historyFile.path);
      } else {
        var offset = 0;
        final historySink = historyFile.openWrite();
        try {
          while (includeHistory) {
            final page = await loadHistoryPage(_historyPageSize, offset);
            for (final item in page) {
              historySink.writeln(jsonEncode(item));
            }
            await historySink.flush();
            historyCount += page.length;
            offset += page.length;
            if (page.length < _historyPageSize) break;
          }
          await historySink.flush();
        } finally {
          await historySink.close();
        }
      }

      final coverManifest = <String, Map<String, String>>{};
      var coverIndex = 0;
      for (final entry in playlistCoverFiles.entries) {
        final sourcePath = entry.value['path'] ?? '';
        final source = File(sourcePath);
        if (sourcePath.isEmpty || !await source.exists()) continue;
        var ext = (entry.value['ext'] ?? p.extension(sourcePath)).toLowerCase();
        if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)) ext = '.jpg';
        final archiveName = 'covers/cover_${coverIndex++}$ext';
        coverManifest[entry.key] = {'ext': ext, 'file': archiveName};
      }

      final photoPath = profile?.photoPath;
      if (photoPath != null &&
          await File(photoPath).length() > _maxProfilePhotoBytes) {
        throw const FormatException('Profile photo is too large');
      }
      final metadata = {
        'magic': magic,
        'format_version': formatVersion,
        'app': AppInfo.appName,
        'app_version': AppInfo.displayVersion,
        'created_at': DateTime.now().toIso8601String(),
        'history_count': historyCount,
        'data': {
          'settings': ?settings,
          if (profile != null)
            'profile': {
              'name': profile.name,
              if (photoPath != null) 'photo': _profilePhotoEntry,
            },
          if (collectionsJson != null || collections.isNotEmpty)
            'collections': collections,
          if (coverManifest.isNotEmpty) 'playlist_covers': coverManifest,
          if (extensions.isNotEmpty) 'extensions': extensions,
        },
      };
      await writeBackupMetadata(
        metadataFile.path,
        metadata,
        collectionsJson: collectionsJson,
      );

      if (await partFile.exists()) await partFile.delete();
      final archiveFiles = <({String path, String name, bool store})>[
        (path: metadataFile.path, name: 'metadata.json', store: false),
        if (includeHistory)
          (path: historyFile.path, name: 'history.ndjson', store: false),
        if (photoPath != null)
          (path: photoPath, name: _profilePhotoEntry, store: true),
      ];
      for (final entry in coverManifest.entries) {
        final sourcePath = playlistCoverFiles[entry.key]?['path'];
        if (sourcePath == null) continue;
        archiveFiles.add((
          path: sourcePath,
          name: entry.value['file']!,
          store: true,
        ));
      }
      if (PlatformBridge.supportsCoreBackend) {
        final result = await PlatformBridge.runNativeDataJob({
          'operation': 'backup_archive_write',
          'output_path': partFile.path,
          'files': [
            for (final file in archiveFiles)
              {'path': file.path, 'name': file.name, 'store': file.store},
          ],
        });
        if (result['published'] != true ||
            result['count'] != archiveFiles.length) {
          throw const FormatException('Incomplete native backup archive');
        }
      } else {
        await _encodeArchiveInBackground(partFile.path, archiveFiles);
      }
      if (await output.exists()) await output.delete();
      await partFile.rename(output.path);
      _log.i('Streaming backup written to ${output.path}');
      return output;
    } finally {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      await deleteFileQuietly(partFile);
    }
  }

  // archive's file-backed encoder still performs compression and writes
  // synchronously. Pass only paths to the worker; database/plugin callbacks
  // and the paged history loader stay on their owning isolate.
  static Future<void> _encodeArchiveInBackground(
    String outputPath,
    List<({String path, String name, bool store})> files,
  ) => Isolate.run(() async {
    final encoder = ZipFileEncoder()..create(outputPath);
    try {
      for (final file in files) {
        await encoder.addFile(
          File(file.path),
          file.name,
          file.store ? ZipFileEncoder.store : null,
        );
      }
    } finally {
      await encoder.close();
    }
  });

  static Future<File> _newBackupFile([Directory? outputDirectory]) async {
    final dir = outputDirectory ?? await getApplicationDocumentsDirectory();
    final backupsDir =
        outputDirectory ?? Directory(p.join(dir.path, 'backups'));
    await backupsDir.create(recursive: true);
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return File(p.join(backupsDir.path, 'mornye_backup_$stamp.$fileExtension'));
  }

  static Future<BackupBundle?> parseFile(
    String path, {
    Directory? temporaryDirectory,
  }) async {
    final tempRoot = temporaryDirectory ?? await getTemporaryDirectory();
    final BackupBundle? bundle;
    if (PlatformBridge.supportsCoreBackend) {
      bundle = await _hasZipHeader(File(path))
          ? await _parseArchiveNative(path, tempRoot)
          : await _parseLegacyNative(path, tempRoot);
    } else {
      bundle = await _parseFileInBackground(path, tempRoot.path);
    }
    if (bundle == null) {
      _log.w('Backup file could not be read: invalid or unsupported contents');
    }
    return bundle;
  }

  /// Called inside the history notifier's write queue. Native work uses a
  /// private database; the live SQLite owner publishes the complete result.
  static Future<void> restoreHistory(BackupBundle bundle) async {
    if (!bundle.hasHistory) return;
    final database = await HistoryDatabase.instance.database;
    if (PlatformBridge.supportsCoreBackend &&
        bundle._historyNdjsonPath != null) {
      await restoreNativeHistory(database, bundle);
      return;
    }
    // Desktop and legacy in-memory callers retain the established codec.
    await HistoryDatabase.instance.clearAll();
    var batch = <Map<String, dynamic>>[];
    await for (final item in bundle.streamHistory()) {
      batch.add(item);
      if (batch.length < _historyPageSize) continue;
      await HistoryDatabase.instance.upsertBatch(batch);
      batch = <Map<String, dynamic>>[];
    }
    if (batch.isNotEmpty) await HistoryDatabase.instance.upsertBatch(batch);
  }

  @visibleForTesting
  static Future<int> exportNativeHistory(Database database, String path) async {
    final staging = await Directory.systemTemp.createTemp('history-export-');
    var detached = true;
    try {
      final snapshotPath = p.join(staging.path, 'history.db');
      await createNativeSqliteSnapshot(
        database,
        snapshotPath,
        tables: const ['history'],
        version: HistoryDatabase.schemaVersion,
      );
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'backup_history_export',
        'history_path': snapshotPath,
        'ndjson_path': path,
        'platform': nativePlatformName(),
        if (Platform.isIOS)
          'documents_path': (await getApplicationDocumentsDirectory()).path,
      });
      if (result['published'] != true || result['count'] is! int) {
        throw const FormatException('Incomplete native history backup');
      }
      return result['count'] as int;
    } on NativeSqliteSnapshotDetachException {
      detached = false;
      _log.w('Retaining history export staging after a failed database detach');
      rethrow;
    } finally {
      if (detached) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException catch (error) {
          _log.w('Could not remove history export staging: $error');
        }
      }
    }
  }

  @visibleForTesting
  static Future<void> restoreNativeHistory(
    Database database,
    BackupBundle bundle,
  ) async {
    final staging = await Directory.systemTemp.createTemp('history-restore-');
    var detached = true;
    try {
      final snapshotPath = p.join(staging.path, 'history.db');
      await createNativeSqliteSnapshot(
        database,
        snapshotPath,
        tables: const ['history', 'history_path_keys'],
        version: HistoryDatabase.schemaVersion,
        copyRows: false,
      );
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'backup_history_import',
        'history_path': snapshotPath,
        'ndjson_path': bundle._historyNdjsonPath,
        if (bundle._historyCount != null)
          'expected_count': bundle._historyCount,
        'platform': nativePlatformName(),
        'mode': 'replace',
      });
      if (result['committed'] != true) {
        throw const FormatException('Incomplete native history restore');
      }
      detached = await replaceTablesFromNativeSnapshot(
        database,
        snapshotPath,
        tables: const ['history', 'history_path_keys'],
        deleteOrder: const ['history_path_keys', 'history'],
      );
      if (!detached) {
        _log.w(
          'History restored; retaining staging after a failed database detach',
        );
      }
    } on NativeSqliteSnapshotDetachException {
      detached = false;
      _log.w(
        'Retaining history restore staging after a failed database detach',
      );
      rethrow;
    } finally {
      if (detached) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException catch (error) {
          _log.w('Could not remove history restore staging: $error');
        }
      }
    }
  }

  static Future<bool> _hasZipHeader(File file) async {
    final header = await file
        .openRead(0, 4)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    return header.length == 4 &&
        header[0] == 0x50 &&
        header[1] == 0x4b &&
        header[2] == 0x03 &&
        header[3] == 0x04;
  }

  static Future<BackupBundle?> _parseLegacyNative(
    String path,
    Directory temporary,
  ) async {
    await temporary.create(recursive: true);
    final staging = await temporary.createTemp('mornye_legacy_backup_');
    try {
      final historyPath = p.join(staging.path, 'history.ndjson');
      final metadataPath = p.join(staging.path, 'metadata.json');
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'backup_split_legacy',
        'input_path': path,
        'ndjson_path': historyPath,
        'metadata_path': metadataPath,
      });
      if (result['published'] != true || result['count'] is! int) {
        throw const FormatException('Incomplete legacy backup staging');
      }
      final parsed = await Isolate.run(
        () => parse(File(metadataPath).readAsStringSync()),
      );
      if (parsed == null) throw const FormatException('Invalid backup');
      return BackupBundle(
        formatVersion: parsed.formatVersion,
        appVersion: parsed.appVersion,
        createdAt: parsed.createdAt,
        settings: parsed.settings,
        profile: parsed.profile,
        history: const [],
        hasHistory: parsed.hasHistory,
        historyCount: result['count'] as int,
        historyNdjsonPath: parsed.hasHistory ? historyPath : null,
        collections: parsed.collections,
        playlistCovers: parsed.playlistCovers,
        extensions: parsed.extensions,
        temporaryDirectoryPath: staging.path,
      );
    } catch (error) {
      await staging.delete(recursive: true);
      _log.w('Legacy backup native parse failed: $error');
      return null;
    }
  }

  static Future<BackupBundle?> _parseArchiveNative(
    String path,
    Directory temporary,
  ) async {
    String? stagingPath;
    try {
      await temporary.create(recursive: true);
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'backup_archive_read',
        'input_path': path,
        'temporary_directory': temporary.path,
      });
      stagingPath = result['temporary_directory_path'] as String?;
      if (result['published'] != true || stagingPath == null) {
        throw const FormatException('Incomplete native backup staging');
      }
      // ZIP decompression and large payloads remain native/on disk; only the
      // bounded metadata is hydrated into Flutter models on a Dart worker.
      return await Isolate.run(() {
        final root =
            jsonDecode(
                  File(result['metadata_path'] as String).readAsStringSync(),
                )
                as Map;
        final data = root['data'] as Map;
        final rawProfile = data['profile'] as Map?;
        final historyPath = result['history_path'] as String?;
        return BackupBundle(
          formatVersion: root['format_version'] as int,
          appVersion: root['app_version'] as String? ?? '',
          createdAt: DateTime.tryParse(root['created_at'] as String? ?? ''),
          settings: _mapOrNull(data['settings']),
          profile: rawProfile == null
              ? null
              : UserProfile(
                  name: rawProfile['name'] as String,
                  photoPath: result['profile_photo_path'] as String?,
                ),
          history: const [],
          hasHistory: historyPath != null,
          historyNdjsonPath: historyPath,
          historyCount: (root['history_count'] as num?)?.toInt(),
          collections: _mapOrEmpty(data['collections']),
          playlistCovers: _mapOrEmpty(result['playlist_covers']),
          extensions: _mapOrEmpty(data['extensions']),
          temporaryDirectoryPath: stagingPath,
        );
      });
    } catch (error) {
      if (stagingPath != null) {
        try {
          await Directory(stagingPath).delete(recursive: true);
        } catch (_) {}
      }
      _log.w('Backup archive native parse failed: $error');
      return null;
    }
  }

  static Future<BackupBundle?> _parseFileInBackground(
    String path,
    String temporaryPath,
  ) => Isolate.run(() => _parseFile(path, temporaryPath));

  static Future<BackupBundle?> _parseFile(
    String path,
    String temporaryPath,
  ) async {
    final file = File(path);
    final isZip = await _hasZipHeader(file);
    return isZip
        ? _parseArchive(file, temporaryDirectory: Directory(temporaryPath))
        : parse(await file.readAsString());
  }

  static Future<BackupBundle?> _parseArchive(
    File file, {
    required Directory temporaryDirectory,
  }) async {
    InputFileStream? input;
    Archive? archive;
    Directory? extractionDir;
    try {
      input = InputFileStream(file.path);
      archive = ZipDecoder().decodeStream(input);
      final metadataEntry = archive.find('metadata.json');
      final historyEntry = archive.find('history.ndjson');
      if (metadataEntry == null ||
          metadataEntry.size > _maxMetadataBytes ||
          (historyEntry != null && historyEntry.size > _maxHistoryBytes)) {
        return null;
      }
      final rootRaw = jsonDecode(utf8.decode(metadataEntry.content));
      if (rootRaw is! Map) return null;
      final root = Map<String, dynamic>.from(rootRaw);
      final version = root['format_version'];
      if ((root['magic'] != magic && root['magic'] != _legacyMagic) ||
          (version != 2 && version != formatVersion)) {
        return null;
      }
      if (version == 2 && historyEntry == null) {
        return null;
      }
      final dataRaw = root['data'];
      if (dataRaw is! Map) return null;
      final data = Map<String, dynamic>.from(dataRaw);

      extractionDir = await Directory(
        p.join(
          temporaryDirectory.path,
          'mornye_restore_${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      String? historyPath;
      if (historyEntry != null) {
        historyPath = p.join(extractionDir.path, 'history.ndjson');
        writeArchiveEntry(historyEntry, OutputFileStream(historyPath));
      }

      final restoredCovers = <String, dynamic>{};
      final coverManifest = data['playlist_covers'];
      if (coverManifest is Map) {
        var index = 0;
        var extractedCoverBytes = 0;
        for (final manifestEntry in coverManifest.entries) {
          if (manifestEntry.value is! Map) continue;
          final cover = Map<String, dynamic>.from(manifestEntry.value as Map);
          final archiveName = cover['file']?.toString() ?? '';
          if (!archiveName.startsWith('covers/') ||
              archiveName.contains('..')) {
            continue;
          }
          final archiveEntry = archive.find(archiveName);
          if (archiveEntry == null || archiveEntry.size > _maxCoverBytes) {
            continue;
          }
          if (extractedCoverBytes + archiveEntry.size > _maxAllCoversBytes) {
            break;
          }
          var ext = cover['ext']?.toString() ?? '.jpg';
          if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)) ext = '.jpg';
          final coverPath = p.join(extractionDir.path, 'cover_${index++}$ext');
          writeArchiveEntry(archiveEntry, OutputFileStream(coverPath));
          extractedCoverBytes += archiveEntry.size;
          restoredCovers[manifestEntry.key.toString()] = {
            'ext': ext,
            'path': coverPath,
          };
        }
      }

      UserProfile? profile;
      if (data.containsKey('profile')) {
        final rawProfile = data['profile'];
        if (rawProfile is! Map || rawProfile['name'] is! String) {
          throw const FormatException('Invalid profile');
        }
        String? photoPath;
        if (rawProfile['photo'] != null) {
          if (rawProfile['photo'] != _profilePhotoEntry) {
            throw const FormatException('Invalid profile photo entry');
          }
          final photoEntry = archive.find(_profilePhotoEntry);
          if (photoEntry == null ||
              !photoEntry.isFile ||
              photoEntry.size > _maxProfilePhotoBytes) {
            throw const FormatException('Missing or oversized profile photo');
          }
          photoPath = p.join(extractionDir.path, 'profile.png');
          writeArchiveEntry(photoEntry, OutputFileStream(photoPath));
        }
        profile = UserProfile(
          name: rawProfile['name'] as String,
          photoPath: photoPath,
        );
      }

      return BackupBundle(
        formatVersion: version as int,
        appVersion: root['app_version'] as String? ?? '',
        createdAt: DateTime.tryParse(root['created_at'] as String? ?? ''),
        settings: _mapOrNull(data['settings']),
        profile: profile,
        history: const [],
        hasHistory: historyEntry != null,
        historyNdjsonPath: historyPath,
        historyCount: (root['history_count'] as num?)?.toInt(),
        collections: _mapOrEmpty(data['collections']),
        playlistCovers: restoredCovers,
        extensions: _mapOrEmpty(data['extensions']),
        temporaryDirectoryPath: extractionDir.path,
      );
    } catch (e) {
      _log.w('Backup archive parse failed: $e');
      if (extractionDir != null) {
        try {
          await extractionDir.delete(recursive: true);
        } catch (_) {}
      }
      return null;
    } finally {
      if (input != null) await input.close();
    }
  }

  /// Consumes and closes the output even when an archive payload cannot be read.
  @visibleForTesting
  static void writeArchiveEntry(ArchiveFile entry, OutputFileStream output) {
    try {
      entry.writeContent(output);
    } finally {
      output.closeSync();
    }
  }

  /// [collectionsJson] is the trusted JSON object from the collection export
  /// worker. Its empty placeholder in metadata retains the normal key order.
  @visibleForTesting
  static Future<void> writeBackupMetadata(
    String path,
    Map<String, dynamic> metadata, {
    String? collectionsJson,
  }) => _writeBackupMetadataInBackground(path, metadata, collectionsJson);

  static BackupBundle? parse(String content) {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      _log.w('Backup parse failed: not valid JSON ($e)');
      return null;
    }
    if (decoded is! Map) return null;
    final root = Map<String, dynamic>.from(decoded);
    if ((root['magic'] != magic && root['magic'] != _legacyMagic) ||
        root['data'] is! Map) {
      return null;
    }
    final data = Map<String, dynamic>.from(root['data'] as Map);
    final history = <Map<String, dynamic>>[];
    if (data['history'] is List) {
      for (final item in data['history'] as List) {
        if (item is Map) history.add(Map<String, dynamic>.from(item));
      }
    }
    return BackupBundle(
      formatVersion: (root['format_version'] as num?)?.toInt() ?? 1,
      appVersion: root['app_version'] as String? ?? '',
      createdAt: DateTime.tryParse(root['created_at'] as String? ?? ''),
      settings: _mapOrNull(data['settings']),
      history: history,
      hasHistory: data['history'] is List,
      collections: _mapOrEmpty(data['collections']),
      playlistCovers: _mapOrEmpty(data['playlist_covers']),
      extensions: _mapOrEmpty(data['extensions']),
    );
  }

  static Map<String, dynamic>? _mapOrNull(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static Map<String, dynamic> _mapOrEmpty(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
