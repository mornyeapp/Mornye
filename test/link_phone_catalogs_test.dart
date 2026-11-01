import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';

const _phone = 'phone-1';

String _fileId(int i) => i.toRadixString(16).padLeft(32, '0');

Map<String, dynamic> _song(int i, {String? coverId}) => LinkPhoneSong(
  fileId: _fileId(i),
  suffix: 'flac',
  title: 'Song $i',
  artist: 'Artist',
  durationMs: 180000,
  coverId: coverId,
).toJson();

void main() {
  late Directory root;
  late LinkHostRouter router;
  late LinkPhoneCatalogs catalogs;
  late Set<String> paired;
  late List<String> commits;
  final sourceId = linkPhoneSourceId(_phone);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-phones-');
    paired = {_phone};
    commits = [];
    router = LinkHostRouter();
    catalogs = LinkPhoneCatalogs(
      root: () async => root,
      paired: (deviceId) async => paired.contains(deviceId),
      onCommit: commits.add,
    )..register(router);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Object?> call(
    String op,
    String method, {
    Map<String, dynamic> args = const {},
    String deviceId = _phone,
  }) => router.dispatch(
    LinkRequest(
      requestId: 'r1',
      op: op,
      deviceId: deviceId,
      args: {...args, '_method': method},
    ),
  );

  Future<Object?> page(
    int offset,
    int total,
    List<Object?> songs, {
    String version = 'v1',
    String deviceId = _phone,
  }) => call(
    LinkOps.phoneCatalog,
    'POST',
    deviceId: deviceId,
    args: {
      'version': version,
      'offset': offset,
      'total': total,
      'songs': songs,
    },
  );

  Matcher linkError(String code) =>
      isA<LinkException>().having((error) => error.code, 'code', code);

  test(
    'matches player states without file ids within one phone catalog',
    () async {
      await page(0, 3, [
        {..._song(1), 'title': 'Same Song', 'durationMs': 150000},
        {..._song(2), 'title': 'Same Song', 'durationMs': 180000},
        {..._song(3), 'isrc': 'USABC2400001'},
      ]);
      final matched = await catalogs.songForRef(
        sourceId,
        const TrackRef(
          title: 'same song',
          artist: 'ARTIST',
          durationMs: 180500,
        ),
      );
      expect(matched!.fileId, _fileId(2));
      final isrc = await catalogs.songForRef(
        sourceId,
        const TrackRef(
          title: 'Different spelling',
          artist: 'Different artist',
          isrc: 'US-ABC-24-00001',
        ),
      );
      expect(isrc!.fileId, _fileId(3));
      expect(
        await catalogs.songForRef(
          sourceId,
          const TrackRef(
            title: 'Same Song',
            artist: 'Artist',
            durationMs: 210000,
          ),
        ),
        isNull,
      );
      expect(
        await catalogs.songForRef(
          linkPhoneSourceId('another-phone'),
          const TrackRef(title: 'Same Song', artist: 'Artist'),
        ),
        isNull,
      );
    },
  );

  test('commits the pages in order and reports the version', () async {
    expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': null});

    expect(await page(0, 3, [_song(1), _song(2)]), {'ok': true});
    // Nothing is committed before the last page.
    expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': null});
    expect(commits, isEmpty);

    expect(await page(2, 3, [_song(3)]), {'ok': true});
    expect(commits, [_phone]);
    expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': 'v1'});
    final songs = await catalogs.songs(sourceId).toList();
    expect(
      [for (final song in songs) song.title],
      ['Song 1', 'Song 2', 'Song 3'],
    );
    expect((await catalogs.song(sourceId, _fileId(2)))?.title, 'Song 2');
    expect(await catalogs.song(sourceId, _fileId(9)), isNull);

    // A fresh store reads the version from disk.
    final reopened = LinkPhoneCatalogs(
      root: () async => root,
      paired: (_) async => true,
    );
    expect(await reopened.version(sourceId), 'v1');
    expect(await reopened.sourceIds(), [sourceId]);
  });

  test('a newer snapshot removes old songs from a persisted catalog', () async {
    await page(0, 3, [_song(1), _song(2), _song(3)]);
    catalogs = LinkPhoneCatalogs(
      root: () async => root,
      paired: (deviceId) async => paired.contains(deviceId),
      onCommit: commits.add,
    )..register(router);

    // A partial upload must keep the last complete snapshot intact.
    await page(0, 2, [_song(1)], version: 'v2');
    expect(await catalogs.song(sourceId, _fileId(2)), isNotNull);
    await page(1, 2, [_song(3)], version: 'v2');

    expect(await catalogs.song(sourceId, _fileId(2)), isNull);
    expect(
      (await catalogs.songs(sourceId).toList()).map((song) => song.fileId),
      [_fileId(1), _fileId(3)],
    );
    expect(await catalogs.version(sourceId), 'v2');
  });

  test('leaves out invalid songs while counting them', () async {
    await page(0, 2, [
      _song(1),
      {'fileId': 'bad', 'suffix': 'flac', 'title': 'Bad'},
    ]);
    expect(commits, [_phone]);
    expect((await catalogs.songs(sourceId).toList()).single.title, 'Song 1');
  });

  test('an out-of-order page is invalid and offset 0 starts over', () async {
    await page(0, 4, [_song(1), _song(2)]);
    await expectLater(page(3, 4, [_song(4)]), throwsA(linkError('invalid')));
    // The unfinished upload is gone, so its next page is out of order too.
    await expectLater(
      page(2, 4, [_song(3), _song(4)]),
      throwsA(linkError('invalid')),
    );
    await expectLater(
      page(0, 1, [_song(5)], version: 'v2'),
      completion({'ok': true}),
    );
    expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': 'v2'});
    expect((await catalogs.songs(sourceId).toList()).single.title, 'Song 5');

    // A restart in the middle of an upload drops it.
    await page(0, 2, [_song(6)], version: 'v3');
    await page(0, 1, [_song(7)], version: 'v4');
    await expectLater(
      page(1, 2, [_song(8)], version: 'v3'),
      throwsA(linkError('invalid')),
    );
    expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': 'v4'});
    expect(
      File('${root.path}/$sourceId/catalog.ndjson.part').existsSync(),
      isFalse,
    );
  });

  test('a total of 0 commits an empty list', () async {
    await page(0, 2, [_song(1), _song(2)]);
    expect(await page(0, 0, const [], version: 'empty'), {'ok': true});
    expect(commits, [_phone, _phone]);
    expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': 'empty'});
    expect(await catalogs.songs(sourceId).toList(), isEmpty);
  });

  test('rejects malformed pages', () async {
    for (final args in <Map<String, dynamic>>[
      {'offset': 0, 'total': 1, 'songs': <Object>[]},
      {'version': 'v', 'offset': 0, 'total': 1, 'songs': <Object>[]},
      {
        'version': 'v',
        'offset': 0,
        'total': 1,
        'songs': [_song(1), _song(2)],
      },
      {
        'version': 'v',
        'offset': 0,
        'total': LinkPhoneCatalogs.maxSongs + 1,
        'songs': [_song(1)],
      },
      {
        'version': 'v',
        'offset': 0,
        'total': linkPhoneCatalogPage + 1,
        'songs': List.generate(linkPhoneCatalogPage + 1, _song),
      },
    ]) {
      await expectLater(
        call(LinkOps.phoneCatalog, 'POST', args: args),
        throwsA(linkError('invalid')),
        reason: '$args',
      );
    }
    expect(commits, isEmpty);
  });

  test('only a paired phone may send songs or covers', () async {
    await expectLater(
      page(0, 1, [_song(1)], deviceId: 'stranger'),
      throwsA(linkError('invalid')),
    );
    await expectLater(
      call(
        LinkOps.phoneCovers,
        'POST',
        deviceId: 'stranger',
        args: {'covers': <Object>[]},
      ),
      throwsA(linkError('invalid')),
    );
    expect(await call(LinkOps.phoneCatalog, 'GET', deviceId: 'stranger'), {
      'version': null,
    });
    expect(await catalogs.sourceIds(), isEmpty);
    expect(commits, isEmpty);
  });

  group('covers', () {
    final jpeg = base64Encode([0xff, 0xd8, 0xff, 1, 2, 3]);
    final coverA = _fileId(0xa);
    final coverB = _fileId(0xb);

    test('stores valid covers and leaves out the rest', () async {
      expect(await call(LinkOps.phoneCovers, 'GET'), {'ids': <String>[]});
      final result = await call(
        LinkOps.phoneCovers,
        'POST',
        args: {
          'covers': [
            {'id': coverA, 'ext': 'jpg', 'data': jpeg},
            {'id': 'ABC', 'ext': 'jpg', 'data': jpeg},
            {'id': coverB.toUpperCase(), 'ext': 'jpg', 'data': jpeg},
            {'id': coverB, 'ext': 'gif', 'data': jpeg},
            {'id': coverB, 'ext': 'png', 'data': 'not base64!'},
            {
              'id': coverB,
              'ext': 'png',
              'data': base64Encode(
                List.filled(LinkPhoneCatalogs.maxCoverBytes + 1, 0),
              ),
            },
          ],
        },
      );
      expect(result, {'ok': true});
      expect(await call(LinkOps.phoneCovers, 'GET'), {
        'ids': [coverA],
      });
      final path = await catalogs.coverPath(sourceId, coverA);
      expect(path, endsWith('/covers/$coverA.jpg'));
      expect(File(path!).readAsBytesSync(), base64Decode(jpeg));
      expect(await catalogs.coverPath(sourceId, coverB), isNull);
    });

    test('a request over the limit is invalid', () async {
      final chunk = 'A' * (LinkPhoneCatalogs.maxCoversRequest ~/ 2 + 4);
      await expectLater(
        call(
          LinkOps.phoneCovers,
          'POST',
          args: {
            'covers': [
              {'id': coverA, 'ext': 'jpg', 'data': chunk},
              {'id': coverB, 'ext': 'jpg', 'data': chunk},
            ],
          },
        ),
        throwsA(linkError('invalid')),
      );
      await expectLater(
        call(LinkOps.phoneCovers, 'POST', args: const {}),
        throwsA(linkError('invalid')),
      );
    });

    test('a commit removes covers its list does not name', () async {
      await call(
        LinkOps.phoneCovers,
        'POST',
        args: {
          'covers': [
            {'id': coverA, 'ext': 'jpg', 'data': jpeg},
            {'id': coverB, 'ext': 'png', 'data': jpeg},
          ],
        },
      );
      await page(0, 1, [_song(1, coverId: coverB)]);
      // The removal runs after the reply.
      await catalogs.idle(sourceId);
      expect(await catalogs.coverPaths(sourceId), {
        coverB: '${root.path}/$sourceId/covers/$coverB.png',
      });
    });

    test('a cover Library rows still show waits for their rescan', () async {
      var shown = <String>{};
      Object? unreadable;
      catalogs = LinkPhoneCatalogs(
        root: () async => root,
        paired: (deviceId) async => paired.contains(deviceId),
        onCommit: commits.add,
        libraryCovers: (id) async {
          if (unreadable case final error?) throw error;
          return id == sourceId ? shown : const {};
        },
      )..register(router = LinkHostRouter());
      Future<void> post(String id) => call(
        LinkOps.phoneCovers,
        'POST',
        args: {
          'covers': [
            {'id': id, 'ext': 'jpg', 'data': jpeg},
          ],
        },
      );
      final pathA = '${root.path}/$sourceId/covers/$coverA.jpg';
      final pathB = '${root.path}/$sourceId/covers/$coverB.jpg';

      await post(coverA);
      await page(0, 1, [_song(1, coverId: coverA)]);
      // The rescan after the commit points the song's row at cover A.
      shown = {pathA};

      // The phone's cover changes: the rows name cover A until the rescan.
      await post(coverB);
      await page(0, 1, [_song(1, coverId: coverB)], version: 'v2');
      await catalogs.idle(sourceId);
      expect(await catalogs.coverPaths(sourceId), {
        coverA: pathA,
        coverB: pathB,
      });

      // Once the rescan moved the rows, the next sync removes cover A (set
      // older than the v2 list, as coarse file times can give both the
      // same time).
      shown = {pathB};
      File(pathA).setLastModifiedSync(DateTime(2000));
      expect(await call(LinkOps.phoneCatalog, 'GET'), {'version': 'v2'});
      await catalogs.idle(sourceId);
      expect(await catalogs.coverPaths(sourceId), {coverB: pathB});

      // Unknown rows keep every cover.
      unreadable = const FileSystemException('locked');
      await page(0, 1, [_song(1)], version: 'v3');
      await catalogs.idle(sourceId);
      expect(await catalogs.coverPaths(sourceId), {coverB: pathB});
      unreadable = null;
      shown = {};
      await page(0, 1, [_song(1)], version: 'v4');
      await catalogs.idle(sourceId);
      expect(await catalogs.coverPaths(sourceId), isEmpty);
    });

    group('in the order a phone syncs', () {
      var shown = <String>{};
      late List<String> posted;

      setUp(() {
        shown = {};
        posted = [];
        catalogs = LinkPhoneCatalogs(
          root: () async => root,
          paired: (deviceId) async => paired.contains(deviceId),
          onCommit: commits.add,
          libraryCovers: (_) async => shown,
        )..register(router = LinkHostRouter());
      });

      /// One sync: the version, then the covers the desktop lacks, then
      /// the songs (fileId to coverId), unless [interrupted] first.
      Future<void> sync(
        String version,
        Map<int, String?> songs, {
        bool interrupted = false,
      }) async {
        await call(LinkOps.phoneCatalog, 'GET');
        final reply = await call(LinkOps.phoneCovers, 'GET');
        final held = {...((reply! as Map)['ids'] as List).cast<String>()};
        final missing = {
          for (final id in songs.values)
            if (id != null && !held.contains(id)) id,
        };
        posted.addAll(missing);
        if (missing.isNotEmpty) {
          await call(
            LinkOps.phoneCovers,
            'POST',
            args: {
              'covers': [
                for (final id in missing)
                  {'id': id, 'ext': 'jpg', 'data': jpeg},
              ],
            },
          );
        }
        if (!interrupted) {
          await page(0, songs.length, [
            for (final MapEntry(:key, :value) in songs.entries)
              _song(key, coverId: value),
          ], version: version);
        }
        await catalogs.idle(sourceId);
      }

      test('a sync that stopped keeps the covers it sent', () async {
        await sync('v1', {1: coverA}, interrupted: true);
        await sync('v1', {1: coverA});
        expect((await catalogs.coverPaths(sourceId)).keys, [coverA]);

        await sync('v2', {1: coverA, 2: coverB}, interrupted: true);
        await sync('v2', {1: coverA, 2: coverB});
        expect(posted, [coverA, coverB], reason: 'each cover is sent once');
        expect(
          (await catalogs.coverPaths(sourceId)).keys,
          unorderedEquals([coverA, coverB]),
        );
      });

      test('a cover kept for Library rows can be named again', () async {
        final pathA = '${root.path}/$sourceId/covers/$coverA.jpg';
        final pathB = '${root.path}/$sourceId/covers/$coverB.jpg';
        await sync('v1', {1: coverA});
        shown = {pathA};
        await sync('v2', {1: coverB});
        expect(
          (await catalogs.coverPaths(sourceId)).keys,
          unorderedEquals([coverA, coverB]),
        );

        // The rescan moved the rows to B; the next sync drops A first, so
        // the phone sends it again. A is set older than the v2 list, as
        // coarse file times can give both the same time.
        shown = {pathB};
        File(pathA).setLastModifiedSync(DateTime(2000));
        await sync('v3', {1: coverA});
        expect(posted, [coverA, coverB, coverA]);
        expect(await catalogs.coverPath(sourceId, coverA), pathA);
      });

      test('a commit removes covers before the next request', () async {
        await sync('v1', {1: coverA});
        // A phone that reconnected sends its next covers while the last
        // page is still being written.
        await Future.wait([
          page(0, 1, [_song(1)], version: 'v2'),
          call(
            LinkOps.phoneCovers,
            'POST',
            args: {
              'covers': [
                {'id': coverB, 'ext': 'jpg', 'data': jpeg},
              ],
            },
          ),
        ]);
        await catalogs.idle(sourceId);
        expect((await catalogs.coverPaths(sourceId)).keys, [coverB]);
      });
    });

    test('finds the covers of uploaded songs by file id', () async {
      const url = 'https://images.example.com/b.jpg';
      await call(
        LinkOps.phoneCovers,
        'POST',
        args: {
          'covers': [
            {'id': coverA, 'ext': 'jpg', 'data': jpeg},
          ],
        },
      );
      await page(0, 3, [
        _song(1, coverId: coverA),
        {..._song(2), 'coverUrl': url},
        _song(3),
      ]);
      expect(await catalogs.coversFor({_fileId(1), _fileId(2), _fileId(3)}), {
        _fileId(1): '${root.path}/$sourceId/covers/$coverA.jpg',
        _fileId(2): url,
      });
      expect(await catalogs.coversFor(const {}), isEmpty);
    });

    test('covers named by address are fetched after the commit', () async {
      const fetchedUrl = 'https://images.example.com/a.jpg';
      const missingUrl = 'https://images.example.com/gone.jpg';
      const textUrl = 'https://images.example.com/page.html';
      final fetched = <Uri>[];
      catalogs = LinkPhoneCatalogs(
        root: () async => root,
        paired: (deviceId) async => paired.contains(deviceId),
        onCommit: commits.add,
        fetchCover: (url) async {
          fetched.add(url);
          return switch (url.toString()) {
            fetchedUrl => base64Decode(jpeg),
            textUrl => utf8.encode('<html>'),
            _ => throw const SocketException('unreachable'),
          };
        },
      )..register(router = LinkHostRouter());
      Map<String, dynamic> withUrl(int i, String url) => {
        ..._song(i),
        'coverUrl': url,
      };

      await page(0, 3, [
        withUrl(1, fetchedUrl),
        withUrl(2, missingUrl),
        withUrl(3, textUrl),
      ]);
      expect(commits, [_phone]);
      await catalogs.idle(sourceId);
      final key = linkCoverUrlId(fetchedUrl);
      expect(fetched, hasLength(3));
      expect(await catalogs.coverPaths(sourceId), {
        key: '${root.path}/$sourceId/covers/$key.jpg',
      });
      // The songs show again with the cover.
      expect(commits, [_phone, _phone]);

      // A cover held already is not fetched again, and a commit keeps it.
      fetched.clear();
      await page(0, 1, [withUrl(1, fetchedUrl)], version: 'v2');
      await catalogs.idle(sourceId);
      expect(fetched, isEmpty);
      expect(await catalogs.coverPath(sourceId, key), isNotNull);
      expect(commits, [_phone, _phone, _phone]);
    });

    test('cover lookups do not wait for a web cover download', () async {
      final download = Completer<Uint8List?>();
      catalogs = LinkPhoneCatalogs(
        root: () async => root,
        paired: (deviceId) async => paired.contains(deviceId),
        fetchCover: (_) => download.future,
      )..register(router = LinkHostRouter());
      addTearDown(() async {
        download.complete(null);
        await catalogs.idle(sourceId);
      });
      await call(
        LinkOps.phoneCovers,
        'POST',
        args: {
          'covers': [
            {'id': coverA, 'ext': 'jpg', 'data': jpeg},
          ],
        },
      );
      await page(0, 2, [
        _song(1, coverId: coverA),
        {..._song(2), 'coverUrl': 'https://images.example.com/slow.jpg'},
      ]);
      // The commit queued the download, which never ends; then the phone
      // starts its next sync.
      await call(LinkOps.phoneCatalog, 'GET');

      final pathA = '${root.path}/$sourceId/covers/$coverA.jpg';
      const soon = Duration(seconds: 1);
      expect(await catalogs.coverPath(sourceId, coverA).timeout(soon), pathA);
      expect(await catalogs.coverPaths(sourceId).timeout(soon), {
        coverA: pathA,
      });
      expect(await catalogs.coversFor({_fileId(1)}).timeout(soon), {
        _fileId(1): pathA,
      });
    });

    test('a large cover is kept shrunk and a failed one is tried again '
        'on the next run', () async {
      const largeUrl = 'https://images.example.com/large.jpg';
      const flakyUrl = 'https://images.example.com/flaky.jpg';
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      final fetched = <String>[];
      var reachable = false;
      LinkPhoneCatalogs open() => LinkPhoneCatalogs(
        root: () async => root,
        paired: (deviceId) async => paired.contains(deviceId),
        onCommit: commits.add,
        fetchCover: (url) async {
          fetched.add(url.toString());
          if (url.toString() == largeUrl) {
            return Uint8List(LinkPhoneCatalogs.maxCoverBytes + 1)
              ..setAll(0, base64Decode(jpeg));
          }
          if (!reachable) throw const SocketException('unreachable');
          return base64Decode(jpeg);
        },
        shrinkCover: (image) async =>
            image.length > LinkPhoneCatalogs.maxCoverBytes ? png : null,
      )..register(router = LinkHostRouter());
      catalogs = open();

      await page(0, 2, [
        {..._song(1), 'coverUrl': largeUrl},
        {..._song(2), 'coverUrl': flakyUrl},
      ]);
      await catalogs.idle(sourceId);
      final large = linkCoverUrlId(largeUrl);
      final flaky = linkCoverUrlId(flakyUrl);
      expect(await catalogs.coverPaths(sourceId), {
        large: '${root.path}/$sourceId/covers/$large.png',
      });
      expect(
        await File('${root.path}/$sourceId/covers/$large.png').readAsBytes(),
        png,
      );

      // A connect in the same run does not try it again.
      fetched.clear();
      reachable = true;
      await call(LinkOps.phoneCatalog, 'GET');
      await catalogs.idle(sourceId);
      expect(fetched, isEmpty);

      // After a restart, the phone's next connect fetches it.
      catalogs = open();
      await call(LinkOps.phoneCatalog, 'GET');
      await catalogs.idle(sourceId);
      expect(fetched, [flakyUrl]);
      expect(await catalogs.coverPath(sourceId, flaky), isNotNull);
    });
  });

  test('remembers the Library source and removes everything', () async {
    await page(0, 1, [_song(1)]);
    expect(await catalogs.hasLibrarySource(sourceId), isFalse);
    await catalogs.markLibrarySource(sourceId);
    expect(await catalogs.hasLibrarySource(sourceId), isTrue);

    await catalogs.remove(sourceId);
    expect(Directory('${root.path}/$sourceId').existsSync(), isFalse);
    expect(await catalogs.sourceIds(), isEmpty);
    expect(await catalogs.version(sourceId), isNull);
    expect(await catalogs.songs(sourceId).toList(), isEmpty);
  });
}
