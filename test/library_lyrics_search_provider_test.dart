import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/providers/library_lyrics_search_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_lyrics_search.dart';
import 'package:mornye/services/library_search.dart';

import 'support/fixed_settings.dart';

class _NoDatabase implements DatabaseExecutor {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingStore extends LibraryLyricsSearchStore {
  _CountingStore() : super(_NoDatabase(), readLyrics: (_) async => '');

  int searches = 0;
  List<String> ids = ['song-1'];

  @override
  Future<List<LibrarySearchHit>> search({
    required String query,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async {
    searches++;
    return [
      for (final id in ids)
        LibrarySearchHit(kind: LibrarySearchKind.songs, id: id, title: id),
    ];
  }
}

void main() {
  test(
    'indexing progress reruns searches only on a new revision or pass end',
    () async {
      final store = _CountingStore();
      final progress = StreamController<LibraryLyricsIndexProgress>();
      addTearDown(progress.close);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          libraryLyricsSearchStoreProvider.overrideWith((ref) => store),
          libraryLyricsIndexProvider.overrideWith((ref) => progress.stream),
        ],
      );
      addTearDown(container.dispose);
      const request = (
        query: 'chorus',
        kind: LibrarySearchKind.songs,
        limit: 41,
        offset: 0,
      );
      final states = <AsyncValue<List<LibrarySearchHit>>>[];
      container.listen(
        libraryLyricsSearchProvider(request),
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      Future<void> emit(LibraryLyricsIndexProgress event) async {
        progress.add(event);
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      List<String> ids() => [
        for (final hit in states.last.value ?? const <LibrarySearchHit>[])
          hit.id,
      ];

      await emit(const LibraryLyricsIndexProgress(revision: 1));
      final settled = states.length;
      final afterStart = store.searches;
      expect(ids(), ['song-1']);

      for (final checked in [8, 16, 24, 32, 40]) {
        await emit(LibraryLyricsIndexProgress(checked: checked, revision: 1));
      }
      expect(store.searches, afterStart);
      expect(states.length, settled);

      await emit(const LibraryLyricsIndexProgress(checked: 48, revision: 2));
      expect(store.searches, afterStart + 1);
      expect(states.length, settled, reason: 'the same hits stay in place');

      store.ids = ['song-1', 'song-2'];
      await emit(const LibraryLyricsIndexProgress(checked: 56, revision: 3));
      expect(store.searches, afterStart + 2);
      expect(states.length, settled + 1);
      expect(states.last.isLoading, isFalse);
      expect(ids(), ['song-1', 'song-2']);

      await emit(
        const LibraryLyricsIndexProgress(
          checked: 60,
          complete: true,
          revision: 4,
        ),
      );
      expect(store.searches, greaterThan(afterStart + 2));
      expect(ids(), ['song-1', 'song-2']);
      expect(states.last.isLoading, isFalse);
    },
  );
}
