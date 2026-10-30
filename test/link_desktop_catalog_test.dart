import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/desktop/link_catalog_exporter.dart';
import 'package:mornye/services/link/link_protocol.dart';

void main() {
  late Directory temp;
  late String song;
  late String download;
  late String cover;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('link_catalog_test');
    song = '${temp.path}/One.flac';
    download = '${temp.path}/Two.mp3';
    cover = '${temp.path}/cover.jpg';
    File(song).writeAsBytesSync(List.filled(64, 1));
    File(download).writeAsBytesSync(List.filled(32, 2));
    File(cover).writeAsBytesSync(const [0xFF, 0xD8]);
    Directory('${temp.path}/folder.flac').createSync();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> local(
    String id,
    String? path, [
    Map<String, Object?>? extra,
  ]) => {
    'source': 'local',
    'item': {
      'id': id,
      'trackName': 'Track $id',
      'artistName': 'Artist',
      'filePath': path,
      ...?extra,
    },
  };

  List<Map<String, dynamic>> rows() => [
    local('1', song, {
      'albumName': 'Album',
      'albumArtist': 'Album Artist',
      'trackNumber': 3,
      'discNumber': 1,
      'releaseDate': '2021-04-02',
      'genre': 'Jazz',
      'duration': 245,
      'fileSize': 1234,
      'bitrate': 900,
      'sampleRate': 44100,
      'bitDepth': 16,
      'isrc': 'us-abc-21-00001',
      'coverPath': cover,
      'scannedAt': '2024-01-02T03:04:05.000Z',
    }),
    {
      'source': 'downloaded',
      'item': {
        'id': 'h9',
        'trackName': 'Downloaded',
        'artistName': 'Someone',
        'filePath': 'EXISTS:$download',
        'coverUrl': 'https://example.com/cover.jpg',
        'downloadedAt': '2024-02-03T00:00:00.000Z',
        'format': 'MP3',
      },
    },
    local('missing', '${temp.path}/gone.flac'),
    local('content', 'content://media/external/audio/7'),
    local('smb', 'smb://nas/music/a.flac'),
    local('relative', 'music/a.flac'),
    local('folder', '${temp.path}/folder.flac'),
    local('empty', null),
  ];

  test('maps readable local files and omits the rest', () {
    final page = mapLinkCatalogRows(rows());
    expect(page.songs.map((song) => song.id), ['l:1', 'd:h9']);
    final lines = const LineSplitter()
        .convert(utf8.decode(page.bytes))
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(lines, hasLength(2));

    final first = lines.first;
    expect(first.keys.toList(), [
      'id',
      'title',
      'artist',
      'albumArtist',
      'album',
      'albumKey',
      'track',
      'disc',
      'year',
      'genre',
      'durationMs',
      'path',
      'size',
      'suffix',
      'bitRate',
      'sampleRate',
      'bitDepth',
      'channels',
      'isrc',
      'matchKey',
      'coverPath',
      'addedMs',
      'trackGain',
      'albumGain',
      'trackPeak',
      'albumPeak',
      'explicit',
    ]);
    expect(first['id'], 'l:1');
    expect(first['title'], 'Track 1');
    expect(first['artist'], 'Artist');
    expect(first['albumArtist'], 'Album Artist');
    expect(first['album'], 'Album');
    expect(first['albumKey'], 'album artist|album');
    expect(first['track'], 3);
    expect(first['disc'], 1);
    expect(first['year'], 2021);
    expect(first['genre'], 'Jazz');
    expect(first['durationMs'], 245000);
    expect(first['path'], song);
    expect(first['size'], 1234);
    expect(first['suffix'], 'flac');
    expect(first['bitRate'], 900);
    expect(first['sampleRate'], 44100);
    expect(first['bitDepth'], 16);
    expect(first['isrc'], 'USABC2100001');
    expect(first['matchKey'], 'track 1|artist');
    expect(first['coverPath'], cover);
    expect(
      first['addedMs'],
      DateTime.parse('2024-01-02T03:04:05.000Z').millisecondsSinceEpoch,
    );
    expect(first['explicit'], isFalse);
    // The desktop player keeps the web cover the catalog drops.
    expect(page.covers, [cover, 'https://example.com/cover.jpg']);

    final second = lines.last;
    expect(second['path'], download);
    expect(second['size'], 32, reason: 'falls back to the file size');
    expect(second['suffix'], 'mp3');
    expect(second['albumKey'], isNull);
    expect(second['coverPath'], isNull, reason: 'no copy is held yet');
    expect(page.webCoverUrls, {'https://example.com/cover.jpg'});
  });

  group('web covers', () {
    const webUrl = 'https://example.com/album.jpg';
    late String held;

    setUp(() => held = '${temp.path}/${linkCoverUrlId(webUrl)}.jpg');

    Map<String, dynamic> downloaded(
      String id, {
      String? coverUrl,
      String? file,
    }) => {
      'source': 'downloaded',
      'item': {
        'id': id,
        'trackName': 'Track $id',
        'artistName': 'Artist',
        'filePath': file ?? download,
        'coverUrl': ?coverUrl,
      },
    };

    test('a song with only a web cover names the copy held', () {
      final page = mapLinkCatalogRows(
        [
          downloaded('web', coverUrl: webUrl),
          downloaded('again', coverUrl: webUrl, file: song),
          downloaded('plain', coverUrl: 'http://example.com/plain.jpg'),
          downloaded('none'),
        ],
        webCovers: {linkCoverUrlId(webUrl): held},
      );
      final lines = const LineSplitter()
          .convert(utf8.decode(page.bytes))
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();

      expect(lines.map((line) => line['coverPath']), [held, held, null, null]);
      // Only https covers are fetched.
      expect(page.webCoverUrls, {webUrl});
      // The desktop player keeps showing the web cover itself.
      expect(page.covers, [
        webUrl,
        webUrl,
        'http://example.com/plain.jpg',
        null,
      ]);
    });

    test('a local cover file is kept and wants no web cover', () {
      final page = mapLinkCatalogRows(
        [
          local('1', song, {'coverPath': cover, 'coverUrl': webUrl}),
          downloaded('2', coverUrl: cover),
        ],
        webCovers: {linkCoverUrlId(webUrl): held},
      );
      final lines = const LineSplitter()
          .convert(utf8.decode(page.bytes))
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();

      expect(lines.map((line) => line['coverPath']), [cover, cover]);
      expect(page.webCoverUrls, isEmpty);
      expect(page.covers, [cover, cover]);
    });

    test('an export names the copies held when it starts', () async {
      var listed = 0;
      final exporter = LinkCatalogExporter(
        directory: () async => Directory('${temp.path}/out'),
        mapPage: (rows, webCovers) async =>
            mapLinkCatalogRows(rows, webCovers: webCovers),
        webCovers: () async {
          listed++;
          return {linkCoverUrlId(webUrl): held};
        },
        pageSize: 1,
        loadPage: (query) async => QueueLibraryDbPage(
          rows: [
            downloaded('a', coverUrl: webUrl),
            downloaded('b', coverUrl: webUrl, file: song),
          ].skip(query.offset).take(query.limit).toList(),
          nextCursor: null,
        ),
      );

      final export = await exporter.export(includeLocal: true, serverId: 's');

      expect(listed, 1, reason: 'one listing for every page');
      final lines = File(export.path).readAsLinesSync().skip(1);
      expect(lines.map((line) => (jsonDecode(line) as Map)['coverPath']), [
        held,
        held,
      ]);
      expect(export.webCoverUrls, {webUrl});
      expect(export.index.coverFor('d:a'), webUrl);
    });
  });

  test('writes the header with the final count and pages by cursor', () async {
    final all = rows();
    final queries = <QueueLibraryDbQuery>[];
    final exporter = LinkCatalogExporter(
      pageSize: 3,
      nowMs: () => 1700000000000,
      directory: () async => Directory('${temp.path}/out'),
      mapPage: (rows, webCovers) async =>
          mapLinkCatalogRows(rows, webCovers: webCovers),
      loadPage: (query) async {
        queries.add(query);
        final page = all.skip(query.offset).take(query.limit).toList();
        return QueueLibraryDbPage(
          rows: page,
          nextCursor: QueueLibraryDbCursor([query.offset + page.length]),
        );
      },
    );

    final export = await exporter.export(includeLocal: true, serverId: 'srv');

    expect(queries.map((query) => query.offset), [0, 3, 6]);
    expect(queries.first.cursor, isNull);
    expect(queries[1].cursor, const QueueLibraryDbCursor([3]));
    expect(queries.every((query) => query.includeLocal), isTrue);
    expect(export.count, 2);
    expect(export.path, endsWith('catalog.ndjson'));
    expect(File('${export.path}.part').existsSync(), isFalse);

    final lines = File(export.path).readAsLinesSync();
    expect(lines, hasLength(3));
    expect(jsonDecode(lines.first), {
      'catalogVersion': 1,
      'generatedMs': 1700000000000,
      'count': 2,
    });
    expect((jsonDecode(lines[1]) as Map)['id'], 'l:1');
    expect((jsonDecode(lines[2]) as Map)['id'], 'd:h9');

    expect(export.index.serverId, 'srv');
    expect(export.index.length, 2);
    expect(export.index.coverFor('l:1'), cover);
    expect(export.index.coverFor('d:h9'), 'https://example.com/cover.jpg');
    expect(export.index.songIdForPath(download), 'd:h9');
  });

  test('an empty Library still writes a valid header', () async {
    final exporter = LinkCatalogExporter(
      nowMs: () => 5,
      directory: () async => Directory('${temp.path}/empty'),
      mapPage: (rows, webCovers) async =>
          mapLinkCatalogRows(rows, webCovers: webCovers),
      loadPage: (_) async =>
          const QueueLibraryDbPage(rows: [], nextCursor: null),
    );
    final export = await exporter.export(includeLocal: false, serverId: 's');
    final lines = File(export.path).readAsLinesSync();
    expect(lines, hasLength(1));
    expect((jsonDecode(lines.single) as Map)['count'], 0);
  });

  test('accepts file URIs and rejects other schemes', () {
    expect(linkLocalFilePath(Uri.file(song).toString()), song);
    expect(linkLocalFilePath('EXISTS:$song'), song);
    expect(linkLocalFilePath('content://a/b'), isNull);
    expect(linkLocalFilePath('relative/path.flac'), isNull);
    expect(linkLocalFilePath(null), isNull);
  });
}
