import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:path/path.dart' as p;

List<int> _jpeg(int version) => [
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  ...List.filled(60, version),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cover-store-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  CoverStore store({
    required Future<void> Function(String ref, File output) fetch,
    int maxFiles = 2000,
    int maxBytes = 200 * 1024 * 1024,
    Duration retryDelay = const Duration(minutes: 1),
  }) {
    final covers = CoverStore(
      directory: () async => directory,
      fetch: fetch,
      maxFiles: maxFiles,
      maxBytes: maxBytes,
      retryDelay: retryDelay,
    );
    addTearDown(covers.dispose);
    return covers;
  }

  List<String> names() =>
      [for (final entry in directory.listSync()) p.basename(entry.path)]
        ..sort();

  test(
    'a network cover keeps one path while resolve answers a new URL',
    () async {
      final bytes = _jpeg(1);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(bytes);
        await request.response.close();
      });
      final network = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(network.dispose);
      await network.save(
        NetworkConnection(
          id: 'nas',
          name: 'Music server',
          protocol: NetworkProtocol.webdav,
          address: 'http://127.0.0.1:${server.port}/music/',
        ),
      );
      final ref = NetworkStorageService.source('nas', 'Album/cover.jpg');
      // Every resolve answers a new loopback route, which no cache can key.
      expect(await network.resolve(ref), isNot(await network.resolve(ref)));

      final covers = store(fetch: network.downloadCover);
      final path = await covers.file(ref);
      expect(path, isNotNull);
      expect(p.isWithin(directory.path, path!), isTrue);
      expect(await File(path).readAsBytes(), bytes);
      expect(await covers.file(ref), path);
      expect(covers.cachedFile(ref), path);
      expect(requests, 1);

      // A later run finds the same file without fetching it.
      final restarted = store(fetch: network.downloadCover);
      expect(restarted.cachedFile(ref), isNull);
      await restarted.warmUp();
      expect(restarted.cachedFile(ref), path);
      expect(await restarted.file(ref), path);
      expect(requests, 1);
    },
  );

  test('concurrent calls for one reference share one fetch', () async {
    final release = Completer<void>();
    var fetches = 0;
    final covers = store(
      fetch: (ref, output) async {
        fetches++;
        await release.future;
        await output.writeAsBytes(_jpeg(1));
      },
    );
    const ref = 'network://desktop/subsonic/cover/YQ.image';
    final calls = [for (var call = 0; call < 5; call++) covers.file(ref)];
    await pumpEventQueue();
    release.complete();
    final paths = await Future.wait(calls);
    expect(paths.first, isNotNull);
    expect(paths.toSet(), hasLength(1));
    expect(fetches, 1);
  });

  test(
    'a failed fetch leaves no file and waits before fetching again',
    () async {
      var fetches = 0;
      final covers = store(
        fetch: (ref, output) async {
          fetches++;
          await output.writeAsBytes(_jpeg(1).sublist(0, 8));
          throw const HttpException('Connection closed');
        },
      );
      const ref = 'network://desktop/subsonic/cover/YQ.image';
      expect(await covers.file(ref), isNull);
      expect(await covers.file(ref), isNull);
      expect(fetches, 1);
      expect(names(), isEmpty);

      // Bytes that are not an image never become a cover either.
      final invalid = store(
        retryDelay: Duration.zero,
        fetch: (ref, output) async {
          fetches++;
          await output.writeAsString('{"subsonic-response":{}}');
        },
      );
      expect(await invalid.file(ref), isNull);
      expect(await invalid.file(ref), isNull);
      expect(fetches, 3);
      expect(names(), isEmpty);
    },
  );

  test('stored covers start like an image and stay within 16 MiB', () async {
    List<int> bytes = const [];
    final covers = store(
      retryDelay: Duration.zero,
      fetch: (ref, output) => output.writeAsBytes(bytes),
    );
    final images = <String, List<int>>{
      'jpeg': [0xFF, 0xD8, 0xFF, 0xDB],
      'png': [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      'gif': ascii.encode('GIF89a'),
      'webp': [...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP')],
      'bmp': ascii.encode('BM'),
      'heic': [0, 0, 0, 24, ...ascii.encode('ftypheic')],
      'avif': [0, 0, 0, 24, ...ascii.encode('ftypavif')],
    };
    for (final MapEntry(:key, :value) in images.entries) {
      bytes = [...value, 1, 2, 3, 4];
      expect(await covers.file('network://nas/$key'), isNotNull, reason: key);
    }
    final large = Uint8List(NetworkStorageService.maxCoverBytes + 1)
      ..setAll(0, [0xFF, 0xD8, 0xFF]);
    final rejected = {
      'html': utf8.encode('<html>Sign in</html>'),
      'm4a': [0, 0, 0, 24, ...ascii.encode('ftypM4A '), 0, 0],
      'empty': <int>[],
      'large': large,
    };
    for (final MapEntry(:key, :value) in rejected.entries) {
      bytes = value;
      expect(await covers.file('network://nas/$key'), isNull, reason: key);
    }
    expect(names().where((name) => name.endsWith('.tmp')), isEmpty);
  });

  test(
    'changed bytes give a stale cover a new path; the same bytes keep it',
    () async {
      var bytes = _jpeg(1);
      var fetches = 0;
      final covers = store(
        fetch: (ref, output) async {
          fetches++;
          await output.writeAsBytes(bytes);
        },
      );
      const ref = 'network://desktop/subsonic/cover/YQ.image';
      final first = (await covers.file(ref))!;
      expect(await covers.file(ref), first);
      expect(fetches, 1);

      final stale = DateTime.now().subtract(const Duration(days: 2));
      await File(first).setLastModified(stale);
      bytes = _jpeg(2);
      final changed = covers.changes.first;
      // A stale cover shows at once while it is fetched again.
      expect(await covers.file(ref), first);
      expect(await changed.timeout(const Duration(seconds: 10)), ref);
      final second = covers.cachedFile(ref)!;
      expect(second, isNot(first));
      expect(await File(second).readAsBytes(), bytes);
      expect(fetches, 2);
      // The old file stays for whoever shows it until a trim.
      expect(await File(first).exists(), isTrue);

      final restarted = store(
        fetch: (_, _) async => fail('A stored cover is not fetched again'),
      );
      await restarted.warmUp();
      expect(restarted.cachedFile(ref), second);

      await File(second).setLastModified(stale);
      var events = 0;
      final subscription = covers.changes.listen((_) => events++);
      addTearDown(subscription.cancel);
      expect(await covers.file(ref), second);
      // Waits for the background fetch.
      await covers.dispose();
      expect(fetches, 3);
      expect(events, 0);
      expect(covers.cachedFile(ref), second);
      final checked = (await File(second).stat()).modified;
      expect(checked.isAfter(stale.add(const Duration(days: 1))), isTrue);
    },
  );

  test(
    'trim removes superseded, abandoned and least recently checked covers',
    () async {
      var version = 0;
      var fetches = 0;
      Future<void> fetch(String ref, File output) async {
        fetches++;
        await output.writeAsBytes(_jpeg(++version));
      }

      final covers = store(maxFiles: 2, fetch: fetch);
      final now = DateTime.now();
      const a = 'network://nas/a.jpg';
      const b = 'network://nas/b.jpg';
      const c = 'network://nas/c.jpg';
      final oldA = (await covers.file(a))!;
      final oldB = (await covers.file(b))!;
      final pathC = (await covers.file(c))!;
      await File(oldB).setLastModified(now.subtract(const Duration(hours: 3)));
      await File(pathC).setLastModified(now.subtract(const Duration(hours: 2)));
      await File(oldA).setLastModified(now.subtract(const Duration(days: 2)));
      final changed = covers.changes.first;
      await covers.file(a);
      await changed.timeout(const Duration(seconds: 10));
      final pathA = covers.cachedFile(a)!;

      final abandoned = File('${directory.path}/abandoned.tmp')
        ..writeAsBytesSync(_jpeg(9));
      await abandoned.setLastModified(now.subtract(const Duration(hours: 2)));
      File('${directory.path}/fresh.tmp').writeAsBytesSync(_jpeg(9));
      File('${directory.path}/notes.txt').writeAsStringSync('kept');

      await covers.trim();
      expect(
        names(),
        [p.basename(pathA), p.basename(pathC), 'fresh.tmp', 'notes.txt']
          ..sort(),
      );
      expect(covers.cachedFile(b), isNull);
      expect(covers.cachedFile(c), pathC);

      // A trimmed cover is fetched again when asked for.
      final fetched = fetches;
      final pathB = (await covers.file(b))!;
      expect(pathB, isNot(oldB));
      expect(fetches, fetched + 1);

      await File(pathA).setLastModified(now.subtract(const Duration(hours: 1)));
      final budget = store(maxBytes: _jpeg(0).length, fetch: fetch);
      await budget.trim();
      expect(budget.cachedFile(b), pathB);
      expect(budget.cachedFile(a), isNull);
      expect(budget.cachedFile(c), isNull);
      expect(names(), [p.basename(pathB), 'fresh.tmp', 'notes.txt']..sort());
    },
  );

  test('file references pass through while their file exists', () async {
    final covers = store(
      fetch: (_, _) async => fail('File references are never fetched'),
    );
    final file = File('${directory.path}/cover.jpg')
      ..writeAsBytesSync(_jpeg(1));
    for (final ref in [file.path, file.uri.toString()]) {
      expect(covers.cachedFile(ref), file.path, reason: ref);
      expect(await covers.file(ref), file.path, reason: ref);
      expect(CoverStore.fetches(ref), isFalse);
    }
    for (final ref in [
      null,
      '',
      '${directory.path}/missing.jpg',
      'cover.jpg',
      'https://example.test/cover.jpg',
      'content://media/external/images/media/1',
    ]) {
      expect(covers.cachedFile(ref), isNull, reason: ref);
      expect(await covers.file(ref), isNull, reason: ref);
      expect(CoverStore.fetches(ref), isFalse);
    }
    expect(CoverStore.fetches('network://nas/cover.jpg'), isTrue);
  });
}
