import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/network_metadata_service.dart';

class _VirtualSources implements NetworkVirtualSources {
  _VirtualSources(this.tags);

  final Future<Map<String, dynamic>> Function(String id, String path) tags;

  @override
  bool owns(String id) => id == 'phone';

  @override
  Stream<NetworkVirtualSong> songs(String id) => const Stream.empty();

  @override
  Future<String> resolve(String id, String path) async =>
      throw StateError('unexpected resolve');

  @override
  Future<Map<String, dynamic>> metadata(String id, String path) =>
      tags(id, path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NetworkStorageService storage;
  late Directory directory;
  setUp(() async {
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    await storage.save(
      const NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.http,
        address: 'https://nas.test/music/',
      ),
    );
    directory = await Directory.systemTemp.createTemp('network-tag-test-');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.zarz.mornye/backend'),
          null,
        );
    await storage.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'native cache returns a file path and excludes oversized tags from memory',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.zarz.mornye/backend'),
            (call) async {
              expect(call.method, 'runNativeDataJob');
              final args = call.arguments as Map;
              final request = jsonDecode(args['request_json'] as String) as Map;
              expect(request['operation'], 'network_metadata');
              expect(request['url'], startsWith('http://127.0.0.1:'));
              expect(
                request['cache_directory'],
                '${directory.path}/network_metadata',
              );
              expect(args['request_id'], isA<String>());
              calls++;
              return jsonEncode({
                'metadata': {
                  'title': 'Native tags',
                  'cover_path': '/native/cover.image',
                },
                'cacheable': calls != 1,
              });
            },
          );
      final reader = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
      );
      final source = NetworkStorageService.source('nas', 'song.flac');
      expect((await reader.read(source))['cover_path'], '/native/cover.image');
      await reader.read(source);
      await reader.read(source);
      expect(calls, 2);
    },
  );

  test(
    'scan cancellation stops only its native reads and queued work',
    () async {
      final jobs = <String, Completer<String>>{};
      final started = Completer<void>();
      final cancelled = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.zarz.mornye/backend'),
            (call) async {
              final args = call.arguments as Map;
              final id = args['request_id'] as String;
              if (call.method == 'cancelNativeDataJob') {
                cancelled.add(id);
                jobs[id]!.completeError(PlatformException(code: 'CANCELLED'));
                return null;
              }
              final gate = Completer<String>();
              jobs[id] = gate;
              if (jobs.length == 3) started.complete();
              return gate.future;
            },
          );
      final scan = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
        maxConcurrentReads: 2,
      );
      final playback = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
      );
      final futures = [
        for (var i = 0; i < 4; i++)
          scan.read(NetworkStorageService.source('nas', '$i.flac')),
      ];
      final settled = Future.wait(
        futures.map(
          (future) => future.then<Object>(
            (value) => value,
            onError: (Object error) => error,
          ),
        ),
      );
      final playing = playback.read(
        NetworkStorageService.source('nas', 'playing.flac'),
      );
      await started.future;
      await scan.cancelPending();
      expect(cancelled, hasLength(2));
      expect(await settled, everyElement(isNot(isA<Map<String, dynamic>>())));
      expect(jobs, hasLength(3));
      final survivor = jobs.keys.singleWhere((id) => !cancelled.contains(id));
      jobs[survivor]!.complete(
        jsonEncode({
          'metadata': {'title': 'playing'},
          'cacheable': true,
        }),
      );
      expect((await playing)['title'], 'playing');
      await expectLater(
        scan.read(NetworkStorageService.source('nas', 'new.flac')),
        throwsStateError,
      );
    },
  );

  test(
    'playback and Lyrics share one read and embedded cover is cached as a file',
    () async {
      var calls = 0;
      final gate = Completer<Map<String, dynamic>>();
      final reader = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
        reader: (url, name) {
          calls++;
          expect(url, startsWith('http://127.0.0.1:'));
          expect(name, 'Song #1.flac');
          return gate.future;
        },
      );
      final source = NetworkStorageService.source('nas', 'Song #1.flac');
      final a = reader.read(source);
      final b = reader.read(source);
      gate.complete({
        'title': 'Title',
        'lyrics': '[00:01.00]Hello',
        'cover_base64': base64Encode([1, 2, 3]),
      });
      final tags = await a;
      expect(await b, tags);
      expect(calls, 1);
      expect(tags['lyrics'], '[00:01.00]Hello');
      expect(tags.containsKey('cover_base64'), false);
      expect(await File(tags['cover_path'] as String).readAsBytes(), [1, 2, 3]);
      await reader.read(source);
      expect(calls, 1);
    },
  );

  test('rescans can refresh tags without reusing the playback cache', () async {
    var calls = 0;
    final reader = NetworkMetadataService(
      storage: storage,
      reader: (_, _) async => {'title': 'Revision ${++calls}'},
    );
    final source = NetworkStorageService.source('nas', 'song.flac');
    expect((await reader.read(source))['title'], 'Revision 1');
    expect((await reader.read(source))['title'], 'Revision 1');
    expect(
      (await reader.read(source, forceRefresh: true))['title'],
      'Revision 2',
    );
    expect(calls, 2);
  });

  test(
    'a failed read is retryable and corrupt artwork does not discard lyrics',
    () async {
      var calls = 0;
      final reader = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
        reader: (_, name) async {
          if (++calls == 1) return {'error': 'offline'};
          return {'lyrics': 'Plain lyrics', 'cover_base64': 'invalid base64!'};
        },
      );
      final source = NetworkStorageService.source('nas', 'song.mp3');
      await expectLater(reader.read(source), throwsStateError);
      expect((await reader.read(source))['lyrics'], 'Plain lyrics');
      expect(calls, 2);
    },
  );

  test('virtual hosts answer their own tags outside the read lanes', () async {
    final pending = Completer<Map<String, dynamic>>();
    storage.virtualSources = _VirtualSources(
      (id, path) => path == 'slow.flac'
          ? pending.future
          : Future.value({'title': '$id $path'}),
    );
    var nasReads = 0;
    final reader = NetworkMetadataService(
      storage: storage,
      reader: (_, _) async {
        nasReads++;
        return {'title': 'NAS'};
      },
    );
    // A read waiting for its file does not hold up the others.
    final slow = reader.read('network://phone/slow.flac');
    expect(await reader.read('network://phone/fast.flac'), {
      'title': 'phone fast.flac',
    });
    expect(
      (await reader.read(
        NetworkStorageService.source('nas', 'a.flac'),
      ))['title'],
      'NAS',
    );
    pending.complete({'title': 'Slow'});
    expect(await slow, {'title': 'Slow'});
    expect(nasReads, 1);
  });

  test(
    'direct HTTP connection supplies the real filename as a native hint',
    () async {
      await storage.save(
        const NetworkConnection(
          id: 'direct',
          name: 'Single',
          protocol: NetworkProtocol.http,
          address: 'https://nas.test/song.m4a',
        ),
      );
      final reader = NetworkMetadataService(
        storage: storage,
        reader: (_, name) async {
          expect(name, 'song.m4a');
          return {'title': 'Song'};
        },
      );
      expect(
        (await reader.read(
          NetworkStorageService.source('direct', ''),
        ))['title'],
        'Song',
      );
    },
  );
}
