import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/folder_cover_file.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/song_folder_file.dart';
import 'package:path/path.dart' as p;

const _jpeg = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1];
const _webp = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50];
const _url = 'https://example.test/cover';

void main() {
  late Directory root;
  late Directory album;
  final requests = <String>[];
  final downloads = <File>[];

  /// A cover store whose downloads hold [bytes], or fail when it is null.
  FolderCoverFile covers(List<int>? bytes, {SongFolderFile? folder}) =>
      FolderCoverFile(
        folder: folder,
        download: (url, maxDimension) async {
          requests.add('$url@$maxDimension');
          if (bytes == null) return null;
          final file = File(p.join(root.path, 'download-${requests.length}'))
            ..writeAsBytesSync(bytes);
          downloads.add(file);
          return file.path;
        },
      );

  String song(String name) => p.join(album.path, name);
  List<String> names() =>
      album.listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('folder-cover-');
    album = Directory(p.join(root.path, 'Artist', 'Album'))
      ..createSync(recursive: true);
    requests.clear();
    downloads.clear();
  });
  tearDown(() => root.delete(recursive: true));

  test('writes folder.jpg once for the songs of an album', () async {
    final store = covers(_jpeg);
    final saves = await Future.wait([
      store.save(_url, maxDimension: 500, song: song('01.flac')),
      store.save(_url, maxDimension: 500, song: song('02.flac')),
    ]);
    expect(saves.where((saved) => saved), hasLength(1));
    expect(
      await store.save(_url, maxDimension: 500, song: song('03.flac')),
      isFalse,
    );
    expect(requests, ['$_url@500']);
    expect(names(), ['folder.jpg']);
    expect(File(song('folder.jpg')).readAsBytesSync(), _jpeg);
    // The downloaded copy does not stay behind.
    expect(downloads.single.existsSync(), isFalse);
  });

  test('names a PNG cover folder.png', () async {
    expect(
      await covers(_png).save(_url, maxDimension: 0, song: song('01.flac')),
      isTrue,
    );
    expect(names(), ['folder.png']);
  });

  test('saves no other image and asks again for the next song', () async {
    final store = covers(_webp);
    for (final name in ['01.flac', '02.flac']) {
      expect(
        await store.save(_url, maxDimension: 0, song: song(name)),
        isFalse,
      );
    }
    expect(requests, hasLength(2));
    expect(names(), isEmpty);
    expect(downloads.every((file) => !file.existsSync()), isTrue);
  });

  test('a failed download saves nothing', () async {
    expect(
      await covers(null).save(_url, maxDimension: 0, song: song('01.flac')),
      isFalse,
    );
    expect(names(), isEmpty);
  });

  test('keeps a cover the user already has', () async {
    final cover = File(song('folder.jpg'))..writeAsBytesSync([9]);
    expect(
      await covers(_jpeg).save(_url, maxDimension: 0, song: song('01.flac')),
      isFalse,
    );
    expect(cover.readAsBytesSync(), [9]);
    expect(names(), ['folder.jpg']);
  });

  test('documents and network songs go through their storage', () async {
    final created = <String>[];
    final uploads = <String>[];
    FolderCoverFile store() => covers(
      _jpeg,
      folder: SongFolderFile(
        createDocument: (treeUri, relativeDir, name, mimeType, path) async {
          created.add('$treeUri|$relativeDir|$name|$mimeType');
          return true;
        },
        upload: (target, file) async {
          uploads.add(target);
          return true;
        },
      ),
    );
    expect(
      await store().save(
        _url,
        maxDimension: 0,
        song: 'content://tree/document/song',
        treeUri: 'content://tree',
        relativeDir: 'Artist/Album',
      ),
      isTrue,
    );
    expect(created, ['content://tree|Artist/Album|folder.jpg|image/jpeg']);
    expect(
      await store().save(
        _url,
        maxDimension: 0,
        song: NetworkStorageService.source('nas', 'Music/Album/01.flac'),
      ),
      isTrue,
    );
    expect(uploads, [
      NetworkStorageService.source('nas', 'Music/Album/folder.jpg'),
    ]);
  });
}
