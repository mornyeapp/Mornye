import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_session_restore.dart';

Map<String, dynamic> _media(int index, {String? artwork, String? source}) =>
    PlayableMedia(
      id: '$index',
      source: source ?? '/music/$index.flac',
      title: 'Track $index',
      artist: 'Fixture artist',
      artUri: artwork,
    ).toJson();

void main() {
  test(
    'an unavailable new folder does not abort restore of other songs',
    () async {
      final result = await prepareRestoredPlaybackMedia(
        [_media(0, source: '/xxx/Song.flac'), _media(1)],
        fileExists: (path) async => path == '/music/1.flac',
        recoverSource: (_) => throw StateError('Folder not mounted'),
        loadLibraryCoverPath: (_) async => null,
      );
      expect(result.items.map((item) => item.source), [
        '/xxx/Song.flac',
        '/music/1.flac',
      ]);
      expect(result.keptOriginalIndices, [0, 1]);
    },
  );

  test(
    'a moved download is repaired before restore drops its missing path',
    () async {
      final result = await prepareRestoredPlaybackMedia(
        [_media(0, source: '/xxx/Artist/Album/Song.flac')],
        fileExists: (_) async => false,
        recoverSource: (media) async {
          expect(media.source, '/xxx/Artist/Album/Song.flac');
          return '/yyy/Artist/Album/Song.flac';
        },
        loadLibraryCoverPath: (_) async => null,
      );
      expect(result.items.single.source, '/yyy/Artist/Album/Song.flac');
      expect(result.sourceRelocated, isTrue);
      expect(result.keptOriginalIndices, [0]);
    },
  );

  test(
    'iOS restore validates rebased artwork and requests a queue rewrite',
    () async {
      const oldContainer =
          '/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111';
      const currentContainer =
          '/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222';
      const suffix = '/Library/Application Support/covers/Album Cover.jpg';
      final checked = <String>[];
      final result = await prepareRestoredPlaybackMedia(
        [
          _media(
            0,
            source: 'network://fixture/music.flac',
            artwork: Uri.file('$oldContainer$suffix').toString(),
          ),
        ],
        iosDocumentsPath: '$currentContainer/Documents',
        fileExists: (path) async {
          checked.add(path);
          return path == '$currentContainer$suffix';
        },
        loadLibraryCoverPath: (_) => throw StateError('Unexpected lookup'),
      );
      expect(checked, ['$currentContainer$suffix']);
      expect(
        result.items.single.artUri,
        Uri.file('$currentContainer$suffix').toString(),
      );
      expect(result.keptOriginalIndices, [0]);
      expect(result.artworkRelocated, isTrue);
    },
  );

  test(
    'cache eviction rechecks old paths while retaining shared cover and order',
    () async {
      final reads = <String, int>{};
      final result = await prepareRestoredPlaybackMedia(
        [
          for (var i = 0; i < 300; i++)
            _media(i, artwork: 'file:///covers/shared.jpg'),
          _media(
            300,
            source: '/music/0.flac',
            artwork: 'file:///covers/shared.jpg',
          ),
        ],
        fileExists: (path) async {
          reads.update(path, (count) => count + 1, ifAbsent: () => 1);
          return true;
        },
        loadLibraryCoverPath: (_) => throw StateError('Unexpected lookup'),
      );
      expect(reads.length, 301);
      expect(reads['/music/0.flac'], 2);
      expect(reads['/covers/shared.jpg'], 1);
      expect(result.keptOriginalIndices, List.generate(301, (index) => index));
      expect(result.items.map((item) => item.id), [
        for (var i = 0; i <= 300; i++) '$i',
      ]);
      expect(result.artworkRelocated, isFalse);
    },
  );

  test(
    'restore overlaps bounded checks and preserves order and missing indices',
    () async {
      final pending = <String, Completer<bool>>{};
      var active = 0;
      var maximumActive = 0;
      final restore = prepareRestoredPlaybackMedia(
        [for (var i = 0; i < 19; i++) _media(i)],
        fileExists: (path) async {
          active++;
          if (active > maximumActive) maximumActive = active;
          final check = Completer<bool>();
          pending[path] = check;
          try {
            return await check.future;
          } finally {
            active--;
          }
        },
        loadLibraryCoverPath: (_) async => null,
      );
      await Future<void>.delayed(Duration.zero);
      expect(active, 8);
      expect(pending, hasLength(8));
      for (var batch = 0; batch < 3; batch++) {
        final checks = pending.entries
            .where((e) => !e.value.isCompleted)
            .toList();
        for (final entry in checks.reversed) {
          entry.value.complete(entry.key != '/music/3.flac');
        }
        await Future<void>.delayed(Duration.zero);
      }
      final result = await restore;
      final expected = [
        for (var i = 0; i < 19; i++)
          if (i != 3) i,
      ];
      expect(result.keptOriginalIndices, expected);
      expect(result.items.map((item) => item.id), expected.map((i) => '$i'));
      expect(result.artworkRelocated, isFalse);
      expect(maximumActive, 8);
    },
  );

  test(
    'shared existing covers reuse in-flight and completed file checks',
    () async {
      final reads = <String, int>{};
      var lookups = 0;
      final coverReady = Completer<bool>();
      final restore = prepareRestoredPlaybackMedia(
        [
          for (var i = 0; i < 80; i++)
            _media(i, artwork: 'file:///covers/album.jpg'),
        ],
        fileExists: (path) {
          reads.update(path, (count) => count + 1, ifAbsent: () => 1);
          return path == '/covers/album.jpg'
              ? coverReady.future
              : Future.value(true);
        },
        loadLibraryCoverPath: (_) async {
          lookups++;
          return null;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads['/covers/album.jpg'], 1);
      coverReady.complete(true);
      final result = await restore;
      expect(result.items, hasLength(80));
      expect(result.artworkRelocated, isFalse);
      expect(reads['/covers/album.jpg'], 1);
      expect(lookups, 0);
    },
  );

  test('missing shared cover retains track-specific recovery', () async {
    final reads = <String, int>{};
    final result = await prepareRestoredPlaybackMedia(
      [for (var i = 0; i < 3; i++) _media(i, artwork: 'file:///old.jpg')],
      fileExists: (path) async {
        reads.update(path, (count) => count + 1, ifAbsent: () => 1);
        return path != '/old.jpg';
      },
      loadLibraryCoverPath: (media) async {
        if (media.id == '2') throw StateError('Library unavailable');
        return '/covers/${media.id}.jpg';
      },
    );
    expect(result.items.map((item) => item.artUri), [
      'file:///covers/0.jpg',
      'file:///covers/1.jpg',
      'file:///old.jpg',
    ]);
    expect(reads['/old.jpg'], 1);
    expect(result.artworkRelocated, isTrue);
  });

  test(
    'remote and SAF sources skip file access and invalid entries retain indices',
    () async {
      final result = await prepareRestoredPlaybackMedia(
        [
          null,
          {'id': 'invalid'},
          _media(
            2,
            source: 'network://fixture/track.flac',
            artwork: 'https://example.test/a.jpg',
          ),
          _media(
            3,
            source: 'content://example.documents/track',
            artwork: 'https://example.test/a.jpg',
          ),
        ],
        fileExists: (_) => throw StateError('Unexpected file check'),
        loadLibraryCoverPath: (_) => throw StateError('Unexpected lookup'),
      );
      expect(result.keptOriginalIndices, [2, 3]);
      expect(result.items.map((item) => item.id), ['2', '3']);
      expect(result.artworkRelocated, isFalse);
    },
  );

  test(
    'restore drops loopback and temporary covers of older sessions',
    () async {
      final result = await prepareRestoredPlaybackMedia(
        [
          _media(0, artwork: 'http://127.0.0.1:41234/2f6d1c'),
          _media(
            1,
            artwork:
                '/data/user/0/app/cache/network_metadata/subsonic_ab.image',
          ),
          _media(2, artwork: 'https://example.test/cover.jpg'),
          _media(3, artwork: 'network://nas/Album/cover.jpg'),
        ],
        fileExists: (_) async => true,
        loadLibraryCoverPath: (_) async => null,
      );
      expect(result.items.map((item) => item.artUri), [
        null,
        null,
        'https://example.test/cover.jpg',
        'network://nas/Album/cover.jpg',
      ]);
      // The next save writes the queue without them.
      expect(result.artworkRelocated, isTrue);
    },
  );
}
