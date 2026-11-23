import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/features/link_metadata_update.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/metadata_persistence_service.dart';

const _server = LinkServerRecord(
  serverId: 'host-a',
  name: 'Studio',
  connectionId: 'connection-a',
  address: 'https://10.0.0.2:47710',
  fingerprint: 'ab',
);

const _other = LinkServerRecord(
  serverId: 'host-b',
  name: 'Laptop',
  connectionId: 'connection-b',
  address: 'https://10.0.0.3:47710',
  fingerprint: 'cd',
);

LocalLibraryItem _song(
  String songId, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  String? albumArtist,
  String? genre,
  String? releaseDate,
  int? track,
  int? disc,
  String? isrc,
}) {
  final source = linkDesktopSongSource(_server, songId, format: 'flac');
  return LocalLibraryItem(
    id: source,
    trackName: title,
    artistName: artist,
    albumName: album,
    albumArtist: albumArtist ?? artist,
    filePath: source,
    scannedAt: DateTime(2026),
    genre: genre,
    releaseDate: releaseDate,
    trackNumber: track,
    discNumber: disc,
    isrc: isrc,
  );
}

DownloadHistoryItem _copy(
  String id, {
  String? origin,
  String service = LinkOfflineSaver.service,
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  String? albumArtist,
  String? genre,
  String? releaseDate,
  int? track,
  int? disc,
  String? isrc,
  String? filePath,
  String storageMode = 'app',
}) => DownloadHistoryItem(
  id: id,
  trackName: title,
  artistName: artist,
  albumName: album,
  albumArtist: albumArtist,
  filePath: filePath ?? '/music/$id.flac',
  originFilePath: origin,
  storageMode: storageMode,
  service: service,
  downloadedAt: DateTime(2026),
  genre: genre,
  releaseDate: releaseDate,
  trackNumber: track,
  discNumber: disc,
  isrc: isrc,
);

String _origin(String songId, [LinkServerRecord server = _server]) =>
    linkDesktopSongSource(server, songId, format: 'flac');

