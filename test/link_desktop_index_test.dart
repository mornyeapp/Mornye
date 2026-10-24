import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_desktop_fakes.dart';

void main() {
  final index = DesktopLinkCatalogIndex(
    serverId: 'srv',
    songs: [
      catalogSong(
        'l:1',
        title: 'Song',
        artist: 'Band',
        isrc: 'USAAA0000001',
        durationMs: 300000,
      ),
      catalogSong('l:2', title: 'Song', artist: 'Band', durationMs: 180000),
      catalogSong('d:3', title: 'Song', artist: 'Band', durationMs: 200500),
      catalogSong(
        'd:4',
        title: 'Other Song (Remastered 2011)',
        artist: 'Band feat. Guest',
        durationMs: 240000,
      ),
      catalogSong('l:5', title: 'Unknown Length', durationMs: null),
    ],
    covers: const {'l:1': '/covers/1.jpg'},
  );

  TrackRef ref({
    String title = 'Song',
    String artist = 'Band',
    int? durationMs = 200000,
    String? isrc,
    String? matchKey,
    String? songId,
    String? serverId,
  }) => TrackRef(
    title: title,
    artist: artist,
    durationMs: durationMs,
    isrc: isrc,
    matchKey: matchKey,
    songId: songId,
    serverId: serverId,
  );

  group('songIdForRef', () {
    test('a song id for this server wins', () {
      expect(index.songIdForRef(ref(songId: 'l:2', serverId: 'srv')), 'l:2');
    });

    test('a song id for another server is ignored', () {
      expect(
        index.songIdForRef(ref(songId: 'l:2', serverId: 'other')),
        'd:3',
        reason: 'falls through to the match key within two seconds',
      );
    });

    test('a song id without a server must carry the same title', () {
      expect(index.songIdForRef(ref(songId: 'l:2')), 'l:2');
      expect(
        index.songIdForRef(ref(title: 'Unrelated', songId: 'l:2')),
        isNull,
      );
    });

    test('the ISRC comes before the match key, whatever the duration', () {
      expect(index.songIdForRef(ref()), 'd:3');
      expect(index.songIdForRef(ref(isrc: 'us-aaa-00-00001')), 'l:1');
    });

    test('the match key needs the duration within two seconds', () {
      expect(index.songIdForRef(ref(durationMs: 181500)), 'l:2');
      expect(index.songIdForRef(ref(durationMs: 201000)), 'd:3');
      expect(index.songIdForRef(ref(durationMs: 190000)), isNull);
    });

    test('an explicit match key is honored', () {
      expect(
        index.songIdForRef(
          ref(
            title: 'x',
            artist: 'y',
            matchKey: 'Song|Band',
            durationMs: 180500,
          ),
        ),
        'l:2',
      );
    });

    test('the loose key ignores case, brackets and featured artists', () {
      expect(
        index.songIdForRef(
          ref(title: 'other song', artist: 'BAND', durationMs: 241000),
        ),
        'd:4',
      );
      expect(
        index.songIdForRef(
          ref(title: 'Other Song', artist: 'Band', durationMs: 250000),
        ),
        isNull,
        reason: 'durations still have to agree',
      );
    });

    test('a side without a duration does not block a match', () {
      expect(
        index.songIdForRef(
          ref(title: 'Unknown Length', artist: 'Artist 5', durationMs: 1),
        ),
        'l:5',
      );
    });
  });

  group('songIdForTrack', () {
    Track track(
      String id, {
      String name = 'Song',
      String artist = 'Band',
      int duration = 200,
      String? source,
    }) => Track(
      id: id,
      name: name,
      artistName: artist,
      albumName: 'Album',
      duration: duration,
      source: source,
    );

    test('a Library or history row id with the same title matches', () {
      expect(index.songIdForTrack(track('2', source: 'local')), 'l:2');
      expect(index.songIdForTrack(track('3')), 'd:3');
    });

    test('a provider id that collides with a row id needs the title', () {
      expect(
        index.songIdForTrack(track('5', name: 'Song', duration: 181)),
        'l:2',
        reason: 'l:5 has another title, so it matches by key and duration',
      );
    });
  });

  test('media lookups go by path, then by row id', () {
    expect(index.songIdForMedia(id: 'x', path: '/music/2.flac'), 'l:2');
    expect(index.songIdForMedia(id: 'x', path: 'EXISTS:/music/3.flac'), 'd:3');
    expect(index.songIdForMedia(id: '4', path: '/elsewhere.flac'), 'd:4');
    expect(index.songIdForMedia(id: 'nope', path: ''), isNull);
    expect(index.coverPathFor('l:1'), '/covers/1.jpg');
  });

  test('the loose key drops brackets and featured artists', () {
    expect(
      linkLooseKey('Hello (Live) [2020]', 'A feat. B'),
      linkLooseKey('hello', 'a'),
    );
    expect(linkLooseKey('Hello', 'A & B'), linkLooseKey('Hello', 'A'));
    expect(linkLooseKey('', 'A'), '');
  });

  test('resolves 50k songs quickly', () {
    final songs = [
      for (var i = 0; i < 50000; i++)
        catalogSong('l:$i', title: 'Title $i', artist: 'Artist ${i % 500}'),
    ];
    final watch = Stopwatch()..start();
    final big = DesktopLinkCatalogIndex(serverId: 's', songs: songs);
    for (var i = 0; i < 1000; i++) {
      expect(
        big.songIdForRef(
          ref(title: 'Title ${i * 37}', artist: 'Artist ${(i * 37) % 500}'),
        ),
        'l:${i * 37}',
      );
    }
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
