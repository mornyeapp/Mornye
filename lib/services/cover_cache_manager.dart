import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/file.dart' as cache_file;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/cover_cache_info_repository.dart';
import 'package:mornye/utils/cache_byte_budget.dart';
import 'package:mornye/utils/periodic_async_task.dart';

/// Persistent cache manager for album/track cover images.
///
/// Unlike the default cache manager which stores in temp directory
/// (can be cleared by system anytime), this stores in app support
/// directory which persists across app restarts.
class CoverCacheManager {
  static const String _cacheKey = 'coverImageCache';
  static const int _maxCacheObjects = 1000;
  static const Duration _maxCacheAge = Duration(days: 365);
  // flutter_cache_manager only caps object count, not bytes; hi-res covers
  // run 300KB-1.5MB each, so 1000 objects can mean hundreds of MB on a
  // storage-starved device. Sweep periodically while the app is foregrounded.
  static const int _maxCacheBytes = 150 << 20;
  static const int _sweepTargetBytes = 120 << 20;

  static CacheManager? _instance;
  static CoverCacheInfoRepository? _repository;
  static Future<void>? _initialization;
  static bool _initialized = false;
  static AppLifecycleListener? _lifecycle;
  static Future<void> _cacheWork = Future<void>.value();
  static final _maintenance = PeriodicAsyncTask(
    interval: const Duration(minutes: 15),
    run: () => _serializeCacheWork(
      () => _trim(maxBytes: _maxCacheBytes, targetBytes: _sweepTargetBytes),
    ),
    onError: (error, _) =>
        debugPrint('CoverCacheManager: Sweep failed: $error'),
  );
  static String? _cachePath;

  /// The one cover cache. It works before [initialize] completes: its
  /// directory and index resolve on first use.
  static CacheManager get instance => _instance ??= _createManager();

  static bool get isInitialized => _initialized;

  static Future<void> initialize() => _initialization ??= _initialize();

  static Future<void> _initialize() async {
    try {
      final cachePath = await _resolveCachePath();

      await Directory(cachePath).create(recursive: true);

      debugPrint('CoverCacheManager: Initializing at $cachePath');

      _instance ??= _createManager();
      _lifecycle ??= AppLifecycleListener(
        onPause: _flushInBackground,
        onDetach: _flushInBackground,
        onExitRequested: _flushBeforeExit,
      );

      _initialized = true;
      debugPrint('CoverCacheManager: Initialized successfully');
    } catch (e) {
      _initialization = null;
      debugPrint('CoverCacheManager: Failed to initialize: $e');
    }
  }

  /// Writes pending cover index changes now.
  static Future<void> flush() => _repository?.flush() ?? Future<void>.value();

  static void _flushInBackground() => unawaited(flush());

  static Future<AppExitResponse> _flushBeforeExit() async {
    await flush().timeout(const Duration(seconds: 2), onTimeout: () {});
    return AppExitResponse.exit;
  }

  static Future<String> _resolveCachePath() async => _cachePath ??= p.join(
    (await getApplicationSupportDirectory()).path,
    'cover_cache',
  );

  // The package names its JSON file after a database name; passing the cache
  // directory as the path left none, so the index has always been here.
  static Future<File> _indexFile() async =>
      File(p.join(p.dirname(await _resolveCachePath()), 'null.json'));

  /// Runs after startup and periodically thereafter. The next sweep is
  /// scheduled after completion, so even slow storage cannot overlap sweeps.
  static void scheduleMaintenance({
    Duration delay = const Duration(seconds: 20),
  }) {
    _maintenance.start(delay: delay);
  }

  static void stopMaintenance() {
    _maintenance.stop();
  }

  static Future<void> _serializeCacheWork(Future<void> Function() operation) {
    final next = _cacheWork.then((_) => operation());
    _cacheWork = next.catchError((Object error) {
      debugPrint('CoverCacheManager: Cache maintenance failed: $error');
    });
    return next;
  }

  /// Runs the byte budget sweep with a test budget.
  @visibleForTesting
  static Future<void> trimForTesting({
    required int maxBytes,
    required int targetBytes,
  }) => _serializeCacheWork(
    () => _trim(maxBytes: maxBytes, targetBytes: targetBytes),
  );

