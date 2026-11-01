import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';

typedef NetworkTagReader =
    Future<Map<String, dynamic>> Function(String url, String name);

/// One bounded native tag read per source, shared by playback and Lyrics.
/// Only the selected track is inspected; browsing does not scan the NAS.
class NetworkMetadataService {
  NetworkMetadataService({
    NetworkStorageService? storage,
    NetworkTagReader? reader,
    Future<Directory> Function()? cacheDirectory,
    int maxConcurrentReads = 1,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _useNativeReader = reader == null,
       _reader =
           reader ??
           ((url, name) =>
               PlatformBridge.readFileMetadata(url, displayName: name)),
       _directory = cacheDirectory ?? getTemporaryDirectory,
       _lanes = List.generate(
         RangeError.checkValueInInterval(maxConcurrentReads, 1, 4),
         (_) => (tail: Future<void>.value(), pending: 0),
       );

  static final instance = NetworkMetadataService();
  final NetworkStorageService _storage;
  final NetworkTagReader _reader;
  final bool _useNativeReader;
  final Future<Directory> Function() _directory;
  final _cache = <String, ({DateTime time, Map<String, dynamic> value})>{};
  final _pending = <String, Future<Map<String, dynamic>>>{};
  final _refreshArtwork = <String>{};
  final List<({Future<void> tail, int pending})> _lanes;
  final _requestIds = <String>{};
  final _subsonicClients = <SubsonicClient>{};
  bool _stopped = false;

  Future<Map<String, dynamic>> read(
    String source, {
    bool forceRefresh = false,
  }) {
    if (_stopped) {
      return Future.error(StateError('Network metadata reader stopped'));
    }
    final uri = Uri.tryParse(source);
    if (uri != null && uri.scheme == 'network') {
      // Their owner answers its own reads, which may wait for a file to
      // arrive; they must not hold up the lanes.
      if (_storage.virtualFor(uri.host) case final virtual?) {
        return virtual.metadata(uri.host, uri.pathSegments.join('/'));
      }
    }
    if (forceRefresh) _cache.remove(source);
    final cached = _cache[source];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 5)) {
      return Future.value(cached.value);
    }
    final pending = _pending[source];
    if (pending != null) return pending;
    if (_pending.length >= 4) {
      return Future.error(StateError('Network metadata reader is busy'));
    }
    var lane = 0;
    for (var i = 1; i < _lanes.length; i++) {
      if (_lanes[i].pending < _lanes[lane].pending) lane = i;
    }
    final requestId = 'network_metadata_${NetworkStorageService.newId()}';
    _requestIds.add(requestId);
    final operation = _lanes[lane].tail.then((_) => _load(source, requestId));
    _lanes[lane] = (
      tail: operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      pending: _lanes[lane].pending + 1,
    );
    final result = operation.whenComplete(() {
      _pending.remove(source);
      _requestIds.remove(requestId);
      _lanes[lane] = (
        tail: _lanes[lane].tail,
        pending: _lanes[lane].pending - 1,
      );
    });
    _pending[source] = result;
    return result;
  }

  /// Retires an in-flight old read too, so it cannot refill the stale cache.
  Future<void> invalidate(String source, {bool refreshArtwork = false}) async {
    _cache.remove(source);
    try {
      await _pending[source];
    } catch (_) {
      // A failed old read must not prevent reading the edited file again.
    }
    _cache.remove(source);
    if (refreshArtwork) {
      if (_refreshArtwork.length >= 32) {
        _refreshArtwork.remove(_refreshArtwork.first);
      }
      _refreshArtwork.add(source);
    }
  }

  /// Scan-owned readers can stop their work without cancelling playback reads.
  Future<void> cancelPending() async {
    _stopped = true;
    for (final client in _subsonicClients.toList()) {
      client.close();
    }
    await Future.wait([
      for (final id in _requestIds.toList())
        PlatformBridge.cancelNativeDataJob(id).catchError((Object _) {}),
    ]);
  }

  void _checkStopped() {
    if (_stopped) throw StateError('Network metadata reader stopped');
  }

