import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:path/path.dart' as p;

const _added = '2026-01-01T00:00:00.000Z';

Map<String, dynamic> _download(
  String id, {
  String album = 'Album',
  String artist = 'Artist',
  int? disc,
  int? track,
  String? path,
}) => {
  'id': id,
  'trackName': 'Song $id',
  'artistName': artist,
  'albumName': album,
  'filePath': path ?? '/music/$id.flac',
  'coverUrl': 'https://covers.example/$id.jpg',
  'service': 'extension',
  'downloadedAt': _added,
  'discNumber': ?disc,
  'trackNumber': ?track,
};

Map<String, dynamic> _scanned(String id, {int? track}) => {
  'id': id,
  'trackName': 'Song $id',
  'artistName': 'Artist',
  'albumName': 'Album',
  'filePath': '/scanned/$id.flac',
  'coverPath': '/covers/$id.jpg',
  'scannedAt': _added,
  'trackNumber': ?track,
};

class _Library implements LibraryDatabase {
  _Library({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.localAlbum = const [],
    this.hits = const {},
    this.byId = const {},
    this.filesByTitle = const {},
  });

  final List<Map<String, dynamic>> songs;
  final List<Map<String, dynamic>> albums;
  final List<Map<String, dynamic>> artists;
  final List<Map<String, dynamic>> localAlbum;
  final Map<LibrarySearchKind, List<LibrarySearchHit>> hits;
  final Map<String, Map<String, dynamic>> byId;
  final Map<String, String> filesByTitle;
  final albumRequests = <QueueLibraryDbQuery>[];

  @override
  Future<QueueLibraryDbPage> getQueueTrackPageResult(
    QueueLibraryDbQuery request,
  ) async => QueueLibraryDbPage(
    rows: songs.skip(request.offset).take(request.limit).toList(),
    nextCursor: null,
  );

