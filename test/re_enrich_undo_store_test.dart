import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/re_enrich_undo_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reenrich_undo_store_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  ReEnrichUndoStore store({int maxSongs = 2000, int maxBytes = 1 << 30}) =>
      ReEnrichUndoStore(
        directory: () async => root,
        maxSongs: maxSongs,
        maxBytes: maxBytes,
      );

  ReEnrichUndoState state(String source, int minute, {String? batch}) =>
      ReEnrichUndoState(
        source: source,
        savedAt: DateTime(2026, 1, 1, 0, minute),
        tags: {'album': 'Album $source', 'genre': ''},
        batch: batch,
      );

  Future<String> coverFile(String name, List<int> bytes) async {
    final file = File(p.join(root.path, 'input', name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  List<String> storedCovers() {
    final covers = Directory(p.join(root.path, 'reenrich_undo', 'covers'));
    if (!covers.existsSync()) return const [];
    return [
      for (final entry in covers.listSync())
        if (entry is File) p.basename(entry.path),
    ];
  }

  test('a saved state survives a restart, one per song', () async {
    final first = store();
    await first.save(state('/music/a.flac', 1, batch: 'run-1'));
    await first.save(
      ReEnrichUndoState(
        source: '/music/a.flac',
        savedAt: DateTime(2026, 1, 1, 0, 2),
        tags: const {'title': 'Old title'},
        lrc: '',
        batch: 'run-2',
      ),
    );

    final reopened = store();
    final read = await reopened.read('EXISTS:/music/a.flac');
    expect(read, isNotNull);
    expect(read!.tags, {'title': 'Old title'});
    expect(read.lrc, '');
    expect(read.batch, 'run-2');
    expect(await reopened.contains('/music/b.flac'), isFalse);

    await reopened.remove('/music/a.flac');
    expect(await store().read('/music/a.flac'), isNull);
  });

  test('songs that share a cover store it once', () async {
    final undo = store();
    final bytes = [0xFF, 0xD8, 0xFF, 1, 2, 3, 4];
    await undo.save(
      state('/music/a.flac', 1),
      coverFile: await coverFile('a.jpg', bytes),
    );
    await undo.save(
      state('/music/b.flac', 2),
      coverFile: await coverFile('b.jpg', bytes),
    );
    expect(storedCovers(), hasLength(1));
    final a = await undo.read('/music/a.flac');
    expect(await File((await undo.coverPath(a!))!).readAsBytes(), bytes);

    await undo.remove('/music/a.flac');
    expect(storedCovers(), hasLength(1), reason: 'b still uses it');
    await undo.remove('/music/b.flac');
    expect(storedCovers(), isEmpty);
  });

  test('a new state for a song drops the cover nothing else uses', () async {
    final undo = store();
    await undo.save(
      state('/music/a.flac', 1),
      coverFile: await coverFile('a.jpg', [1, 2, 3]),
    );
    await undo.save(
      state('/music/a.flac', 2),
      coverFile: await coverFile('b.png', [0x89, 0x50, 0x4E, 0x47, 9]),
    );
    expect(storedCovers().single, endsWith('.png'));
  });

  test('the song count bound evicts the oldest states first', () async {
    final undo = store(maxSongs: 2);
    await undo.save(state('/music/b.flac', 2));
    await undo.save(state('/music/a.flac', 1));
    await undo.save(state('/music/c.flac', 3));
    expect(await undo.contains('/music/a.flac'), isFalse);
    expect(await undo.contains('/music/b.flac'), isTrue);
    expect(await undo.contains('/music/c.flac'), isTrue);

    // The newest state stays even when it was saved with an older time.
    await undo.save(state('/music/d.flac', 0));
    expect(await undo.contains('/music/d.flac'), isTrue);
    expect(await undo.contains('/music/b.flac'), isFalse);
  });

  test('the size bound evicts the oldest states and their covers', () async {
    final undo = store(maxBytes: 3000);
    await undo.save(
      state('/music/a.flac', 1),
      coverFile: await coverFile('a.jpg', List.filled(1500, 1)),
    );
    await undo.save(
      state('/music/b.flac', 2),
      coverFile: await coverFile('b.jpg', List.filled(1500, 2)),
    );
    expect(await undo.contains('/music/a.flac'), isFalse);
    expect(await undo.contains('/music/b.flac'), isTrue);
    expect(storedCovers(), hasLength(1));

    // A restart counts what is already stored.
    final reopened = store(maxBytes: 3000);
    await reopened.save(
      state('/music/c.flac', 3),
      coverFile: await coverFile('c.jpg', List.filled(1500, 3)),
    );
    expect(await reopened.contains('/music/b.flac'), isFalse);
    expect(await reopened.contains('/music/c.flac'), isTrue);
  });

  test('an unreadable state is ignored and cleaned up', () async {
    final songs = Directory(p.join(root.path, 'reenrich_undo', 'songs'));
    await songs.create(recursive: true);
    final broken = File(p.join(songs.path, 'broken.json'));
    await broken.writeAsString('{');
    final undo = store();
    await undo.save(state('/music/a.flac', 1));
    expect(await broken.exists(), isFalse);
    expect(await undo.contains('/music/a.flac'), isTrue);
  });
}