  static Future<void> _trim({
    required int maxBytes,
    required int targetBytes,
  }) async {
    final cachePath = _cachePath;
    if (cachePath == null) return;
    final deleted = await trimCacheToByteBudget(
      Directory(cachePath),
      maxBytes: maxBytes,
      targetBytes: targetBytes,
    );
    if (deleted > 0) {
      debugPrint('CoverCacheManager: Trimmed $deleted cached covers');
      await _forgetDeletedFiles(cachePath);
    }
  }

  /// The sweep deletes files behind the cache manager; drop their index
  /// entries and memory hits.
  static Future<void> _forgetDeletedFiles(String cachePath) async {
    final instance = _instance;
    final repository = _repository;
    if (instance == null || repository == null) return;
    final objects = await repository.getAllObjects();
    final paths = [
      for (final object in objects) p.join(cachePath, object.relativePath),
    ];
    final missing = await Isolate.run(() => _missingFileIndexes(paths));
    for (final index in missing) {
      // Checks the file again: a download may have replaced it since.
      await instance.store.retrieveCacheData(
        objects[index].key,
        ignoreMemCache: true,
      );
    }
  }

  static List<int> _missingFileIndexes(List<String> paths) => [
    for (var i = 0; i < paths.length; i++)
      if (!File(paths[i]).existsSync()) i,
  ];

  static Future<void> clearCache() => _serializeCacheWork(_clearCache);

  static Future<void> _clearCache() async {
    if (!_initialized) await initialize();

    final instance = _instance;
    final cachePath = _cachePath;

    if (!_initialized || instance == null || cachePath == null) return;

    try {
      await instance.emptyCache();
    } catch (e) {
      debugPrint('CoverCacheManager: emptyCache failed, fallback to wipe: $e');
      await _wipeDirectory(cachePath);
    }

    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();

    // Pending downloads publish into this manager when their files finish.
    // Preserve their unindexed files and the single repository writer.
    instance.store.emptyMemoryCache();
    await flush();
  }

  static Future<CacheStats> getStats() async {
    final String cachePath;
    try {
      cachePath = await _resolveCachePath();
    } catch (_) {
      return const CacheStats(fileCount: 0, totalSizeBytes: 0);
    }

    final cacheDir = Directory(cachePath);

    if (!await cacheDir.exists()) {
      return const CacheStats(fileCount: 0, totalSizeBytes: 0);
    }

    int fileCount = 0;
    int totalSize = 0;

    try {
      await for (final entity in cacheDir.list(recursive: true)) {
        if (entity is File) {
          fileCount++;
          totalSize += await entity.length();
        }
      }
    } catch (e) {
      debugPrint('CoverCacheManager: Error getting stats: $e');
    }

    return CacheStats(fileCount: fileCount, totalSizeBytes: totalSize);
  }

  static CacheManager _createManager() {
    final repository = _repository = CoverCacheInfoRepository(_indexFile);
    return _CoverCache(
      Config(
        _cacheKey,
        stalePeriod: _maxCacheAge,
        maxNrOfCacheObjects: _maxCacheObjects,
        repo: repository,
        fileSystem: _CoverCacheFileSystem(_resolveCachePath),
        fileService: HttpFileService(),
      ),
    );
  }

  static Future<void> _wipeDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      return;
    }

    try {
      final entities = <FileSystemEntity>[];
      await for (final entity in directory.list(followLinks: false)) {
        entities.add(entity);
      }

      for (final entity in entities) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}

    try {
      await directory.create(recursive: true);
    } catch (_) {}
  }
}

/// The byte budget sweep deletes files behind the cache manager, so a memory
/// hit counts only while its file exists.
class _CoverCache extends CacheManager {
  _CoverCache(super.config);

  @override
  Future<FileInfo?> getFileFromMemory(String key) async {
    final info = await super.getFileFromMemory(key);
    return info != null && await info.file.exists() ? info : null;
  }
}

/// [IOFileSystem] in a directory resolved on first use.
class _CoverCacheFileSystem implements FileSystem {
  _CoverCacheFileSystem(this._resolveDirectory);

  final Future<String> Function() _resolveDirectory;
  IOFileSystem? _files;

  @override
  Future<cache_file.File> createFile(String name) async {
    final directory = await _resolveDirectory();
    return (_files ??= IOFileSystem(directory)).createFile(name);
  }
}

class CacheStats {
  final int fileCount;
  final int totalSizeBytes;

  const CacheStats({required this.fileCount, required this.totalSizeBytes});
}
