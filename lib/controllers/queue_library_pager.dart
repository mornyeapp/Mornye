import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/queue_library_refresh_policy.dart';
import 'package:mornye/services/library_database.dart' show QueueLibraryCounts;

/// A paged Library query as seen by [QueueLibraryPager].
abstract interface class QueueLibraryPageKey<K> {
  int get offset;
  int get limit;

  /// Whether [other] lists the same filtered and sorted Library rows, ignoring
  /// the page offset and cursor.
  bool hasSamePageScope(K other);
}

/// A loaded Library page as seen by [QueueLibraryPager].
abstract interface class QueueLibraryPageContent {
  bool get isEmpty;
}

/// Page offsets and the count and page snapshots behind the Library tab.
///
/// Snapshots outlive provider reloads so a refresh, a metadata backfill or a
/// download completion never flashes the Library as empty. The owning State
/// passes its `setState` and `mounted` checks to the methods that rebuild.
class QueueLibraryPager<
  C,
  R extends QueueLibraryPageKey<R>,
  P extends QueueLibraryPageContent
> {
  QueueLibraryPager({
    required this.pageSize,
    required P Function(List<P> pages) combinePages,
  }) : _combinePages = combinePages;

  final int pageSize;
  final P Function(List<P> pages) _combinePages;

  final Map<String, int> _pageOffsetByFilter = {};
  bool _pageLoadScheduled = false;

  final Map<C, QueueLibraryCounts> _countsCache = {};
  final Map<R, P> _pageDataCache = {};

  /// Recent combine results with their source pages, newest first.
  final List<(List<P>, P)> _combined = [];
  DateTime? _lastBlankRepairAt;

  int pageOffsetFor(String filterMode) => _pageOffsetByFilter[filterMode] ?? 0;

  void resetOffsets() {
    _pageOffsetByFilter.clear();
  }

  void resetPaging() {
    resetOffsets();
    _pageDataCache.clear();
    _combined.clear();
  }

  void _loadMore({
    required String filterMode,
    required bool hasMoreLibrary,
    required void Function(VoidCallback fn) setState,
  }) {
    if (_pageLoadScheduled) return;
    _pageLoadScheduled = true;
    setState(() {
      if (hasMoreLibrary) {
        _pageOffsetByFilter[filterMode] = pageOffsetFor(filterMode) + pageSize;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageLoadScheduled = false;
    });
  }

  QueueLibraryCounts resolveCounts(
    AsyncValue<QueueLibraryCounts> value,
    C request, {
    QueueLibraryCounts? nonEmptyFallback,
  }) {
    return value.maybeWhen(
      data: (counts) {
        final cached = _countsCache[request];
        final resolved = resolveQueueLibraryCountsSnapshot(
          current: counts,
          cached: cached,
          activeDownloadFallback: nonEmptyFallback,
        );
        _countsCache[request] = resolved;
        _trimCountsCache();
        return resolved;
      },
      orElse: () =>
          _countsCache[request] ??
          nonEmptyFallback ??
          const QueueLibraryCounts(
            allTrackCount: 0,
            albumCount: 0,
            singleTrackCount: 0,
          ),
    );
  }

  /// [nonEmptyFallback] is non-null when an in-memory snapshot is available;
  /// it is only invoked when no cached or live page has content.
  P resolvePageData(
    AsyncValue<P>? value,
    R request, {
    P Function()? nonEmptyFallback,
  }) {
    void storePage(P data) {
      final cached = cachedPageAt(request, request.offset);
      if (shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: data.isEmpty,
        cachedHasContent: cached != null && !cached.isEmpty,
        activeDownloadFallbackAvailable: nonEmptyFallback != null,
      )) {
        return;
      }
      final staleRequests = _pageDataCache.keys
          .where(
            (cachedRequest) =>
                cachedRequest.offset == request.offset &&
                cachedRequest != request &&
                cachedRequest.hasSamePageScope(request),
          )
          .toList(growable: false);
      for (final staleRequest in staleRequests) {
        _pageDataCache.remove(staleRequest);
      }
      _pageDataCache[request] = data;
      _trimPageDataCache(protectedRequest: request);
    }

    if (value != null) {
      final liveData = value.asData?.value;
      if (liveData != null) {
        storePage(liveData);
      }
      value.whenOrNull(data: storePage);
    }

    final pages = <P>[];
    for (var offset = 0; offset <= request.offset; offset += pageSize) {
      final page = cachedPageAt(request, offset);
      if (page != null) pages.add(page);
    }

    final combined = _combine(pages);
    if (combined.isEmpty && nonEmptyFallback != null) {
      return nonEmptyFallback();
    }
    return combined;
  }

  /// Reuses the result for the same page objects, so rebuilds keep the
  /// combined lists (and every cache keyed on them) instead of copying all
  /// loaded rows again.
  P _combine(List<P> pages) {
    search:
    for (final (sources, combined) in _combined) {
      if (sources.length != pages.length) continue;
      for (var i = 0; i < pages.length; i++) {
        if (!identical(sources[i], pages[i])) continue search;
      }
      return combined;
    }
    final combined = _combinePages(pages);
    _combined.insert(0, (pages, combined));
    if (_combined.length > 4) _combined.removeLast();
    return combined;
  }

  void _invalidateDataCaches() {
    _countsCache.clear();
    _pageDataCache.clear();
    _combined.clear();
  }

  /// Clears the snapshots and runs [repair] after the frame when the queue
  /// has items but the Library shows nothing, at most once per 8 seconds.
  void scheduleBlankLibraryRepair({
    required bool hasQueueItems,
    required bool hasLibraryContent,
    required bool hasAnyLibraryItems,
    required bool isLibraryPageLoading,
    required bool Function() isMounted,
    required VoidCallback repair,
  }) {
    if (!hasQueueItems ||
        hasLibraryContent ||
        hasAnyLibraryItems ||
        isLibraryPageLoading) {
      return;
    }
    final now = DateTime.now();
    final last = _lastBlankRepairAt;
    if (last != null && now.difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastBlankRepairAt = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      _invalidateDataCaches();
      repair();
    });
  }

  void _trimCountsCache() {
    const maxCountEntries = 24;
    while (_countsCache.length > maxCountEntries) {
      _countsCache.remove(_countsCache.keys.first);
    }
  }

  bool _isProtectedPage(R request, R protectedRequest) {
    return request.hasSamePageScope(protectedRequest) &&
        request.limit == protectedRequest.limit &&
        request.offset <= protectedRequest.offset;
  }

  P? cachedPageAt(R request, int offset) {
    for (final entry in _pageDataCache.entries) {
      if (entry.key.offset == offset && entry.key.hasSamePageScope(request)) {
        return entry.value;
      }
    }
    return null;
  }

  void _trimPageDataCache({required R protectedRequest}) {
    const maxPageEntries = 96;
    while (_pageDataCache.length > maxPageEntries) {
      final removableKey = _pageDataCache.keys
          .where((request) => !_isProtectedPage(request, protectedRequest))
          .firstOrNull;
      if (removableKey == null) break;
      _pageDataCache.remove(removableKey);
    }
  }

  bool handleScrollNotification({
    required ScrollNotification notification,
    required String filterMode,
    required bool hasMoreLibrary,
    required bool isPageLoading,
    required void Function(VoidCallback fn) setState,
  }) {
    if (isPageLoading || !hasMoreLibrary || notification.depth != 0) {
      return false;
    }

    final metrics = notification.metrics;
    if (metrics.maxScrollExtent <= 0) return false;
    final threshold = metrics.maxScrollExtent * 0.7;
    final nearEnd =
        metrics.pixels >= threshold ||
        metrics.extentAfter <= metrics.viewportDimension * 1.5;
    if (!nearEnd) return false;

    _loadMore(
      filterMode: filterMode,
      hasMoreLibrary: hasMoreLibrary,
      setState: setState,
    );
    return false;
  }
}
