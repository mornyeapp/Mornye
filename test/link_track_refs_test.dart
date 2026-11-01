import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/link_fakes.dart';

void main() {
  group('TrackRef building', () {
    test('a desktop stream carries its song id and the server id', () {
      final ref = linkTrackRefFromMedia(
        linkDesktopMedia(
          'tr-1/a b',
          title: 'Blue',
          artist: 'Band',
          duration: const Duration(seconds: 200),
        ),
        server: linkTestServer,
        isrc: 'us-abc-24-00001',
      );
      expect(ref.songId, 'tr-1/a b');
      expect(ref.serverId, linkTestServer.serverId);
      expect(ref.isrc, 'USABC2400001');
      expect(ref.matchKey, 'blue|band');
      expect(ref.durationMs, 200000);
      expect(ref.album, 'Album');
    });

    test('a file on the phone or another connection has no song id', () {
      final local = linkTrackRefFromMedia(
        linkLocalMedia('a'),
        server: linkTestServer,
      );
      expect(local.songId, isNull);
      expect(local.serverId, isNull);

      const other = LinkServerRecord(
        serverId: 'server-2',
        name: 'Other',
        connectionId: 'conn-2',
        address: 'https://192.0.2.11:8443',
        fingerprint: 'ef',
      );
      final foreign = linkTrackRefFromMedia(
        linkDesktopMedia('song'),
        server: other,
      );
      expect(foreign.songId, isNull);
      expect(foreign.serverId, isNull);
    });

    test('queue items, history, Library rows and search tracks', () {
      final item = linkMediaItem(linkDesktopMedia('s1', title: 'One'));
      final fromItem = linkTrackRefFromMediaItem(item, server: linkTestServer);
      expect(fromItem.songId, 's1');
      expect(fromItem.title, 'One');

      final history = DownloadHistoryItem(
        id: 'h1',
        trackName: 'Two',
        artistName: 'Artist',
        albumName: '',
        filePath: '/music/two.flac',
        service: 'test',
        downloadedAt: DateTime(2026),
        isrc: 'GBXYZ2400002',
        duration: 61,
      );
      final fromHistory = linkTrackRefFromHistory(
        history,
        server: linkTestServer,
      );
      expect(fromHistory.durationMs, 61000);
      expect(fromHistory.isrc, 'GBXYZ2400002');
      expect(fromHistory.album, isNull);
      expect(fromHistory.songId, isNull);

      final row = LocalLibraryItem(
        id: 'network_x',
        trackName: 'Three',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: linkDesktopSongSource(linkTestServer, 's3', format: 'mp3'),
        scannedAt: DateTime(2026),
        duration: 10,
      );
      final fromRow = linkTrackRefFromLocal(row, server: linkTestServer);
      expect(fromRow.songId, 's3');
      expect(fromRow.durationMs, 10000);

      const track = Track(
        id: 'provider-id',
        name: 'Four',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 120,
        isrc: 'USAAA2400004',
      );
      final fromTrack = linkTrackRefFromTrack(track);
      expect(fromTrack.songId, isNull);
      expect(fromTrack.durationMs, 120000);
      expect(fromTrack.matchKey, 'four|artist');
    });

    test('song paths round trip through the Subsonic path codec', () {
      for (final id in ['plain', 'with/slash', 'ümlaut id', '']) {
        final path = subsonicSongPath(id, 'flac');
        expect(subsonicSongIdFromPath(path), id.isEmpty ? isNull : id);
      }
      expect(subsonicSongIdFromPath('subsonic/cover/abc.jpg'), isNull);
      expect(subsonicSongIdFromPath('music/song.flac'), isNull);
    });

    test('the queue window keeps at most 200 items around the current', () {
      expect(linkQueueWindow(10, 3), (start: 0, end: 10));
      expect(linkQueueWindow(500, 0), (start: 0, end: 200));
      expect(linkQueueWindow(500, 120), (start: 70, end: 270));
      expect(linkQueueWindow(500, 499), (start: 300, end: 500));
      expect(linkQueueWindow(500, -1), (start: 0, end: 200));
    });
  });

  group('TrackRef resolution', () {
    LinkLocalTrack local(
      String id, {
      String title = 'Song',
      String artist = 'Artist',
      int seconds = 200,
      String? isrc,
    }) => LinkLocalTrack(
      linkLocalMedia(
        id,
        title: title,
        artist: artist,
        duration: Duration(seconds: seconds),
      ),
      isrc: isrc,
    );

    test('an ISRC match wins regardless of duration', () async {
      final lookup = FakeLibraryLookup([
        local('by-key', seconds: 200),
        local('by-isrc', title: 'Other', seconds: 300, isrc: 'USABC2400001'),
      ]);
      final media = await LinkTrackResolver(lookup: lookup).resolve(
        const TrackRef(
          title: 'Song',
          artist: 'Artist',
          durationMs: 200000,
          isrc: 'USABC2400001',
          matchKey: 'song|artist',
        ),
      );
      expect(media?.id, 'by-isrc');
      expect(lookup.queries.first, 'isrc USABC2400001');
    });

    test('a match key needs the duration within two seconds', () async {
      final lookup = FakeLibraryLookup([local('a', seconds: 200)]);
      final resolver = LinkTrackResolver(lookup: lookup);
      Future<String?> resolve(int durationMs) async => (await resolver.resolve(
        TrackRef(
          title: 'Song',
          artist: 'Artist',
          durationMs: durationMs,
          matchKey: 'song|artist',
        ),
      ))?.id;
      expect(await resolve(201999), 'a');
      expect(await resolve(197500), isNull);
    });

    test('title and artist stand in for a key built elsewhere', () async {
      final lookup = FakeLibraryLookup([local('a', title: 'Song (Live)')]);
      final media = await LinkTrackResolver(lookup: lookup).resolve(
        const TrackRef(
          title: 'Song (Live)',
          artist: 'Artist',
          durationMs: 200000,
          matchKey: 'song live|artist',
        ),
      );
      expect(media?.id, 'a');
      expect(lookup.queries, [
        'key song live|artist',
        'key song (live)|artist',
      ]);
    });

    test('a file on the phone beats a scanned desktop row', () async {
      final network = LinkLocalTrack(
        linkDesktopMedia('s1', duration: const Duration(seconds: 200)),
      );
      final lookup = FakeLibraryLookup([network, local('phone')]);
      final media =
          await LinkTrackResolver(
            lookup: lookup,
            server: linkTestServer,
          ).resolve(
            const TrackRef(
              title: 'Song',
              artist: 'Artist',
              durationMs: 200000,
              matchKey: 'song|artist',
              songId: 's1',
              serverId: 'server-1',
            ),
          );
      expect(media?.id, 'phone');
    });

    test('without a file the desktop song streams from its server', () async {
      final scanned = LinkLocalTrack(linkDesktopMedia('s1', title: 'Song'));
      final resolver = LinkTrackResolver(
        lookup: FakeLibraryLookup([scanned]),
        server: linkTestServer,
      );
      final known = await resolver.resolve(
        const TrackRef(
          title: 'Song',
          artist: 'Artist',
          songId: 's1',
          serverId: 'server-1',
        ),
      );
      expect(known, same(scanned.media));

      final streamed = await resolver.resolve(
        const TrackRef(
          title: 'New',
          artist: 'Artist',
          album: 'Record',
          durationMs: 1000,
          songId: 's9',
          serverId: 'server-1',
        ),
      );
      expect(streamed, isNotNull);
      expect(linkDesktopSongId(streamed!.source, linkTestServer), 's9');
      expect(streamed.id, startsWith('network_'));
      expect(streamed.album, 'Record');
      expect(streamed.duration, const Duration(seconds: 1));
    });

    test('a song id of another server does not stream', () async {
      final resolver = LinkTrackResolver(
        lookup: FakeLibraryLookup(),
        server: linkTestServer,
      );
      final media = await resolver.resolve(
        const TrackRef(
          title: 'New',
          artist: 'Artist',
          songId: 's9',
          serverId: 'server-2',
        ),
      );
      expect(media, isNull);
      final all = await resolver.resolveAll(const [
        TrackRef(title: 'New', artist: 'Artist'),
        TrackRef(title: 'New', artist: 'Artist', songId: 's9'),
      ]);
      expect(all, [null, null]);
    });

    test('queue item refs pick up the ISRC of their record once', () async {
      final media = linkLocalMedia('a');
      final lookup = FakeLibraryLookup([
        LinkLocalTrack(media, isrc: 'USABC2400001'),
      ]);
      final cache = LinkTrackRefCache(lookup: lookup, server: linkTestServer);
      final item = linkMediaItem(media);
      expect(cache.refFor(item).isrc, isNull);
      expect(await cache.resolveAll([item]), isTrue);
      expect(cache.refFor(item).isrc, 'USABC2400001');
      expect(await cache.resolveAll([item]), isFalse);
      expect(lookup.queries, ['record ${media.source}']);

      final desktop = linkMediaItem(linkDesktopMedia('s1'));
      expect(await cache.resolveAll([desktop]), isFalse);
      expect(cache.refFor(desktop).songId, 's1');
      expect(lookup.queries, hasLength(1));
    });

    test(
      'local player refs use the same file identity as the phone catalog',
      () async {
        final directory = await Directory.systemTemp.createTemp('phone-ref-');
        addTearDown(() => directory.delete(recursive: true));
        final file = await File(
          '${directory.path}/song.flac',
        ).writeAsBytes([1, 2, 3]);
        for (final (source, size) in [
          (file.path, 3),
          ('content://test.documents/music/song.flac', 0),
        ]) {
          final media = PlayableMedia(
            id: source,
            source: source,
            title: 'Song',
            artist: 'Band',
          );
          final cache = LinkTrackRefCache(lookup: FakeLibraryLookup());
          final item = linkMediaItem(media);
          expect(await cache.resolveAll([item]), isTrue);
          expect(cache.refFor(item).fileId, linkFileIdFor(source, size));
          expect(await cache.resolveAll([item]), isFalse);
        }
      },
    );
  });
}
