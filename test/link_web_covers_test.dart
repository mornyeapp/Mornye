import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/desktop/link_catalog_exporter.dart';
import 'package:mornye/services/link/desktop/link_web_covers.dart';
import 'package:mornye/services/link/link_protocol.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 4, 5, 6]);

String _url(String name) => 'https://images.example.com/$name.jpg';

/// A song named [name] whose web cover is [url], or its own address.
LinkWebCoverSong _song(String name, {String? url}) => (
  path: '/music/$name.flac',
  stamp: '/music/$name.flac\n1\n1',
  url: url ?? _url(name),
);

List<LinkWebCoverSong> _songs(Iterable<String> names) => [
  for (final name in names) _song(name),
];

void main() {
  late Directory temp;
  late Directory folder;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('link-web-covers-');
    folder = Directory('${temp.path}/covers');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A store in [folder] that answers each fetch with [answer]. Files embed
  /// no picture unless [embeds] says so (null: it cannot be read).
  LinkWebCovers open(
    FutureOr<Uint8List?> Function(Uri url) answer, {
    DateTime Function()? now,
    Duration firstRetry = const Duration(minutes: 1),
    int maxStore = 1 << 20,
    List<Uri>? fetched,
    Map<String, bool?> embeds = const {},
    List<String>? probed,
  }) {
    final covers = LinkWebCovers(
      folder: () async => folder,
      probe: (paths) async {
        probed?.addAll(paths);
        return [
          for (final path in paths)
            embeds.containsKey(path) ? embeds[path] : false,
        ];
      },
      fetchCover: (url) async {
        fetched?.add(url);
        return answer(url);
      },
      shrinkCover: (image) async => _png,
      now: now,
      firstRetry: firstRetry,
      maxStore: maxStore,
    );
    addTearDown(covers.close);
    return covers;
  }

  String pathOf(String url, [String ext = 'jpg']) =>
      '${folder.path}/${linkCoverUrlId(url)}.$ext';

  Set<String> listed() => {
    if (folder.existsSync())
      for (final entry in folder.listSync())
        entry.path.substring(folder.path.length + 1),
  };

  test('keeps each address once under a stable name', () async {
    final fetched = <Uri>[];
    final covers = open((_) => _jpeg, fetched: fetched);
    var added = 0;
    covers.added.listen((_) => added++);

    covers.fetch([
      ..._songs(['a', 'b']),
      _song('again', url: _url('a')),
    ]);
    await covers.idle();

    expect(await covers.held(), {
      linkCoverUrlId(_url('a')): pathOf(_url('a')),
      linkCoverUrlId(_url('b')): pathOf(_url('b')),
    });
    expect(File(pathOf(_url('a'))).readAsBytesSync(), _jpeg);
    // Written through a staged file that is gone now.
    expect(listed(), {
      '${linkCoverUrlId(_url('a'))}.jpg',
      '${linkCoverUrlId(_url('b'))}.jpg',
      'pictures.json',
    });
    expect(fetched, hasLength(2));
    expect(added, 1);

    // A cover held already is not fetched again.
    covers.fetch(_songs(['a', 'b']));
    await covers.idle();
    await pumpEventQueue();
    expect(fetched, hasLength(2));
    expect(added, 1);
  });

  test('fetches only for songs whose file embeds no picture', () async {
    final fetched = <Uri>[];
    final probed = <String>[];
    final covers = open(
      (_) => _jpeg,
      fetched: fetched,
      probed: probed,
      embeds: {'/music/embeds.flac': true, '/music/unreadable.flac': null},
    );
    final songs = [
      ..._songs(['bare', 'embeds', 'unreadable']),
      // An address a file with a picture shares with one without.
      _song('shared', url: _url('bare')),
    ];

    covers.fetch(songs);
    await covers.idle();

    expect(fetched, [Uri.parse(_url('bare'))]);
    expect(await covers.pictures(), {
      songs[0].stamp: false,
      songs[1].stamp: true,
      songs[3].stamp: false,
    });

    // Known files are not read again; one it could not read is.
    probed.clear();
    covers.fetch(songs);
    await covers.idle();
    expect(probed, ['/music/unreadable.flac']);
    // A file that changed is a new version to ask about.
    final changed = (path: '/music/bare.flac', stamp: 'new', url: _url('b'));
    covers.fetch([changed]);
    await covers.idle();
    expect(probed.last, '/music/bare.flac');
    expect(await covers.pictures(), {'new': false});
  });

  test('remembers which files embed a picture after a restart', () async {
    final first = open((_) => _jpeg, embeds: {'/music/embeds.flac': true});
    first.fetch(_songs(['bare', 'embeds', 'gone']));
    await first.idle();
    first.close();

    final probed = <String>[];
    final fetched = <Uri>[];
    final second = open((_) => _jpeg, probed: probed, fetched: fetched);
    final songs = _songs(['bare', 'embeds']);
    second.fetch(songs);
    await second.idle();

    expect(probed, isEmpty);
    expect(fetched, isEmpty);
    // Only the songs listed now are kept.
    expect(await second.pictures(), {
      songs[0].stamp: false,
      songs[1].stamp: true,
    });
    final saved = jsonDecode(
      File('${folder.path}/pictures.json').readAsStringSync(),
    );
    expect((saved as Map)['pictures'], hasLength(2));
  });

  test('a cover held already counts once its file is found without a '
      'picture', () async {
    await folder.create(recursive: true);
    File(pathOf(_url('a'))).writeAsBytesSync(_jpeg);
    final fetched = <Uri>[];
    final covers = open((_) => _jpeg, fetched: fetched);
    var added = 0;
    covers.added.listen((_) => added++);

    covers.fetch(_songs(['a']));
    await covers.idle();
    await pumpEventQueue();
    expect(fetched, isEmpty);
    expect(added, 1);

    covers.fetch(_songs(['a']));
    await covers.idle();
    await pumpEventQueue();
    expect(added, 1, reason: 'nothing new for the next export');
  });

  test('leaves out what is not an image and keeps a large cover '
      'shrunk', () async {
    final covers = open(
      (url) => switch (url.toString()) {
        'https://images.example.com/page.jpg' => utf8.encode('<html>'),
        'https://images.example.com/large.jpg' => Uint8List(
          LinkWebCovers.maxCoverBytes + 1,
        )..setAll(0, _jpeg),
        _ => null,
      },
    );

    covers.fetch(_songs(['page', 'large', 'gone']));
    await covers.idle();

    expect(await covers.held(), {
      linkCoverUrlId(_url('large')): pathOf(_url('large'), 'png'),
    });
    expect(File(pathOf(_url('large'), 'png')).readAsBytesSync(), _png);
  });

  test('fetches a few covers at a time', () async {
    var running = 0;
    var most = 0;
    final covers = open((_) async {
      running++;
      if (running > most) most = running;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      return _jpeg;
    });

    covers.fetch(_songs([for (var i = 0; i < 10; i++) '$i']));
    await covers.idle();

    expect(most, LinkWebCovers.fetchesAtOnce);
    expect(await covers.held(), hasLength(10));
  });

  test('a failed cover waits longer after each failure', () async {
    var now = DateTime(2026, 10, 30, 12);
    var reachable = false;
    final fetched = <Uri>[];
    final covers = open(
      (_) => reachable ? _jpeg : throw const SocketException('unreachable'),
      now: () => now,
      fetched: fetched,
    );
    Future<void> exportAt(Duration later) async {
      now = now.add(later);
      covers.fetch(_songs(['a']));
      await covers.idle();
    }

    await exportAt(Duration.zero);
    expect(fetched, hasLength(1));
    // Exports within a minute of the failure leave it alone.
    await exportAt(const Duration(seconds: 30));
    expect(fetched, hasLength(1));
    await exportAt(const Duration(seconds: 31));
    expect(fetched, hasLength(2));
    // The second failure waits two minutes.
    await exportAt(const Duration(seconds: 90));
    expect(fetched, hasLength(2));
    reachable = true;
    await exportAt(const Duration(seconds: 31));
    expect(fetched, hasLength(3));
    expect(await covers.held(), {linkCoverUrlId(_url('a')): pathOf(_url('a'))});
  });

  test('tries a failed cover again by itself until stopped', () async {
    var reachable = false;
    final fetched = <Uri>[];
    final covers = open(
      (_) => reachable ? _jpeg : null,
      firstRetry: const Duration(milliseconds: 20),
      fetched: fetched,
    );
    final added = covers.added.first;

    covers.fetch(_songs(['a']));
    await covers.idle();
    expect(fetched, hasLength(1));
    reachable = true;
    await added.timeout(const Duration(seconds: 5));
    expect(fetched, hasLength(2));
    expect(await covers.held(), hasLength(1));

    reachable = false;
    covers.fetch(_songs(['b']));
    await covers.idle();
    expect(fetched, hasLength(3));
    covers.stop();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(fetched, hasLength(3), reason: 'a stopped store fetches nothing');
  });

  test('a cover fetched while it stops is not written', () async {
    final release = Completer<void>();
    final covers = open((_) async {
      await release.future;
      return _jpeg;
    });

    covers.fetch(_songs(['a']));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    covers.stop();
    release.complete();
    await covers.idle();

    expect(await covers.held(), isEmpty);
  });

  test('once full, fetches nothing until a prune frees space', () async {
    final fetched = <Uri>[];
    final covers = open(
      (url) => url.path == '/fail.jpg' ? null : _jpeg,
      fetched: fetched,
      maxStore: _jpeg.length + 3,
      firstRetry: const Duration(milliseconds: 20),
    );
    final songs = _songs(['fail', 'a', 'b']);

    covers.fetch(songs);
    await covers.idle();
    expect(fetched, hasLength(3));
    expect((await covers.held()).keys, [linkCoverUrlId(_url('a'))]);

    // No retry and no new fetch while full.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    covers.fetch(songs);
    await covers.idle();
    expect(fetched, hasLength(3));

    // A prune that removes a cover lets the rest in.
    final remaining = [songs[0], songs[2]];
    covers.fetch(remaining);
    await covers.prune(remaining);
    await covers.idle();
    expect(fetched.skip(3).toSet(), {
      Uri.parse(_url('fail')),
      Uri.parse(_url('b')),
    });
    expect((await covers.held()).keys, [linkCoverUrlId(_url('b'))]);
  });

  test('a removal keeps the covers songs may want and takes the '
      'rest', () async {
    await folder.create(recursive: true);
    final other = File('${folder.path}/notes.txt')..writeAsStringSync('x');
    for (final name in ['bare', 'embeds', 'unknown', 'gone']) {
      File(pathOf(_url(name))).writeAsBytesSync(_jpeg);
    }
    final covers = open(
      (_) => _jpeg,
      embeds: {'/music/embeds.flac': true, '/music/unknown.flac': null},
    );
    final songs = _songs(['bare', 'embeds', 'unknown']);
    covers.fetch(songs);
    await covers.idle();

    // Queued before the listing an export starts with.
    unawaited(covers.prune(songs));
    expect(await covers.held(), {
      linkCoverUrlId(_url('bare')): pathOf(_url('bare')),
      // Not known yet, so kept for now.
      linkCoverUrlId(_url('unknown')): pathOf(_url('unknown')),
    });
    expect(other.existsSync(), isTrue);

    await covers.prune(const []);
    expect(await covers.held(), isEmpty);
  });

  test('a folder it cannot use gives no covers and no error', () async {
    final covers = LinkWebCovers(
      folder: () async => throw StateError('no app support folder'),
      probe: (paths) async => [for (final _ in paths) false],
      fetchCover: (_) async => _jpeg,
    );
    addTearDown(covers.close);
    expect(await covers.held(), isEmpty);
    await covers.prune(_songs(['a']));
    covers.fetch(_songs(['a']));
    await covers.idle();
    expect(await covers.held(), isEmpty);
  });

  test('a failed probe leaves the files unknown', () async {
    final fetched = <Uri>[];
    final covers = LinkWebCovers(
      folder: () async => folder,
      probe: (_) async => throw StateError('no native library'),
      fetchCover: (url) async {
        fetched.add(url);
        return _jpeg;
      },
    );
    addTearDown(covers.close);
    covers.fetch(_songs(['a']));
    await covers.idle();
    expect(fetched, isEmpty);
    expect(await covers.pictures(), isEmpty);
  });

  test('a failed write leaves no staged file', () async {
    final id = linkCoverUrlId(_url('a'));
    // A folder in the cover's place makes the rename fail.
    File('${folder.path}/$id.jpg/keep').createSync(recursive: true);

    await expectLater(
      writeLinkCover(folder.path, id, 'jpg', _jpeg),
      throwsA(isA<FileSystemException>()),
    );
    expect(listed(), {'$id.jpg'});
  });

  group('the catalog export', () {
    late String bare;
    late String embeds;
    late List<Map<String, dynamic>> rows;
    late LinkWebCovers covers;
    late bool reachable;
    late List<Uri> fetched;

    Map<String, dynamic> download(String id, String path) => {
      'source': 'downloaded',
      'item': {
        'id': id,
        'trackName': 'Song $id',
        'artistName': 'Artist',
        'filePath': path,
        'coverUrl': _url('album'),
      },
    };

    setUp(() {
      bare = '${temp.path}/Bare.mp3';
      embeds = '${temp.path}/Embeds.flac';
      File(bare).writeAsBytesSync(List.filled(16, 1));
      File(embeds).writeAsBytesSync(List.filled(16, 2));
      rows = [download('bare', bare)];
      reachable = true;
      fetched = [];
      covers = open(
        (_) => reachable ? _jpeg : null,
        fetched: fetched,
        now: () => DateTime(2026, 10, 30),
        embeds: {embeds: true},
      );
    });

    /// Exports [rows], then does what the host does once the server reads
    /// the catalog. Returns each song's `coverPath`.
    Future<({List<Object?> coverPaths, LinkCatalogExport export})>
    export() async {
      final exporter = LinkCatalogExporter(
        directory: () async => Directory('${temp.path}/out'),
        mapPage: (rows, webCovers, pictures) async =>
            mapLinkCatalogRows(rows, webCovers: webCovers, pictures: pictures),
        webCovers: covers.held,
        pictures: covers.pictures,
        loadPage: (query) async => QueueLibraryDbPage(
          rows: rows.skip(query.offset).take(query.limit).toList(),
          nextCursor: null,
        ),
      );
      final export = await exporter.export(includeLocal: true, serverId: 's');
      final pruned = covers.prune(export.webCoverSongs);
      covers.fetch(export.webCoverSongs);
      await Future.wait([pruned, covers.idle()]);
      return (
        coverPaths: [
          for (final line in File(export.path).readAsLinesSync().skip(1))
            (jsonDecode(line) as Map)['coverPath'],
        ],
        export: export,
      );
    }

    test('a web-only download names a lasting cover after the '
        'fetch', () async {
      final first = await export();
      expect(first.coverPaths, [null], reason: 'not fetched yet');
      expect(first.export.webCoverSongs.single.url, _url('album'));

      final second = await export();
      expect(second.coverPaths, [pathOf(_url('album'))]);
      // The prune after it keeps the cover the catalog names.
      final third = await export();
      expect(third.coverPaths, [pathOf(_url('album'))]);
      expect(File(pathOf(_url('album'))).existsSync(), isTrue);
      expect(fetched, hasLength(1));

      // Once no song wants it, it goes.
      rows = [];
      await export();
      expect(File(pathOf(_url('album'))).existsSync(), isFalse);
    });

    test('a download with an embedded picture keeps it', () async {
      rows = [download('embeds', embeds)];
      for (var i = 0; i < 3; i++) {
        expect((await export()).coverPaths, [null]);
      }
      expect(fetched, isEmpty);
      expect(listed(), {'pictures.json'});

      // Beside a web-only song at the same address, only that one takes
      // the copy.
      rows = [download('embeds', embeds), download('bare', bare)];
      await export();
      expect((await export()).coverPaths, [null, pathOf(_url('album'))]);
      expect(fetched, hasLength(1));

      // Once the web-only song goes, so does the copy.
      rows = [download('embeds', embeds)];
      await export();
      expect(File(pathOf(_url('album'))).existsSync(), isFalse);
    });

    test('a failed fetch still exports the song and backs off', () async {
      reachable = false;
      final first = await export();
      final second = await export();
      expect(first.export.count, 1);
      expect(second.export.count, 1);
      expect(second.coverPaths, [null]);
      expect(fetched, hasLength(1), reason: 'not tried again at once');
    });
  });

  test('fetches web covers only from public https addresses', () {
    for (final url in [
      'https://images.example.com/a.jpg',
      'https://8.8.8.8/a.jpg',
      'https://[2001:db8::1]/a.jpg',
      'https://172.32.0.1/a.jpg',
    ]) {
      expect(isLinkWebCoverUrl(Uri.parse(url)), isTrue, reason: url);
    }
    for (final url in [
      'http://images.example.com/a.jpg',
      'https://localhost/a.jpg',
      'https://LOCALHOST./a.jpg',
      'https://cover.localhost/a.jpg',
      'https://127.0.0.1/a.jpg',
      'https://10.1.2.3/a.jpg',
      'https://172.16.0.1/a.jpg',
      'https://192.168.0.10/a.jpg',
      'https://169.254.169.254/a.jpg',
      'https://100.64.0.1/a.jpg',
      'https://0.0.0.0/a.jpg',
      'https://2130706433/a.jpg',
      'https://0x7f.1/a.jpg',
      'https://[::1]/a.jpg',
      'https://[::]/a.jpg',
      'https://[fe80::1]/a.jpg',
      'https://[fd00::1]/a.jpg',
      'https://[::ffff:127.0.0.1]/a.jpg',
      'https://[::ffff:192.168.0.1]/a.jpg',
    ]) {
      expect(isLinkWebCoverUrl(Uri.parse(url)), isFalse, reason: url);
    }
  });

  group('fetchLinkCover', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        try {
          switch (request.uri.path) {
            case '/cover.jpg':
              response.add(_jpeg);
            case '/huge.jpg':
              response.add(Uint8List(linkMaxFetchedCoverBytes + 1));
            case '/moved.jpg':
              await response.redirect(Uri.parse('/cover.jpg'));
              return;
            case '/loop.jpg':
              await response.redirect(Uri.parse('/loop.jpg'));
              return;
            case '/slow.jpg':
              await Future<void>.delayed(const Duration(seconds: 2));
              response.add(_jpeg);
            default:
              response.statusCode = HttpStatus.notFound;
          }
          await response.close();
        } on Object {
          // The client hung up.
        }
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('takes a cover and refuses a missing or oversized one', () async {
      expect(await fetchLinkCover(at('/cover.jpg')), _jpeg);
      expect(await fetchLinkCover(at('/gone.jpg')), isNull);
      expect(await fetchLinkCover(at('/huge.jpg')), isNull);
      // A phone's cover follows redirects as before.
      expect(await fetchLinkCover(at('/moved.jpg')), _jpeg);
    });

    test('checks every address a redirect leads to', () async {
      final asked = <String>[];
      bool allowAll(Uri url) {
        asked.add(url.path);
        return true;
      }

      expect(await fetchLinkCover(at('/moved.jpg'), allow: allowAll), _jpeg);
      expect(asked, ['/moved.jpg', '/cover.jpg']);
      expect(
        await fetchLinkCover(
          at('/moved.jpg'),
          allow: (url) => url.path != '/cover.jpg',
        ),
        isNull,
      );
      asked.clear();
      expect(await fetchLinkCover(at('/loop.jpg'), allow: allowAll), isNull);
      expect(asked, hasLength(6), reason: 'at most five redirects');
      // A web cover never comes from this machine.
      expect(await fetchLinkWebCover(at('/cover.jpg')), isNull);
    });

    test('gives up once the deadline passes', () async {
      final watch = Stopwatch()..start();
      final cover = await fetchLinkCover(
        at('/slow.jpg'),
        deadline: const Duration(milliseconds: 200),
      ).catchError((Object _) => null);
      expect(cover, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });
}
