import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/re_enrich_undo.dart';
import 'package:mornye/services/re_enrich_undo_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String songPath;
  late List<MetadataSaveRequest> saves;
  late Map<String, dynamic> fileTags;
  late List<int>? embeddedCover;
  List<int>? writtenCover;
  MetadataSaveResult saveResult = const MetadataSaveResult.saved();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reenrich_undo_');
    songPath = p.join(root.path, 'music', 'song.flac');
    await Directory(p.dirname(songPath)).create(recursive: true);
    await File(songPath).writeAsBytes([0]);
    saves = [];
    saveResult = const MetadataSaveResult.saved();
    embeddedCover = [0xFF, 0xD8, 0xFF, 7, 7, 7];
    fileTags = {
      'title': 'Song',
      'artist': 'Artist',
      'album': 'Album',
      'date': '2012',
      'track_number': 3,
      'total_tracks': 10,
      'genre': '',
      'lyrics': '[00:01.00]Old line',
    };
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  ReEnrichUndo undo() => ReEnrichUndo(
    store: ReEnrichUndoStore(
      directory: () async => Directory(p.join(root.path, 'support')),
    ),
    readTags: (path) async => fileTags,
    extractCover: (audio, output) async {
      final bytes = embeddedCover;
      if (bytes == null) return false;
      await File(output).writeAsBytes(bytes);
      return true;
    },
    save: (request) async {
      saves.add(request);
      final cover = request.selectedCoverPath;
      writtenCover = cover == null ? null : await File(cover).readAsBytes();
      return saveResult;
    },
  );

  LocalLibraryItem song() => LocalLibraryItem(
    id: 'song',
    trackName: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: songPath,
    scannedAt: DateTime(2026),
    trackNumber: 3,
    totalTracks: 10,
    releaseDate: '2012',
    hasLyrics: true,
  );

  BatchReEnrichPreview preview({Set<String>? fields}) {
    final metadata = <String, dynamic>{
      'album_name': 'Greatest Hits',
      'release_date': '2020',
      'track_number': 7,
      'genre': 'Pop',
      'cover_url': 'https://example.invalid/cover.jpg',
    };
    final full = BatchReEnrichPreview(
      item: song(),
      updateFields: ReEnrichFields.all,
      enrichedMetadata: metadata,
      changes: buildReEnrichMetadataChanges(
        song(),
        metadata,
        ReEnrichFields.all,
      ),
    );
    return fields == null ? full : full.selecting(fields);
  }

  test('only what the write replaces is saved and written back', () async {
    final subject = undo();
    final draft = await subject.capture(
      preview(fields: {'album_name', 'track_number', 'cover_url'}),
      songPath,
      const AppSettings(),
    );
    expect(draft, isNotNull);
    expect(draft!.tags, {
      'album': 'Album',
      'track_number': '3',
      'track_total': '10',
    });
    expect(
      await subject.commit(draft, songPath, const {
        'method': 'native',
        'lyrics_status': 'not_requested',
      }),
      isTrue,
    );
    await draft.discard();

    final restored = await subject.restore(songPath, artistTagMode: 'joined');
    expect(restored.outcome, ReEnrichUndoOutcome.restored);
    final request = saves.single;
    expect(request.filePath, songPath);
    expect(request.preserveUnspecifiedTags, isTrue);
    expect(request.metadata, {
      'album': 'Album',
      'track_number': '3',
      'track_total': '10',
    });
    expect(writtenCover, embeddedCover);
    expect(await subject.canUndo(songPath), isFalse);
    expect(
      Directory(
        p.join(root.path, 'support', 'reenrich_undo', 'covers'),
      ).listSync(),
      isEmpty,
      reason: 'a restored state leaves no cover behind',
    );
  });

  test(
    'a filled tag goes back empty and lyrics only when they changed',
    () async {
      final subject = undo();
      final draft = await subject.capture(
        preview(fields: {'genre', 'lyrics'}),
        songPath,
        const AppSettings(embedLyrics: true, lyricsMode: 'embed'),
      );
      expect(draft!.lyrics, '[00:01.00]Old line');
      expect(draft.lrc, isNull, reason: 'embedded lyrics leave the sidecar');
      await subject.commit(draft, songPath, const {
        'method': 'native',
        'lyrics_status': 'preserved',
      });
      expect((await subject.store.read(songPath))!.tags, {'genre': ''});

      await subject.commit(draft, songPath, const {
        'method': 'native',
        'lyrics_status': 'updated',
      });
      expect((await subject.store.read(songPath))!.tags, {
        'genre': '',
        'lyrics': '[00:01.00]Old line',
      });
    },
  );

  test('a song without a sidecar loses the one re-enrich wrote', () async {
    final subject = undo();
    final lrc = File(p.join(p.dirname(songPath), 'song.lrc'));
    final draft = await subject.capture(
      preview(fields: {'lyrics'}),
      songPath,
      const AppSettings(embedLyrics: true, lyricsMode: 'external'),
    );
    expect(draft!.lrc, '');
    expect(draft.lyrics, isNull, reason: 'external lyrics leave the tags');
    await lrc.writeAsString('[00:01.00]New line');
    await subject.commit(draft, songPath, const {
      'method': 'native',
      'lyrics_status': 'updated',
      'write_external_lrc': true,
    });

    final result = await subject.restore(songPath, artistTagMode: 'joined');
    expect(result.restored, isTrue);
    expect(saves, isEmpty, reason: 'no tag changed');
    expect(await lrc.exists(), isFalse);
  });

  test('a previous sidecar is written back', () async {
    final subject = undo();
    final lrc = File(p.join(p.dirname(songPath), 'song.lrc'));
    await lrc.writeAsString('[00:01.00]Old line');
    final draft = await subject.capture(
      preview(fields: {'lyrics'}),
      songPath,
      const AppSettings(embedLyrics: true, lyricsMode: 'both'),
    );
    await lrc.writeAsString('[00:01.00]New line');
    await subject.commit(draft!, songPath, const {
      'method': 'native',
      'lyrics_status': 'updated',
      'write_external_lrc': true,
    });
    await subject.restore(songPath, artistTagMode: 'joined');
    expect(await lrc.readAsString(), '[00:01.00]Old line');
    expect(saves.single.metadata, {'lyrics': '[00:01.00]Old line'});
  });

  test('a first cover cannot be taken out again', () async {
    embeddedCover = null;
    final subject = undo();
    final draft = await subject.capture(
      preview(fields: {'cover_url'}),
      songPath,
      const AppSettings(),
    );
    await subject.commit(draft!, songPath, const {'method': 'native'});
    final result = await subject.restore(songPath, artistTagMode: 'joined');
    expect(result.outcome, ReEnrichUndoOutcome.coverKept);
    expect(saves, isEmpty);
  });

  test(
    'a failed restore keeps the state; another run does not take it',
    () async {
      final subject = undo();
      final draft = await subject.capture(
        preview(fields: {'album_name'}),
        songPath,
        const AppSettings(),
      );
      await subject.commit(draft!, songPath, const {
        'method': 'native',
      }, batch: 'run-1');

      expect(
        (await subject.restore(
          songPath,
          artistTagMode: 'joined',
          batch: 'run-2',
        )).outcome,
        ReEnrichUndoOutcome.missing,
      );
      expect(saves, isEmpty);

      saveResult = const MetadataSaveResult.failed(
        MetadataSaveFailure.backend,
        'disk full',
      );
      final failed = await subject.restore(
        songPath,
        artistTagMode: 'joined',
        batch: 'run-1',
      );
      expect(failed.outcome, ReEnrichUndoOutcome.failed);
      expect(await subject.canUndo(songPath, batch: 'run-1'), isTrue);
    },
  );

  group('runner', () {
    test('writes only the chosen fields and saves the state first', () async {
      final requests = <Map<String, dynamic>>[];
      final subject = undo();
      final runner = BatchReEnrichRunner(
        beginPhase: () async => const AppSettings(),
        undo: subject,
        reEnrich: (request) async {
          requests.add(request);
          fileTags = {...fileTags, 'album': 'Greatest Hits'};
          return {'method': 'native', 'lyrics_status': 'not_requested'};
        },
        writeSidecar:
            ({required audioFilePath, required reEnrichResult}) async {},
      );
      final written = await runner.apply(
        [
          preview(fields: {'album_name'}),
        ],
        shouldStop: () => false,
        onProgress: (_, _) {},
      );
      expect(written, 1);
      final request = requests.single;
      expect(request['update_fields'], ['album_name']);
      expect(request['album_name'], 'Greatest Hits');
      expect(request['release_date'], '2012', reason: 'not chosen');
      expect(request['search_online'], isFalse);
      expect(runner.undoSources, [songPath]);
      expect((await subject.store.read(songPath))!.tags, {'album': 'Album'});
      expect((await subject.store.read(songPath))!.batch, runner.undoBatch);
    });

    test('nothing for the file means no write', () async {
      var writes = 0;
      final motion = <String>[];
      final runner = BatchReEnrichRunner(
        beginPhase: () async => const AppSettings(),
        undo: undo(),
        reEnrich: (request) async {
          writes++;
          return {'method': 'native'};
        },
        saveMotionArtwork: (item, metadata) async =>
            motion.add(metadata['header_video'].toString()),
      );
      final full = BatchReEnrichPreview(
        item: song(),
        updateFields: const [ReEnrichFields.cover],
        enrichedMetadata: const {
          'header_video': 'https://example.invalid/motion.m3u8',
        },
        changes: buildReEnrichMetadataChanges(
          song(),
          const {'header_video': 'https://example.invalid/motion.m3u8'},
          const [ReEnrichFields.cover],
        ),
      );
      expect(
        await runner.apply(
          [
            full.selecting({'header_video'}),
          ],
          shouldStop: () => false,
          onProgress: (_, _) {},
        ),
        1,
      );
      expect(writes, 0);
      expect(motion, ['https://example.invalid/motion.m3u8']);
      expect(runner.undoSources, isEmpty);
    });

    test('a failed write saves no state and reports the error', () async {
      final subject = undo();
      Object? failure;
      final runner = BatchReEnrichRunner(
        beginPhase: () async => const AppSettings(),
        undo: subject,
        reEnrich: (request) async => {'method': 'error', 'error': 'locked'},
      );
      expect(
        await runner.apply(
          [
            preview(fields: {'album_name'}),
          ],
          shouldStop: () => false,
          onProgress: (_, _) {},
          onFailed: (_, error) => failure = error,
        ),
        0,
      );
      expect(failure, 'locked');
      expect(await subject.canUndo(songPath), isFalse);
      expect(runner.undoSources, isEmpty);
    });
  });
}
