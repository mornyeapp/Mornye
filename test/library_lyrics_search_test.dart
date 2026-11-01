import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_lyrics_search.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final fts in [false, true]) {
    group('Library lyrics search (FTS: $fts)', () {
      late SqliteProcessDatabase db;
      late LibraryLyricsSearchStore store;
      late Map<String, String> lyrics;
      late List<String> reads;

      setUp(() async {
        db = await SqliteProcessDatabase.open();
        await createNativeLibraryFixture(db);
        await db.execute('''CREATE TABLE history_db.history (
          id TEXT PRIMARY KEY, file_path TEXT, track_name TEXT,
          artist_name TEXT, cover_url TEXT, downloaded_at TEXT, has_lyrics INTEGER
        )''');
        await db.insert('history_db.history', {
          'id': 'download',
          'file_path': '/music/download.flac',
          'track_name': 'Unrelated title',
          'artist_name': 'Artist',
          'downloaded_at': '2026-11-01',
          'has_lyrics': 1,
        });
        await addNativeLibraryDownload(db, '/music/download.flac');
        await db.update('history_db.history_path_keys', {
          'item_id': 'download',
        });
        await addNativeLibraryTrack(db, nativeLibraryTrack('local'));
        await addNativeLibraryTrack(
          db,
          nativeLibraryTrack('duplicate', path: '/music/download.flac'),
        );
        await addNativeLibraryTrack(
          db,
          nativeLibraryTrack('hidden'),
          source: 'other',
        );
        await db.update('library_sources', {
          'enabled': 0,
        }, where: "id = 'other'");
        lyrics = {
          '/music/download.flac':
              '[ar:Secret header]\n[00:01.20]Dancing in the moonlight\n[00:04.00]With you',
          '/music/local.flac':
              '[00:02.00]v1: 夜空の下\n[00:03.00]Dancing <00:03.20>in the rain',
        };
        reads = [];
        store = LibraryLyricsSearchStore(
          db,
          useFts: fts,
          readLyrics: (path) async {
            reads.add(path);
            return lyrics[path]!;
          },
        );
      });
      tearDown(() => db.close());

      Future<LibraryLyricsIndexProgress> index({bool local = true}) =>
          store.index(includeLocal: local, cancelled: () => false).last;

      Future<List<String>> search(
        String query, {
        bool local = true,
        int limit = 40,
        int offset = 0,
      }) async => [
        for (final hit in await store.search(
          query: query,
          includeLocal: local,
          limit: limit,
          offset: offset,
        ))
          hit.id,
      ];

      test(
        'searches saved lyrics, strips LRC tags, hides disabled and duplicate files',
        () async {
          final progress = await index();
          expect(progress.checked, 2);
          expect(progress.failed, 0);
          expect(progress.complete, isTrue);
          expect(reads, ['/music/download.flac', '/music/local.flac']);
          expect(await search('moonlight dancing'), ['download']);
          expect(await search('夜空'), ['local']);
          expect(await search('you'), ['download']);
          expect(await search('secret header'), isEmpty);
          expect(await search('00 01'), isEmpty);
          expect(await search('Unrelated title'), isEmpty);
          expect(await search('dancing', local: false), ['download']);
          expect(await search('dancing', limit: 1), ['local']);
          expect(await search('dancing', limit: 1, offset: 1), ['download']);
          expect(await search('% OR "'), isEmpty);
        },
      );

      test(
        'reopening the cache and changing queries never rereads audio',
        () async {
          await index();
          store = LibraryLyricsSearchStore(
            db,
            useFts: fts,
            readLyrics: (_) async {
              fail('Cached audio must not be read');
            },
          );
          expect((await index()).checked, 0);
          expect(await search('rain'), ['local']);
          expect(await search('moonlight'), ['download']);
        },
      );

      test(
        'changed files and explicit refresh replace old terms in FTS and fallback',
        () async {
          await index();
          lyrics['/music/local.flac'] = 'Brand new words';
          await db.update('library', {
            'file_mod_time': 1770000000001,
          }, where: "id = 'local'");
          expect(await search('rain'), isEmpty);
          reads.clear();
          expect((await index()).checked, 1);
          expect(reads, ['/music/local.flac']);
          expect(await search('brand new'), ['local']);
          expect(await search('rain'), isEmpty);
          lyrics['/music/local.flac'] = '';
          await store.invalidate('/music/local.flac');
          await index();
          expect(await search('brand'), isEmpty);
          await store.clear();
          expect(await search('moonlight'), isEmpty);
          expect((await index()).checked, 2);
        },
      );

      test(
        'failed reads are retried and are not saved as empty lyrics',
        () async {
          lyrics.remove('/music/local.flac');
          expect((await index()).failed, 1);
          expect(await search('moonlight'), ['download']);
          lyrics['/music/local.flac'] = 'Recovered words';
          final retry = await index();
          expect(retry.checked, 1);
          expect(retry.failed, 0);
          expect(await search('recovered'), ['local']);
        },
      );

      test(
        'cancellation stops after one read and invalidation rejects stale work',
        () async {
          final started = Completer<void>();
          final release = Completer<String>();
          var cancelled = false;
          store = LibraryLyricsSearchStore(
            db,
            useFts: fts,
            readLyrics: (_) {
              started.complete();
              return release.future;
            },
          );
          final pending = store
              .index(includeLocal: true, cancelled: () => cancelled)
              .toList();
          await started.future;
          cancelled = true;
          await store.invalidate('/music/download.flac');
          release.complete('Obsolete lyrics');
          final events = await pending;
          expect(events.last.complete, isFalse);
          expect(await search('obsolete'), isEmpty);
        },
      );

      test('deleted files disappear from cached search results', () async {
        await index();
        await db.delete('history_db.history', where: "id = 'download'");
        expect(await search('moonlight'), isEmpty);
        await db.delete('library', where: "id = 'local'");
        expect(await search('rain'), isEmpty);
      });

      test(
        'edits invalidate persistent lyrics before a search session opens',
        () async {
          await index();
          await LibraryLyricsSearchStore.invalidateStored(
            db,
            'file:///music/download.flac',
          );
          expect(await search('moonlight'), isEmpty);
          lyrics['/music/download.flac'] = 'Replacement chorus';
          store = LibraryLyricsSearchStore(
            db,
            useFts: fts,
            readLyrics: (path) async => lyrics[path]!,
          );
          expect((await index()).checked, 1);
          expect(await search('replacement'), ['download']);
        },
      );

      test(
        'large libraries index in bounded pages and publish partial progress',
        () async {
          for (var i = 0; i < 40; i++) {
            final id = 'extra-$i';
            await addNativeLibraryTrack(db, nativeLibraryTrack(id));
            lyrics['/music/$id.flac'] = 'Shared chorus $i';
          }
          final events = await store
              .index(includeLocal: true, cancelled: () => false)
              .toList();
          expect(events.last.checked, 42);
          expect(events.last.complete, isTrue);
          expect(
            events.where((event) => !event.complete && event.checked > 0),
            isNotEmpty,
          );
          expect(reads.toSet().length, 42);
          expect((await search('shared', limit: 100)).length, 40);
        },
      );
    });
  }
}
