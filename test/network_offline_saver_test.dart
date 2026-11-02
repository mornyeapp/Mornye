import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_offline_saver.dart';
import 'package:mornye/services/network_storage_service.dart';

LocalLibraryItem song(String path) => LocalLibraryItem(
  id: 'server-song',
  filePath: path,
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  format: 'flac',
  scannedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'origins deduplicate by connection and path, never title and artist',
    () {
      final a = UnifiedLibraryItem.fromLocalLibrary(
        song('network://one/a.flac'),
      );
      final b = UnifiedLibraryItem.fromLocalLibrary(
        song('network://two/a.flac'),
      );
      expect(networkOfflineSongs([a, a, b]).map((song) => song.songId), [
        'network://one/a.flac',
        'network://two/a.flac',
      ]);
      final saved = DownloadHistoryItem(
        id: 'saved',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/phone/a.flac',
        originFilePath: a.filePath,
        service: 'Network offline',
        downloadedAt: DateTime(2026),
      );
      expect(
        networkOfflineSongs([a, UnifiedLibraryItem.fromDownloadHistory(saved)]),
        hasLength(1),
      );
      expect(
        DownloadHistoryItem.fromJson(saved.toJson()).originFilePath,
        a.filePath,
      );
      expect(saved.copyWith(trackName: 'Edited').originFilePath, a.filePath);
    },
  );

  test(
    'original layout preserves Unicode, percent and filename, rejects traversal',
    () {
      final item = song('network://nas/Artist/Album/01.flac');
      final layout = networkOfflineLayout(
        item,
        '/Артист/Album 100%/01 Hello.flac',
      );
      expect(layout.relativeDir, 'Артист/Album 100%');
      expect(layout.fileName, '01 Hello.flac');
      for (final path in [
        '../outside.flac',
        'Album/../../outside.flac',
        r'Album\..\outside.flac',
      ]) {
        expect(() => networkOfflineLayout(item, path), throwsFormatException);
      }
      expect(networkOfflineLayout(item, null).fileName, 'Song - Artist.flac');
    },
  );

  for (final protocol in [
    NetworkProtocol.http,
    NetworkProtocol.webdav,
    NetworkProtocol.subsonic,
  ]) {
    test(
      '${protocol.name} saves original bytes once with durable origin and original folders',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'network_offline_test_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final root = Directory('${temp.path}/downloads');
        final staged = await Directory('${temp.path}/stage').create();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final payload = List.generate(180000, (i) => i % 251);
        final requests = <Uri>[];
        server.listen((request) async {
          requests.add(request.uri);
          if (request.uri.path.contains('getSong')) {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'subsonic-response': {
                  'status': 'ok',
                  'song': {
                    'id': 'song-1',
                    'title': 'Song',
                    'path': 'Artist/Album/01 Original.flac',
                    'suffix': 'flac',
                  },
                },
              }),
            );
          } else {
            request.response.headers.contentType = ContentType('audio', 'flac');
            request.response.contentLength = payload.length;
            request.response.add(payload);
          }
          await request.response.close();
        });
        final storage = NetworkStorageService(
          read: () async => null,
          write: (_) async {},
          ensureAccess: (_) async {},
        );
        addTearDown(storage.dispose);
        await storage.save(
          NetworkConnection(
            id: 'nas',
            name: 'NAS',
            protocol: protocol,
            address: 'http://127.0.0.1:${server.port}/',
          ),
        );
        final path = protocol == NetworkProtocol.subsonic
            ? subsonicSongPath('song-1', 'flac')
            : 'Artist/Album/01 Original.flac';
        final source = NetworkStorageService.source('nas', path);
        final rows = <DownloadHistoryItem>[];
        final transport = NetworkOfflineTransport(storage: storage);
        final saver = LinkOfflineSaver(
          serverId: 'network',
          idPrefix: 'offline',
          serviceName: 'Network offline',
          openTransport: () => transport,
          prepareSong: transport.prepare,
          destination: LinkDownloadFolderDestination(
            AppSettings(downloadDirectory: root.path),
          ),
          record: (item) async => rows.add(item),
          temporaryDirectory: () async => staged,
        );
        final result = await saver.save([
          LinkOfflineSong(item: song(source), songId: source),
        ]);
        expect(result.saved, 1);
        expect(result.failed, 0);
        expect(rows.single.originFilePath, source);
        expect(
          UnifiedLibraryItem.fromDownloadHistory(rows.single).collectionKey,
          UnifiedLibraryItem.fromLocalLibrary(song(source)).collectionKey,
        );
        expect(
          UnifiedLibraryItem.fromDownloadHistory(rows.single).toTrack().id,
          song(source).id,
        );
        expect(
          rows.single.filePath,
          '${root.path}/Artist/Album/01 Original.flac',
        );
        expect(await File(rows.single.filePath).readAsBytes(), payload);
        expect(await staged.list().toList(), isEmpty);
        if (protocol == NetworkProtocol.subsonic) {
          expect(requests.last.path, endsWith('/download.view'));
          expect(requests.last.queryParameters['id'], 'song-1');
          expect(requests.any((uri) => uri.path.contains('stream')), isFalse);
        }
      },
    );
  }

  test(
    'direct HTTP audio keeps the original file name without copying URL tokens',
    () async {
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        const NetworkConnection(
          id: 'nas',
          name: 'NAS',
          protocol: NetworkProtocol.http,
          address:
              'https://example.test/music/Original%20Song.flac?token=private',
        ),
      );
      final transport = NetworkOfflineTransport(storage: storage);
      addTearDown(transport.close);
      final source = NetworkStorageService.source('nas', '');
      final prepared = await transport.prepare(
        LinkOfflineSong(item: song(source), songId: source),
      );
      expect(prepared.fileName, 'Original Song.flac');
      expect(prepared.relativeDir, '');
    },
  );

  test('a 200 HTML error never becomes an offline song', () async {
    final temp = await Directory.systemTemp.createTemp(
      'network_offline_error_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html>Login required</html>');
      await request.response.close();
    });
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
    );
    addTearDown(storage.dispose);
    await storage.save(
      NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.webdav,
        address: 'http://127.0.0.1:${server.port}/',
      ),
    );
    final transport = NetworkFileDownload(storage);
    addTearDown(transport.close);
    await expectLater(
      transport.download(
        NetworkStorageService.source('nas', 'a.flac'),
        File('${temp.path}/a.flac'),
        checkpoint: () {},
        progress: (_, _) {},
      ),
      throwsA(isA<HttpException>()),
    );
    expect(await File('${temp.path}/a.flac').exists(), isFalse);
  });

  test(
    'cancel interrupts a stalled read and never records or publishes a partial song',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'network_offline_cancel_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final staged = await Directory('${temp.path}/stage').create();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.listen((request) async {
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.contentLength = 1000;
        request.response.add(List.filled(10, 1));
        await request.response.flush();
        started.complete();
        await release.future;
        try {
          await request.response.close();
        } catch (_) {}
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        NetworkConnection(
          id: 'nas',
          name: 'NAS',
          protocol: NetworkProtocol.http,
          address: 'http://127.0.0.1:${server.port}/',
        ),
      );
      final transport = NetworkOfflineTransport(storage: storage);
      final cancel = LinkOfflineCancel();
      final source = NetworkStorageService.source('nas', 'a.flac');
      final recorded = <DownloadHistoryItem>[];
      final saved =
          LinkOfflineSaver(
            serverId: 'network',
            openTransport: () => transport,
            prepareSong: transport.prepare,
            destination: LinkDownloadFolderDestination(
              AppSettings(downloadDirectory: '${temp.path}/downloads'),
            ),
            record: (item) async => recorded.add(item),
            temporaryDirectory: () async => staged,
          ).save([
            LinkOfflineSong(item: song(source), songId: source),
          ], cancel: cancel);
      await started.future;
      cancel.cancel();
      final result = await saved.timeout(const Duration(seconds: 3));
      expect(result.cancelled, isTrue);
      expect(result.saved, 0);
      expect(recorded, isEmpty);
      expect(await staged.list().toList(), isEmpty);
      expect(await Directory('${temp.path}/downloads').exists(), isFalse);
    },
  );
}
