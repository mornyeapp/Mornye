import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/library_database.dart';

/// The filters a Library count is taken under. Equal requests share one
/// count, so the Library badges, Home and the Home mixes read the unfiltered
/// Library once per change.
class LibraryCountsRequest {
  final String searchQuery;
  final String? filterSource;
  final String? filterQuality;
  final String? filterFormat;
  final String? filterMetadata;
  final bool localLibraryEnabled;

  const LibraryCountsRequest({
    required this.searchQuery,
    required this.filterSource,
    required this.filterQuality,
    required this.filterFormat,
    required this.filterMetadata,
    required this.localLibraryEnabled,
  });

  /// The whole Library, as the unfiltered Library tab counts it.
  const LibraryCountsRequest.all({required this.localLibraryEnabled})
    : searchQuery = '',
      filterSource = null,
      filterQuality = null,
      filterFormat = null,
      filterMetadata = null;

  QueueLibraryDbQuery toDbQuery() => QueueLibraryDbQuery(
    searchQuery: searchQuery,
    source: filterSource,
    quality: filterQuality,
    format: filterFormat,
    metadata: filterMetadata,
    includeLocal: localLibraryEnabled,
  );

  bool get allowsInMemoryHistoryFallback =>
      searchQuery.trim().isEmpty &&
      filterSource != 'local' &&
      filterQuality == null &&
      filterFormat == null &&
      filterMetadata == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryCountsRequest &&
          searchQuery == other.searchQuery &&
          filterSource == other.filterSource &&
          filterQuality == other.filterQuality &&
          filterFormat == other.filterFormat &&
          filterMetadata == other.filterMetadata &&
          localLibraryEnabled == other.localLibraryEnabled;

  @override
  int get hashCode => Object.hash(
    searchQuery,
    filterSource,
    filterQuality,
    filterFormat,
    filterMetadata,
    localLibraryEnabled,
  );
}

/// Track, album and single counts, taken again when downloads or the scanned
/// Library change. The scanned side follows the index revision, so a count
/// does not load the Library index ahead of its startup warmup.
final libraryCountsProvider = FutureProvider.autoDispose
    .family<QueueLibraryCounts, LibraryCountsRequest>((ref, request) async {
      ref.watch(
        downloadHistoryProvider.select((state) => state.loadedIndexVersion),
      );
      if (request.localLibraryEnabled) {
        ref.watch(localLibraryIndexRevisionProvider);
      }
      return LibraryDatabase.instance.getQueueCounts(request.toDbQuery());
    });