  @override
  Future<QueueLibraryDbPage> getQueueAlbumPageResult(
    QueueLibraryDbQuery request,
  ) async {
    albumRequests.add(request);
    return QueueLibraryDbPage(
      rows: [
        for (final album in albums)
          if (request.albumArtist == null ||
              album['artist_name'] == request.albumArtist)
            album,
      ],
      nextCursor: null,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getQueueArtistPage(
    QueueLibraryDbQuery request,
  ) async => artists;

  @override
  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracksByKey(
    String albumKey,
  ) async => albumKey == 'scanned-album' ? localAlbum : const [];

  @override
  Future<List<LibrarySearchHit>> searchLibrary({
    required String query,
    required LibrarySearchKind kind,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async => (hits[kind] ?? const []).take(limit).toList();

  @override
  Future<Map<String, dynamic>?> getById(String id) async => byId[id];

  @override
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async => [
    for (final request in requests)
      if (filesByTitle[request.trackName] case final path?)
        {'filePath': path}
      else
        null,
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History implements HistoryDatabase {
  _History({this.album = const [], this.byId = const {}});

  final List<Map<String, dynamic>> album;
  final Map<String, Map<String, dynamic>> byId;

  @override
  Future<List<Map<String, dynamic>>> getAlbumTracks(
    String albumName,
    String artistName,
  ) async => albumName == 'Album' && artistName == 'Artist' ? album : const [];

  @override
  Future<Map<String, dynamic>?> getById(String id) async => byId[id];

  @override
  Future<List<Map<String, dynamic>?>> findExistingTracks(
    List<HistoryLookupRequest> requests,
  ) async => List.filled(requests.length, null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collections implements LibraryCollectionsDatabase {
  _Collections({this.loved = const [], this.playlists = const {}});

  final List<Track> loved;
  final Map<String, List<Track>> playlists;

  @override
  Future<List<Track>> loadLovedTracks({int limit = 500}) async => loved;

  @override
  Future<List<({String id, String name, int trackCount, String? coverUrl})>>
  loadPlaylistSummaries() async => [
    for (final MapEntry(:key, :value) in playlists.entries)
      (id: key, name: key, trackCount: value.length, coverUrl: null),
  ];

  @override
  Future<List<Track>> loadPlaylistTracks(
    String playlistId, {
    int limit = 500,
  }) async => playlists[playlistId] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Track _track(String name) => Track(
  id: 'catalog-$name',
  name: name,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
);

MediaLibraryBrowser _browser({
  _Library? library,
  _History? history,
  _Collections? collections,
  bool includeLocal = true,
  CoverStore? covers,
  Future<BrowserCoverProvider?> Function()? coverProvider,
}) => MediaLibraryBrowser(
  library: library ?? _Library(),
  history: history ?? _History(),
  collections: collections ?? _Collections(),
  includeLocal: () => includeLocal,
  strings: () => lookupAppLocalizations(const Locale('en')),
  covers: covers,
  coverProvider: coverProvider ?? BrowserCoverProvider.load,
);

const _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46];

List<String> _titles(List<MediaItem> items) => [
  for (final item in items) item.title,
];

void main() {
  test('the root shows song, album, artist and playlist tabs', () async {
    final tabs = await _browser().children(AudioService.browsableRootId);

    expect(_titles(tabs), ['Songs', 'Albums', 'Artists', 'Playlists']);
    expect(tabs.every((tab) => !tab.playable!), isTrue);
    expect(
      tabs[1].extras?[AndroidContentStyle.browsableHintKey],
      AndroidContentStyle.gridItemHintValue,
    );
    expect(
      MediaLibraryBrowser.rootExtras['android.media.browse.SEARCH_SUPPORTED'],
      isTrue,
    );
  });

  test(
    'Songs lists the first songs and plays the whole Library from one',
    () async {
      final songs = [
        for (var i = 0; i <= MediaLibraryBrowser.listLimit; i++)
          i.isEven
              ? {'source': 'downloaded', 'item': _download('d$i')}
              : {'source': 'local', 'item': _scanned('l$i')},
      ];
      final browser = _browser(library: _Library(songs: songs));

      final items = await browser.children(MediaLibraryBrowser.songsId);
      expect(items.first.id, MediaLibraryBrowser.shuffleId);
      expect(items.first.title, 'Shuffle library');
      expect(items, hasLength(MediaLibraryBrowser.listLimit + 1));
      expect(items[1].title, 'Song d0');
      expect(items[1].artUri.toString(), 'https://covers.example/d0.jpg');
      // Without the cover provider, as here, a car cannot load local covers.
      expect(items[2].artUri, isNull);

      final queue = (await browser.queueFor(items[2].id))!;
      expect(queue.items, hasLength(MediaLibraryBrowser.listLimit + 1));
      expect(queue.items[queue.index].source, '/scanned/l1.flac');
      expect(queue.shuffle, isFalse);

      final shuffled = (await browser.queueFor(MediaLibraryBrowser.shuffleId))!;
      expect(shuffled.shuffle, isTrue);
      expect(shuffled.items, hasLength(MediaLibraryBrowser.listLimit + 1));
    },
  );

  test('an album plays in disc and track order from the chosen song', () async {
    final browser = _browser(
      library: _Library(
        albums: [
          {
            'queue_source': 'downloaded',
            'album_key': 'album|artist',
            'album_name': 'Album',
            'artist_name': 'Artist',
            'cover_url': 'https://covers.example/album.jpg',
          },
          {
            'queue_source': 'local',
            'album_key': 'scanned-album',
            'album_name': 'Scanned',
            'artist_name': 'Artist',
            'cover_path': '/covers/scanned.jpg',
          },
        ],
        localAlbum: [_scanned('b', track: 2), _scanned('a', track: 1)],
      ),
      history: _History(
        album: [
          _download('c', disc: 2, track: 1),
          _download('b', disc: 1, track: 2),
          _download('a', disc: 1, track: 1),
        ],
      ),
    );

    final albums = await browser.children(MediaLibraryBrowser.albumsId);
    expect(_titles(albums), ['Album', 'Scanned']);
    expect(albums.first.playable, isFalse);
    expect(albums.first.artist, 'Artist');

    final downloaded = await browser.children(albums.first.id);
    expect(_titles(downloaded), ['Song a', 'Song b', 'Song c']);
    final queue = (await browser.queueFor(downloaded[1].id))!;
    expect([for (final media in queue.items) media.id], ['a', 'b', 'c']);
    expect(queue.index, 1);

    final scanned = await browser.children(albums.last.id);
    expect(_titles(scanned), ['Song a', 'Song b']);
  });

  test('an artist opens its albums', () async {
    final library = _Library(
      artists: [
        {'artist_key': 'artist', 'artist_name': 'Artist'},
      ],
      albums: [
        {
          'queue_source': 'downloaded',
          'album_name': 'Album',
          'artist_name': 'Artist',
        },
        {
          'queue_source': 'downloaded',
          'album_name': 'Other',
          'artist_name': 'Someone else',
        },
      ],
    );
    final browser = _browser(library: library);

    final artists = await browser.children(MediaLibraryBrowser.artistsId);
    expect(_titles(artists), ['Artist']);
    expect(
      artists.single.extras?[AndroidContentStyle.browsableHintKey],
      AndroidContentStyle.gridItemHintValue,
    );
    final albums = await browser.children(artists.single.id);
    expect(_titles(albums), ['Album']);
    expect(library.albumRequests.last.albumArtist, 'Artist');
  });

  test(
    'playlists list Loved first and play the songs that have a file',
    () async {
      final directory = await Directory.systemTemp.createTemp('browser');
      addTearDown(() => directory.delete(recursive: true));
      Future<String> file(String name) async =>
          (await File('${directory.path}/$name.flac').create()).path;
      final first = await file('first');
      final third = await file('third');
      final browser = _browser(
        library: _Library(
          filesByTitle: {'First': first, 'Third': third, 'Loved': first},
        ),
        collections: _Collections(
          loved: [_track('Loved')],
          playlists: {
            'Road trip': [_track('First'), _track('Missing'), _track('Third')],
            'Empty': const [],
          },
        ),
      );

      final playlists = await browser.children(MediaLibraryBrowser.playlistsId);
      expect(_titles(playlists), ['Loved', 'Road trip']);
      expect(_titles(await browser.children(playlists.first.id)), ['Loved']);

      final songs = await browser.children(playlists.last.id);
      expect(_titles(songs), ['First', 'Third']);
      final queue = (await browser.queueFor(songs.last.id))!;
      expect([for (final media in queue.items) media.source], [first, third]);
      expect(queue.index, 1);
    },
  );

  test('Loved shows no loopback cover an older build stored', () async {
    final directory = await Directory.systemTemp.createTemp('browser');
    addTearDown(() => directory.delete(recursive: true));
    final file = (await File('${directory.path}/loved.flac').create()).path;
    Track loved(String name, String cover) => Track(
      id: 'catalog-$name',
      name: name,
      artistName: 'Artist',
      albumName: 'Album',
      coverUrl: cover,
      duration: 200,
    );
    final browser = _browser(
      library: _Library(filesByTitle: {'Old': file, 'Web': file}),
      collections: _Collections(
        loved: [
          loved('Old', 'http://127.0.0.1:41234/7f3a'),
          loved('Web', 'https://covers.example/web.jpg'),
        ],
      ),
    );

    final songs = await browser.children(MediaLibraryBrowser.lovedId);
    expect(_titles(songs), ['Old', 'Web']);
    expect(songs.first.artUri, isNull);
    expect(songs.last.artUri.toString(), 'https://covers.example/web.jpg');
  });

  group('the cover provider', () {
    const library = '/data/app/files/library_covers';
    late Directory directory;
    late CoverStore covers;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('browser-covers');
      covers = CoverStore(
        directory: () async => Directory('${directory.path}/covers'),
        fetch: (ref, output) => output.writeAsBytes(_jpeg),
      );
    });
    tearDown(() async {
      await covers.dispose();
      await directory.delete(recursive: true);
    });

    BrowserCoverProvider provider() => BrowserCoverProvider(
      authority: 'app.covers',
      folders: {
        'covers': '${directory.path}/covers',
        'library_covers': library,
        // Even a folder the provider serves shows no temporary file.
        'temporary': Directory.systemTemp.path,
      },
    );
    String cover(String folder, String name) => Uri(
      scheme: 'content',
      host: 'app.covers',
      pathSegments: [folder, name],
    ).toString();
    Map<String, dynamic> album(String name, String? cover) => {
      'queue_source': 'local',
      'album_key': name,
      'album_name': name,
      'artist_name': 'Artist',
      'cover_url': cover,
    };
    Map<String, String?> art(List<MediaItem> items) => {
      for (final item in items) item.title: item.artUri?.toString(),
    };

    test('shows the covers in its folders, the same for every form', () async {
      var loads = 0;
      final rows = _Library(
        songs: [
          {
            'source': 'local',
            'item': {..._scanned('l'), 'coverPath': '$library/l 1.jpg'},
          },
        ],
        albums: [
          album('Path', '$library/a.jpg'),
          album('File URI', 'file://$library/a.jpg'),
          album('Web', 'https://covers.example/w.jpg'),
          album('Loopback', 'http://127.0.0.1:41234/7f3a'),
          album('Elsewhere', '/storage/emulated/0/Music/cover.jpg'),
          album('Nested', '$library/old/a.jpg'),
          album('Escape', '$library/../shared_prefs/a.jpg'),
          album('Hidden', '$library/.a.jpg'),
          album('Temporary', '${Directory.systemTemp.path}/a.jpg'),
          album('Content', 'content://media/external/images/media/1'),
          album('None', null),
        ],
        artists: [
          {
            'artist_key': 'artist',
            'artist_name': 'Artist',
            'cover_url': '$library/artist.jpg',
          },
        ],
      );
      final browser = _browser(
        library: rows,
        covers: covers,
        coverProvider: () async {
          loads++;
          return provider();
        },
      );

      final songs = await browser.children(MediaLibraryBrowser.songsId);
      expect(songs[1].artUri.toString(), cover('library_covers', 'l 1.jpg'));
      final albums = await browser.children(MediaLibraryBrowser.albumsId);
      expect(art(albums), {
        'Path': cover('library_covers', 'a.jpg'),
        'File URI': cover('library_covers', 'a.jpg'),
        'Web': 'https://covers.example/w.jpg',
        'Loopback': null,
        'Elsewhere': null,
        'Nested': null,
        'Escape': null,
        'Hidden': null,
        'Temporary': null,
        'Content': null,
        'None': null,
      });
      expect(
        art(await browser.children(MediaLibraryBrowser.albumsId)),
        art(albums),
      );
      final artists = await browser.children(MediaLibraryBrowser.artistsId);
      expect(
        artists.single.artUri.toString(),
        cover('library_covers', 'artist.jpg'),
      );
      expect(loads, 1);

      // Without the provider a car cannot load them.
      final without = _browser(
        library: rows,
        covers: covers,
        coverProvider: () async => null,
      );
      expect(
        art(
          await without.children(MediaLibraryBrowser.albumsId),
        ).values.nonNulls,
        ['https://covers.example/w.jpg'],
      );
    });

    test('looks for the provider again after it was not found', () async {
      final answers = <Object?>[StateError('channel'), null, provider()];
      var loads = 0;
      final browser = _browser(
        library: _Library(albums: [album('Path', '$library/a.jpg')]),
        covers: covers,
        coverProvider: () async {
          final answer = answers[loads++];
          if (answer is Error) throw answer;
          return answer as BrowserCoverProvider?;
        },
      );
      Future<String?> shown() async => (await browser.children(
        MediaLibraryBrowser.albumsId,
      )).single.artUri?.toString();

      expect(await shown(), isNull);
      expect(await shown(), isNull);
      expect(await shown(), cover('library_covers', 'a.jpg'));
      expect(await shown(), cover('library_covers', 'a.jpg'));
      expect(loads, 3);
    });

    test('the tabs do not wait for the provider', () async {
      final found = Completer<BrowserCoverProvider?>();
      var loads = 0;
      final browser = _browser(
        library: _Library(albums: [album('Path', '$library/a.jpg')]),
        covers: covers,
        coverProvider: () {
          loads++;
          return found.future;
        },
      );

      final tabs = await browser.children(AudioService.browsableRootId);
      expect(_titles(tabs), ['Songs', 'Albums', 'Artists', 'Playlists']);
      final albums = browser.children(MediaLibraryBrowser.albumsId);
      found.complete(provider());
      expect(
        (await albums).single.artUri.toString(),
        cover('library_covers', 'a.jpg'),
      );
      expect(loads, 1);
    });

    test('shows the file the store keeps for a network cover', () async {
      const stored = 'network://connection/covers/a.jpg';
      const song = 'network://connection/music/song.flac';
      final storedPath = (await covers.file(stored))!;
      final tags = await File('${directory.path}/tags.jpg').writeAsBytes(_jpeg);
      final adoptedPath = (await covers.adopt(
        CoverStore.songCoverReference(song),
        tags.path,
      ))!;
      final browser = _browser(
        library: _Library(
          songs: [
            {
              'source': 'local',
              'item': {..._scanned('n'), 'filePath': song, 'coverPath': null},
            },
          ],
          hits: {
            LibrarySearchKind.albums: const [
              LibrarySearchHit(
                kind: LibrarySearchKind.albums,
                id: 'stored',
                title: 'Stored',
                source: 'local',
                cover: stored,
              ),
              LibrarySearchHit(
                kind: LibrarySearchKind.albums,
                id: 'missing',
                title: 'Not stored',
                source: 'local',
                cover: 'network://connection/covers/b.jpg',
              ),
            ],
          },
        ),
        covers: covers,
        coverProvider: () async => provider(),
      );

      expect(art(await browser.search('stored')), {
        'Stored': cover('covers', p.basename(storedPath)),
        'Not stored': null,
      });
      final songs = await browser.children(MediaLibraryBrowser.songsId);
      expect(
        songs[1].artUri.toString(),
        cover('covers', p.basename(adoptedPath)),
      );
    });
  });

  test('with Local Library off, Loved plays no scanned files', () async {
    final directory = await Directory.systemTemp.createTemp('browser');
    addTearDown(() => directory.delete(recursive: true));
    final file = (await File('${directory.path}/loved.flac').create()).path;
    final browser = _browser(
      library: _Library(filesByTitle: {'Loved': file}),
      collections: _Collections(loved: [_track('Loved')]),
      includeLocal: false,
    );

    expect(await browser.children(MediaLibraryBrowser.lovedId), isEmpty);
  });

  test('search groups its results by kind and plays found songs', () async {
    final browser = _browser(
      library: _Library(
        hits: {
          LibrarySearchKind.songs: const [
            LibrarySearchHit(
              kind: LibrarySearchKind.songs,
              id: 'b',
              title: 'Blue',
              source: 'downloaded',
            ),
            LibrarySearchHit(
              kind: LibrarySearchKind.songs,
              id: 'l',
              title: 'Blue too',
              source: 'local',
            ),
          ],
          LibrarySearchKind.albums: const [
            LibrarySearchHit(
              kind: LibrarySearchKind.albums,
              id: 'album|artist',
              title: 'Album',
              artist: 'Artist',
              source: 'downloaded',
            ),
          ],
          LibrarySearchKind.artists: const [
            LibrarySearchHit(
              kind: LibrarySearchKind.artists,
              id: 'artist',
              title: 'Blue Band',
            ),
          ],
        },
        byId: {'l': _scanned('l')},
      ),
      history: _History(byId: {'b': _download('b')}),
      collections: _Collections(
        playlists: {
          'Blue mornings': [_track('First')],
          'Other': [_track('First')],
        },
      ),
    );

    final results = await browser.search('blue');
    expect(_titles(results), [
      'Song b',
      'Song l',
      'Album',
      'Blue Band',
      'Blue mornings',
    ]);
    const group = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
    expect(
      [for (final item in results) item.extras?[group]],
      ['Songs', 'Songs', 'Albums', 'Artists', 'Playlists'],
    );
    final queue = (await browser.queueFor(results[1].id))!;
    expect([for (final media in queue.items) media.id], ['b', 'l']);
    expect(queue.index, 1);
    expect(await browser.search('  '), isEmpty);
  });

  test('a spoken request plays songs first or the kind it asks for', () async {
    final library = _Library(
      songs: [
        {'source': 'downloaded', 'item': _download('x')},
      ],
      hits: {
        LibrarySearchKind.songs: const [
          LibrarySearchHit(
            kind: LibrarySearchKind.songs,
            id: 'b',
            title: 'Blue',
            source: 'downloaded',
          ),
        ],
        LibrarySearchKind.albums: const [
          LibrarySearchHit(
            kind: LibrarySearchKind.albums,
            id: 'album|artist',
            title: 'Album',
            artist: 'Artist',
            source: 'downloaded',
          ),
        ],
      },
    );
    final browser = _browser(
      library: library,
      history: _History(
        byId: {'b': _download('b')},
        album: [_download('a1', track: 1), _download('a2', track: 2)],
      ),
    );
    List<String> ids(BrowserQueue? queue) => [
      for (final media in queue!.items) media.id,
    ];

    expect(ids(await browser.queueForSearch('blue')), ['b']);
    expect(
      ids(
        await browser.queueForSearch('album', {
          'android.intent.extra.focus': 'vnd.android.cursor.item/album',
        }),
      ),
      ['a1', 'a2'],
    );
    final shuffled = await browser.queueForSearch('');
    expect(ids(shuffled), ['x']);
    expect(shuffled!.shuffle, isTrue);

    final albumsOnly = _browser(
      library: _Library(
        hits: {LibrarySearchKind.albums: library.hits.values.last},
      ),
      history: _History(album: [_download('a1')]),
    );
    expect(ids(await albumsOnly.queueForSearch('album')), ['a1']);
    expect(await _browser().queueForSearch('nothing'), isNull);
  });

  test('a browser that asks for pages gets one page', () async {
    final browser = _browser(
      library: _Library(
        artists: [
          for (var i = 0; i < 5; i++)
            {'artist_key': 'a$i', 'artist_name': 'Artist $i'},
        ],
      ),
    );

    final page = await browser.children(MediaLibraryBrowser.artistsId, {
      'android.media.browse.extra.PAGE': 1,
      'android.media.browse.extra.PAGE_SIZE': 2,
    });
    expect(_titles(page), ['Artist 2', 'Artist 3']);
    expect(
      await browser.children(MediaLibraryBrowser.artistsId, {
        'android.media.browse.extra.PAGE': 3,
        'android.media.browse.extra.PAGE_SIZE': 2,
      }),
      isEmpty,
    );
    expect(await browser.children('another-app:root'), isEmpty);
    expect(await browser.queueFor('song-id'), isNull);
  });
}
