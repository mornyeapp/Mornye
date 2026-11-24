import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_lyrics_search.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/source_metadata_events.dart';

final FutureProvider<LibraryLyricsSearchStore>
libraryLyricsSearchStoreProvider = FutureProvider<LibraryLyricsSearchStore>((
  ref,
) async {
  final store = LibraryLyricsSearchStore(
    await LibraryDatabase.instance.openLyricsSearchDatabase(),
    readLyrics: (path) async {
      final metadata = await readPlaybackFileMetadataWithRetry(
        path,
        retryDelays: const [Duration.zero],
      );
      return metadata['lyrics']?.toString() ?? '';
    },
  );
  await store.open();
  if (ref.mounted) {
    ref.onDispose(
      SourceMetadataEvents.instance.subscribe((path) async {
        await store.invalidate(path);
        if (ref.mounted) ref.invalidate(libraryLyricsIndexProvider);
      }),
    );
  }
  return store;
});

/// Query changes reuse this pass. Removing the Lyrics filter cancels it after
/// the current native read, so typing never starts concurrent Library scans.
final libraryLyricsIndexProvider =
    StreamProvider.autoDispose<LibraryLyricsIndexProgress>((ref) async* {
      var cancelled = false;
      ref.onDispose(() => cancelled = true);
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      if (includeLocal) {
        ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      }
      final store = await ref.watch(libraryLyricsSearchStoreProvider.future);
      if (cancelled) return;
      yield* store.index(
        includeLocal: includeLocal,
        cancelled: () => cancelled,
      );
    });

final libraryLyricsSearchProvider = AsyncNotifierProvider.autoDispose
    .family<
      LibraryLyricsSearchNotifier,
      List<LibrarySearchHit>,
      LibrarySearchRequest
    >(LibraryLyricsSearchNotifier.new);

/// Searches again when an indexing pass starts or ends, and in between only
/// when the index publishes a new revision. Those refreshes keep the current
/// hits on screen and replace them only when the result changed.
class LibraryLyricsSearchNotifier
    extends AsyncNotifier<List<LibrarySearchHit>> {
  LibraryLyricsSearchNotifier(this.request);

  final LibrarySearchRequest request;
  bool _includeLocal = true;
  int _generation = 0;

  @override
  Future<List<LibrarySearchHit>> build() async {
    _generation++;
    if (LibrarySearchQuery(request.query).terms.isEmpty) return [];
    _includeLocal = ref.watch(
      settingsProvider.select((s) => s.localLibraryEnabled),
    );
    final error = ref.watch(
      libraryLyricsIndexProvider.select(
        (progress) =>
            progress.hasError ? (progress.error!, progress.stackTrace!) : null,
      ),
    );
    if (error case (final error, final stackTrace)) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    ref.watch(
      libraryLyricsIndexProvider.select(
        (progress) => progress.value?.complete ?? false,
      ),
    );
    ref.listen(
      libraryLyricsIndexProvider.select((progress) => progress.value?.revision),
      (_, _) => _refresh(),
    );
    return _search(await ref.watch(libraryLyricsSearchStoreProvider.future));
  }

  Future<List<LibrarySearchHit>> _search(LibraryLyricsSearchStore store) =>
      store.search(
        query: request.query,
        includeLocal: _includeLocal,
        limit: request.limit,
        offset: request.offset,
      );

  Future<void> _refresh() async {
    final refresh = ++_generation;
    try {
      final hits = await _search(
        await ref.read(libraryLyricsSearchStoreProvider.future),
      );
      if (!ref.mounted || refresh != _generation) return;
      final current = state.value;
      if (current != null && _sameHits(current, hits)) return;
      state = AsyncData(hits);
    } catch (error, stackTrace) {
      if (ref.mounted && refresh == _generation) {
        state = AsyncError(error, stackTrace);
      }
    }
  }
}

bool _sameHits(List<LibrarySearchHit> a, List<LibrarySearchHit> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.kind != y.kind ||
        x.id != y.id ||
        x.title != y.title ||
        x.artist != y.artist ||
        x.source != y.source ||
        x.cover != y.cover ||
        x.samplePath != y.samplePath ||
        x.trackCount != y.trackCount) {
      return false;
    }
  }
  return true;
}
