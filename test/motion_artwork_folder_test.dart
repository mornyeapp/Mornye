import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/motion_artwork_folder.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _album = Track(
  id: 'album',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  albumType: 'album',
  totalTracks: 10,
);

const _single = Track(
  id: 'single',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Song',
  duration: 180,
  albumType: 'single',
  totalTracks: 1,
);

DownloadItem _item(Track track, {String? playlist}) => DownloadItem(
  id: track.id,
  track: track,
  service: 'example',
  playlistName: playlist,
  createdAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('album folder rule', () {
    final queue = DownloadQueueNotifier();

    Future<bool> holds(
      AppSettings settings, {
      Track track = _album,
      String? playlist,
      String? path,
    }) {
      final planned = queue.relativeOutputDirFor(
        track,
        settings,
        playlistName: playlist,
      );
      return queue.holdsAlbumFilesFor(
        _item(track, playlist: playlist),
        settings,
        filePath: path ?? p.join('/music', planned, 'Song.flac'),
      );
    }

    test('album folders hold album files', () async {
      for (final structure in ['artist_album', 'album_only', 'year_album']) {
        expect(
          await holds(
            AppSettings(
              folderOrganization: 'album',
              albumFolderStructure: structure,
              separateSingles: false,
            ),
          ),
          isTrue,
          reason: structure,
        );
      }
      expect(
        await holds(
          const AppSettings(
            folderOrganization: 'artist_album',
            separateSingles: false,
          ),
        ),
        isTrue,
      );
      // Albums kept apart from singles still get a folder each.
      expect(
        await holds(
          const AppSettings(
            folderOrganization: 'none',
            separateSingles: true,
            albumFolderStructure: 'artist_album_singles',
          ),
        ),
        isTrue,
      );
    });

    test('shared folders never get an album file', () async {
      for (final organization in ['none', 'artist']) {
        expect(
          await holds(
            AppSettings(
              folderOrganization: organization,
              separateSingles: false,
            ),
          ),
          isFalse,
          reason: organization,
        );
      }
      expect(
        await holds(
          const AppSettings(
            folderOrganization: 'playlist',
            separateSingles: false,
          ),
          playlist: 'Road Trip',
        ),
        isFalse,
      );
      // Every single shares one Singles folder.
      expect(
        await holds(
          const AppSettings(
            folderOrganization: 'none',
            separateSingles: true,
            albumFolderStructure: 'artist_album_singles',
          ),
          track: _single,
        ),
        isFalse,
      );
      // A release named like the Singles folder is still a single there.
      expect(
        await holds(
          const AppSettings(
            folderOrganization: 'none',
            separateSingles: true,
            albumFolderStructure: 'artist_album_singles',
          ),
          track: Track(
            id: 'named',
            name: 'Song',
            artistName: 'Artist',
            albumName: 'Singles',
            duration: 180,
            totalTracks: 2,
          ),
        ),
        isFalse,
      );
      expect(
        await queue.holdsAlbumFilesFor(
          _item(_album.copyWith(albumName: ' ')),
          const AppSettings(
            folderOrganization: 'album',
            separateSingles: false,
          ),
          filePath: '/music/Artist/Song.flac',
        ),
        isFalse,
      );
    });

    test('the song must be in the planned folder', () async {
      const settings = AppSettings(
        folderOrganization: 'album',
        albumFolderStructure: 'artist_album',
        separateSingles: false,
      );
      final planned = queue.relativeOutputDirFor(_album, settings);
      // An earlier copy kept in an older flat layout.
      expect(await holds(settings, path: '/music/Song.flac'), isFalse);
      expect(
        await queue.holdsAlbumFilesFor(
          _item(_album),
          settings,
          filePath: 'content://tree/document/song',
          relativeDir: planned,
        ),
        isTrue,
      );
      expect(
        await queue.holdsAlbumFilesFor(
          _item(_album),
          settings,
          filePath: 'content://tree/document/song',
          relativeDir: 'Other',
        ),
        isFalse,
      );
      expect(
        await queue.holdsAlbumFilesFor(
          _item(_album),
          settings,
          filePath: NetworkStorageService.source(
            'nas',
            'Music/$planned/Song.flac',
          ),
        ),
        isTrue,
      );
    });

    test('custom folders hold an album when its name ends them', () async {
      const backend = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'buildFilename') return null;
        final args = call.arguments as Map;
        final metadata = jsonDecode(args['metadata'] as String) as Map;
        return (args['template'] as String)
            .replaceAll('{album}', '${metadata['album']}')
            .replaceAll('{artist}', '${metadata['artist']}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(backend, null));

      Future<bool> custom(String template) async {
        final settings = AppSettings(
          folderOrganization: 'custom',
          folderPathTemplate: template,
          separateSingles: false,
        );
        final item = _item(_album);
        final folder = template
            .replaceAll('{album}', 'Album')
            .replaceAll('{artist}', 'Artist');
        return queue.holdsAlbumFilesFor(
          item,
          settings,
          filePath: '/music/$folder/Song.flac',
        );
      }

      expect(await custom('{artist}/{album}'), isTrue);
      expect(await custom('{album}/{artist}'), isFalse);
      expect(await custom('{artist}'), isFalse);
    });
  });

  group('MotionArtworkFolder', () {
    late Directory root;
    late File video;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('motion-folder-');
      video = File(p.join(root.path, 'stored.mp4'))
        ..writeAsBytesSync([1, 2, 3]);
    });
    tearDown(() => root.delete(recursive: true));

    test('writes cover.mp4 beside a local song once', () async {
      final album = Directory(p.join(root.path, 'Artist', 'Album'))
        ..createSync(recursive: true);
      final folder = MotionArtworkFolder(directory: () async => root);
      final saves = await Future.wait([
        folder.save(video, song: p.join(album.path, '01.flac')),
        folder.save(video, song: p.join(album.path, '02.flac')),
      ]);
      expect(saves.where((saved) => saved), hasLength(1));
      final cover = File(p.join(album.path, motionArtworkFileName));
      expect(cover.readAsBytesSync(), [1, 2, 3]);
      expect(album.listSync().map((e) => p.basename(e.path)), [
        motionArtworkFileName,
      ]);
      expect(
        await folder.save(video, song: p.join(album.path, '03.flac')),
        isFalse,
      );
    });

    test('keeps a cover the user already has', () async {
      final album = Directory(p.join(root.path, 'Album'))..createSync();
      final cover = File(p.join(album.path, motionArtworkFileName))
        ..writeAsBytesSync([9]);
      final folder = MotionArtworkFolder(directory: () async => root);
      expect(
        await folder.save(video, song: p.join(album.path, '01.flac')),
        isFalse,
      );
      expect(cover.readAsBytesSync(), [9]);
    });

    test('documents and network songs go through their storage', () async {
      final created = <String>[];
      final uploads = <String>[];
      final folder = MotionArtworkFolder(
        directory: () async => root,
        createDocument: (treeUri, relativeDir, name, path) async {
          created.add('$treeUri|$relativeDir|$name|${p.basename(path)}');
          return true;
        },
        upload: (target, file) async {
          uploads.add(target);
          return true;
        },
      );
      expect(
        await folder.save(video, song: 'content://tree/document/song'),
        isFalse,
      );
      expect(
        await folder.save(
          video,
          song: 'content://tree/document/song',
          treeUri: 'content://tree',
          relativeDir: 'Artist/Album',
        ),
        isTrue,
      );
      expect(created, ['content://tree|Artist/Album|cover.mp4|stored.mp4']);
      final song = NetworkStorageService.source('nas', 'Music/Album/01.flac');
      expect(await folder.save(video, song: song), isTrue);
      expect(uploads, [
        NetworkStorageService.source('nas', 'Music/Album/cover.mp4'),
      ]);
    });

    test('finds cover.mp4 beside a local song', () async {
      final album = Directory(p.join(root.path, 'Album'))..createSync();
      final song = p.join(album.path, '01.flac');
      final folder = MotionArtworkFolder(directory: () async => root);
      expect(await folder.find(song), isNull);
      final cover = File(p.join(album.path, motionArtworkFileName))
        ..writeAsBytesSync([4, 5]);
      expect((await folder.find(song))?.source, cover.uri.toString());
      expect(
        (await folder.find(Uri.file(song).toString()))?.source,
        cover.uri.toString(),
      );
      expect(
        await folder.find(NetworkStorageService.source('nas', 'a/b.flac')),
        isNull,
      );
    });

    test('copies a document cover in once per version', () async {
      var modified = 1;
      var copies = 0;
      final folder = MotionArtworkFolder(
        directory: () async => root,
        documents: true,
        sibling: (song, name) async {
          expect(name, motionArtworkFileName);
          return (
            uri: 'content://tree/document/cover',
            size: 2,
            modified: modified,
          );
        },
        copyDocument: (uri) async {
          copies++;
          final temp = File(p.join(root.path, 'temp-$copies.mp4'));
          await temp.writeAsBytes([7, copies]);
          return temp.path;
        },
      );
      final first = await Future.wait([
        folder.find('content://tree/document/song-1'),
        folder.find('content://tree/document/song-2'),
      ]);
      expect(copies, 1);
      expect(first[0]?.source, first[1]?.source);
      final copy = File.fromUri(Uri.parse(first[0]!.source));
      expect(p.isWithin(root.path, copy.path), isTrue);
      expect(copy.readAsBytesSync(), [7, 1]);

      // Another song of the album reuses the copy.
      await folder.find('content://tree/document/song-3');
      expect(copies, 1);

      // A replaced cover is copied again once lookups expire.
      modified = 2;
      folder.forget();
      await folder.find('content://tree/document/song-1');
      expect(copies, 2);
      expect(copy.readAsBytesSync(), [7, 2]);
    });

    test('documents are not read off Android', () async {
      var asked = false;
      final folder = MotionArtworkFolder(
        directory: () async => root,
        documents: false,
        sibling: (_, _) async {
          asked = true;
          return null;
        },
      );
      expect(await folder.find('content://tree/document/song'), isNull);
      expect(asked, isFalse);
    });
  });

  group('songMotionArtworkProvider', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('prefers the folder cover over the saved one', () async {
      final root = await Directory.systemTemp.createTemp('motion-song-');
      addTearDown(() => root.delete(recursive: true));
      final album = Directory(p.join(root.path, 'Album'))..createSync();
      final song = p.join(album.path, '01.flac');
      const saved = MotionArtwork('file:///saved.mp4', aspectRatio: 1);
      final container = ProviderContainer(
        overrides: [
          motionArtworkFolderProvider.overrideWithValue(
            MotionArtworkFolder(directory: () async => root),
          ),
          playerMotionArtworkProvider.overrideWith((ref, album) async => saved),
        ],
      );
      addTearDown(container.dispose);
      Future<MotionArtwork?> read(String source) => container.read(
        songMotionArtworkProvider((
          album: 'Album',
          artist: 'Artist',
          source: source,
        )).future,
      );

      expect((await read(song))?.source, saved.source);
      final cover = File(p.join(album.path, motionArtworkFileName))
        ..writeAsBytesSync([1]);
      container.invalidate(songMotionArtworkProvider);
      expect((await read(song))?.source, cover.uri.toString());
      expect((await read(''))?.source, saved.source);

      container.read(settingsProvider.notifier).setMotionArtworkEnabled(false);
      expect(await read(song), isNull);
    });
  });
}
