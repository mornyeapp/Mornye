import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/library_database.dart';

typedef LibraryBrowseRequest = ({
  bool artists,
  String? artist,
  String search,
  String sort,
  int limit,
  String? completeness,
});

class LibraryBrowseEntry {
  final String source;
  final String key;
  final String name;
  final String artist;
  final String? cover;
  final String samplePath;
  final int trackCount;
  final AlbumCompleteness? completeness;

  const LibraryBrowseEntry({
    required this.source,
    required this.key,
    required this.name,
    required this.artist,
    this.cover,
    required this.samplePath,
    required this.trackCount,
    this.completeness,
  });

  factory LibraryBrowseEntry.fromRow(
    Map<String, dynamic> row, {
    required bool isArtist,
  }) {
    final artist = row['artist_name'] as String? ?? '';
    final localCover = row['cover_path'] as String?;
    return LibraryBrowseEntry(
      source: row['queue_source'] as String? ?? '',
      key: (row[isArtist ? 'artist_key' : 'album_key'] as String?) ?? '',
      name: isArtist ? artist : row['album_name'] as String? ?? '',
      artist: artist,
      cover: localCover?.isNotEmpty == true
          ? localCover
          : row['cover_url'] as String?,
      samplePath: row['sample_file_path'] as String? ?? '',
      trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
      completeness: AlbumCompleteness.fromRow(row),
    );
  }
}

typedef LibraryBrowsePageRequest = ({
  LibraryBrowseRequest browse,
  int offset,
  QueueLibraryDbCursor? cursor,
  bool includeLocal,
});

class LibraryBrowsePage {
  final List<LibraryBrowseEntry> entries;
  final QueueLibraryDbCursor? nextCursor;

  const LibraryBrowsePage(this.entries, {this.nextCursor});

  factory LibraryBrowsePage.fromRows(
    List<Map<String, dynamic>> rows, {
    required bool artists,
    QueueLibraryDbCursor? nextCursor,
  }) => LibraryBrowsePage(
    rows
        .map((row) => LibraryBrowseEntry.fromRow(row, isArtist: artists))
        .toList(growable: false),
    nextCursor: nextCursor,
  );
}

class LibraryBrowseState {
  final List<LibraryBrowseEntry> entries;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;

  const LibraryBrowseState(
    this.entries, {
    required this.hasMore,
    this.isLoadingMore = false,
    this.loadMoreError,
  });
}

QueueLibraryDbQuery libraryBrowseQuery(LibraryBrowsePageRequest request) =>
    QueueLibraryDbQuery(
      limit: request.browse.limit,
      offset: request.offset,
      cursor: request.cursor,
      includeSingleTrackAlbums: true,
      albumArtist: request.browse.artist,
      searchQuery: request.browse.search,
      sortMode: request.browse.sort,
      includeLocal: request.includeLocal,
      metadata: request.browse.completeness,
    );

/// One bounded read; callers retain earlier pages instead of querying a prefix.
final libraryBrowsePageLoaderProvider =
    Provider<Future<LibraryBrowsePage> Function(LibraryBrowsePageRequest)>(
      (ref) => (request) async {
        final query = libraryBrowseQuery(request);
        if (request.browse.artists) {
          return LibraryBrowsePage.fromRows(
            await LibraryDatabase.instance.getQueueArtistPage(query),
            artists: true,
          );
        }
        final page = await LibraryDatabase.instance.getQueueAlbumPageResult(
          query,
        );
        return LibraryBrowsePage.fromRows(
          page.rows,
          artists: false,
          nextCursor: page.nextCursor,
        );
      },
    );

final libraryBrowseProvider = AsyncNotifierProvider.autoDispose
    .family<LibraryBrowseNotifier, LibraryBrowseState, LibraryBrowseRequest>(
      LibraryBrowseNotifier.new,
    );

class LibraryBrowseNotifier extends AsyncNotifier<LibraryBrowseState> {
  LibraryBrowseNotifier(this.request);

  static const _refreshPageLimit = 200;

  final LibraryBrowseRequest request;
  List<LibraryBrowseEntry> _rows = const [];
  QueueLibraryDbCursor? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _includeLocal = true;
  int _generation = 0;

  LibraryBrowsePageRequest _pageRequest(
    int offset,
    QueueLibraryDbCursor? cursor, {
    int? limit,
  }) => (
    browse: limit == null || limit == request.limit
        ? request
        : (
            artists: request.artists,
            artist: request.artist,
            search: request.search,
            sort: request.sort,
            limit: limit,
            completeness: request.completeness,
          ),
    offset: offset,
    cursor: request.artists ? null : cursor,
    includeLocal: _includeLocal,
  );

  @override
  Future<LibraryBrowseState> build() async {
    assert(request.limit > 0);
    _includeLocal = ref.watch(
      settingsProvider.select((s) => s.localLibraryEnabled),
    );
    ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
    if (_includeLocal) {
      ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
    }
    final loadPage = ref.watch(libraryBrowsePageLoaderProvider);
    final generation = ++_generation;
    _loadingMore = false;
    // Refresh the loaded range in bounded reads. Keep the old range visible
    // until its replacement is ready, preserving the user's scroll position.
    final target = math.max(request.limit, _rows.length);
    // Replaying tiny scroll pages repeatedly recomputes album grouping after
    // an index revision. Larger refresh pages still cap each SQL transfer.
    final refreshLimit = _rows.length >= _refreshPageLimit
        ? math.max(1, _refreshPageLimit ~/ request.limit) * request.limit
        : request.limit;
    final rows = <LibraryBrowseEntry>[];
    QueueLibraryDbCursor? cursor;
    late LibraryBrowsePage page;
    late int pageLimit;
    do {
      pageLimit = math.min(
        refreshLimit,
        ((target - rows.length + request.limit - 1) ~/ request.limit) *
            request.limit,
      );
      page = await loadPage(
        _pageRequest(rows.length, cursor, limit: pageLimit),
      );
      if (!ref.mounted || generation != _generation) {
        return LibraryBrowseState(rows, hasMore: false);
      }
      rows.addAll(page.entries);
      cursor = page.nextCursor;
    } while (page.entries.length == pageLimit && rows.length < target);
    _rows = List.unmodifiable(rows);
    _cursor = cursor;
    _hasMore = page.entries.length == pageLimit;
    return LibraryBrowseState(_rows, hasMore: _hasMore);
  }

  Future<void> loadMore() async {
    final current = state;
    if (current.isLoading || current.hasError || _loadingMore || !_hasMore) {
      return;
    }
    final generation = _generation;
    _loadingMore = true;
    state = AsyncData(
      LibraryBrowseState(_rows, hasMore: _hasMore, isLoadingMore: true),
    );
    try {
      final page = await ref.read(libraryBrowsePageLoaderProvider)(
        _pageRequest(_rows.length, _cursor),
      );
      if (!ref.mounted || generation != _generation) return;
      _rows = List.unmodifiable([..._rows, ...page.entries]);
      _cursor = page.nextCursor;
      _hasMore = page.entries.length == request.limit;
      state = AsyncData(LibraryBrowseState(_rows, hasMore: _hasMore));
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = AsyncData(
        LibraryBrowseState(_rows, hasMore: _hasMore, loadMoreError: error),
      );
    } finally {
      if (ref.mounted && generation == _generation) _loadingMore = false;
    }
  }
}
