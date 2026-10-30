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

  /// A store in [folder] that answers each fetch with [answer].
  LinkWebCovers open(
    FutureOr<Uint8List?> Function(Uri url) answer, {
    DateTime Function()? now,
    Duration firstRetry = const Duration(minutes: 1),
    List<Uri>? fetched,
  }) {
    final covers = LinkWebCovers(
      folder: () async => folder,
      fetchCover: (url) async {
        fetched?.add(url);
        return answer(url);
      },
      shrinkCover: (image) async => _png,
      now: now,
      firstRetry: firstRetry,
    );
    addTearDown(covers.close);
    return covers;
  }

  String pathOf(String url, [String ext = 'jpg']) =>
      '${folder.path}/${linkCoverUrlId(url)}.$ext';

  test('keeps each address once under a stable name', () async {
    final fetched = <Uri>[];
    final covers = open((_) => _jpeg, fetched: fetched);
    var added = 0;
    covers.added.listen((_) => added++);

    covers.fetch({_url('a'), _url('b')});
    await covers.idle();

    expect(await covers.held(), {
      linkCoverUrlId(_url('a')): pathOf(_url('a')),
      linkCoverUrlId(_url('b')): pathOf(_url('b')),
    });
    expect(File(pathOf(_url('a'))).readAsBytesSync(), _jpeg);
    // Written through a staged file that is gone now.
    expect(folder.listSync().map((entry) => entry.path).toSet(), {
      pathOf(_url('a')),
      pathOf(_url('b')),
    });
    expect(fetched, hasLength(2));
    expect(added, 1);

    // A cover held already is not fetched again.
    covers.fetch({_url('a'), _url('b')});
    await covers.idle();
    expect(fetched, hasLength(2));
    expect(added, 1);
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

    covers.fetch({_url('page'), _url('large'), _url('gone')});
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

    covers.fetch({for (var i = 0; i < 10; i++) _url('$i')});
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
      covers.fetch({_url('a')});
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

    covers.fetch({_url('a')});
    await covers.idle();
    expect(fetched, hasLength(1));
    reachable = true;
    await added.timeout(const Duration(seconds: 5));
    expect(fetched, hasLength(2));
    expect(await covers.held(), hasLength(1));

    reachable = false;
    covers.fetch({_url('b')});
    await covers.idle();
    expect(fetched, hasLength(3));
    covers.stop();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(fetched, hasLength(3), reason: 'a stopped store fetches nothing');
  });

  test('a removal keeps the covers wanted and takes the rest', () async {
    await folder.create(recursive: true);
    final other = File('${folder.path}/notes.txt')..writeAsStringSync('x');
    for (final name in ['a', 'b']) {
      File(pathOf(_url(name))).writeAsBytesSync(_jpeg);
    }
    final covers = open((_) => _jpeg);

    // Queued before the listing an export starts with.
    unawaited(covers.prune({_url('a')}));
    expect(await covers.held(), {linkCoverUrlId(_url('a')): pathOf(_url('a'))});
    expect(File(pathOf(_url('b'))).existsSync(), isFalse);
    expect(other.existsSync(), isTrue);

    await covers.prune(const {});
    expect(await covers.held(), isEmpty);
  });

  test('a folder it cannot use gives no covers and no error', () async {
    final covers = LinkWebCovers(
      folder: () async => throw StateError('no app support folder'),
      fetchCover: (_) async => _jpeg,
    );
    addTearDown(covers.close);
    expect(await covers.held(), isEmpty);
    await covers.prune({_url('a')});
    covers.fetch({_url('a')});
    await covers.idle();
    expect(await covers.held(), isEmpty);
  });

  group('the catalog export', () {
    late String song;
    late List<Map<String, dynamic>> rows;
    late LinkWebCovers covers;
    late bool reachable;
    late List<Uri> fetched;

    setUp(() {
      song = '${temp.path}/Song.mp3';
      File(song).writeAsBytesSync(List.filled(16, 1));
      rows = [
        {
          'source': 'downloaded',
          'item': {
            'id': 'web',
            'trackName': 'Song',
            'artistName': 'Artist',
            'filePath': song,
            'coverUrl': _url('album'),
          },
        },
      ];
      reachable = true;
      fetched = [];
      covers = open(
        (_) => reachable ? _jpeg : null,
        fetched: fetched,
        now: () => DateTime(2026, 10, 30),
      );
    });

    /// Exports [rows], then does what the host does once the server reads
    /// the catalog.
    Future<({String? coverPath, LinkCatalogExport export})> export() async {
      final exporter = LinkCatalogExporter(
        directory: () async => Directory('${temp.path}/out'),
        mapPage: (rows, webCovers) async =>
            mapLinkCatalogRows(rows, webCovers: webCovers),
        webCovers: covers.held,
        loadPage: (query) async => QueueLibraryDbPage(
          rows: rows.skip(query.offset).take(query.limit).toList(),
          nextCursor: null,
        ),
      );
      final export = await exporter.export(includeLocal: true, serverId: 's');
      final pruned = covers.prune(export.webCoverUrls);
      covers.fetch(export.webCoverUrls);
      await Future.wait([pruned, covers.idle()]);
      final lines = File(export.path).readAsLinesSync().skip(1).toList();
      return (
        coverPath: lines.isEmpty
            ? null
            : (jsonDecode(lines.single) as Map)['coverPath'] as String?,
        export: export,
      );
    }

    test('a web-only download names a lasting cover after the '
        'fetch', () async {
      final first = await export();
      expect(first.coverPath, isNull, reason: 'not fetched yet');
      expect(first.export.webCoverUrls, {_url('album')});

      final second = await export();
      expect(second.coverPath, pathOf(_url('album')));
      // The prune after it keeps the cover the catalog names.
      final third = await export();
      expect(third.coverPath, pathOf(_url('album')));
      expect(File(pathOf(_url('album'))).existsSync(), isTrue);
      expect(fetched, hasLength(1));

      // Once no song wants it, it goes.
      rows = [];
      await export();
      expect(File(pathOf(_url('album'))).existsSync(), isFalse);
    });

    test('a failed fetch still exports the song and backs off', () async {
      reachable = false;
      final first = await export();
      final second = await export();
      expect(first.export.count, 1);
      expect(second.export.count, 1);
      expect(second.coverPath, isNull);
      expect(fetched, hasLength(1), reason: 'not tried again at once');
    });
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
            default:
              response.statusCode = HttpStatus.notFound;
          }
          await response.close();
        } on Object {
          // The client hung up on the oversized cover.
        }
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('takes a cover and refuses a missing or oversized one', () async {
      expect(await fetchLinkCover(at('/cover.jpg')), _jpeg);
      expect(await fetchLinkCover(at('/gone.jpg')), isNull);
      expect(await fetchLinkCover(at('/huge.jpg')), isNull);
    });
  });
}
