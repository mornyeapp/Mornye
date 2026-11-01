import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playlist_sources.dart';

const _tree =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

String _document(String relative) =>
    '$_tree/document/primary%3AMusic%2F${Uri.encodeComponent(relative)}';

Map<String, dynamic> _row(
  String id,
  String filePath, {
  String title = 'Song',
  String album = 'Album',
  int? trackNumber,
  int? discNumber,
}) => {
  'id': id,
  'trackName': title,
  'artistName': 'Artist',
  'albumName': album,
  'filePath': filePath,
  'scannedAt': '2026-10-01T00:00:00.000',
  'trackNumber': ?trackNumber,
  'discNumber': ?discNumber,
};

class _Library extends Fake implements LibraryDatabase {
  _Library(this.rows);

  final List<Map<String, dynamic>> rows;
  final lookups = <LocalLibraryBatchLookupRequest>[];

  @override
  Future<List<LibraryFilePathRow>> getFilePathRows() async => [
    for (final row in rows)
      (
        id: row['id'] as String,
        sourceId: 'music',
        filePath: row['filePath'] as String,
      ),
  ];

  @override
  Future<List<Map<String, dynamic>>> getByIds(List<String> ids) async => [
    for (final id in ids) ...rows.where((row) => row['id'] == id),
  ];

  @override
  Future<List<LocalLibrarySource>> getSources() async => [
    LocalLibrarySource(id: 'music', path: _tree, displayName: 'Music'),
  ];

  @override
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async {
    lookups.addAll(requests);
    return [
      for (final request in requests)
        rows
            .where(
              (row) =>
                  row['trackName'] == request.trackName &&
                  row['artistName'] == request.artistName,
            )
            .firstOrNull,
    ];
  }
}

void main() {
  test('folders come from SAF trees, plain paths and network shares', () {
    expect(libraryFolderPath(_document('Album/01.flac')), 'Album');
    expect(libraryFolderPath(_document('loose.flac')), '');
    expect(
      libraryFolderPath('/storage/emulated/0/Music/Album/02.flac#track=2'),
      '/storage/emulated/0/Music/Album',
    );
    expect(
      libraryFolderPath('network://nas/Music/Album/03.flac'),
      'network://nas/Music/Album',
    );
  });

  test('groups folders by source, named after the folder or source', () {
    final folders = groupLibraryFolders(
      [
        (id: '1', sourceId: 'music', filePath: _document('b/one.flac')),
        (id: '2', sourceId: 'music', filePath: _document('A/two.flac')),
        (id: '3', sourceId: 'music', filePath: _document('b/three.flac')),
        (id: '4', sourceId: 'music', filePath: _document('root.flac')),
        (id: '5', sourceId: 'other', filePath: '/sd/b/five.flac'),
      ],
      sourceNames: {'music': 'Music'},
    );
    expect(
      [
        for (final folder in folders)
          (folder.name, folder.path, folder.ids.join(',')),
      ],
      [
        ('A', 'A', '2'),
        ('b', '/sd/b', '5'),
        ('b', 'b', '1,3'),
        ('Music', '', '4'),
      ],
    );
  });

  test('one numbered album plays by disc and track, others by file', () {
    LocalLibraryItem item(
      String id,
      String file, {
      int? track,
      int? disc,
      String album = 'Album',
    }) => LocalLibraryItem.fromJson(
      _row(
        id,
        '/music/x/$file',
        trackNumber: track,
        discNumber: disc,
        album: album,
      ),
    );

    expect(
      sortFolderItems([
        item('a', 'z.flac', track: 1, disc: 2),
        item('b', 'y.flac', track: 2, disc: 1),
        item('c', 'x.flac', track: 1, disc: 1),
      ]).map((item) => item.id),
      ['c', 'b', 'a'],
    );
    expect(
      sortFolderItems([
        item('a', 'B.flac', track: 1),
        item('b', 'a.flac', track: 2, album: 'Other'),
        item('c', 'c.flac'),
      ]).map((item) => item.id),
      ['b', 'a', 'c'],
    );
  });

  test('playlist paths match by their longest unambiguous tail', () {
    final index = PlaylistPathIndex([
      (
        id: 'saf',
        sourceId: 's',
        filePath: _document('Rock/Album/01 Song.flac'),
      ),
      (id: 'plain', sourceId: 's', filePath: r'C:\Music\Jazz\Live\Take.flac'),
      (id: 'one', sourceId: 's', filePath: '/m/A/Intro.flac'),
      (id: 'two', sourceId: 's', filePath: '/m/B/Intro.flac'),
      (id: 'cue', sourceId: 's', filePath: '/m/Live/disc.flac#track=1'),
      (id: 'cue2', sourceId: 's', filePath: '/m/Live/disc.flac#track=2'),
    ]);

    expect(
      index.match('/storage/emulated/0/Music/Rock/Album/01 Song.flac'),
      'saf',
    );
    expect(index.match('../album/01 song.FLAC'), 'saf');
    expect(index.match('file:///sdcard/Jazz/Live/Take.flac'), 'plain');
    expect(index.match(r'Live\Take.flac'), 'plain');
    expect(index.match('file:///x/A/Intro.flac'), 'one');
    expect(index.match('Intro.flac'), isNull);
    expect(index.match('/other/Missing.flac'), isNull);
    expect(index.match('Live/disc.flac'), isNull);
  });

  test(
    'M3U imports keep their path lines and skip a byte order mark',
    () async {
      final entries = await parsePlaylistImportFile(
        Uint8List.fromList(
          utf8.encode(
            '\uFEFF#EXTM3U\n'
            '#EXTINF:200,Artist - First\n'
            'Album/01 First.flac\n'
            '../Second.mp3\n',
          ),
        ),
        'Mix.m3u8',
      );
      expect(
        [for (final entry in entries) (entry.track.name, entry.path)],
        [('First', 'Album/01 First.flac'), ('Second', '../Second.mp3')],
      );
    },
  );

  test(
    'imports match paths, then title and artist, and keep the rest',
    () async {
      final library = _Library([
        _row('by-path', _document('Album/01 First.flac'), title: 'First'),
        _row('by-name', '/music/Other/Second.flac', title: 'Second'),
      ]);
      Track track(String name) => Track(
        id: 'm3u_$name',
        name: name,
        artistName: 'Artist',
        albumName: 'Unknown Album',
        duration: 0,
      );

      final result = await matchPlaylistImport([
        PlaylistImportEntry(track('Renamed'), 'Music/Album/01 First.flac'),
        PlaylistImportEntry(track('Second'), 'elsewhere/2.flac'),
        PlaylistImportEntry(track('Missing')),
        PlaylistImportEntry(track('Renamed'), 'Album/01 First.flac'),
      ], library);

      expect(result.matched, 3);
      expect(
        [for (final track in result.tracks) (track.id, track.source)],
        [
          ('by-path', 'local'),
          ('by-name', 'local'),
          ('m3u_Missing', null),
          ('by-path', 'local'),
        ],
      );
      expect(
        [for (final lookup in library.lookups) lookup.trackName],
        ['Second', 'Missing'],
      );
    },
  );
}
