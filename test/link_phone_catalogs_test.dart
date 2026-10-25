import 'dart:convert';
import 'dart:io';

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
      expect(await catalogs.coverPaths(sourceId), {
        coverB: '${root.path}/$sourceId/covers/$coverB.png',
      });
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