void main() {
  group('differences', () {
    test('the same tags differ in nothing', () {
      expect(
        linkMetadataDifferences(
          _copy('a', genre: 'Rock', track: 3, releaseDate: '2020'),
          _song('1', genre: 'Rock', track: 3, releaseDate: '2020'),
        ),
        isEmpty,
      );
    });

    test('noise is not a difference', () {
      final differences = linkMetadataDifferences(
        _copy(
          'a',
          title: ' Song ',
          genre: '',
          releaseDate: '2020-05-01',
          isrc: 'us-abc-20-00001',
        ),
        _song(
          '1',
          title: 'Song',
          // An empty host tag is not sent, so it never clears one.
          genre: '  ',
          releaseDate: '2020',
          disc: 1,
          isrc: 'USABC2000001',
        ),
      );
      expect(differences, isEmpty);
    });

    test('a tag the host does not have is never a difference', () {
      expect(
        linkMetadataDifferences(
          _copy('a', album: 'Kept', genre: 'Rock', track: 2, isrc: 'X'),
          _song('1', album: 'Unknown Album'),
        ),
        isEmpty,
      );
      expect(
        linkMetadataDifferences(
          _copy('a', artist: 'Someone'),
          _song('1', artist: 'Unknown Artist'),
        ),
        isEmpty,
      );
    });

    test('an album artist the host fills in fills no empty tag', () {
      expect(linkMetadataDifferences(_copy('a'), _song('1')), isEmpty);
      expect(
        linkMetadataDifferences(
          _copy('a'),
          _song('1', albumArtist: 'Various Artists'),
        ),
        isEmpty,
      );
      expect(
        linkMetadataDifferences(_copy('a'), _song('1', albumArtist: 'Band')),
        [
          const LinkMetadataDifference(
            LinkMetadataField.albumArtist,
            phone: '',
            computer: 'Band',
          ),
        ],
      );
      expect(
        linkMetadataDifferences(
          _copy('a', albumArtist: 'Old Band'),
          _song('1', albumArtist: 'Artist'),
        ),
        [
          const LinkMetadataDifference(
            LinkMetadataField.albumArtist,
            phone: 'Old Band',
            computer: 'Artist',
          ),
        ],
      );
    });

    test('lists each changed tag with both values', () {
      expect(
        linkMetadataDifferences(
          _copy(
            'a',
            title: 'Old',
            artist: 'Artist',
            album: 'Album',
            genre: 'Pop',
            releaseDate: '2019-01-02',
            track: 3,
            disc: 1,
          ),
          _song(
            '1',
            title: 'New',
            artist: 'Artist feat. Guest',
            album: 'Album (Deluxe)',
            albumArtist: 'Artist',
            genre: 'Rock',
            releaseDate: '2021',
            track: 4,
            disc: 2,
            isrc: 'USABC2100001',
          ),
        ),
        const [
          LinkMetadataDifference(
            LinkMetadataField.title,
            phone: 'Old',
            computer: 'New',
          ),
          LinkMetadataDifference(
            LinkMetadataField.artist,
            phone: 'Artist',
            computer: 'Artist feat. Guest',
          ),
          LinkMetadataDifference(
            LinkMetadataField.album,
            phone: 'Album',
            computer: 'Album (Deluxe)',
          ),
          LinkMetadataDifference(
            LinkMetadataField.albumArtist,
            phone: '',
            computer: 'Artist',
          ),
          LinkMetadataDifference(
            LinkMetadataField.genre,
            phone: 'Pop',
            computer: 'Rock',
          ),
          LinkMetadataDifference(
            LinkMetadataField.year,
            phone: '2019-01-02',
            computer: '2021',
          ),
          LinkMetadataDifference(
            LinkMetadataField.trackNumber,
            phone: '3',
            computer: '4',
          ),
          LinkMetadataDifference(
            LinkMetadataField.discNumber,
            phone: '1',
            computer: '2',
          ),
          LinkMetadataDifference(
            LinkMetadataField.isrc,
            phone: '',
            computer: 'USABC2100001',
          ),
        ],
      );
    });

    test('the applied record takes only the chosen tags', () {
      final copy = _copy('a', title: 'Old', genre: 'Pop', track: 3);
      final applied = linkMetadataApplied(copy, const [
        LinkMetadataDifference(
          LinkMetadataField.title,
          phone: 'Old',
          computer: 'New',
        ),
        LinkMetadataDifference(
          LinkMetadataField.trackNumber,
          phone: '3',
          computer: '5',
        ),
        LinkMetadataDifference(
          LinkMetadataField.year,
          phone: '',
          computer: '2021',
        ),
      ]);
      expect(applied.trackName, 'New');
      expect(applied.trackNumber, 5);
      expect(applied.releaseDate, '2021');
      expect(applied.genre, 'Pop');
      expect(applied.filePath, copy.filePath);
      expect(applied.id, copy.id);
    });

    test('a number is written with the total the copy has', () {
      const changes = [
        LinkMetadataDifference(
          LinkMetadataField.trackNumber,
          phone: '3',
          computer: '5',
        ),
        LinkMetadataDifference(
          LinkMetadataField.discNumber,
          phone: '',
          computer: '2',
        ),
        LinkMetadataDifference(
          LinkMetadataField.title,
          phone: 'Old',
          computer: 'New',
        ),
      ];
      expect(
        linkMetadataTags(
          _copy('a').copyWith(totalTracks: 12, totalDiscs: 0),
          changes,
        ),
        {
          'track_number': '5',
          'track_total': '12',
          'disc_number': '2',
          'title': 'New',
        },
      );
      expect(linkMetadataTags(_copy('a'), changes.take(1)), {
        'track_number': '5',
      });
    });
  });

  group('collector', () {
    test('matches copies to the host songs they came from', () async {
      final checked = <String>[];
      final collector = LinkMetadataCollector(
        server: _server,
        copies: () async => [
          _copy('changed', origin: _origin('1'), title: 'Old'),
          _copy('same', origin: _origin('2')),
          _copy('gone', origin: _origin('9'), title: 'Old'),
          _copy('other host', origin: _origin('1', _other), title: 'Old'),
          // An older record without an origin, found by its id.
          _copy(linkOfflineHistoryId(_server.serverId, '3'), genre: 'Pop'),
          _copy(
            'not link',
            origin: _origin('1'),
            service: 'Network offline',
            title: 'Old',
          ),
          _copy('deleted', origin: _origin('4'), title: 'Old'),
          _copy(
            'saf',
            origin: _origin('5'),
            title: 'Old',
            filePath: 'content://tree/document/primary%3AMusic%2FSong.flac',
            storageMode: 'saf',
          ),
        ],
        computerSongs: () => Stream.fromIterable([
          _song('1', title: 'New'),
          _song('2'),
          _song('3', genre: 'Rock'),
          _song('4', title: 'New'),
          _song('5', title: 'New'),
        ]),
        exists: (path) async {
          checked.add(path);
          return path != '/music/deleted.flac';
        },
      );
      final candidates = await collector.collect();
      expect(candidates.map((candidate) => candidate.copy.id), [
        'changed',
        linkOfflineHistoryId(_server.serverId, '3'),
        'saf',
      ]);
      expect(candidates.first.differences, const [
        LinkMetadataDifference(
          LinkMetadataField.title,
          phone: 'Old',
          computer: 'New',
        ),
      ]);
      // Only copies that differ are looked for on the phone.
      expect(checked, hasLength(4));
      expect(checked.last, startsWith('content://'));
    });

    test('stops reading the host once every copy is found', () async {
      Stream<LocalLibraryItem> songs() async* {
        yield _song('1', title: 'New');
        throw StateError('read past the saved songs');
      }

      final candidates = await LinkMetadataCollector(
        server: _server,
        copies: () async => [_copy('a', origin: _origin('1'))],
        computerSongs: songs,
        exists: (_) async => true,
      ).collect();
      expect(candidates.single.copy.id, 'a');
    });

    test('reads nothing without saved copies', () async {
      var read = false;
      final candidates = await LinkMetadataCollector(
        server: _server,
        copies: () async => [_copy('a', service: 'Tidal')],
        computerSongs: () {
          read = true;
          return const Stream.empty();
        },
      ).collect();
      expect(candidates, isEmpty);
      expect(read, isFalse);
    });

    test('a host that cannot be read fails the comparison', () async {
      final collector = LinkMetadataCollector(
        server: _server,
        copies: () async => [_copy('a', origin: _origin('1'))],
        computerSongs: () => Stream.error(StateError('offline')),
      );
      await expectLater(collector.collect(), throwsStateError);
    });
  });

  group('applier', () {
    test('writes the chosen tags and goes on after a failure', () async {
      final requests = <MetadataSaveRequest>[];
      final records = <DownloadHistoryItem>[];
      final published = <String>[];
      final progress = <(int, int)>[];
      final applier = LinkMetadataApplier(
        artistTagMode: () => 'joined',
        save: (request) async {
          requests.add(request);
          if (request.filePath == '/music/broken.flac') {
            return const MetadataSaveResult.failed(MetadataSaveFailure.backend);
          }
          if (request.filePath == '/music/throws.flac') {
            throw StateError('storage gone');
          }
          return const MetadataSaveResult.saved();
        },
        record: (item) async => records.add(item),
        publish: (path) async => published.add(path),
      );
      const title = LinkMetadataDifference(
        LinkMetadataField.title,
        phone: 'Old',
        computer: 'New',
      );
      const year = LinkMetadataDifference(
        LinkMetadataField.year,
        phone: '',
        computer: '2021',
      );
      const saf = 'content://tree/document/primary%3AMusic%2FSong.flac';
      final result = await applier.apply([
        LinkMetadataUpdate(
          copy: _copy('broken', title: 'Old'),
          changes: const [title],
        ),
        LinkMetadataUpdate(
          copy: _copy('saf', title: 'Old', filePath: saf, storageMode: 'saf'),
          changes: const [title, year],
        ),
        LinkMetadataUpdate(
          copy: _copy('throws', title: 'Old'),
          changes: const [title],
        ),
        LinkMetadataUpdate(
          copy: _copy('plain', genre: 'Pop'),
          changes: const [year],
        ),
      ], onProgress: (done, total) => progress.add((done, total)));

      expect(result.failed, 2);
      expect(result.updated.map((item) => item.id), ['saf', 'plain']);
      expect(requests, hasLength(4));
      final safRequest = requests[1];
      // The file is written where it is, never renamed or moved.
      expect(safRequest.filePath, saf);
      expect(safRequest.metadata, {'title': 'New', 'date': '2021'});
      expect(safRequest.preserveUnspecifiedTags, isTrue);
      expect(safRequest.artistTagMode, 'joined');
      expect(safRequest.selectedCoverPath, isNull);
      expect(safRequest.coverMaxDimension, isNull);
      expect(requests[3].metadata, {'date': '2021'});
      expect(records.map((item) => item.id), ['saf', 'plain']);
      expect(records.first.trackName, 'New');
      expect(records.first.releaseDate, '2021');
      expect(records.first.filePath, saf);
      expect(records.last.genre, 'Pop');
      expect(published, [saf, '/music/plain.flac']);
      expect(progress.last, (4, 4));
    });

    test('a record that cannot be saved counts as failed', () async {
      final result =
          await LinkMetadataApplier(
            artistTagMode: () => 'joined',
            save: (_) async => const MetadataSaveResult.saved(),
            record: (_) async => throw StateError('history locked'),
            publish: (_) async {},
          ).apply([
            LinkMetadataUpdate(
              copy: _copy('a', title: 'Old'),
              changes: const [
                LinkMetadataDifference(
                  LinkMetadataField.title,
                  phone: 'Old',
                  computer: 'New',
                ),
              ],
            ),
          ]);
      expect(result.updated, isEmpty);
      expect(result.failed, 1);
    });
  });
}
