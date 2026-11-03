import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_library_upload.dart';
import 'package:mornye/services/network_storage_service.dart';

UnifiedLibraryItem local(
  String path, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  String? albumArtist,
}) => UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: path,
    filePath: path,
    trackName: title,
    artistName: artist,
    albumName: album,
    albumArtist: albumArtist,
    format: 'flac',
    scannedAt: DateTime(2026),
  ),
);

NetworkConnection connection(String id, NetworkProtocol protocol) =>
    NetworkConnection(
      id: id,
      name: id,
      protocol: protocol,
      address: protocol == NetworkProtocol.smb
          ? 'smb://server/music/'
          : 'https://server.example/music/',
    );

final writable = [
  connection('nas', NetworkProtocol.webdav),
  connection('share', NetworkProtocol.smb),
  connection('server', NetworkProtocol.subsonic),
  connection('web', NetworkProtocol.http),
];

void main() {
  test('only files on this device are uploaded, once each', () {
    final offline = UnifiedLibraryItem.fromDownloadHistory(
      DownloadHistoryItem(
        id: 'offline',
        trackName: 'Saved',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/saved.flac',
        originFilePath: 'network://nas/saved.flac',
        service: 'Network offline',
        downloadedAt: DateTime(2026),
      ),
    );
    final songs = networkUploadSongs([
      local('/music/a.flac'),
      local('/music/a.flac'),
      local('content://media/tree/primary%3AMusic/document/b.flac'),
      local('network://nas/c.flac'),
      local('/music/album.cue#track02'),
      offline,
    ]);
    expect(songs.map((song) => song.path), [
      '/music/a.flac',
      'content://media/tree/primary%3AMusic/document/b.flac',
    ]);
  });

  test('remote layout is Album Artist/Album/original file name', () {
    final song = networkUploadSongs([
      local(
        '/music/Some/Where/01 Intro.flac',
        artist: 'Guest',
        albumArtist: 'Band',
        album: 'First: Record',
      ),
    ]).single;
    expect(song.relativeDir, 'Band/First Record');
    expect(song.fileName, '01 Intro.flac');

    final noAlbum = networkUploadSongs([
      local('/music/x.mp3', album: ' '),
    ]).single;
    expect(noAlbum.relativeDir, 'Artist');
  });

  test('content URIs keep their document or download file name', () {
    final document = networkUploadSongs([
      local('content://tree/document/primary%3AMusic%2FAlbum%2FTrack%3F.m4a'),
    ]).single;
    expect(document.fileName, 'Track.m4a');

    final download = networkUploadSongs([
      UnifiedLibraryItem.fromDownloadHistory(
        DownloadHistoryItem(
          id: 'download',
          trackName: 'Title',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: 'content://tree/document/42',
          safFileName: 'Title - Artist.flac',
          service: 'provider',
          downloadedAt: DateTime(2026),
        ),
      ),
    ]).single;
    expect(download.fileName, 'Title - Artist.flac');

    final unnamed = networkUploadSongs([
      local('content://tree/document/42', title: 'Title'),
    ]).single;
    expect(unnamed.fileName, 'Title - Artist.flac');
  });

  test('only SMB and WebDAV folders of saved connections accept uploads', () {
    expect(canUploadToNetworkFolder('network://nas/', writable), isTrue);
    expect(
      canUploadToNetworkFolder('network://share/Music/', writable),
      isTrue,
    );
    expect(canUploadToNetworkFolder('network://server/', writable), isFalse);
    expect(canUploadToNetworkFolder('network://web/', writable), isFalse);
    expect(canUploadToNetworkFolder('network://gone/', writable), isFalse);
    expect(canUploadToNetworkFolder('network://nas/a.flac', writable), isFalse);
    expect(canUploadToNetworkFolder('/music/', writable), isFalse);
    expect(canUploadToNetworkFolder('', writable), isFalse);
  });

  test('rescans only the network Library folders that received files', () {
    final sources = [
      const LocalLibrarySource(
        id: 'root',
        path: 'network://nas/',
        displayName: 'NAS',
      ),
      const LocalLibrarySource(
        id: 'other',
        path: 'network://nas/Other/',
        displayName: 'Other',
      ),
      const LocalLibrarySource(
        id: 'off',
        path: 'network://nas/Band',
        displayName: 'Off',
        enabled: false,
      ),
      const LocalLibrarySource(
        id: 'band',
        path: 'network://nas/Band',
        displayName: 'Band',
      ),
      const LocalLibrarySource(id: 'phone', path: '/music', displayName: 'M'),
    ];
    expect(
      networkUploadSourcesToRescan(sources, ['network://nas/Band/A/x.flac']),
      ['root', 'band'],
    );
    expect(networkUploadSourcesToRescan(sources, const []), isEmpty);
  });

  group('uploader', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('library-upload-test-');
    });
    tearDown(() => temp.delete(recursive: true));

    Future<String> file(String name) async {
      final file = File('${temp.path}/$name');
      await file.writeAsBytes([1, 2, 3]);
      return file.path;
    }

    NetworkUploadSong song(String path, String fileName) => NetworkUploadSong(
      path: path,
      title: fileName,
      relativeDir: 'Artist/Album',
      fileName: fileName,
    );

    test('read-only destinations fail before any file is touched', () async {
      var prepared = 0;
      final uploader = NetworkLibraryUploader(
        connections: () async => writable,
        prepare: (_, _, _) async {
          prepared++;
          return 'network://server/x.flac';
        },
        publish: (_, _, _, {required checkpoint, required progress}) async {},
      );
      for (final folder in ['network://server/', 'network://gone/']) {
        await expectLater(
          uploader.upload([song('/music/a.flac', 'a.flac')], folder: folder),
          throwsA(isA<NetworkUploadReadOnly>()),
        );
      }
      expect(prepared, 0);
    });

    test('counts uploaded, already there and failed songs', () async {
      final released = <String>[];
      final published = <String>[];
      final prepares = <String>[];
      final a = await file('a.flac');
      final b = await file('b.flac');
      final c = await file('c.flac');
      final uploader = NetworkLibraryUploader(
        connections: () async => writable,
        prepare: (folder, relativeDir, fileName) async {
          prepares.add('$folder|$relativeDir|$fileName');
          // b.flac is already on the server; nothing replaces it.
          return fileName == 'b.flac'
              ? null
              : NetworkStorageService.source('nas', '$relativeDir/$fileName');
        },
        publish:
            (target, file, _, {required checkpoint, required progress}) async {
              if (target.endsWith('c.flac')) {
                throw StateError('Network destination already contains a file');
              }
              progress(3, 3);
              published.add(target);
            },
        openFile: (path) async {
          if (path.endsWith('missing.flac')) {
            throw FileSystemException('missing', path);
          }
          return NetworkUploadFile(File(path), () async => released.add(path));
        },
      );
      final progress = <LinkOfflineProgress>[];
      final result = await uploader.upload(
        [
          song(a, 'a.flac'),
          song(b, 'b.flac'),
          song(c, 'c.flac'),
          song('/music/missing.flac', 'missing.flac'),
        ],
        folder: 'network://nas/',
        onProgress: progress.add,
      );
      expect(result.saved, 1);
      expect(result.skipped, 1);
      expect(result.failed, 2);
      expect(result.cancelled, isFalse);
      expect(result.uploaded, ['network://nas/Artist/Album/a.flac']);
      expect(published, result.uploaded);
      expect(prepares.first, 'network://nas/|Artist/Album|a.flac');
      // Every opened file is released, uploaded or not.
      expect(released, [a, c]);
      expect(progress.map((p) => p.done).toSet(), {0, 1, 2, 3});
      expect(progress.last.total, 4);
    });

    test('a lyrics sidecar goes along without replacing anything', () async {
      final audio = await file('a.flac');
      await file('a.lrc');
      final published = <String>[];
      final result = await NetworkLibraryUploader(
        connections: () async => writable,
        prepare: (_, relativeDir, fileName) async =>
            NetworkStorageService.source('nas', '$relativeDir/$fileName'),
        publish:
            (target, file, _, {required checkpoint, required progress}) async {
              if (target.endsWith('.lrc')) {
                published.add('${file.path.split('/').last} -> $target');
                throw StateError('Network destination already contains a file');
              }
              published.add(target);
            },
        openFile: (path) async => NetworkUploadFile(File(path), () async {}),
      ).upload([song(audio, 'a.flac')], folder: 'network://nas/');
      expect(result.saved, 1);
      expect(result.failed, 0);
      expect(published, [
        'network://nas/Artist/Album/a.flac',
        'a.lrc -> network://nas/Artist/Album/a.lrc',
      ]);
    });

    test('cancelling stops the run without counting a failure', () async {
      final cancel = LinkOfflineCancel();
      final a = await file('a.flac');
      final b = await file('b.flac');
      final published = <String>[];
      final result =
          await NetworkLibraryUploader(
            connections: () async => writable,
            prepare: (_, relativeDir, fileName) async =>
                NetworkStorageService.source('nas', '$relativeDir/$fileName'),
            publish:
                (
                  target,
                  file,
                  _, {
                  required checkpoint,
                  required progress,
                }) async {
                  cancel.cancel();
                  checkpoint();
                  published.add(target);
                },
            openFile: (path) async =>
                NetworkUploadFile(File(path), () async {}),
          ).upload(
            [song(a, 'a.flac'), song(b, 'b.flac')],
            folder: 'network://nas/',
            cancel: cancel,
          );
      expect(result.cancelled, isTrue);
      expect(result.saved, 0);
      expect(result.failed, 0);
      expect(published, isEmpty);
    });
  });
}
