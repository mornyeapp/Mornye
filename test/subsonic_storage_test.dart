import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_storage_error.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/subsonic_fixture.dart';
import 'support/network_scan_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late SubsonicFixture server;
  late NetworkStorageService storage;
  late Directory directory;
  setUp(() async {
    server = await SubsonicFixture.start();
    directory = await Directory.systemTemp.createTemp('subsonic-test-');
    String? saved;
    storage = NetworkStorageService(
      read: () async => saved,
      write: (value) async => saved = value,
      ensureAccess: (_) async {},
    );
    await storage.save(server.connection());
  });
  tearDown(() async {
    await storage.dispose();
    await server.close();
    await directory.delete(recursive: true);
  });

  for (final auth in SubsonicAuth.values) {
    test(
      'auth $auth preserves the base path and sends no Basic credentials',
      () async {
        final connection = server.connection(auth: auth, path: '/prefix/rest/');
        await storage.list(connection);
        await storage.list(connection);
        final query = server.requests.first.queryParameters;
        expect(
          server.requests.map((uri) => uri.path),
          everyElement('/prefix/rest/ping.view'),
        );
        expect(server.authorizations, everyElement(isNull));
        expect(query['v'], '1.16.1');
        switch (auth) {
          case SubsonicAuth.saltedToken:
            expect(
              query['t'],
              md5
                  .convert(utf8.encode('${connection.password}${query['s']}'))
                  .toString(),
            );
            expect(query['u'], connection.username);
            expect(query.keys, isNot(contains('p')));
            expect(query.keys, isNot(contains('apiKey')));
            expect(server.salts.toSet(), hasLength(2));
          case SubsonicAuth.password:
            expect(
              query['p'],
              'enc:${utf8.encode(connection.password).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
            );
            expect(query.keys, isNot(contains('apiKey')));
            expect(query.keys, isNot(contains('t')));
          case SubsonicAuth.apiKey:
            expect(query['apiKey'], connection.apiKey);
            expect(
              query.keys.toSet().intersection({'u', 'p', 't', 's'}),
              isEmpty,
            );
        }
        final restored = NetworkConnection.fromJson(connection.toJson());
        expect(restored.subsonicAuth, auth);
        expect(restored.apiKey, connection.apiKey);
      },
    );
  }

  test(
    'browse, paging, Unicode identifiers, search and extended metadata',
    () async {
      final connection = server.connection();
      final root = await storage.list(connection);
      final artists = await storage.list(connection, root.first.path);
      final albums = await storage.list(connection, artists.single.path);
      final songs = await storage.list(connection, albums.single.path);
      expect(songs, hasLength(2));
      expect(songs.first.song!.title, 'A song');
      expect(server.requests.last.queryParameters['id'], 'album/1');
      final client = storage.openSubsonic(connection);
      try {
        final song = await client.song(songs.first.path);
        expect(server.requests.last.queryParameters['id'], server.song['id']);
        expect(song.metadata, containsPair('bpm', 120));
        expect(song.metadata, containsPair('mood', 'Calm'));
        expect(song.metadata, containsPair('replaygain_track_gain', '-4.2 dB'));
        expect(song.metadata, containsPair('sample_rate', 96000));
      } finally {
        client.close();
      }
      final results = await storage.searchSubsonic(connection, '  日本語 &  ');
      expect(results.first.song!.id, server.song['id']);
      expect(server.requests.last.queryParameters['query'], '日本語 &');
      server.albumCount = 201;
      final page = await storage.list(connection, 'subsonic/albums/');
      expect(page, hasLength(201));
      final next = await storage.list(connection, page.last.path);
      expect(next.single.name, 'Album 200');
    },
  );

  test(
    'stream and artwork use fresh authentication, support range and restore',
    () async {
      final song = SubsonicSong(server.song);
      final source = NetworkStorageService.source('fixture', song.path);
      final art = NetworkStorageService.source('fixture', song.coverPath!);
      final saved = PlayableMedia(
        id: source,
        source: source,
        title: song.title,
        artist: song.artist,
        networkArtworkSource: art,
      ).toJson();
      expect(jsonEncode(saved), isNot(contains('private-')));
      final restored = PlayableMedia.fromJson(saved)!;
      final url = await storage.resolve(restored.source);
      expect(Uri.parse(url).query, isEmpty);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.getUrl(Uri.parse(url));
      request.headers.set('range', 'bytes=1-2');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 1-2/4');
      expect(await response.expand((chunk) => chunk).toList(), [1, 2]);
      expect(server.requests.last.queryParameters['format'], 'raw');
      expect(server.requests.last.queryParameters['id'], server.song['id']);
      final head = await (await http.openUrl('HEAD', Uri.parse(url))).close();
      await head.drain<void>();
      expect(head.contentLength, 4);
      expect(server.methods.last, 'GET');
      final cover = await (await http.getUrl(
        Uri.parse(await storage.resolve(restored.networkArtworkSource!)),
      )).close();
      expect(cover.headers.contentType!.mimeType, 'image/png');
      await cover.drain<void>();
      expect(server.salts.toSet(), hasLength(3));
      expect(server.authorizations, everyElement(isNull));
      expect(await storage.canDeleteFile(source), isFalse);
      await expectLater(
        storage.checkUploadAccess(NetworkStorageService.source('fixture', '')),
        throwsFormatException,
      );
    },
  );

  test(
    'API errors and media error documents do not leak server messages',
    () async {
      server.errorCode = 40;
      try {
        await storage.list(server.connection());
        fail('Expected an authentication failure');
      } on SubsonicException catch (error) {
        expect(
          classifyNetworkStorageError(error),
          NetworkStorageError.authentication,
        );
        expect(error.toString(), isNot(contains('private')));
      }
      server.errorCode = null;
      server.mediaError = true;
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final source = NetworkStorageService.source(
        'fixture',
        SubsonicSong(server.song).path,
      );
      final response = await (await http.getUrl(
        Uri.parse(await storage.resolve(source)),
      )).close();
      expect(response.statusCode, 502);
      expect(
        await utf8.decoder.bind(response).join(),
        isNot(contains('private')),
      );
    },
  );

  test('transport failures do not expose authenticated request URLs', () async {
    server.disconnect = true;
    await expectLater(
      storage.list(server.connection(auth: SubsonicAuth.apiKey)),
      throwsA(
        isA<HttpException>().having(
          (error) => error.toString(),
          'safe error',
          allOf(
            isNot(contains('private-api-key')),
            isNot(contains('apiKey=')),
            isNot(contains('/ping.view')),
          ),
        ),
      ),
    );
  });

  NetworkLibraryScanner scanner() => NetworkLibraryScanner(
    storage: storage,
    supportDirectory: () async => directory,
    temporaryDirectory: () async => directory,
  );

  test(
    'catalog sync deduplicates, caches artwork and never reads audio bytes',
    () async {
      server.albumCount = 201;
      final scan = await scanner().scan(
        'network://fixture/',
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      expect(scan.expectedCount, 1);
      final row = (await scan.rows().toList()).single;
      expect(row['trackName'], 'A song');
      expect(row['duration'], 243);
      expect(row['bitDepth'], 24);
      expect(row['replaygain_album_gain'], '-3.5 dB');
      expect(await File(row['coverPath'] as String).readAsBytes(), [
        0,
        1,
        2,
        3,
      ]);
      expect(
        server.requests.where((uri) => uri.path.contains('getCoverArt')),
        hasLength(1),
      );
      expect(
        server.requests.where((uri) => uri.path.contains('stream')),
        isEmpty,
      );
      expect(jsonEncode(row), isNot(contains('private')));
      final metadata = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
      );
      final tags = await metadata.read(row['filePath'] as String);
      expect(tags['title'], 'A song');
      expect(tags['cover_path'], isNotNull);
      expect(
        server.requests.where((uri) => uri.path.contains('stream')),
        isEmpty,
      );
    },
  );

  test('lyrics come from the songLyrics extension', () async {
    final source = NetworkStorageService.source(
      server.connection().id,
      subsonicSongPath(server.song['id'] as String, 'flac'),
    );
    Future<Object?> lyrics() async {
      final metadata = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
      );
      final tags = await metadata.read(source);
      expect(tags['title'], 'A song');
      return tags['lyrics'];
    }

    expect(await lyrics(), isNull, reason: 'no songLyrics extension');
    expect(
      server.requests.map((uri) => uri.pathSegments.last),
      contains('getLyricsBySongId.view'),
    );

    server.lyricsList = {
      'structuredLyrics': [
        {
          'lang': 'xxx',
          'synced': false,
          'line': [
            {'value': 'Plain'},
          ],
        },
        {
          'kind': 'translation',
          'lang': 'xxx',
          'synced': true,
          'line': [
            {'start': 0, 'value': 'Translated'},
          ],
        },
        {
          'lang': 'xxx',
          'synced': true,
          'offset': 100,
          'line': [
            {'start': 50, 'value': 'First'},
            {'start': 61234, 'value': 'Second'},
          ],
        },
      ],
    };
    expect(await lyrics(), '[00:00.00]First\n[01:01.13]Second');

    server.lyricsList = {
      'structuredLyrics': [
        {
          'lang': 'xxx',
          'synced': false,
          'line': [
            {'value': 'One'},
            {'value': 'Two'},
          ],
        },
      ],
    };
    expect(await lyrics(), 'One\nTwo');

    const stored = '[00:01.00]v1:<00:01.00>Word <00:01.50>timed';
    server.lyricsList = {
      'structuredLyrics': [
        {
          'lang': 'xxx',
          'synced': true,
          'line': [
            {'start': 1000, 'value': 'Word timed'},
          ],
          'mornyeRaw': stored,
        },
      ],
    };
    expect(await lyrics(), stored);

    server.lyricsList = {'structuredLyrics': <Object>[]};
    expect(await lyrics(), isNull);
  });

  test(
    'failed catalogue is never published as an empty or partial scan',
    () async {
      server.albumCount = 2;
      server.errorCode = 70;
      server.failMethod = 'getAlbum';
      server.failAlbum = 'album/1';
      var processed = 0;
      await expectLater(
        scanner().scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (count, _, _) => processed = count,
        ),
        throwsA(isA<SubsonicException>()),
      );
      expect(processed, 1);
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'a server that repeats full pages cannot publish a truncated catalogue',
    () async {
      server.albumCount = 200;
      server.repeatPage = true;
      await expectLater(
        scanner().scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        ),
        throwsA(isA<HttpException>()),
      );
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'a partial output write failure removes the scan and allows retry',
    () async {
      final worker = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => directory,
        temporaryDirectory: () async => directory,
        openOutput: (file) async => InstrumentedScanOutput(
          await file.open(mode: FileMode.write),
          writeError: StateError('disk full'),
        ),
      );
      await expectLater(
        worker.scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        ),
        throwsStateError,
      );
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
      expect(
        (await scanner().scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        )).expectedCount,
        1,
      );
    },
  );

  test(
    'cancel interrupts a blocked catalogue request and permits retry',
    () async {
      server.blockMethod = 'getAlbum';
      final worker = scanner();
      final pending = worker.scan(
        'network://fixture/',
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      final failure = expectLater(pending, throwsA(anything));
      await server.held.future;
      await worker.cancelPending();
      await failure;
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
      server.blockMethod = null;
      server.release.complete();
      expect(
        (await worker.scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        )).expectedCount,
        1,
      );
    },
  );

  test(
    'self-signed TLS requires a certificate pin for API, artwork and playback',
    () async {
      final secure = await SubsonicFixture.start(
        context: SecurityContext()
          ..useCertificateChain('test/fixtures/network_tls/cert.pem')
          ..usePrivateKey('test/fixtures/network_tls/key.pem'),
      );
      addTearDown(secure.close);
      String? pin;
      try {
        await storage.list(secure.connection());
        fail('Untrusted TLS must be rejected');
      } on NetworkCertificateException catch (error) {
        pin = error.fingerprint;
      }
      expect(pin, isNotNull);
      final trusted = secure.connection(fingerprint: pin);
      await storage.list(trusted);
      await storage.save(trusted);
      final client = storage.openSubsonic(trusted);
      try {
        expect(
          await client.cachedCover(SubsonicSong(secure.song), directory),
          isNotNull,
        );
      } finally {
        client.close();
      }
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final response = await (await http.getUrl(
        Uri.parse(
          await storage.resolve(
            NetworkStorageService.source(
              'fixture',
              SubsonicSong(secure.song).path,
            ),
          ),
        ),
      )).close();
      expect(response.statusCode, 200);
      expect(await response.expand((chunk) => chunk).toList(), [0, 1, 2, 3]);
    },
  );

  test('redirects never forward API keys to another origin', () async {
    var forwarded = false;
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    other.listen((request) async {
      forwarded = true;
      await request.response.close();
    });
    addTearDown(() => other.close(force: true));
    server.redirect = 'http://127.0.0.1:${other.port}/';
    await expectLater(
      storage.list(server.connection(auth: SubsonicAuth.apiKey)),
      throwsA(isA<HttpException>()),
    );
    expect(forwarded, isFalse);
  });
}
