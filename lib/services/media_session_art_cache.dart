import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/file.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:mornye/services/cover_cache_manager.dart';

/// The cache audio_service loads web covers through, or null for its default.
/// Android and Apple read the file as each song arrives. The Windows and Linux
/// sessions hand its path to other programs that read it later, and the cover
/// cache may delete an old file while its song still plays.
BaseCacheManager? mediaSessionArtCache() => switch (defaultTargetPlatform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.macOS => const MediaSessionArtCache(),
  _ => null,
};

/// Where the system media session finds a song's web cover: the app's cover
/// cache, so a cover the app already fetched is neither downloaded nor stored
/// again. The cover cache works before the app shell initializes it.
class MediaSessionArtCache implements BaseCacheManager {
  const MediaSessionArtCache();

  static CacheManager get _cache => CoverCacheManager.instance;

  @override
  Future<FileInfo?> getFileFromMemory(String key) =>
      _cache.getFileFromMemory(key);

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) => _cache.getSingleFile(url, key: key, headers: headers);

  @override
  @Deprecated('Prefer to use the new getFileStream method')
  Stream<FileInfo> getFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) => getFileStream(
    url,
    key: key,
    headers: headers,
  ).where((response) => response is FileInfo).cast<FileInfo>();

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => _cache.getFileStream(
    url,
    key: key,
    headers: headers,
    withProgress: withProgress,
  );

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) => _cache.downloadFile(
    url,
    key: key,
    authHeaders: authHeaders,
    force: force,
  );

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) => _cache.getFileFromCache(key, ignoreMemCache: ignoreMemCache);

  @override
  Future<File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) => _cache.putFile(
    url,
    fileBytes,
    key: key,
    eTag: eTag,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );

  @override
  Future<File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) => _cache.putFileStream(
    url,
    source,
    key: key,
    eTag: eTag,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );

  @override
  Future<void> removeFile(String key) => _cache.removeFile(key);

  @override
  Future<void> emptyCache() => _cache.emptyCache();

  /// The caches behind it belong to the app.
  @override
  Future<void> dispose() async {}
}
