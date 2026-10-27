import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/cue_split_library_service.dart';
import 'package:mornye/services/library_ingestion_store.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/utils/file_access.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SqliteProcessDatabase db;
  late File cue;
  late File audio;
  late List<String> outputs;
  late List<CueSplitTrackInfo> tracks;
  late List<Map<String, dynamic>> originals;
  late Map<String, Map<String, dynamic>> metadata;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cue-split-library-');
    db = await SqliteProcessDatabase.open(
      path: '${directory.path}/local_library.db',
    );
    await createNativeLibraryFixture(db);
    cue = await File(
      '${directory.path}/Album.cue',
    ).writeAsString('Original CUE');
    audio = await File('${directory.path}/Album.flac').writeAsBytes([1, 2, 3]);
    outputs = [];
    tracks = [];
    metadata = {};
    originals = [nativeLibraryTrack('whole', path: audio.path)];
    for (var i = 1; i <= 2; i++) {
      final path = (await File(
        '${directory.path}/0$i - Song $i.flac',
      ).writeAsBytes([i])).path;
      outputs.add(path);
      tracks.add(
        CueSplitTrackInfo(
          number: i,
          title: 'Song $i',
          artist: 'Artist',
          startSec: (i - 1) * 60,
          endSec: i * 60,
        ),
      );
      originals.add({
        ...nativeLibraryTrack('cue$i', path: '${cue.path}#track0$i'),
        'format': 'cue+flac',
      });
      metadata[path] = {
        ...nativeLibraryTrack('output$i', path: path),
        'format': 'flac',
      };
    }
    for (final row in originals) {
      await addNativeLibraryTrack(db, row);
    }
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  CueSplitLibraryService service() => CueSplitLibraryService(
    database: () async => db,
    readMetadata: (path) async => metadata[path],
  );

  Future<void> publish({List<String>? paths}) => service().publish(
    cuePath: cue.path,
    audioPath: audio.path,
    tracks: tracks,
    outputPaths: paths ?? outputs,
    sourceId: 'source',
  );

  Future<List<String>> visible() async => [
    for (final row in await db.query(LibrarySchema.visibleView, orderBy: 'id'))
      row['id'] as String,
  ];

  test(
    'complete split hides original entries and preserves source files',
    () async {
      await publish();
      expect(await visible(), ['output1', 'output2']);
      expect(await db.query('library'), hasLength(5));
      expect(await cue.readAsString(), 'Original CUE');
      expect(await audio.readAsBytes(), [1, 2, 3]);
      expect(
        (await db.query('library_path_keys')).map((row) => row['item_id']),
        containsAll(['output1', 'output2']),
      );
      final store = LibraryQueueStore(db, historyFts: false, localFts: false);
      const query = QueueLibraryDbQuery(source: 'local');
      final counts = await store.counts(query);
      expect(counts.allTrackCount, 2);
      expect(counts.albumCount, 1);
      final albums = await store.albumPage(query);
      expect(albums.rows.single['track_count'], 2);

      await db.close();
      db = await SqliteProcessDatabase.open(
        path: '${directory.path}/local_library.db',
      );
      expect(await visible(), ['output1', 'output2']);
    },
  );

  test(
    'a full rescan retains the rule and missing outputs restore CUE entries',
    () async {
      await publish();
      final ingestion = LibraryIngestionStore(
        openDatabase: () async => db,
        ensureHistoryAttached: (_) async {},
      );
      await ingestion.replaceSourceStream(
        'source',
        Stream.fromIterable([...originals, ...metadata.values]),
      );
      expect(await visible(), ['output1', 'output2']);
      await db.delete('library', where: 'id = ?', whereArgs: ['output2']);
      expect(await visible(), ['cue1', 'cue2', 'output1', 'whole']);
    },
  );

  test('incomplete, missing and unreadable outputs never hide CUE', () async {
    await expectLater(
      publish(paths: outputs.take(1).toList()),
      throwsStateError,
    );
    metadata[outputs.last] = {'metadataFromFilename': true};
    await expectLater(publish(), throwsStateError);
    expect(await visible(), ['cue1', 'cue2', 'whole']);
    expect(await db.query('library_cue_split_sources'), isEmpty);
    await File(outputs.last).delete();
    await expectLater(publish(), throwsStateError);
    expect(await db.query('library'), hasLength(3));
  });

  test(
    'SAF output identities remain document URIs with unknown sizes',
    () async {
      final uris = [
        for (var i = 1; i <= 2; i++) 'content://music/document/track%20$i.flac',
      ];
      final saf = CueSplitLibraryService(
        database: () async => db,
        stat: (_) async => const FileAccessStat(),
        readMetadata: (path) async => {
          ...metadata[outputs[uris.indexOf(path)]]!,
          'id': 'reused-descriptor-id',
          'filePath': '/temporary/copy.flac',
        },
      );
      await saf.publish(
        cuePath: cue.path,
        audioPath: audio.path,
        tracks: tracks,
        outputPaths: uris,
      );
      final rows = await db.query(
        'library',
        where: 'file_path IN (?, ?)',
        whereArgs: uris,
        orderBy: 'file_path',
      );
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['id']).toSet(), hasLength(2));
      expect(await visible(), unorderedEquals(rows.map((row) => row['id'])));
      expect(rows.map((row) => row['file_path']), uris);
    },
  );

  test(
    'unavailable output source restores originals without deleting split files',
    () async {
      await service().publish(
        cuePath: cue.path,
        audioPath: audio.path,
        tracks: tracks,
        outputPaths: outputs,
        sourceId: 'other',
      );
      expect(await visible(), ['output1', 'output2']);
      await db.update(
        'library_sources',
        {'available': 0},
        where: 'id = ?',
        whereArgs: ['other'],
      );
      expect(await visible(), ['cue1', 'cue2', 'whole']);
      expect(await File(outputs.first).exists(), isTrue);
    },
  );

  test(
    'an insertion failure rolls back outputs and visibility together',
    () async {
      metadata[outputs.last]!.remove('trackName');
      await expectLater(publish(), throwsStateError);
      expect(await visible(), ['cue1', 'cue2', 'whole']);
      expect(await db.query('library'), hasLength(3));
      expect(await db.query('library_cue_split_outputs'), isEmpty);
    },
  );

  test(
    'v18 upgrade installs visibility tables and retains indexed tracks',
    () async {
      await db.execute('DROP VIEW ${LibrarySchema.visibleView}');
      await db.execute('DROP TABLE library_cue_split_sources');
      await db.execute('DROP TABLE library_cue_split_outputs');
      await db.execute(
        'CREATE VIEW ${LibrarySchema.visibleView} AS SELECT * FROM library',
      );
      await LibrarySchema.upgrade(db, 18, LibrarySchema.version);
      expect(await visible(), ['cue1', 'cue2', 'whole']);
      await publish();
      expect(await visible(), ['output1', 'output2']);
    },
  );
}
