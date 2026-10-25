import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/desktop/link_transfer_songs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_desktop_fakes.dart';

const _phone = 'phone-1';

String _fileId(int i) => i.toRadixString(16).padLeft(32, '0');

DownloadHistoryItem _download(String id, String path) => DownloadHistoryItem(
  id: id,
  trackName: 'Down $id',
  artistName: 'Artist',
  albumName: 'Album',
  albumArtist: 'Band',
  filePath: path,
  service: 'tidal',
  downloadedAt: DateTime(2026),
  trackNumber: 3,
  duration: 200,
  releaseDate: '2021-04-01',
  isrc: 'USAAA0000001',
  format: 'flac',
  bitDepth: 24,
  sampleRate: 96000,
);

LocalLibraryItem _scanned(String id, String path, {String? cover}) =>
    LocalLibraryItem(
      id: id,
      trackName: 'Scan $id',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: path,
      coverPath: cover,
      scannedAt: DateTime(2026),
      duration: 180,
      releaseDate: '1999',
      trackNumber: 7,
    );

void main() {
  final sourceId = linkPhoneSourceId(_phone);

  test('a received song keeps one history id per phone and song', () {
    final id = linkTransferHistoryId(_phone, 'a.flac');
    expect(id, matches(RegExp(r'^link_[0-9a-f]{64}$')));
    expect(linkTransferHistoryId(_phone, 'a.flac'), id);
    expect(linkTransferHistoryId('phone-2', 'a.flac'), isNot(id));
  });

  test('reads phone song paths of the Library', () {
    final name = '${_fileId(1)}.flac';
    expect(linkPhoneSongPath('network://$sourceId/$name'), (
      sourceId: sourceId,
      name: name,
    ));
    for (final path in [
      '/music/$name',
      'network://smb-share/$name',
      'network://$sourceId/x/$name',
      'network://$sourceId/${_fileId(1)}.exe',
      'network://$sourceId/song.flac',
    ]) {
      expect(linkPhoneSongPath(path), isNull, reason: path);
    }
  });

  test('names desktop songs by their catalog ids', () {
    expect(
      linkDesktopSongIdOf(
        UnifiedLibraryItem.fromDownloadHistory(_download('h1', '/m/a.flac')),
      ),
      'd:h1',
    );
    expect(
      linkDesktopSongIdOf(
        UnifiedLibraryItem.fromLocalLibrary(_scanned('s1', '/m/b.flac')),
      ),
      'l:s1',
    );
    expect(
      linkDesktopSongIdOf(
        UnifiedLibraryItem.fromLocalLibrary(
          _scanned('n1', 'network://$sourceId/${_fileId(1)}.flac'),
        ),
      ),
      isNull,
    );
  });

  test('offers the catalog songs once each, with tags and sizes', () async {
    final folder = await Directory.systemTemp.createTemp('link-out-');
    addTearDown(() => folder.delete(recursive: true));
    final file = File('${folder.path}/a.flac')..writeAsBytesSync([1, 2, 3]);
    final index = DesktopLinkCatalogIndex(
      serverId: 'server-1',
      songs: [catalogSong('d:h1'), catalogSong('l:s1')],
    );
    final download = UnifiedLibraryItem.fromDownloadHistory(
      _download('h1', file.path),
    );
    final songs = await linkOutgoingSongs([
      download,
      download,
      UnifiedLibraryItem.fromLocalLibrary(
        _scanned('s1', '${folder.path}/gone.mp3', cover: '/covers/s1.jpg'),
      ),
      UnifiedLibraryItem.fromLocalLibrary(
        _scanned('s2', '${folder.path}/b.flac'),
      ),
      UnifiedLibraryItem.fromLocalLibrary(
        _scanned('n1', 'network://$sourceId/${_fileId(1)}.flac'),
      ),
    ], index);
    expect([for (final song in songs) song.song.songId], ['d:h1', 'l:s1']);
    final first = songs.first.song;
    expect(first.suffix, 'flac');
    expect(first.title, 'Down h1');
    expect(first.albumArtist, 'Band');
    expect(first.track, 3);
    expect(first.year, 2021);
    expect(first.durationMs, 200000);
    expect(first.isrc, 'USAAA0000001');
    expect(first.bitDepth, 24);
    expect(first.size, 3);
    final second = songs.last;
    expect(second.song.suffix, 'mp3');
    expect(second.song.size, 0);
    expect(second.song.year, 1999);
    expect(second.coverPath, '/covers/s1.jpg');
  });

  test('finds the Library songs behind playlist tracks', () async {
    final index = DesktopLinkCatalogIndex(
      serverId: 'server-1',
      songs: [catalogSong('d:h1', title: 'Down h1')],
    );
    Track track(String id, String name, {String? source}) => Track(
      id: id,
      name: name,
      artistName: 'Artist',
      albumName: 'Album',
      duration: 200,
      source: source,
    );
    final asked = <String>[];
    final items = await linkLibraryItemsForTracks(
      [
        track('network_n1', 'Phone song', source: 'local'),
        track('provider-1', 'Not here'),
        track('h1', 'Down h1'),
      ],
      index,
      loadHistory: (ids) async {
        asked.add('history:${ids.join(',')}');
        return {'h1': _download('h1', '/m/a.flac').toJson()};
      },
      loadLibrary: (ids) async {
        asked.add('library:${ids.join(',')}');
        return [
          _scanned(
            'network_n1',
            'network://$sourceId/${_fileId(1)}.flac',
          ).toJson(),
        ];
      },
    );
    expect(asked, ['history:h1', 'library:network_n1']);
    expect(
      [for (final item in items) item.trackName],
      ['Scan network_n1', 'Down h1'],
    );
  });

  test('groups phone songs by phone, once each', () {
    final name = '${_fileId(1)}.flac';
    final other = linkPhoneSourceId('phone-2');
    final song = UnifiedLibraryItem.fromLocalLibrary(
      _scanned('n1', 'network://$sourceId/$name'),
    );
    final grouped = linkPhoneSongsOf([
      song,
      song,
      UnifiedLibraryItem.fromLocalLibrary(
        _scanned('n2', 'network://$other/${_fileId(2)}.mp3'),
      ),
      UnifiedLibraryItem.fromDownloadHistory(_download('h1', '/m/a.flac')),
    ]);
    expect(grouped.keys, [sourceId, other]);
    expect([for (final entry in grouped[sourceId]!) entry.name], [name]);
  });

  test('receives the stored phone song, else the Library row', () async {
    final root = await Directory.systemTemp.createTemp('link-phones-');
    addTearDown(() => root.delete(recursive: true));
    final router = LinkHostRouter();
    final catalogs = LinkPhoneCatalogs(
      root: () async => root,
      paired: (deviceId) async => deviceId == _phone,
    )..register(router);
    final coverId = _fileId(0xc);
    Future<Object?> call(String op, Map<String, dynamic> args) =>
        router.dispatch(
          LinkRequest(
            requestId: 'r1',
            op: op,
            deviceId: _phone,
            args: {...args, '_method': 'POST'},
          ),
        );
    await call(LinkOps.phoneCovers, {
      'covers': [
        {
          'id': coverId,
          'ext': 'jpg',
          'data': base64Encode([0xff, 0xd8, 0xff, 1]),
        },
      ],
    });
    await call(LinkOps.phoneCatalog, {
      'version': 'v1',
      'offset': 0,
      'total': 1,
      'songs': [
        LinkPhoneSong(
          fileId: _fileId(1),
          suffix: 'flac',
          title: 'Stored',
          artist: 'Artist',
          size: 900,
          coverId: coverId,
        ).toJson(),
      ],
    });
    final songs = await linkIncomingSongs(catalogs, sourceId, [
      (
        name: '${_fileId(1)}.flac',
        item: _scanned('n1', 'network://$sourceId/${_fileId(1)}.flac'),
      ),
      (
        name: '${_fileId(2)}.mp3',
        item: _scanned(
          'n2',
          'network://$sourceId/${_fileId(2)}.mp3',
          cover: '/covers/n2.jpg',
        ),
      ),
    ]);
    expect(songs.first.song.title, 'Stored');
    expect(songs.first.song.size, 900);
    expect(songs.first.coverPath, '${root.path}/$sourceId/covers/$coverId.jpg');
    final fallback = songs.last;
    expect(fallback.song.name, '${_fileId(2)}.mp3');
    expect(fallback.song.title, 'Scan n2');
    expect(fallback.song.durationMs, 180000);
    expect(fallback.song.year, 1999);
    expect(fallback.coverPath, '/covers/n2.jpg');
  });

  test('the download folder falls back to the desktop default', () async {
    final folder = await Directory.systemTemp.createTemp('link-folder-');
    addTearDown(() => folder.delete(recursive: true));
    final source = File('${folder.path}/in.flac')..writeAsBytesSync([1]);
    final stored =
        await LinkDesktopDownloadFolder(
          const AppSettings(downloadDirectory: ''),
          defaultRoot: () async => '${folder.path}/Mornye',
        ).store(
          source,
          relativeDir: 'Band/Album',
          fileName: 'Song.flac',
          mimeType: 'audio/flac',
        );
    final sep = Platform.pathSeparator;
    expect(
      stored.filePath,
      '${folder.path}/Mornye${sep}Band${sep}Album${sep}Song.flac',
    );
    expect(File(stored.filePath).existsSync(), isTrue);
  });
}
