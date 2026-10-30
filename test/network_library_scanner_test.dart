import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

import 'support/network_scan_output.dart';

class _Storage extends NetworkStorageService {
  _Storage(this.tree, {this.failedFolder});
  final Map<String, List<NetworkEntry>> tree;
  final String? failedFolder;

  @override
  Future<NetworkConnection> connection(String id) async => NetworkConnection(
    id: id,
    name: 'NAS',
    protocol: NetworkProtocol.webdav,
    address: 'https://nas.test/music/',
    username: 'private-user',
    password: 'private-password',
  );

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async {
    if (path == failedFolder) throw const SocketException('offline');
    return tree[path] ?? [];
  }
}

class _BlockedFolderStorage extends _Storage {
  _BlockedFolderStorage()
    : super({
        '': [const NetworkEntry('Album/', 'Album', directory: true)],
      });

  final started = Completer<void>();
  final listing = Completer<List<NetworkEntry>>();

  @override
  Future<List<NetworkEntry>> list(NetworkConnection c, [String path = '']) {
    if (path != 'Album/') return super.list(c, path);
    started.complete();
    return listing.future;
  }
}

/// A storage without saved connections whose `virtual` host lists songs.
class _VirtualStorage extends NetworkStorageService {
  _VirtualStorage(List<NetworkVirtualSong> songs) {
    virtualSources = _VirtualSources(songs);
  }

  @override
  Future<NetworkConnection> connection(String id) async =>
      throw StateError('Network connection unavailable');
}

class _VirtualSources implements NetworkVirtualSources {
  _VirtualSources(this.songList);

  final List<NetworkVirtualSong> songList;

  @override
  bool owns(String id) => id == 'virtual';

  @override
  bool reachable(String id) => true;

  @override
  Stream<NetworkVirtualSong> songs(String id) => Stream.fromIterable(songList);

  @override
  Future<String> resolve(String id, String path) async => '/received/$path';

