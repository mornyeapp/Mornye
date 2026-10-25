import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/features/link_phone_library_sync.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/link_fakes.dart';

/// Waits, in real time, until [condition] holds.
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

String _uri(int i) => 'content://media/external/audio/media/$i';

/// Rows of [count] content URI songs, which need no files.
FakeLibraryRows _uriRows(int count) => FakeLibraryRows([
  for (var i = 0; i < count; i++) linkLocalRow(_uri(i), {'format': 'flac'}),
]);

class _RevisionNotifier extends Notifier<LinkPhoneLibraryRevision> {
  @override
  LinkPhoneLibraryRevision build() =>
      (downloads: 0, library: 0, includeLocal: true);

  void set(LinkPhoneLibraryRevision revision) => state = revision;
}

final _revisionProvider =
    NotifierProvider<_RevisionNotifier, LinkPhoneLibraryRevision>(
      _RevisionNotifier.new,
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('link_phone_library_sync_');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String jpeg(String name, int size) {
    final path = '${dir.path}/$name';
    File(path).writeAsBytesSync([
      0xFF,
      0xD8,
      0xFF,
      ...List.filled(size - 3, size % 251),
    ]);
    return path;
  }

  List<Map<String, dynamic>> pages(FakeLinkClient client) => [
    for (final post in client.posts)
      if (post.op == LinkOps.phoneCatalog) post.body,
  ];

  group('publishing', () {
    test('stops when the desktop holds this version', () async {
      final library = _uriRows(3).library();
      final version = (await library.catalog()).version;
      final client = FakeLinkClient(onGet: (op, _) => {'version': version});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: library,
      );

      publisher.publish();
      await publisher.idle;

      expect(client.gets, [LinkOps.phoneCatalog]);
      expect(client.posts, isEmpty);
    });

    test('sends only the covers the desktop lacks', () async {
      final held = jpeg('held.jpg', 10);
      final first = jpeg('first.jpg', 11);
      final second = jpeg('second.jpg', 12);
      final library = FakeLibraryRows([
        linkLocalRow(_uri(0), {'format': 'flac', 'coverPath': held}),
        linkLocalRow(_uri(1), {'format': 'flac', 'coverPath': first}),
        linkLocalRow(_uri(2), {'format': 'flac', 'coverPath': second}),
        linkLocalRow(_uri(3), {'format': 'flac', 'coverPath': first}),
      ]).library();
      final client = FakeLinkClient(
        onGet: (op, _) => switch (op) {
          LinkOps.phoneCovers => {
            'ids': [linkFileIdFor(held, 10)],
          },
          _ => {'version': null},
        },
      );
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: library,
      );

      publisher.publish();
      await publisher.idle;

      expect(client.gets, [LinkOps.phoneCatalog, LinkOps.phoneCovers]);
      expect(
        [for (final post in client.posts) post.op],
        [LinkOps.phoneCovers, LinkOps.phoneCatalog],
      );
      expect(client.posts.first.body, {
        'covers': [
          {
            'id': linkFileIdFor(first, 11),
            'ext': 'jpg',
            'data': base64Encode(File(first).readAsBytesSync()),
          },
          {
            'id': linkFileIdFor(second, 12),
            'ext': 'jpg',
            'data': base64Encode(File(second).readAsBytesSync()),
          },
        ],
      });
    });

    test('keeps each covers request within 4 MiB of base64', () async {
      const size = 900 * 1024;
      final library = FakeLibraryRows([
        for (var i = 0; i < 4; i++)
          linkLocalRow(_uri(i), {
            'format': 'flac',
            'coverPath': jpeg('cover$i.jpg', size - i),
          }),
      ]).library();
      final client = FakeLinkClient(onGet: (op, _) => const {});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: library,
      );

      publisher.publish();
      await publisher.idle;

      final requests = [
        for (final post in client.posts)
          if (post.op == LinkOps.phoneCovers)
            (post.body['covers'] as List).cast<Map<String, dynamic>>(),
      ];
      expect([for (final covers in requests) covers.length], [3, 1]);
      for (final covers in requests) {
        final bytes = covers.fold<int>(
          0,
          (sum, cover) => sum + (cover['data'] as String).length,
        );
        expect(bytes, lessThanOrEqualTo(4 * 1024 * 1024));
      }
    });

    test('sends a cover over 1 MiB shrunk, as a PNG', () async {
      const size = linkPhoneCoverMaxBytes + 1;
      final small = jpeg('small.jpg', 10);
      final large = jpeg('large.jpg', size);
      final huge = jpeg('huge.jpg', size + 1);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2]);
      final library = FakeLibraryRows([
        linkLocalRow(_uri(0), {'format': 'flac', 'coverPath': large}),
        linkLocalRow(_uri(1), {'format': 'flac', 'coverPath': small}),
        linkLocalRow(_uri(2), {'format': 'flac', 'coverPath': huge}),
      ]).library();
      final client = FakeLinkClient(onGet: (op, _) => const {});
      final shrunk = <int>[];
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: library,
        encodeCovers: (covers) => encodeLinkPhoneCoversShrinking(
          covers,
          shrink: (image) async {
            shrunk.add(image.length);
            // One too large even shrunk is left out.
            return image.length == size
                ? png
                : Uint8List(linkPhoneShrunkCoverMaxBytes + 1);
          },
          encode: (covers) async => encodeLinkPhoneCovers(covers),
        ),
      );

      publisher.publish();
      await publisher.idle;

      expect(shrunk, [size, size + 1]);
      expect(client.posts.first.body, {
        'covers': [
          {
            'id': linkFileIdFor(small, 10),
            'ext': 'jpg',
            'data': base64Encode(File(small).readAsBytesSync()),
          },
          {
            'id': linkFileIdFor(large, size),
            'ext': 'png',
            'data': base64Encode(png),
          },
        ],
      });
    });

    test('leaves out covers replaced since the build', () async {
      final kept = jpeg('kept.jpg', 10);
      final replaced = jpeg('replaced.jpg', 11);
      final library = FakeLibraryRows([
        linkLocalRow(_uri(0), {'format': 'flac', 'coverPath': kept}),
        linkLocalRow(_uri(1), {'format': 'flac', 'coverPath': replaced}),
      ]).library();
      await library.catalog();
      jpeg('replaced.jpg', 20);
      final client = FakeLinkClient(onGet: (op, _) => const {});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: library,
      );

      publisher.publish();
      await publisher.idle;
      final covers = client.posts.first.body['covers'] as List;
      expect(
        [for (final cover in covers) (cover as Map)['id']],
        [linkFileIdFor(kept, 10)],
      );

      // Nothing left to send: no covers request at all.
      client.posts.clear();
      jpeg('kept.jpg', 12);
      publisher.publish();
      await publisher.idle;
      expect(
        [for (final post in client.posts) post.op],
        [LinkOps.phoneCatalog],
      );
    });

    test('sends the songs in pages, in order', () async {
      final library = _uriRows(1001).library();
      final client = FakeLinkClient(onGet: (op, _) => {'version': 'old'});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: library,
      );

      publisher.publish();
      await publisher.idle;

      final catalog = library.last!;
      final sent = pages(client);
      expect([for (final page in sent) page['offset']], [0, 500, 1000]);
      expect([for (final page in sent) page['total']], [1001, 1001, 1001]);
      expect(
        [for (final page in sent) (page['songs'] as List).length],
        [500, 500, 1],
      );
      expect(sent.every((page) => page['version'] == catalog.version), isTrue);
      expect(
        [for (final page in sent) ...page['songs'] as List],
        [for (final song in catalog.songs) song.toJson()],
      );
    });

    test('starts over once when a page is out of order', () async {
      var refusals = 1;
      final client = FakeLinkClient(
        onGet: (op, _) => {'version': null},
        onPost: (op, body) {
          if (body['offset'] == 500 && refusals-- > 0) {
            return const LinkException('invalid', 'Out of order');
          }
          return null;
        },
      );
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: _uriRows(1001).library(),
      );

      publisher.publish();
      await publisher.idle;
      expect(
        [for (final page in pages(client)) page['offset']],
        [0, 500, 0, 500, 1000],
      );

      client.posts.clear();
      refusals = 2;
      publisher.publish();
      await publisher.idle;
      expect(
        [for (final page in pages(client)) page['offset']],
        [0, 500, 0, 500],
      );
    });

    test('commits an empty list with one empty page', () async {
      final client = FakeLinkClient(onGet: (op, _) => {'version': 'old'});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: FakeLibraryRows().library(),
      );

      publisher.publish();
      await publisher.idle;

      expect(client.gets, [LinkOps.phoneCatalog]);
      expect(pages(client), [
        {
          'version': (await FakeLibraryRows().library().catalog()).version,
          'offset': 0,
          'total': 0,
          'songs': <Object?>[],
        },
      ]);
    });

    test('logs a failure and tries again on the next run', () async {
      Object? reply = const LinkException('unavailable');
      final client = FakeLinkClient(onGet: (op, _) => reply);
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: _uriRows(1).library(),
      );

      publisher.publish();
      await publisher.idle;
      expect(client.posts, isEmpty);

      reply = {'version': null};
      publisher.publish();
      await publisher.idle;
      expect(pages(client), hasLength(1));
    });

    test('a newer run replaces a running one', () async {
      final rows = _uriRows(2)..hold = Completer<void>();
      final client = FakeLinkClient(onGet: (op, _) => {'version': null});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: rows.library(),
      );

      publisher.publish();
      publisher.publish();
      rows.hold!.complete();
      await publisher.idle;

      // The first run stops once its build ends; only the second asks, with
      // that build.
      expect(rows.queries, hasLength(1));
      expect(client.gets, [LinkOps.phoneCatalog]);
      expect(pages(client), hasLength(1));
    });
  });

  group('triggers', () {
    testWidgets('publish on each connection', (tester) async {
      final client = FakeLinkClient(
        connectionState: LinkConnectionState.disconnected,
        onGet: (op, _) => {'version': null},
      );
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: _uriRows(1).library(),
      )..start();
      await tester.pump();
      expect(client.gets, isEmpty);

      client.setConnection(LinkConnectionState.connected);
      await tester.pump();
      expect(client.gets, [LinkOps.phoneCatalog]);

      client.setConnection(LinkConnectionState.disconnected);
      client.setConnection(LinkConnectionState.connected);
      await tester.pump();
      expect(client.gets, [LinkOps.phoneCatalog, LinkOps.phoneCatalog]);
      publisher.dispose();
    });

    testWidgets('reuse the list until the Library changes', (tester) async {
      // The desktop holds the last list committed.
      Object? held;
      final client = FakeLinkClient(
        onGet: (op, _) => {'version': held},
        onPost: (op, body) {
          final songs = body['songs'];
          if (op == LinkOps.phoneCatalog &&
              songs is List &&
              (body['offset'] as int) + songs.length == body['total']) {
            held = body['version'];
          }
          return null;
        },
      );
      final rows = _uriRows(2);
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: rows.library(),
      )..start();
      await tester.pump();
      expect(rows.queries, hasLength(1));
      expect(pages(client), hasLength(1));

      client
        ..setConnection(LinkConnectionState.disconnected)
        ..setConnection(LinkConnectionState.connected);
      await tester.pump();
      // Only the version is compared.
      expect(rows.queries, hasLength(1));
      expect(client.gets, hasLength(2));
      expect(pages(client), hasLength(1));

      rows
        ..rows = [
          ...rows.rows,
          linkLocalRow(_uri(2), {'format': 'flac'}),
        ]
        ..bump();
      publisher.libraryChanged();
      await tester.pump(const Duration(seconds: 2));
      expect(rows.queries, hasLength(2));
      expect(pages(client), hasLength(2));
      expect(pages(client).last['total'], 3);
      publisher.dispose();
    });

    testWidgets('publish 2 s after the Library settles', (tester) async {
      final client = FakeLinkClient(onGet: (op, _) => {'version': null});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: _uriRows(1).library(),
      )..start();
      await tester.pump();
      expect(client.gets, hasLength(1));

      publisher.libraryChanged();
      await tester.pump(const Duration(seconds: 1));
      publisher.libraryChanged();
      await tester.pump(const Duration(milliseconds: 1999));
      expect(client.gets, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(client.gets, hasLength(2));
      publisher.dispose();
    });

    testWidgets('wait for a connection', (tester) async {
      final client = FakeLinkClient(
        connectionState: LinkConnectionState.disconnected,
        onGet: (op, _) => {'version': null},
      );
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: _uriRows(1).library(),
      )..start();

      publisher.libraryChanged();
      await tester.pump(const Duration(seconds: 5));
      expect(client.gets, isEmpty);

      // Dropped while the change waits.
      client.setConnection(LinkConnectionState.connected);
      await tester.pump();
      publisher.libraryChanged();
      client.setConnection(LinkConnectionState.disconnected);
      await tester.pump(const Duration(seconds: 5));
      expect(client.gets, hasLength(1));
      publisher.dispose();
    });

    testWidgets('stop when disposed', (tester) async {
      final client = FakeLinkClient(onGet: (op, _) => {'version': null});
      final publisher = LinkPhoneLibraryPublisher(
        client: client,
        library: _uriRows(1).library(),
      )..start();
      await tester.pump();
      publisher
        ..libraryChanged()
        ..dispose();
      client.setConnection(LinkConnectionState.connected);
      await tester.pump(const Duration(seconds: 5));
      expect(client.gets, hasLength(1));
    });
  });

  group('file requests', () {
    late String song;

    setUp(() {
      song = '${dir.path}/Song.flac';
      File(song).writeAsBytesSync(List.filled(64, 7));
    });

    String nameOf(String path, int size) => '${linkFileIdFor(path, size)}.flac';

    List<Map<String, dynamic>> said(FakeLinkClient client, String type) => [
      for (final message in client.sent)
        if (message['type'] == type) message,
    ];

    LinkPhoneFileRequests requests(
      FakeLinkClient client,
      FakeLibraryRows rows, {
      LinkPhoneFiles? files,
    }) => LinkPhoneFileRequests(
      client: client,
      library: rows.library(),
      files: files ?? LinkPhoneFiles(),
    )..start();

    test('upload the song and say it is coming', () async {
      final client = FakeLinkClient();
      final handler = requests(client, FakeLibraryRows([linkLocalRow(song)]));
      final name = nameOf(song, 64);

      client.push({'type': LinkMessageTypes.filesRequest, 'name': name});
      await until(() => client.uploads.isNotEmpty);

      expect(said(client, LinkMessageTypes.filesSending), [
        {
          'type': LinkMessageTypes.filesSending,
          'name': name,
          'file': name,
          'size': 64,
          'streamable': true,
        },
      ]);
      expect(client.uploads.single.name, name);
      expect(client.uploads.single.bytes, File(song).readAsBytesSync());
      expect(said(client, LinkMessageTypes.filesFailed), isEmpty);
      handler.dispose();
    });

    test('name a content URI copy by its own format', () async {
      final copy = '${dir.path}/copy.m4a';
      File(copy).writeAsBytesSync(const [0, 0, 0, 8, 0x6D, 0x6F, 0x6F, 0x76]);
      final client = FakeLinkClient();
      final handler = requests(
        client,
        FakeLibraryRows([
          linkLocalRow(_uri(1), {'format': 'flac'}),
        ]),
        files: LinkPhoneFiles(copyContentUri: (uri) async => copy),
      );
      final fileId = linkFileIdFor(_uri(1), 0);

      client.push({
        'type': LinkMessageTypes.filesRequest,
        'name': '$fileId.flac',
      });
      await until(() => client.uploads.isNotEmpty);

      expect(said(client, LinkMessageTypes.filesSending).single, {
        'type': LinkMessageTypes.filesSending,
        'name': '$fileId.flac',
        'file': '$fileId.m4a',
        'size': 8,
        'streamable': true,
      });
      handler.dispose();
    });

    test('say an unknown or unsendable song failed', () async {
      final client = FakeLinkClient()
        ..onUpload = (name) => const LinkException('unavailable');
      final handler = requests(client, FakeLibraryRows([linkLocalRow(song)]));
      final unknown = '${linkFileIdFor('/elsewhere.flac', 1)}.flac';

      client
        ..push({'type': LinkMessageTypes.open, 'url': 'https://example.com'})
        ..push({'type': LinkMessageTypes.filesRequest})
        ..push({'type': LinkMessageTypes.filesRequest, 'name': unknown})
        ..push({
          'type': LinkMessageTypes.filesRequest,
          'name': nameOf(song, 64),
        });
      await until(() => said(client, LinkMessageTypes.filesFailed).length == 2);

      expect(said(client, LinkMessageTypes.filesFailed), [
        {
          'type': LinkMessageTypes.filesFailed,
          'name': unknown,
          'reason': 'not_found',
        },
        {
          'type': LinkMessageTypes.filesFailed,
          'name': nameOf(song, 64),
          'reason': 'unavailable',
        },
      ]);
      handler.dispose();
    });

    test('run two at once, in order, ignoring repeats', () async {
      final paths = [for (var i = 0; i < 3; i++) '${dir.path}/song$i.flac'];
      for (final path in paths) {
        File(path).writeAsBytesSync(List.filled(16, 1));
      }
      final names = [for (final path in paths) nameOf(path, 16)];
      final releases = <String, Completer<void>>{};
      final started = <String>[];
      final client = FakeLinkClient()
        ..whileUploading = (name, size, sent) {
          started.add(name);
          return (releases[name] = Completer<void>()).future;
        };
      final handler = requests(
        client,
        FakeLibraryRows([for (final path in paths) linkLocalRow(path)]),
      );

      for (final name in [...names, names.first, names.last]) {
        client.push({'type': LinkMessageTypes.filesRequest, 'name': name});
      }
      await until(() => started.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(started, names.take(2));

      releases[names.first]!.complete();
      await until(() => started.length == 3);
      expect(started, names);
      releases[names[1]]!.complete();
      releases[names[2]]!.complete();
      await until(() => client.uploads.length == 3);
      expect(said(client, LinkMessageTypes.filesSending), hasLength(3));

      // A finished song can be asked for again.
      client.push({'type': LinkMessageTypes.filesRequest, 'name': names[0]});
      await until(() => started.length == 4);
      releases[names[0]]!.complete();
      await until(() => client.uploads.length == 4);
      handler.dispose();
    });

    test('drop waiting requests when the connection drops', () async {
      final paths = [for (var i = 0; i < 3; i++) '${dir.path}/song$i.flac'];
      for (final path in paths) {
        File(path).writeAsBytesSync(List.filled(16, 1));
      }
      final releases = <Completer<void>>[];
      final client = FakeLinkClient()
        ..whileUploading = (name, size, sent) {
          releases.add(Completer<void>());
          return releases.last.future;
        };
      final handler = requests(
        client,
        FakeLibraryRows([for (final path in paths) linkLocalRow(path)]),
      );

      for (final path in paths) {
        client.push({
          'type': LinkMessageTypes.filesRequest,
          'name': nameOf(path, 16),
        });
      }
      await until(() => releases.length == 2);
      client.setConnection(LinkConnectionState.disconnected);
      for (final release in releases) {
        release.complete();
      }
      await until(() => client.uploads.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(releases, hasLength(2));
      handler.dispose();
    });
  });

  group('wiring', () {
    tearDown(() => debugDesktopPlatformOverride = null);

    ProviderContainer container(
      FakeLibraryRows rows, {
      LinkPhoneOptions options = const LinkPhoneOptions(loaded: true),
    }) {
      final container = ProviderContainer(
        overrides: [
          linkPhoneLibraryRevisionProvider.overrideWith(
            (ref) => ref.watch(_revisionProvider),
          ),
          linkPhoneLibraryRowsProvider.overrideWithValue(rows.load),
          linkPhoneOptionsProvider.overrideWith(
            () => LinkPhoneOptionsNotifier(initial: options),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('waits for the saved choices', () async {
      final rows = FakeLibraryRows();
      final phone = container(rows, options: const LinkPhoneOptions());
      phone.read(linkActiveClientProvider.notifier).set(FakeLinkClient());
      expect(phone.read(linkPhoneLibraryProvider), isNull);
    });

    test('sends an empty list while sharing is off', () async {
      final rows = _uriRows(3);
      final client = FakeLinkClient(onGet: (op, _) => {'version': null});
      final phone = container(rows);
      phone.read(linkActiveClientProvider.notifier).set(client);
      phone.listen(linkPhoneLibraryProvider, (_, _) {});
      await phone.read(linkPhoneLibraryProvider)!.idle;
      expect(pages(client).single['total'], 3);

      phone.read(linkPhoneOptionsProvider.notifier).setShareSongs(false);
      final publisher = phone.read(linkPhoneLibraryProvider)!;
      await publisher.idle;
      expect(pages(client).last['total'], 0);
      expect(pages(client).last['songs'], isEmpty);
    });

    test('stays off without a paired desktop or on a desktop', () async {
      final rows = FakeLibraryRows();
      final phone = container(rows);
      expect(phone.read(linkPhoneLibraryProvider), isNull);

      debugDesktopPlatformOverride = true;
      final desktop = container(rows);
      desktop.read(linkActiveClientProvider.notifier).set(FakeLinkClient());
      expect(desktop.read(linkPhoneLibraryProvider), isNull);
      expect(rows.queries, isEmpty);
    });

    test('publishes with the Local Library switch', () async {
      final rows = FakeLibraryRows();
      final client = FakeLinkClient(onGet: (op, _) => {'version': null});
      final phone = container(rows);
      phone.read(linkActiveClientProvider.notifier).set(client);
      phone.listen(linkPhoneLibraryProvider, (_, _) {});

      final publisher = phone.read(linkPhoneLibraryProvider)!;
      await publisher.idle;
      expect(pages(client), hasLength(1));
      expect(rows.queries.single.includeLocal, isTrue);

      phone.read(_revisionProvider.notifier).set((
        downloads: 0,
        library: 1,
        includeLocal: false,
      ));
      await pumpEventQueue();
      expect(phone.read(linkPhoneLibraryProvider), same(publisher));
      publisher.publish();
      await publisher.idle;
      expect(rows.queries.last.includeLocal, isFalse);
    });
  });
}
