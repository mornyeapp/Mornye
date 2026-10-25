import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

void main() {
  late Directory dir;
  late String song;
  late String download;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('link_phone_library_');
    song = '${dir.path}/One.flac';
    download = '${dir.path}/Two.MP3';
    File(song).writeAsBytesSync(List.filled(64, 1));
    File(download).writeAsBytesSync(List.filled(32, 2));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String image(String name, List<int> head, {int size = 16}) {
    final path = '${dir.path}/$name';
    File(
      path,
    ).writeAsBytesSync([...head, ...List.filled(size - head.length, 0)]);
    return path;
  }

  String version(List<LinkPhoneSong> songs) => sha256
      .convert(
        utf8.encode(
          songs.map((song) => '${jsonEncode(song.toJson())}\n').join(),
        ),
      )
      .toString();

  group('songs', () {
    test('keep local files and content URIs the desktop takes', () async {
      const mediaUri = 'content://media/external/audio/media/7';
      const documentUri =
          'content://provider.example/document/primary%3AMusic%2FThree.opus';
      Directory('${dir.path}/folder.flac').createSync();
      File('${dir.path}/notes.txt').writeAsStringSync('hi');
      final rows = FakeLibraryRows([
        linkLocalRow(song),
        linkDownloadRow(download),
        linkLocalRow(mediaUri, {'format': 'FLAC'}),
        linkDownloadRow(documentUri),
        linkDownloadRow('content://media/external/audio/media/8', {
          'safFileName': 'Four.m4a',
        }),
        linkLocalRow('content://media/external/audio/media/9'),
        linkLocalRow('content://media/external/audio/media/10', {
          'format': 'xyz',
        }),
        linkLocalRow('network://library-host/Five.flac'),
        linkLocalRow('https://music.example.com/six.flac'),
        linkLocalRow('${dir.path}/gone.flac'),
        linkLocalRow('${dir.path}/notes.txt'),
        linkLocalRow('${dir.path}/folder.flac'),
        linkLocalRow('relative/seven.flac'),
        {'source': 'local', 'item': 'not a map'},
      ]);

      final catalog = await rows.library().build();

      expect(
        [for (final song in catalog.songs) song.name],
        [
          '${linkFileIdFor(song, 64)}.flac',
          '${linkFileIdFor(download, 32)}.mp3',
          '${linkFileIdFor(mediaUri, 0)}.flac',
          '${linkFileIdFor(documentUri, 0)}.opus',
          '${linkFileIdFor('content://media/external/audio/media/8', 0)}.m4a',
        ],
      );
      expect(catalog.songs.first.size, 64);
      expect(catalog.songs[2].size, 0);
      expect(catalog.files[linkFileIdFor(song, 64)]!.extension, 'flac');
      // A content URI's copy names its upload.
      expect(catalog.files[linkFileIdFor(mediaUri, 0)]!.extension, isNull);
    });

    test('use the file ids Play on desktop gives the same files', () async {
      const uri = 'content://media/external/audio/media/7';
      final catalog = await FakeLibraryRows([
        linkLocalRow(song),
        linkLocalRow(uri, {'format': 'flac'}),
      ]).library().build();
      final files = LinkPhoneFiles();
      MediaItem item(String source) =>
          MediaItem(id: source, title: 'Song', extras: {'source': source});

      expect(
        catalog.songs.first.fileId,
        (await files.fileFor(item(song)))!.fileId,
      );
      expect(
        catalog.songs.last.fileId,
        (await files.fileFor(item(uri)))!.fileId,
      );
      expect(catalog.fileNamed(catalog.songs.last.name)!.source, uri);
    });

    test('carry the row fields', () async {
      final catalog = await FakeLibraryRows([
        linkLocalRow(song, {
          'trackName': ' Title ',
          'artistName': 'Artist',
          'albumName': 'Album',
          'albumArtist': 'Album Artist',
          'trackNumber': 3,
          'discNumber': 1,
          'releaseDate': '2021-04-02',
          'genre': 'Jazz',
          'duration': 245,
          'bitrate': 900,
          'sampleRate': 44100,
          'bitDepth': 16,
          'isrc': 'us-abc-21-00001',
          'explicit': 1,
          'scannedAt': '2024-01-02T03:04:05.000Z',
        }),
        linkDownloadRow(download, {
          'trackName': null,
          'downloadedAt': '2024-02-03T00:00:00.000Z',
        }),
      ]).library().build();

      expect(catalog.songs.first.toJson(), {
        'fileId': linkFileIdFor(song, 64),
        'suffix': 'flac',
        'title': 'Title',
        'artist': 'Artist',
        'size': 64,
        'album': 'Album',
        'albumArtist': 'Album Artist',
        'track': 3,
        'disc': 1,
        'year': 2021,
        'genre': 'Jazz',
        'durationMs': 245000,
        'isrc': 'USABC2100001',
        'bitRate': 900,
        'sampleRate': 44100,
        'bitDepth': 16,
        'explicit': true,
        'addedMs': DateTime.utc(2024, 1, 2, 3, 4, 5).millisecondsSinceEpoch,
      });
      // Without a title the file name names it.
      expect(catalog.songs.last.title, 'Two');
      expect(
        catalog.songs.last.addedMs,
        DateTime.utc(2024, 2, 3).millisecondsSinceEpoch,
      );
    });

    test('go once when a file is listed twice', () async {
      final catalog = await FakeLibraryRows([
        linkLocalRow(song),
        linkDownloadRow(song),
      ]).library().build();
      expect(catalog.songs, hasLength(1));
      expect(catalog.version, version(catalog.songs));
    });

    test('are paged with the Local Library switch', () async {
      final rows = FakeLibraryRows([
        for (var i = 0; i < 5; i++)
          linkLocalRow('content://media/external/audio/media/$i', {
            'format': 'mp3',
          }),
      ]);
      final catalog = await rows
          .library(includeLocal: false, pageSize: 2)
          .build();
      expect(catalog.songs, hasLength(5));
      expect([for (final query in rows.queries) query.offset], [0, 2, 4]);
      expect(rows.queries.every((query) => !query.includeLocal), isTrue);
    });
  });

  group('covers', () {
    test('are the local images of at most 1 MiB, each once', () async {
      final jpeg = image('cover.jpg', const [0xFF, 0xD8, 0xFF]);
      // The first bytes name the type, not the extension.
      final png = image('art.jpg', const [0x89, 0x50, 0x4E, 0x47]);
      final webp = image('art.webp', [
        ...ascii.encode('RIFF'),
        0,
        0,
        0,
        0,
        ...ascii.encode('WEBP'),
      ]);
      final large = image('large.jpg', const [
        0xFF,
        0xD8,
        0xFF,
      ], size: linkPhoneCoverMaxBytes + 1);
      final text = '${dir.path}/cover.txt';
      File(text).writeAsStringSync('not an image');
      String uri(int i) => 'content://media/external/audio/media/$i';
      final catalog = await FakeLibraryRows([
        linkLocalRow(song, {'coverPath': jpeg}),
        linkLocalRow(uri(1), {'format': 'flac', 'coverPath': jpeg}),
        linkDownloadRow(download, {'coverUrl': 'file://$png'}),
        linkLocalRow(uri(2), {'format': 'flac', 'coverPath': webp}),
        linkLocalRow(uri(3), {'format': 'flac', 'coverPath': large}),
        linkLocalRow(uri(4), {'format': 'flac', 'coverPath': text}),
        linkDownloadRow(uri(5), {
          'format': 'flac',
          'coverUrl': 'https://images.example.com/a.jpg',
        }),
        linkLocalRow(uri(6), {
          'format': 'flac',
          'coverPath': '${dir.path}/gone.jpg',
        }),
      ]).library().build();

      expect(
        [for (final song in catalog.songs) song.coverId],
        [
          linkFileIdFor(jpeg, 16),
          linkFileIdFor(jpeg, 16),
          linkFileIdFor(png, 16),
          linkFileIdFor(webp, 16),
          null,
          null,
          null,
          null,
        ],
      );
      expect(
        [for (final cover in catalog.covers) (cover.path, cover.ext)],
        [(jpeg, 'jpg'), (png, 'png'), (webp, 'webp')],
      );
    });
  });

  group('version', () {
    test('hashes the songs in order and stays while they do', () async {
      final rows = FakeLibraryRows([
        linkLocalRow(song),
        linkDownloadRow(download),
      ]);
      final library = rows.library();
      final first = await library.build();
      expect(first.version, version(first.songs));
      expect((await library.build()).version, first.version);

      rows.rows = rows.rows.reversed.toList();
      expect((await library.build()).version, isNot(first.version));
    });

    test('changes with a file or a field', () async {
      final rows = FakeLibraryRows([linkLocalRow(song)]);
      final library = rows.library();
      final first = (await library.build()).version;

      File(song).writeAsBytesSync(List.filled(65, 1));
      final resized = (await library.build()).version;
      expect(resized, isNot(first));

      rows.rows = [
        linkLocalRow(song, {'genre': 'Jazz'}),
      ];
      expect((await library.build()).version, isNot(resized));
    });

    test('of an empty Library is the hash of nothing', () async {
      final catalog = await FakeLibraryRows().library().build();
      expect(catalog.songs, isEmpty);
      expect(catalog.version, sha256.convert(const []).toString());
    });
  });

  group('file lookups', () {
    test('build the list when there is none yet', () async {
      final rows = FakeLibraryRows([linkLocalRow(song)]);
      final library = rows.library();
      final name = '${linkFileIdFor(song, 64)}.flac';

      expect((await library.fileNamed(name))!.source, song);
      expect(rows.queries, hasLength(1));
      expect((await library.fileNamed(name))!.source, song);
      expect(rows.queries, hasLength(1));
    });

    test('build again for an unknown name only after a change', () async {
      final rows = FakeLibraryRows([linkLocalRow(song)]);
      final library = rows.library();
      await library.build();
      final name = '${linkFileIdFor(download, 32)}.mp3';

      expect(await library.fileNamed(name), isNull);
      expect(rows.queries, hasLength(1));

      rows.rows = [linkLocalRow(song), linkDownloadRow(download)];
      library.changed();
      expect((await library.fileNamed(name))!.source, download);
      expect(rows.queries, hasLength(2));
      expect(await library.fileNamed('not-a-song'), isNull);
      expect(rows.queries, hasLength(2));
    });

    test('share a running build until the Library changes', () async {
      final rows = FakeLibraryRows([linkLocalRow(song)])
        ..hold = Completer<void>();
      final library = rows.library();
      final first = library.build();
      final joined = library.build();
      library.changed();
      final second = library.build();
      rows.hold!.complete();

      expect(identical(await first, await joined), isTrue);
      expect(identical(await first, await second), isFalse);
      expect(rows.queries, hasLength(2));
      expect(library.last, same(await second));
    });
  });
}
