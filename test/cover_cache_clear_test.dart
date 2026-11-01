import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_cache_manager.dart';

class _CacheBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _CacheBinding();
  test('clear retains pending covers and one persistent cache index', () async {
    final directory = await Directory.systemTemp.createTemp('cover-clear-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    final prefixSent = Completer<void>();
    CacheManager? manager;
    Future<void>? pendingWork;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
      await pendingWork?.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'Pending HTTP download did not stop during cleanup',
        ),
      );
      await manager?.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });
    final cover = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6qVQAAAAASUVORK5CYII=',
    );
    final requests = <String, int>{};
    server.listen((request) async {
      final path = request.uri.path;
      requests.update(path, (count) => count + 1, ifAbsent: () => 1);
      final response = request.response
        ..bufferOutput = false
        ..persistentConnection = false
        ..headers.contentType = ContentType('image', 'png')
        ..headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600')
        ..contentLength = cover.length;
      if (path == '/pending.png') {
        response.add(cover.sublist(0, 32));
        await response.flush();
        prefixSent.complete();
        await release.future;
        response.add(cover.sublist(32));
      } else {
        response.add(cover);
      }
      await response.close();
    });
    await CoverCacheManager.initialize();
    final original = CoverCacheManager.instance;
    manager = original;
    original.store.cleanupRunMinInterval = Duration.zero;
    const staleKey = 'https://example.invalid/stale-cover.png';
    final stale = await original.putFile(staleKey, cover, fileExtension: 'png');
    final base = 'http://${server.address.address}:${server.port}';
    final pendingUrl = '$base/pending.png';
    final afterUrl = '$base/after.png';
    final pending = original.getSingleFile(pendingUrl);
    pendingWork = pending.then<void>((_) {}, onError: (Object _) {});
    await prefixSent.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          throw TimeoutException('Deferred HTTP prefix was not flushed'),
    );
    final partial = await _waitForPartialCover(stale);
    expect(await partial.readAsBytes(), cover.sublist(0, 32));
    await CoverCacheManager.clearCache();
    expect(CoverCacheManager.instance, same(original));
    expect(await stale.exists(), isFalse);
    expect(await partial.exists(), isTrue);
    expect(await original.getFileFromCache(staleKey), isNull);
    final after = await CoverCacheManager.instance
        .getSingleFile(afterUrl)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException(
            'Cover requested after clear did not finish',
          ),
        );
    release.complete();
    final completed = await pending.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Pending streamed cover did not finish after release',
      ),
    );
    expect(await completed.readAsBytes(), cover);
    expect(await after.readAsBytes(), cover);
    for (final url in [pendingUrl, afterUrl]) {
      final cached = await CoverCacheManager.instance.getFileFromCache(url);
      expect(cached, isNotNull);
      expect(await cached!.file.readAsBytes(), cover);
    }
    await CoverCacheManager.flush();
    final rows =
        jsonDecode(await File('${directory.path}/null.json').readAsString())
            as List<dynamic>;
    expect(rows.map((row) => (row as Map<String, dynamic>)['key']).toSet(), {
      pendingUrl,
      afterUrl,
    });
    expect(requests, {'/pending.png': 1, '/after.png': 1});
  });
}

Future<File> _waitForPartialCover(File stale) async {
  final directory = Directory(stale.parent.path);
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await for (final file in directory.list()) {
      if (file is File && file.path != stale.path && await file.length() > 0) {
        return file;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException(
    'Pending cover prefix was not written to its cache file',
  );
}
