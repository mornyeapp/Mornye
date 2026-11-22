import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// When a session of the app last saw Home.
@visibleForTesting
const homeLastVisitKey = 'home_status_last_visit_v1';

/// The previous session's Home visit and this session's first one.
typedef HomeVisitWindow = ({DateTime? previous, DateTime current});

/// Songs added since the previous visit; [sinceYesterday] when that visit
/// was on the calendar day before [HomeVisitWindow.current].
typedef HomeArrivals = ({int count, bool sinceYesterday});

/// The queue at a glance for Home's downloads section. Progress samples
/// leave it unchanged.
typedef HomeQueueSummary = ({
  String? currentId,
  int active,
  int waiting,
  int failed,
  bool paused,
});

/// The clock Home's status reads; tests replace it.
final homeStatusClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// History entries that finished after [since] and no later than [until].
int countHomeArrivals(
  Iterable<DownloadHistoryItem> items, {
  required DateTime since,
  required DateTime until,
}) {
  var count = 0;
  for (final item in items) {
    final at = item.downloadedAt;
    if (at.isAfter(since) && !at.isAfter(until)) count++;
  }
  return count;
}

/// History entries that finished on the local calendar day of [now].
int countFinishedOnDay(Iterable<DownloadHistoryItem> items, DateTime now) {
  final start = DateTime(now.year, now.month, now.day);
  final end = DateTime(now.year, now.month, now.day + 1);
  var count = 0;
  for (final item in items) {
    final at = item.downloadedAt.toLocal();
    if (!at.isBefore(start) && at.isBefore(end)) count++;
  }
  return count;
}

/// Whether [previous] fell on the local calendar day before [current].
bool isDayBefore(DateTime previous, DateTime current) {
  final day = DateTime(current.year, current.month, current.day - 1);
  final local = previous.toLocal();
  return local.year == day.year &&
      local.month == day.month &&
      local.day == day.day;
}

HomeQueueSummary homeQueueSummary(DownloadQueueState state) {
  final lookup = state.lookup;
  final current = lookup.firstDownloading ?? lookup.firstFinalizing;
  return (
    currentId: current?.id,
    active: lookup.queuedCount,
    waiting:
        lookup.queuedCount -
        lookup.activeDownloadsCount -
        lookup.finalizingCount,
    failed: lookup.failedCount,
    paused: state.isPaused,
  );
}

/// What Home shows of one downloading song, in whole percent so a progress
/// sample within the same percent changes nothing.
typedef HomeDownloadingSong = ({
  String title,
  String artist,
  bool finalizing,
  int percent,
});

HomeDownloadingSong? homeDownloadingSong(
  DownloadQueueLookup lookup,
  String itemId,
) {
  final item = lookup.byItemId[itemId];
  if (item == null) return null;
  return (
    title: item.track.name,
    artist: item.track.artistName,
    finalizing: item.status == DownloadStatus.finalizing,
    percent: (item.progress.clamp(0.0, 1.0) * 100).floor(),
  );
}

/// Reads the previous visit and records this one, once per app session.
final homeVisitWindowProvider = FutureProvider<HomeVisitWindow>((ref) async {
  final now = ref.read(homeStatusClockProvider)();
  DateTime? previous;
  try {
    final prefs = await SharedPreferences.getInstance();
    previous = DateTime.tryParse(
      prefs.getString(homeLastVisitKey) ?? '',
    )?.toLocal();
    await prefs.setString(homeLastVisitKey, now.toUtc().toIso8601String());
  } catch (_) {
    // Without storage every visit is a first one.
  }
  return (previous: previous, current: now);
});

/// Songs that finished downloading between the previous session's Home
/// visit and this session's first, counted among the loaded recent history.
/// The window is fixed for the session, so the number holds while browsing.
final homeArrivalsProvider = Provider<HomeArrivals>((ref) {
  final window = ref.watch(homeVisitWindowProvider).value;
  final previous = window?.previous;
  if (window == null || previous == null) {
    return (count: 0, sinceYesterday: false);
  }
  final items = ref.watch(downloadHistoryProvider.select((s) => s.items));
  return (
    count: countHomeArrivals(items, since: previous, until: window.current),
    sinceYesterday: isDayBefore(previous, window.current),
  );
});

/// Songs that finished downloading today, among the loaded recent history.
final homeFinishedTodayProvider = Provider<int>((ref) {
  final items = ref.watch(downloadHistoryProvider.select((s) => s.items));
  return countFinishedOnDay(items, ref.read(homeStatusClockProvider)());
});

/// Waiting, downloading and finalizing songs.
final homeActiveDownloadsProvider = Provider<int>(
  (ref) => ref.watch(downloadQueueLookupProvider.select((l) => l.queuedCount)),
);

final homeQueueSummaryProvider = Provider<HomeQueueSummary>(
  (ref) => ref.watch(downloadQueueProvider.select(homeQueueSummary)),
);