  @override
  Future<Map<String, dynamic>> metadata(String id, String path) async => {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('nas-library-test-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  NetworkLibraryScanner scanner(
    NetworkStorageService storage,
    Future<Map<String, dynamic>> Function(String) reader, {
    Future<RandomAccessFile> Function(File)? openOutput,
  }) => NetworkLibraryScanner(
    storage: storage,
    readMetadata: reader,
    supportDirectory: () async => directory,
    temporaryDirectory: () async => directory,
    openOutput: openOutput,
    metadataConcurrency: 1,
  );

  _Storage tracks(int count) => _Storage({
    '': List.generate(
      count,
      (index) => NetworkEntry('$index.flac', '$index.flac'),
    ),
  });

  Future<void> expectNoOutput() async {
    expect(
      await Directory('${directory.path}/network_scans').list().toList(),
      isEmpty,
    );
  }

  test(
    'cancel interrupts active native metadata reads and drains their work',
    () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final jobs = <String, Completer<String>>{};
      final cancelled = <String>{};
      final started = Completer<void>();
      var blockReads = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final arguments = call.arguments as Map;
        final id = arguments['request_id'] as String;
        if (call.method == 'cancelNativeDataJob') {
          final job = jobs[id];
          if (job != null && !job.isCompleted) {
            cancelled.add(id);
            job.completeError(PlatformException(code: 'CANCELLED'));
          }
          return null;
        }
        expect(call.method, 'runNativeDataJob');
        if (!blockReads) {
          return jsonEncode({
            'metadata': {'title': 'Track'},
            'cacheable': true,
          });
        }
        final job = Completer<String>();
        jobs[id] = job;
        if (jobs.length == 2) started.complete();
        return job.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final storage = tracks(20);
      addTearDown(storage.dispose);
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => directory,
        temporaryDirectory: () async => directory,
        metadataConcurrency: 2,
      );
      final scan = scanner.scan(
        NetworkStorageService.source('nas', ''),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      final stopped = expectLater(scan, throwsStateError);
      await started.future;
      await scanner.cancelPending();
      await stopped;
      expect(jobs, hasLength(2));
      expect(cancelled, jobs.keys.toSet());
      expect(jobs.values.every((job) => job.isCompleted), isTrue);
      await expectNoOutput();

      // A completed cancellation does not poison a later scan or retain its reader.
      blockReads = false;
      final retry = await scanner.scan(
        NetworkStorageService.source('nas', ''),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      expect(retry.expectedCount, 20);
      expect(retry.errorCount, 0);
    },
  );

  test(
    'cancelling a blocked child listing discards staging and its late error',
    () async {
      final storage = _BlockedFolderStorage();
      addTearDown(storage.dispose);
      final reader = scanner(storage, (_) async => {});
      final scan = reader.scan(
        'network://nas/',
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      final stopped = expectLater(scan, throwsStateError);
      await storage.started.future;
      await reader.cancelPending();
      await stopped.timeout(const Duration(seconds: 1));
      await expectNoOutput();
      storage.listing.completeError(
        const SocketException('Late listing failure'),
      );
      await pumpEventQueue();
    },
  );

  test(
    'directory-scoped deduplication rejects cross-folder listing entries',
    () async {
      final storage = _Storage({
        '': [
          const NetworkEntry('root.flac', 'root.flac'),
          const NetworkEntry('root.flac', 'root.flac'),
          const NetworkEntry('nested/song.flac', 'song.flac'),
          const NetworkEntry('nested/', 'nested', directory: true),
          const NetworkEntry('nested/', 'nested', directory: true),
        ],
        'nested/': [
          const NetworkEntry('nested/song.flac', 'song.flac'),
          const NetworkEntry('nested/song.flac', 'song.flac'),
          const NetworkEntry('root.flac', 'root.flac'),
        ],
      });
      final reads = <String>[];
      final result =
          await scanner(storage, (source) async {
            reads.add(Uri.parse(source).pathSegments.join('/'));
            return {'title': 'Track'};
          }).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      expect(reads, ['root.flac', 'nested/song.flac']);
      expect(result.expectedCount, 2);
      expect(result.errorCount, 0);
    },
  );

  test(
    'bounded prefetch retains listing order after out-of-order failures',
    () async {
      final gates = List.generate(6, (_) => Completer<Map<String, dynamic>>());
      final started = Completer<void>();
      final progress = <String>[];
      var reads = 0;
      var active = 0;
      var maximum = 0;
      final scan =
          NetworkLibraryScanner(
            storage: tracks(6),
            metadataConcurrency: 3,
            readMetadata: (source) async {
              final index = int.parse(
                Uri.parse(source).pathSegments.last.split('.').first,
              );
              reads++;
              active++;
              if (active > maximum) maximum = active;
              if (reads == 3) started.complete();
              try {
                return await gates[index].future;
              } finally {
                active--;
              }
            },
            supportDirectory: () async => directory,
            temporaryDirectory: () async => directory,
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, name) => progress.add(name),
          );
      await started.future;
      gates[2].complete({'title': '2'});
      gates[1].completeError(StateError('unreadable tags'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(progress, isEmpty);
      expect(reads, 3);
      for (final index in [0, 3, 4, 5]) {
        gates[index].complete({'title': '$index'});
      }
      final result = await scan;
      expect((await result.rows().toList()).map((row) => row['trackName']), [
        '0',
        '2',
        '3',
        '4',
        '5',
      ]);
      expect(progress, List.generate(6, (index) => '$index.flac'));
      expect(result.errorCount, 1);
      expect(maximum, 3);
      expect(active, 0);
    },
  );

  test(
    'pause stops prefetch dispatch and resumes without skipping tracks',
    () async {
      final paused = Completer<void>();
      final resume = Completer<void>();
      var shouldPause = false;
      var reads = 0;
      final scan =
          NetworkLibraryScanner(
            storage: tracks(8),
            metadataConcurrency: 3,
            readMetadata: (_) async => {'title': '${++reads}'},
            supportDirectory: () async => directory,
            temporaryDirectory: () async => directory,
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {
              if (shouldPause) {
                if (!paused.isCompleted) paused.complete();
                await resume.future;
              }
            },
            onProgress: (processed, _, _) {
              if (processed == 1) shouldPause = true;
            },
          );
      await paused.future;
      expect(reads, 3);
      shouldPause = false;
      resume.complete();
      final result = await scan;
      expect(result.expectedCount, 8);
      expect(reads, 8);
      expect(result.errorCount, 0);
    },
  );

  test(
    'prefetch cancellation drains pending errors and deletes staging',
    () async {
      final later = Completer<Map<String, dynamic>>();
      var cancelled = false;
      var reads = 0;
      final scan =
          NetworkLibraryScanner(
            storage: tracks(10),
            metadataConcurrency: 3,
            readMetadata: (_) {
              reads++;
              return reads == 1
                  ? Future.value({'title': 'first'})
                  : later.future;
            },
            supportDirectory: () async => directory,
            temporaryDirectory: () async => directory,
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {
              if (cancelled) throw StateError('cancelled');
            },
            onProgress: (_, _, _) {
              cancelled = true;
              later.completeError(StateError('stopped read'));
            },
          );
      await expectLater(scan, throwsStateError);
      expect(reads, 3);
      await expectNoOutput();
    },
  );

  test('WebDAV traversal indexes 1806 tracks across encoded album folders', () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final tree = <String, List<NetworkEntry>>{
      '': [
        const NetworkEntry('Music/', 'Music', directory: true),
        const NetworkEntry('Other/', 'Other', directory: true),
      ],
      'Music/': [
        const NetworkEntry('Music/lossless/', 'lossless', directory: true),
      ],
      'Music/lossless/': [
        const NetworkEntry(
          'Music/lossless/Ordinary/',
          'Ordinary',
          directory: true,
        ),
        const NetworkEntry(
          'Music/lossless/Artist & Band/',
          'Artist & Band',
          directory: true,
        ),
      ],
      'Music/lossless/Artist & Band/': [],
    };
    var trackIndex = 0;
    void addTracks(String folder, int count) {
      tree[folder] = List.generate(count, (_) {
        final index = trackIndex++;
        final extension = ['flac', 'mp3', 'ogg'][index % 3];
        final name = index < 369
            ? 'A & B $index.$extension'
            : 'Song $index.$extension';
        return NetworkEntry('$folder$name', name, size: 123);
      });
    }

    addTracks('Music/lossless/Ordinary/', 1168);
    addTracks('Other/', 37);
    for (var album = 0; album < 20; album++) {
      final name = 'Album + $album [Live]';
      final folder = 'Music/lossless/Artist & Band/$name/';
      tree['Music/lossless/Artist & Band/']!.add(
        NetworkEntry(folder, name, directory: true),
      );
      addTracks(folder, album == 19 ? 31 : 30);
    }
    expect(trackIndex, 1806);
    final listed = <String>[];
    server.listen((request) async {
      expect(request.method, 'PROPFIND');
      expect(request.headers.value('Depth'), '1');
      await request.drain<void>();
      final folder = request.uri.pathSegments.skip(1).join('/');
      listed.add(folder);
      final entries = tree[folder];
      if (entries == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.statusCode = HttpStatus.multiStatus;
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write('<d:multistatus xmlns:d="DAV:">');
        for (final entry in entries) {
          final href =
              '/dav/${entry.path.split('/').map(Uri.encodeComponent).join('/')}';
          request.response.write(
            '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
            '${entry.directory ? '<d:resourcetype><d:collection/></d:resourcetype>' : '<d:getcontentlength>123</d:getcontentlength>'}'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
        }
        request.response.write('</d:multistatus>');
      }
      await request.response.close();
    });
    final connection = NetworkConnection(
      id: 'nas',
      name: 'NAS',
      protocol: NetworkProtocol.webdav,
      address: 'http://127.0.0.1:${server.port}/dav/',
    );
    final storage = NetworkStorageService(
      read: () async => jsonEncode([connection.toJson()]),
      write: (_) async {},
    );
    addTearDown(storage.dispose);
    final scan =
        await scanner(
          storage,
          (source) async => {
            'title': Uri.parse(source).pathSegments.last,
            'artist': 'Artist',
            'album': 'Album',
          },
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, errors, _) => expect(errors, 0),
        );
    final rows = await scan.rows().toList();
    expect(scan.expectedCount, 1806);
    expect(scan.errorCount, 0);
    expect(rows, hasLength(1806));
    expect(rows.map((row) => row['id']).toSet(), hasLength(1806));
    expect(
      rows.where(
        (row) =>
            Uri.parse(row['filePath'] as String).pathSegments.first == 'Music',
      ),
      hasLength(1769),
    );
    expect(
      rows.where((row) => (row['trackName'] as String).contains('&')),
      hasLength(369),
    );
    expect(listed.toSet(), tree.keys.toSet());
  });

  test(
    'bounded writes preserve all rows, Unicode, order and progress',
    () async {
      late InstrumentedScanOutput output;
      final progress = <(int, int, String)>[];
      final scan =
          await scanner(
            tracks(1000),
            (source) async => {
              'title': 'Title — 音楽 🎵 ${Uri.parse(source).pathSegments.last}',
              'artist': 'Artist\nTwo',
              'genre': 'Line\r\nTwo',
            },
            openOutput: (file) async => output = InstrumentedScanOutput(
              await file.open(mode: FileMode.write),
            ),
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (count, errors, name) =>
                progress.add((count, errors, name)),
          );
      final rows = await scan.rows().toList();
      expect(scan.expectedCount, 1000);
      expect(scan.errorCount, 0);
      expect(rows, hasLength(1000));
      expect(progress, List.generate(1000, (i) => (i + 1, 0, '$i.flac')));
      for (var index = 0; index < rows.length; index++) {
        expect(rows[index]['trackName'], 'Title — 音楽 🎵 $index.flac');
        expect(rows[index]['artistName'], 'Artist\nTwo');
        expect(rows[index]['genre'], 'Line\r\nTwo');
      }
      expect(rows.map((row) => row['id']).toSet(), hasLength(1000));
      expect(output.physicalWrites, lessThan(100));
      expect(output.maximumConcurrentWrites, 1);
      expect(
        output.writeLengths.every((length) => length <= 64 * 1024),
        isTrue,
      );
      expect(output.rowCounts.every((count) => count <= 64), isTrue);
    },
  );

  test('oversized rows are written intact between bounded batches', () async {
    late InstrumentedScanOutput output;
    final longTitle = List.filled(70000, '音楽 🎵').join();
    final scan =
        await scanner(
          tracks(3),
          (source) async => {
            'title': source.endsWith('1.flac') ? longTitle : 'Small',
          },
          openOutput: (file) async => output = InstrumentedScanOutput(
            await file.open(mode: FileMode.write),
          ),
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        );
    expect((await scan.rows().toList()).map((row) => row['trackName']), [
      'Small',
      longTitle,
      'Small',
    ]);
    expect(
      output.writeLengths.where((length) => length > 64 * 1024),
      hasLength(1),
    );
    expect(output.rowCounts, everyElement(1));
    expect(output.maximumConcurrentWrites, 1);
  });

  test(
    'large metadata reaches the character bound before the row bound',
    () async {
      late InstrumentedScanOutput output;
      final title = List.filled(10000, '音楽').join();
      final scan =
          await scanner(
            tracks(25),
            (source) async => {'title': title, 'artist': source},
            openOutput: (file) async => output = InstrumentedScanOutput(
              await file.open(mode: FileMode.write),
            ),
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      final rows = await scan.rows().toList();
      expect(rows, hasLength(25));
      expect(rows.map((row) => row['trackName']), everyElement(title));
      expect(rows.map((row) => row['artistName']).toSet(), hasLength(25));
      expect(
        output.writeLengths.every((length) => length <= 64 * 1024),
        isTrue,
      );
      expect(output.rowCounts.reduce((a, b) => a + b), 25);
      expect(output.physicalWrites, greaterThan(1));
      expect(output.maximumConcurrentWrites, 1);
    },
  );

  test('unencodable metadata does not discard adjacent valid rows', () async {
    final cycle = <String, dynamic>{};
    cycle['cycle'] = cycle;
    final scan =
        await scanner(
          tracks(3),
          (source) async => {
            'title': source,
            'genre': source.endsWith('1.flac') ? cycle : 'Valid',
          },
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        );
    expect(scan.errorCount, 1);
    expect(scan.expectedCount, 2);
    expect((await scan.rows().toList()).map((row) => row['filePath']), [
      NetworkStorageService.source('nas', '0.flac'),
      NetworkStorageService.source('nas', '2.flac'),
    ]);
  });

  test('cancel before a flush drops buffered rows and stops reads', () async {
    late InstrumentedScanOutput output;
    var cancelled = false;
    var reads = 0;
    await expectLater(
      scanner(
        tracks(500),
        (_) async {
          reads++;
          return {'title': 'Track'};
        },
        openOutput: (file) async => output = InstrumentedScanOutput(
          await file.open(mode: FileMode.write),
        ),
      ).scan(
        NetworkStorageService.source('nas', ''),
        checkpoint: () async {
          if (cancelled) throw StateError('cancelled');
        },
        onProgress: (count, _, _) {
          if (count == 5) cancelled = true;
        },
      ),
      throwsStateError,
    );
    expect(reads, 5);
    expect(output.physicalWrites, 0);
    await expectNoOutput();
  });

  for (final cancelOnClose in [false, true]) {
    test(
      'cancel during final ${cancelOnClose ? 'close' : 'write'} aborts',
      () async {
        var cancelled = false;
        await expectLater(
          scanner(
            tracks(3),
            (_) async => {'title': 'Track'},
            openOutput: (file) async => InstrumentedScanOutput(
              await file.open(mode: FileMode.write),
              afterWrite: cancelOnClose ? null : () => cancelled = true,
              afterClose: cancelOnClose ? () => cancelled = true : null,
            ),
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {
              if (cancelled) throw StateError('cancelled');
            },
            onProgress: (_, _, _) {},
          ),
          throwsStateError,
        );
        expect(cancelled, isTrue);
        await expectNoOutput();
      },
    );
  }

  for (final failClose in [false, true]) {
    test(
      'partial write failure aborts even with close failure: $failClose',
      () async {
        final failure = FileSystemException('disk full');
        var reads = 0;
        final errors = <int>[];
        await expectLater(
          scanner(
            tracks(500),
            (_) async {
              reads++;
              return {'title': 'Track'};
            },
            openOutput: (file) async => InstrumentedScanOutput(
              await file.open(mode: FileMode.write),
              writeError: failure,
              closeError: failClose ? StateError('close failed') : null,
            ),
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, errorCount, _) => errors.add(errorCount),
          ),
          throwsA(same(failure)),
        );
        expect(reads, lessThan(500));
        expect(errors, isNotEmpty);
        expect(errors, everyElement(0));
        await expectNoOutput();
      },
    );
  }

  test(
    'close failure removes completed output without returning success',
    () async {
      final failure = StateError('close failed');
      await expectLater(
        scanner(
          tracks(3),
          (_) async => {'title': 'Track'},
          openOutput: (file) async => InstrumentedScanOutput(
            await file.open(mode: FileMode.write),
            closeError: failure,
          ),
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        ),
        throwsA(same(failure)),
      );
      await expectNoOutput();
    },
  );

  test('failed output open cleans up any partially created file', () async {
    final failure = FileSystemException('open failed');
    await expectLater(
      scanner(
        tracks(1),
        (_) async => {},
        openOutput: (file) async {
          await file.writeAsString('partial');
          throw failure;
        },
      ).scan(
        NetworkStorageService.source('nas', ''),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      ),
      throwsA(same(failure)),
    );
    await expectNoOutput();
  });

  test('empty folder produces a valid empty scan without writes', () async {
    late InstrumentedScanOutput output;
    final scan =
        await scanner(
          tracks(0),
          (_) async => throw StateError('unexpected read'),
          openOutput: (file) async => output = InstrumentedScanOutput(
            await file.open(mode: FileMode.write),
          ),
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) => fail('unexpected progress'),
        );
    expect(scan.expectedCount, 0);
    expect(scan.errorCount, 0);
    expect(await scan.rows().toList(), isEmpty);
    expect(output.physicalWrites, 0);
  });

  test(
    'identical artwork shares storage until the last reference is gone',
    () async {
      final shared = await File(
        '${directory.path}/shared.jpg',
      ).writeAsBytes([1, 2]);
      final different = await File(
        '${directory.path}/different.jpg',
      ).writeAsBytes([3]);
      final scan =
          await scanner(
            _Storage({
              '': [
                const NetworkEntry('one.flac', 'one.flac'),
                const NetworkEntry('two.flac', 'two.flac'),
                const NetworkEntry('three.flac', 'three.flac'),
              ],
            }),
            (source) async => {
              'title': 'Track',
              'cover_path': source.endsWith('three.flac')
                  ? different.path
                  : shared.path,
            },
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      final rows = await scan.rows().toList();
      expect(rows[0]['id'], isNot(rows[1]['id']));
      expect(rows[0]['coverPath'], rows[1]['coverPath']);
      expect(rows[0]['coverPath'], isNot(rows[2]['coverPath']));
      final covers = Directory('${directory.path}/library_covers');
      expect(await covers.list().length, 2);
      // Removing one track retains its sibling's shared cover.
      expect(
        await pruneUnreferencedLibraryCovers(covers, {
          for (final row in rows.skip(1)) row['coverPath'] as String,
        }, referenceColumns: const []),
        0,
      );
      expect(
        await pruneUnreferencedLibraryCovers(covers, {
          rows[2]['coverPath'] as String,
        }, referenceColumns: const []),
        1,
      );
      expect(await File(rows[2]['coverPath'] as String).readAsBytes(), [3]);
    },
  );

  test(
    'subfolders keep original metadata, stable identities and persistent artwork',
    () async {
      final cover = await File(
        '${directory.path}/transient.jpg',
      ).writeAsBytes([1, 2, 3]);
      final storage = _Storage({
        'albums/': [const NetworkEntry('albums/One/', 'One', directory: true)],
        'albums/One/': [
          const NetworkEntry(
            'albums/One/Title - Artist #1.flac',
            'Title - Artist #1.flac',
          ),
          const NetworkEntry(
            'albums/One/Title - Artist #1.flac',
            'Title - Artist #1.flac',
          ),
          const NetworkEntry('albums/', 'Parent', directory: true),
        ],
      });
      var reads = 0;
      final progress = <int>[];
      final scan =
          await scanner(storage, (source) async {
            reads++;
            expect(
              Uri.parse(source).pathSegments.last,
              'Title - Artist #1.flac',
            );
            return {
              'title': 'Original Title',
              'artist': 'Original Artist',
              'album': 'Original Album',
              'audio_codec': 'flac',
              'bit_depth': 24,
              'sample_rate': 96000,
              'lyrics': '[00:01.00]Words',
              'replaygain_track_gain': '-4 dB',
              'cover_path': cover.path,
            };
          }).scan(
            NetworkStorageService.source('nas', 'albums/'),
            checkpoint: () async {},
            onProgress: (count, errors, name) => progress.add(count),
          );
      final rows = await scan.rows().toList();
      expect(reads, 1);
      expect(progress, [1]);
      expect(scan.errorCount, 0);
      expect(rows.single['albumName'], 'Original Album');
      expect(rows.single['trackName'], 'Original Title');
      expect(rows.single['artistName'], 'Original Artist');
      expect(rows.single['hasLyrics'], true);
      expect(rows.single['replaygain_track_gain'], '-4 dB');
      expect(rows.single['sampleRate'], 96000);
      expect(rows.toString(), isNot(contains('private-password')));
      expect(rows.toString(), isNot(contains('127.0.0.1')));
      await cover.delete();
      expect(await File(rows.single['coverPath'] as String).readAsBytes(), [
        1,
        2,
        3,
      ]);
      await scan.delete();
      expect(await scan.file.exists(), false);
    },
  );

  test(
    'failed folders and tags report partial results instead of deleting old rows',
    () async {
      LogBuffer().clear();
      final storage = _Storage({
        '': [
          const NetworkEntry('offline/', 'Offline', directory: true),
          const NetworkEntry('ok.flac', 'ok.flac'),
          const NetworkEntry('bad.flac', 'bad.flac'),
        ],
      }, failedFolder: 'offline/');
      final scan =
          await scanner(storage, (source) async {
            if (source.endsWith('bad.flac')) {
              return {'metadataFromFilename': true};
            }
            return {'title': 'Valid', 'album': 'Album'};
          }).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      expect(scan.errorCount, 2);
      expect(scan.expectedCount, 1);
      expect((await scan.rows().toList()).single['trackName'], 'Valid');
      final errors = LogBuffer().entries.where(
        (entry) => entry.level == 'ERROR',
      );
      expect(errors, hasLength(2));
      expect(errors.any((entry) => entry.message.contains('bad.flac')), isTrue);
      expect(errors.any((entry) => entry.message.contains('offline/')), isTrue);
      expect(errors.first.error, contains('Network tags unavailable'));
    },
  );

  test(
    'root connection failure never produces an empty successful scan',
    () async {
      await expectLater(
        scanner(_Storage({}, failedFolder: ''), (_) async => {}).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        ),
        throwsA(isA<SocketException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'cancellation removes incomplete output and stops further tag reads',
    () async {
      var cancelled = false;
      var reads = 0;
      await expectLater(
        scanner(
          _Storage({
            '': [
              const NetworkEntry('one.flac', 'one.flac'),
              const NetworkEntry('two.flac', 'two.flac'),
            ],
          }),
          (_) async {
            reads++;
            cancelled = true;
            return {'title': 'One'};
          },
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {
            if (cancelled) throw StateError('cancelled');
          },
          onProgress: (_, _, _) {},
        ),
        throwsStateError,
      );
      expect(reads, 1);
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
    },
  );

  test('a virtual host lists its songs without a connection', () async {
    final progress = <String>[];
    final storage = _VirtualStorage([
      (
        path: 'a.flac',
        tags: const {
          'title': 'First',
          'artist': 'Artist',
          'duration': 200,
          'format': 'flac',
        },
        coverPath: '/covers/a.jpg',
        size: 1000,
        modifiedTime: 1700000000000,
      ),
      (
        path: 'b.mp3',
        tags: const {'title': 'Second'},
        coverPath: null,
        size: null,
        modifiedTime: null,
      ),
    ]);
    final scan =
        await scanner(
          storage,
          (_) async => throw StateError('unexpected read'),
        ).scan(
          NetworkStorageService.source('virtual', ''),
          checkpoint: () async {},
          onProgress: (_, _, name) => progress.add(name),
        );
    expect(scan.expectedCount, 2);
    expect(scan.preserveMissingPaths, isEmpty);
    final rows = await scan.rows().toList();
    final source = NetworkStorageService.source('virtual', 'a.flac');
    expect(rows.first['filePath'], source);
    expect(rows.first['id'], 'network_${sha256.convert(utf8.encode(source))}');
    expect(rows.first['coverPath'], '/covers/a.jpg');
    expect(rows.first['trackName'], 'First');
    expect(rows.first['duration'], 200);
    expect(rows.first['format'], 'flac');
    expect(rows.first['fileModTime'], 1700000000000);
    expect(rows.last['filePath'], 'network://virtual/b.mp3');
    expect(rows.last['artistName'], 'Unknown Artist');
    expect(rows.last.containsKey('coverPath'), isFalse);
    expect(progress, ['First', 'Second']);

    await expectLater(
      scanner(storage, (_) async => {}).scan(
        NetworkStorageService.source('virtual', 'folder/'),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      ),
      throwsFormatException,
    );
    // Hosts it does not own still need a saved connection.
    await expectLater(
      scanner(storage, (_) async => {}).scan(
        NetworkStorageService.source('nas', ''),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      ),
      throwsStateError,
    );
  });

  test(
    'local file checks never delete or classify NAS files as missing',
    () async {
      final path = NetworkStorageService.source('offline', 'Song.flac');
      expect(await fileExists(path), true);
      expect(await fileStat(path), isNotNull);
      expect((await fileExistenceByPath([path]))[path], isNull);
      expect(await deleteFile(path), false);
    },
  );
}
