import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_library_upload.dart';
import 'package:mornye/services/network_storage_service.dart';

UnifiedLibraryItem local(
  String path, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  String? albumArtist,
  String? releaseDate,
}) => UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: path,
    filePath: path,
    trackName: title,
    artistName: artist,
    albumName: album,
    albumArtist: albumArtist,
    releaseDate: releaseDate,
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
    final songs = networkUploadItems([
      local('/music/a.flac'),
      local('/music/a.flac'),
      local('content://media/tree/primary%3AMusic/document/b.flac'),
      local('network://nas/c.flac'),
      local('/music/album.cue#track02'),
      offline,
    ]);
    expect(songs.map((song) => song.filePath), [
      '/music/a.flac',
      'content://media/tree/primary%3AMusic/document/b.flac',
    ]);
  });

  test('each song goes into its folder under its original name', () async {
    final songs = await networkUploadSongs([
      local('/music/Some/Where/01 Intro.flac', album: 'One'),
      local('/music/b.mp3', album: 'Two'),
      local('/music/b.mp3', album: 'Two'),
    ], folderFor: (item) async => 'Folder ${item.albumName}');
    expect(
      [for (final song in songs) '${song.relativeDir}|${song.fileName}'],
      ['Folder One|01 Intro.flac', 'Folder Two|b.mp3'],
    );
  });

  group('upload folders follow Folder Organization', () {
    final queue = DownloadQueueNotifier();
    final song = local(
      '/music/Some/Where/01 Intro.flac',
      artist: 'Guest feat. Other',
      albumArtist: 'Band',
      album: 'First: Record',
      releaseDate: '2024-03-01',
    );
    Future<String> folder(AppSettings settings, [UnifiedLibraryItem? item]) =>
        queue.libraryFolderFor(item ?? song, settings);

    test('the preset layouts match downloads', () async {
      // The phone's own default keeps every song in the download folder.
      expect(await folder(AppSettings()), '');
      expect(
        await folder(AppSettings(folderOrganization: 'album')),
        'First Record',
      );
      expect(await folder(AppSettings(folderOrganization: 'artist')), 'Band');
      expect(
        await folder(AppSettings(folderOrganization: 'artist_album')),
        'Band/First Record',
      );
      expect(
        await folder(
          AppSettings(
            folderOrganization: 'artist_album',
            useAlbumArtistForFolders: false,
          ),
        ),
        'Guest feat. Other/First Record',
      );
      expect(
        await folder(AppSettings(separateSingles: true)),
        'Albums/Band/First Record',
      );
      expect(
        await folder(
          AppSettings(
            separateSingles: true,
            albumFolderStructure: 'artist_year_album',
          ),
        ),
        'Albums/Band/[2024] First Record',
      );
    });

    test('playlist folders keep the folder in the download folder', () async {
      final settings = AppSettings(
        folderOrganization: 'playlist',
        downloadDirectory: '/music',
      );
      expect(
        await folder(settings, local('/music/Road Trip/a.flac')),
        'Road Trip',
      );
      expect(await folder(settings, local('/music/a.flac')), '');
      expect(await folder(settings, local('/elsewhere/List/a.flac')), '');
    });

    test('a custom template expands from the tags', () async {
      const backend = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'buildFilename') return null;
        final args = call.arguments as Map;
        final metadata = jsonDecode(args['metadata'] as String) as Map;
        return (args['template'] as String).replaceAllMapped(
          RegExp(r'\{([a-z_]+)\}'),
          (match) => '${metadata[match[1]] ?? ''}',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(backend, null));
      expect(
        await folder(
          AppSettings(
            folderOrganization: 'custom',
            folderPathTemplate: '{album_artist}/{year} - {album}',
          ),
        ),
        'Band/2024 - First Record',
      );
    });
  });

  test('content URIs keep their document or download file name', () {
    expect(
      networkUploadFileName(
        local('content://tree/document/primary%3AMusic%2FAlbum%2FTrack%3F.m4a'),
      ),
      'Track.m4a',
    );
    expect(
      networkUploadFileName(
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
      ),
      'Title - Artist.flac',
    );
    expect(
      networkUploadFileName(
        local('content://tree/document/42', title: 'Title'),
      ),
      'Title - Artist.flac',
    );
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

    test('an Android document takes its lyrics sidecar along too', () async {
      const document = 'content://tree/document/primary%3AMusic%2Fa.flac';
      const silent = 'content://tree/document/primary%3AMusic%2Fb.flac';
      final audio = await file('copy.flac');
      final published = <String, String>{};
      final transfers = <String>[];
      final sidecars = <String>[];
      final result =
          await NetworkLibraryUploader(
            connections: () async => writable,
            prepare: (_, relativeDir, fileName) async =>
                NetworkStorageService.source('nas', '$relativeDir/$fileName'),
            publish:
                (
                  target,
                  file,
                  transferId, {
                  required checkpoint,
                  required progress,
                }) async {
                  transfers.add(transferId);
                  if (target.endsWith('.lrc')) sidecars.add(file.path);
                  published[target] = target.endsWith('.lrc')
                      ? await file.readAsString()
                      : 'audio';
                },
            openFile: (path) async =>
                NetworkUploadFile(File(audio), () async {}),
            readDocumentLyrics: (uri) async =>
                uri == document ? '[00:01.00]Line' : null,
          ).upload([
            song(document, 'a.flac'),
            song(silent, 'b.flac'),
          ], folder: 'network://nas/');
      expect(result.saved, 2);
      expect(published, {
        'network://nas/Artist/Album/a.flac': 'audio',
        'network://nas/Artist/Album/a.lrc': '[00:01.00]Line',
        'network://nas/Artist/Album/b.flac': 'audio',
      });
      // The sidecar is a transfer of its own, never the audio's.
      expect(transfers.toSet(), hasLength(3));
      // The sidecar's temporary copy is gone once it is uploaded.
      expect(sidecars, hasLength(1));
      expect(File(sidecars.single).parent.existsSync(), isFalse);
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