  Future<Map<String, dynamic>> _load(String source, String requestId) async {
    _checkStopped();
    final refreshArtwork = _refreshArtwork.remove(source);
    final uri = Uri.parse(source);
    if (uri.scheme != 'network') {
      throw const FormatException('Expected a network source');
    }
    final connection = await _storage.connection(uri.host);
    final path = uri.pathSegments.join('/');
    if (connection.protocol == NetworkProtocol.subsonic) {
      final client = _storage.openSubsonic(connection);
      _subsonicClients.add(client);
      try {
        _checkStopped();
        final song = await client.song(path);
        final metadata = Map<String, dynamic>.from(song.metadata);
        // Asked alongside the cover. Servers without the songLyrics
        // extension fail it, which leaves the tags as they are.
        final lyrics = client.lyrics(song).catchError((Object _) => '');
        try {
          final cover = await client.cachedCover(
            song,
            Directory('${(await _directory()).path}/network_metadata'),
            refresh: refreshArtwork,
          );
          if (cover != null) {
            metadata['cover_path'] = cover;
            await _trimNetworkMetadataCovers(File(cover).parent);
          }
        } catch (_) {
          _checkStopped();
        }
        final text = await lyrics;
        if (text.trim().isNotEmpty) metadata['lyrics'] = text;
        _checkStopped();
        return _remember(source, metadata);
      } finally {
        client.close();
        _subsonicClients.remove(client);
      }
    }
    var name =
        (path.isEmpty
            ? connection.root.pathSegments.lastOrNull
            : uri.pathSegments.lastOrNull) ??
        '';
    if (name.toLowerCase().endsWith('.alac')) {
      name = '${name.substring(0, name.length - 5)}.m4a';
    }
    final url = await _storage.resolve(source);
    _checkStopped();
    Map<String, dynamic>? loaded;
    if (_useNativeReader) {
      try {
        final directory = await _directory();
        _checkStopped();
        loaded = await PlatformBridge.runNativeDataJob({
          'operation': 'network_metadata',
          'url': url,
          'display_name': name,
          'cache_directory': '${directory.path}/network_metadata',
        }, requestId: requestId);
      } on MissingPluginException {
        // Test/unsupported hosts retain the same reader on an isolate.
      }
    }
    if (loaded == null) {
      _checkStopped();
      final tags = await _reader(url, name);
      _checkStopped();
      String directory = '';
      if (tags['cover_base64'] is String &&
          (tags['cover_base64'] as String).isNotEmpty) {
        try {
          directory = '${(await _directory()).path}/network_metadata';
        } catch (_) {}
      }
      loaded = await compute(_cacheNetworkMetadata, {
        'source': source,
        'directory': directory,
        'metadata': tags,
      });
    }
    _checkStopped();
    final result = loaded ?? (throw StateError('Network metadata is empty'));
    final metadata = Map<String, dynamic>.from(result['metadata'] as Map);
    if (metadata['error']?.toString().isNotEmpty == true) {
      throw StateError('Network metadata could not be read');
    }
    final value = Map<String, dynamic>.unmodifiable(metadata);
    if (result['cacheable'] != true) return value;
    return _remember(source, value);
  }

  Map<String, dynamic> _remember(String source, Map<String, dynamic> tags) {
    final value = Map<String, dynamic>.unmodifiable(tags);
    if (utf8.encode(jsonEncode(value)).length > 128 * 1024) return value;
    _cache.remove(source);
    while (_cache.length >= 32) {
      _cache.remove(_cache.keys.first);
    }
    _cache[source] = (time: DateTime.now(), value: value);
    return value;
  }
}

/// Compatibility path keeps cover decoding/hash/directory sorting off the UI
/// isolate too. Production receives only native file paths and small tags.
Future<Map<String, dynamic>> _cacheNetworkMetadata(
  Map<String, dynamic> job,
) async {
  final metadata = Map<String, dynamic>.from(job['metadata'] as Map);
  final cover = metadata.remove('cover_base64');
  if (cover is String &&
      cover.isNotEmpty &&
      (job['directory'] as String).isNotEmpty &&
      cover.length <= 6 * 1024 * 1024) {
    // A cover/cache failure must not discard successfully read tags or lyrics.
    try {
      final directory = Directory(job['directory'] as String);
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/${sha256.convert(utf8.encode(job['source'] as String))}.image',
      );
      await file.writeAsBytes(base64Decode(cover), flush: true);
      metadata['cover_path'] = file.path;
      await _trimNetworkMetadataCovers(directory);
    } catch (_) {}
  }
  return {
    'metadata': metadata,
    'cacheable': utf8.encode(jsonEncode(metadata)).length <= 128 * 1024,
  };
}

Future<void> _trimNetworkMetadataCovers(Directory directory) async {
  final files = await directory
      .list()
      .where((entry) => entry is File)
      .cast<File>()
      .toList();
  final dated = <({File file, DateTime time})>[];
  for (final entry in files) {
    if (entry.path.endsWith('.etag')) continue;
    dated.add((file: entry, time: (await entry.stat()).modified));
  }
  dated.sort((a, b) => b.time.compareTo(a.time));
  for (final old in dated.skip(32)) {
    await old.file.delete();
  }
  // A cover's ETag (`<cover>.etag`) goes with the cover.
  final kept = {for (final entry in dated.take(32)) entry.file.path};
  for (final entry in files) {
    if (entry.path.endsWith('.etag') &&
        !kept.contains(entry.path.substring(0, entry.path.length - 5))) {
      await entry.delete();
    }
  }
}
