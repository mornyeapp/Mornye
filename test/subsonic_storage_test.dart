import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  test(
    'forced artwork refresh changes the decoded image key and survives reconnect',
    () async {
      final client = storage.openSubsonic(server.connection());
      final song = SubsonicSong(server.song);
      final before = await client.cachedCover(song, directory);
      server.cover = [4, 5, 6, 7];
      final refreshed = await client.cachedCover(
        song,
        directory,
        refresh: true,
      );
      expect(refreshed, isNot(before));
      expect(await File(refreshed!).readAsBytes(), [4, 5, 6, 7]);
      expect(await File(before!).exists(), isTrue);
      expect(await File(refreshed).exists(), isTrue);
      expect(await client.cachedCover(song, directory), refreshed);
      client.close();
      final next = storage.openSubsonic(server.connection());
      addTearDown(next.close);
      final requests = server.requests.length;
      expect(await next.cachedCover(song, directory), refreshed);
      expect(server.requests.length, requests);
    },
  );

  test('unchanged artwork keeps its path on a forced refresh', () async {
    final client = storage.openSubsonic(server.connection());
    addTearDown(client.close);
    final song = SubsonicSong(server.song);
    final before = await client.cachedCover(song, directory);
    final old = DateTime.now().subtract(const Duration(hours: 2));
    await File(before!).setLastModified(old);
    final requests = server.methods.length;
    expect(await client.cachedCover(song, directory, refresh: true), before);
    expect(server.methods.length, greaterThan(requests));
    expect((await File(before).stat()).modified.isAfter(old), isTrue);
    expect(
      await directory.list().map((file) => file.path).toList(),
      unorderedEquals([before]),
    );
  });

  test(
    'daily artwork check keeps an unchanged image and moves a changed one',
    () async {
      final client = storage.openSubsonic(server.connection());
      addTearDown(client.close);
      final song = SubsonicSong(server.song);
      final before = await client.cachedCover(song, directory);
      final stale = DateTime.now().subtract(const Duration(days: 2));
      await File(before!).setLastModified(stale);
      expect(await client.cachedCover(song, directory), before);
      expect(await File(before).readAsBytes(), [0, 1, 2, 3]);

      await File(before).setLastModified(stale);
      server.cover = [4, 5, 6, 7];
      final changed = await client.cachedCover(song, directory);
      expect(changed, isNot(before));
      expect(await File(before).readAsBytes(), [0, 1, 2, 3]);
      expect(await File(changed!).readAsBytes(), [4, 5, 6, 7]);
      expect(await client.cachedCover(song, directory), changed);
    },
  );

  test(
    'a stale cover is revalidated by its ETag and a 304 keeps the image',
    () async {
      server.coverEtag = '"v1"';
      final song = SubsonicSong(server.song);
      final client = storage.openSubsonic(server.connection());
      final before = await client.cachedCover(song, directory);
      client.close();
      expect(server.ifNoneMatch.last, isNull);
      expect(await File('$before.etag').readAsString(), '"v1"\n4');
      final stale = DateTime.now().subtract(const Duration(days: 2));
      await File(before!).setLastModified(stale);
      // Never sent: the server answers 304.
      server.cover = [4, 5, 6, 7];
      // A new client, as after a restart, reads the ETag from disk.
      final next = storage.openSubsonic(server.connection());
      addTearDown(next.close);
      expect(await next.cachedCover(song, directory), before);
      expect(server.ifNoneMatch.last, '"v1"');
      expect(await File(before).readAsBytes(), [0, 1, 2, 3]);
      expect(
        DateTime.now().difference((await File(before).stat()).modified),
        lessThan(const Duration(hours: 1)),
      );
      expect(
        await directory.list().map((file) => file.path).toList(),
        unorderedEquals([before, '$before.etag']),
      );
    },
  );

  test('a changed cover behind a new ETag moves to a new path', () async {
    server.coverEtag = '"v1"';
    final client = storage.openSubsonic(server.connection());
    addTearDown(client.close);
    final song = SubsonicSong(server.song);
    final before = await client.cachedCover(song, directory);
    final stale = DateTime.now().subtract(const Duration(days: 2));
    await File(before!).setLastModified(stale);
    server.cover = [4, 5, 6, 7, 8];
    server.coverEtag = '"v2"';
    final changed = await client.cachedCover(song, directory);
    expect(server.ifNoneMatch.last, '"v1"');
    expect(changed, isNot(before));
    expect(await File(changed!).readAsBytes(), [4, 5, 6, 7, 8]);
    expect(await File('$changed.etag').readAsString(), '"v2"\n5');
    expect(await File(before).readAsBytes(), [0, 1, 2, 3]);
    await File(changed).setLastModified(stale);
    expect(await client.cachedCover(song, directory), changed);
    expect(server.ifNoneMatch.last, '"v2"');
  });

  test(
    'covers without a matching ETag are checked by their bytes as before',
    () async {
      final client = storage.openSubsonic(server.connection());
      addTearDown(client.close);
      final song = SubsonicSong(server.song);
      final stale = DateTime.now().subtract(const Duration(days: 2));
      final before = await client.cachedCover(song, directory);
      final validator = File('$before.etag');
      expect(await validator.exists(), isFalse);
      await File(before!).setLastModified(stale);
      expect(await client.cachedCover(song, directory), before);
      expect(server.ifNoneMatch, everyElement(isNull));

      // An older cache has no validator; the next download stores one.
      server.coverEtag = '"v1"';
      await File(before).setLastModified(stale);
      expect(await client.cachedCover(song, directory), before);
      expect(server.ifNoneMatch.last, isNull);
      expect(await validator.readAsString(), '"v1"\n4');

      // A validator written for other bytes is ignored.
      await validator.writeAsString('"v1"\n5');
      await File(before).setLastModified(stale);
      expect(await client.cachedCover(song, directory), before);
      expect(server.ifNoneMatch.last, isNull);

      // A forced refresh reads the image again.
      expect(await client.cachedCover(song, directory, refresh: true), before);
      expect(server.ifNoneMatch.last, isNull);

      // A server that stops sending ETags loses the validator.
      server.coverEtag = null;
      await File(before).setLastModified(stale);
      expect(await client.cachedCover(song, directory), before);
      expect(server.ifNoneMatch.last, '"v1"');
      expect(await validator.exists(), isFalse);
    },
  );

  test('song metadata keeps 32 covers, each with its ETag', () async {
    server.coverEtag = '"v1"';
    final cache = await Directory(
      '${directory.path}/network_metadata',
    ).create();
    final old = DateTime.now().subtract(const Duration(hours: 1));
    for (var i = 0; i < 40; i++) {
      final cover = File('${cache.path}/cover_$i.image');
      await cover.writeAsBytes([i]);
      await File('${cover.path}.etag').writeAsString('"$i"\n1');
      await cover.setLastModified(old.add(Duration(seconds: i)));
    }
    final metadata = NetworkMetadataService(
      storage: storage,
      cacheDirectory: () async => directory,
    );
    final tags = await metadata.read(
      NetworkStorageService.source('fixture', SubsonicSong(server.song).path),
    );
    final cover = tags['cover_path'] as String;
    expect(await File('$cover.etag').readAsString(), '"v1"\n4');
    final names = await cache.list().map((file) => file.path).toSet();
    expect(names.where((name) => name.endsWith('.image')), hasLength(32));
    expect(names.where((name) => name.endsWith('.etag')), hasLength(32));
    expect(names, contains(cover));
    for (var i = 9; i < 40; i++) {
      final kept = '${cache.path}/cover_$i.image';
      expect(names, containsAll([kept, '$kept.etag']));
    }
  });

  test(
    'failed artwork refresh preserves the previously published image',
    () async {
      final client = storage.openSubsonic(server.connection());
      addTearDown(client.close);
      final song = SubsonicSong(server.song);
      final before = await client.cachedCover(song, directory);
      server.mediaError = true;
      await expectLater(
        client.cachedCover(song, directory, refresh: true),
        throwsA(isA<HttpException>()),
      );
      server.mediaError = false;
      expect(await client.cachedCover(song, directory), before);
      expect(
        await directory
            .list()
            .where((file) => file.path.endsWith('.tmp'))
            .toList(),
        isEmpty,
      );
    },
  );

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

  test(
    'covers are read through getCoverArt; error documents are rejected',
    () async {
      final song = SubsonicSong(server.song);
      final source = NetworkStorageService.source('fixture', song.coverPath!);
      final output = File('${directory.path}/cover.image');
      await storage.downloadCover(source, output);
      expect(await output.readAsBytes(), [0, 1, 2, 3]);
      expect(server.requests.last.path, endsWith('/rest/getCoverArt.view'));
      expect(server.requests.last.queryParameters['id'], song.coverId);

      server.mediaError = true;
      final rejected = File('${directory.path}/rejected.image');
      await expectLater(
        storage.downloadCover(source, rejected),
        throwsA(
          isA<HttpException>().having(
            (error) => error.toString(),
            'safe error',
            allOf(
              contains('Subsonic media unavailable'),
              isNot(contains('private')),
            ),
          ),
        ),
      );
      expect(await rejected.exists(), isFalse);
      server.mediaError = false;

      // A song path is not a cover; its audio is never read.
      await expectLater(
        storage.downloadCover(
          NetworkStorageService.source('fixture', song.path),
          rejected,
        ),
        throwsFormatException,
      );
      expect(
        server.requests.where((uri) => uri.path.contains('stream')),
        isEmpty,
      );
    },
  );

  test('a broken cover transfer does not expose the request URL', () async {
    final broken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(broken.close);
    broken.listen((socket) {
      var answered = false;
      socket.listen((_) {
        if (answered) return;
        answered = true;
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\ncontent-type: image/png\r\n'
            'content-length: 100\r\n\r\n',
          ),
        );
        socket.add([0x89, 0x50, 0x4E, 0x47]);
        socket.flush().whenComplete(socket.destroy).ignore();
      }, onError: (Object _) {});
    });
    await storage.save(
      NetworkConnection(
        id: 'broken',
        name: 'Music server',
        protocol: NetworkProtocol.subsonic,
        address: 'http://127.0.0.1:${broken.port}/',
        subsonicAuth: SubsonicAuth.apiKey,
        apiKey: 'private-api-key',
      ),
    );
    await expectLater(
      storage.downloadCover(
        NetworkStorageService.source('broken', subsonicCoverPath('cover')),
        File('${directory.path}/broken.image'),
      ),
      throwsA(
        isA<HttpException>().having(
          (error) => error.toString(),
          'safe error',
          allOf(
            contains('Connection closed'),
            isNot(contains('private-api-key')),
            isNot(contains('getCoverArt')),
          ),
        ),
      ),
    );
  });

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

  /// 120 albums of ten songs and one video. Albums 110 to 114 have no
  /// cover; the songs of albums 115 to 119 have their own.
  List<Map<String, dynamic>> library() => [
    for (var album = 0; album < 120; album++)
      for (var track = 1; track <= 10; track++)
        {
          for (final field in server.song.entries)
            if (field.key != 'coverArt') field.key: field.value,
          'id': 'song $album/$track',
          'title': 'Song $album/$track',
          'album': 'Album $album',
          'albumId': 'album/$album',
          'track': track,
          if (album < 110) 'coverArt': 'album/$album',
          if (album >= 115) 'coverArt': 'song $album/$track',
        },
    {...server.song, 'id': 'video', 'albumId': 'album/0', 'isVideo': true},
  ];

  List<Map<String, String>> requested(String method) => [
    for (final uri in server.requests)
      if (uri.pathSegments.last == '$method.view') uri.queryParameters,
  ];

  test(
    'a Mornye desktop syncs through search3 pages with the same rows',
    () async {
      Future<List<String>> rows() async {
        final scan = await scanner().scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        );
        expect(scan.expectedCount, 1200);
        return [
          for (final row in await scan.rows().toList())
            jsonEncode(row..remove('scannedAt')),
        ]..sort();
      }

      final songs = library();
      server.type = 'mornye';
      // search3 lists songs in export order, which keeps no album together.
      server.library = [...songs]..shuffle(Random(7));
      final searched = await rows();
      expect(requested('getAlbumList2'), hasLength(1));
      expect(requested('getAlbum'), isEmpty);
      final pages = requested('search3');
      expect(pages.map((page) => page['songOffset']), [
        '0',
        '500',
        '1000',
        '1201',
      ]);
      for (final page in pages) {
        expect(page, containsPair('query', ''));
        expect(page, containsPair('songCount', '500'));
        expect(page, containsPair('artistCount', '0'));
        expect(page, containsPair('albumCount', '0'));
      }
      // One artwork request per cover id: 110 albums and 50 songs.
      final covers = requested('getCoverArt').map((query) => query['id']);
      expect(covers, hasLength(160));
      expect(covers.toSet(), hasLength(160));
      expect(
        searched.where((row) => row.contains('"coverPath"')),
        hasLength(1150),
      );

      server.requests.clear();
      server.type = null;
      server.library = songs;
      final walked = await rows();
      expect(requested('getAlbumList2'), hasLength(1));
      expect(requested('getAlbum'), hasLength(120));
      expect(requested('search3'), isEmpty);
      expect(requested('getCoverArt'), isEmpty);
      expect(searched, walked);
    },
  );

  test('a Mornye sync puts the desktop order first in latest', () async {
    Future<List<(String, int)>> scanned() async {
      final scan = await scanner().scan(
        'network://fixture/',
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      // Network rows have no file time, so sort_added is scannedAt.
      return [
        for (final row in await scan.rows().toList())
          (
            row['filePath'] as String,
            DateTime.parse(row['scannedAt'] as String).millisecondsSinceEpoch,
          ),
      ];
    }

    List<String> sources(List<Map<String, dynamic>> songs) => [
      for (final song in songs)
        if (song['isVideo'] != true)
          NetworkStorageService.source('fixture', SubsonicSong(song).path),
    ];

    final songs = library();
    server.type = 'mornye';
    server.library = [...songs]..shuffle(Random(7));
    final searched = await scanned();
    final latest = [...searched]..sort((a, b) => b.$2.compareTo(a.$2));
    expect(latest.map((row) => row.$1), sources(server.library!));
    expect({for (final row in searched) row.$2}, hasLength(1200));

    // Other servers keep the album walk, stamped as each row is read.
    server.type = null;
    server.library = songs;
    final walked = await scanned();
    expect(walked.map((row) => row.$1), sources(songs));
    for (var i = 1; i < walked.length; i++) {
      expect(walked[i].$2, greaterThanOrEqualTo(walked[i - 1].$2));
    }
  });

  test('a forced Mornye sync refreshes each cover once', () async {
    server.type = 'mornye';
    server.library = library()..shuffle(Random(7));
    Future<void> scan({bool forceFullScan = false}) => scanner().scan(
      'network://fixture/',
      forceFullScan: forceFullScan,
      checkpoint: () async {},
      onProgress: (_, _, _) {},
    );
    await scan();
    server.requests.clear();
    await scan(forceFullScan: true);
    expect(requested('getCoverArt'), hasLength(160));
  });

  test('a Mornye desktop with smaller song pages syncs every song', () async {
    server.type = 'mornye';
    // The last page holds only the video.
    server.library = library();
    server.searchPage = 120;
    final scan = await scanner().scan(
      'network://fixture/',
      checkpoint: () async {},
      onProgress: (_, _, _) {},
    );
    expect(scan.expectedCount, 1200);
    final paths = {
      for (final row in await scan.rows().toList()) row['filePath'],
    };
    expect(paths, {
      for (final song in library().take(1200))
        NetworkStorageService.source('fixture', SubsonicSong(song).path),
    });
    expect(requested('search3').map((page) => page['songOffset']), [
      for (var offset = 0; offset <= 1201; offset += 120) '$offset',
      '1201',
    ]);
  });

  test(
    'a Mornye desktop that repeats full song pages cannot publish a truncated catalogue',
    () async {
      server.type = 'mornye';
      server.library = library();
      server.repeatPage = true;
      server.searchPage = 120;
      await expectLater(
        scanner().scan(
          'network://fixture/',
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        ),
        throwsA(isA<HttpException>()),
      );
      expect(requested('search3'), hasLength(2));
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
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
      final pinned = File('${directory.path}/pinned.image');
      await storage.downloadCover(
        NetworkStorageService.source(
          'fixture',
          SubsonicSong(secure.song).coverPath!,
        ),
        pinned,
      );
      expect(await pinned.readAsBytes(), [0, 1, 2, 3]);
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
