import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show compute, mapEquals, visibleForTesting;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart'
    show RecentAccessItem, RecentAccessType;
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('LibraryMixes');

// Versioned so new kinds of mixes replace a cache made before them the
// same day.
const _cacheKey = 'home_library_mixes_v2';

/// The year a release date such as `2019-05-10` or `2019` names, or null.
int? libraryMixReleaseYear(Object? releaseDate) {
  if (releaseDate is! String) return null;
  final match = RegExp(r'^\s*(\d{4})').firstMatch(releaseDate);
  final year = match == null ? null : int.parse(match.group(1)!);
  return year != null && year > 0 ? year : null;
}

/// When a mix song came into the Library: a download's time, or a scanned
/// file's modification time, falling back to when it was scanned, as the
/// Library's Recently Added does.
DateTime? libraryMixAddedAt(Map<String, Object?> row) {
  final modified = row['file_mod_time'];
  if (modified is num && modified > 0) {
    return DateTime.fromMillisecondsSinceEpoch(modified.toInt());
  }
  final added = row['added_at'];
  return added is String ? DateTime.tryParse(added) : null;
}

/// Songs a kept mix still needs once deleted songs drop out.
const _minVisibleSongs = 10;

/// Rows per Library read, so a large Library never arrives as one result.
const _pageSize = 2000;

/// A mix with its songs resolved to their current Library entries.
class LibraryMixView {
  const LibraryMixView({required this.mix, required this.items});

  final LibraryMix mix;
  final List<UnifiedLibraryItem> items;
}

/// Whether the cached mixes give way to new ones: on a new day, when Local
/// Library is switched, or when the Library grew or shrank by a tenth (at
/// least ten songs). A Library too small for mixes is checked again as soon
/// as it changes.
@visibleForTesting
bool libraryMixesStale({
  required String cachedDay,
  required bool cachedIncludeLocal,
  required int cachedCount,
  required bool cachedEmpty,
  required String day,
  required bool includeLocal,
  required int count,
}) {
  if (cachedDay != day || cachedIncludeLocal != includeLocal) return true;
  if (cachedEmpty && count != cachedCount) return true;
  final change = (count - cachedCount).abs();
  return change >= 10 && change * 10 >= cachedCount;
}

/// How long after the first frame the mixes wait before building, so the
/// Library warmup and its launch scan start first.
@visibleForTesting
const libraryMixesStartupDelay = Duration(seconds: 6);

/// The longest the mixes then wait for the app to go idle: a screen that
/// animates for as long as it is open must not hold them back for good.
@visibleForTesting
const libraryMixesIdleTimeout = Duration(seconds: 20);

/// Whether startup has settled enough for the mixes to be built: a few
/// seconds after the first frame, once no animation runs (or after
/// [libraryMixesIdleTimeout] more). Until then Home shows the cached mixes
/// only.
final libraryMixesStartupProvider = NotifierProvider<_StartupSettled, bool>(
  _StartupSettled.new,
);

class _StartupSettled extends Notifier<bool> {
  @override
  bool build() {
    Timer? delay, idle;
    ref.onDispose(() {
      delay?.cancel();
      idle?.cancel();
    });

    // As the Library warmup does: a pause after the first frame. Then, as
    // idle-priority work does, no start while an animation runs. A
    // scheduler task would spin through the event loop for as long as one
    // runs, so the check repeats each second instead.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ref.mounted) return;
      delay = Timer(libraryMixesStartupDelay, () {
        idle = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (SchedulerBinding.instance.transientCallbackCount > 0 &&
              timer.tick < libraryMixesIdleTimeout.inSeconds) {
            return;
          }
          timer.cancel();
          if (ref.mounted) state = true;
        });
      });
    });
    return false;
  }
}

/// The day's mixes of the Library's own songs for Home. They are built once
/// a day on a worker isolate and kept in preferences, so Home reopens to
/// the same mixes in the same order until the day ends or the Library
/// changes enough to matter. Building waits until startup has settled and
/// no Library scan runs; meanwhile the cached mixes show, if any.
final libraryMixesProvider = FutureProvider<List<LibraryMixView>>((ref) async {
  final includeLocal = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  if (!ref.watch(libraryMixesStartupProvider)) {
    return _cachedViews(includeLocal);
  }
  // A download or a rescan may change what the mixes can hold. The Local
  // Library is only read once startup has settled, so it keeps its own
  // deferred warmup. Downloads in a batch arrive coalesced, at most one
  // revision a second.
  ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
  if (includeLocal) {
    ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
    if (ref.watch(localLibraryProvider.select((s) => s.isScanning))) {
      return _cachedViews(includeLocal);
    }
  }
  // The Library tab and Home count the same Library; one count serves all.
  final counts = ref.watch(
    libraryCountsProvider(
      LibraryCountsRequest.all(localLibraryEnabled: includeLocal),
    ).future,
  );
  final now = DateTime.now();
  // New mixes at midnight while Home stays open.
  final midnight = Timer(
    DateTime(now.year, now.month, now.day + 1).difference(now) +
        const Duration(seconds: 5),
    ref.invalidateSelf,
  );
  ref.onDispose(midnight.cancel);
  try {
    final mixes = await _LibraryMixes.instance.load(
      includeLocal: includeLocal,
      now: now,
      runtime: ref.read(musicPlayerRuntimeProvider),
      count: (await counts).allTrackCount,
    );
    return await _resolve(mixes, includeLocal);
  } on Object catch (error, stack) {
    _log.w('Could not make Library mixes: $error\n$stack');
    return const [];
  }
});

/// The cached mixes however old, for while building waits.
Future<List<LibraryMixView>> _cachedViews(bool includeLocal) async {
  try {
    return await _resolve(
      await _LibraryMixes.instance.cached(includeLocal),
      includeLocal,
    );
  } on Object catch (error, stack) {
    _log.w('Could not read cached Library mixes: $error\n$stack');
    return const [];
  }
}

class _LibraryMixes {
  _LibraryMixes._();

  static final instance = _LibraryMixes._();

  Future<List<LibraryMix>> cached(bool includeLocal) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = _decode(prefs.getString(_cacheKey));
    return cached != null && cached.includeLocal == includeLocal
        ? cached.mixes
        : const [];
  }

  /// One load at a time; Library changes during one reuse it.
  Future<List<LibraryMix>>? _building;
  bool _buildingIncludeLocal = false;

  Future<List<LibraryMix>> load({
    required bool includeLocal,
    required DateTime now,
    required MusicPlayerRuntime runtime,
    required int count,
  }) async {
    final pending = _building;
    if (pending != null) {
      if (_buildingIncludeLocal == includeLocal) return pending;
      // Local Library was switched: the next load starts after this one.
      await pending.then((_) {}, onError: (_) {});
      return load(
        includeLocal: includeLocal,
        now: now,
        runtime: runtime,
        count: count,
      );
    }
    final operation = _load(includeLocal, now, runtime, count);
    _building = operation;
    _buildingIncludeLocal = includeLocal;
    try {
      return await operation;
    } finally {
      if (identical(_building, operation)) _building = null;
    }
  }

  Future<List<LibraryMix>> _load(
    bool includeLocal,
    DateTime now,
    MusicPlayerRuntime runtime,
    int count,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final day = listeningDay(now);
    final cached = _decode(prefs.getString(_cacheKey));
    if (cached != null &&
        !libraryMixesStale(
          cachedDay: cached.day,
          cachedIncludeLocal: cached.includeLocal,
          cachedCount: cached.count,
          cachedEmpty: cached.mixes.isEmpty,
          day: day,
          includeLocal: includeLocal,
          count: count,
        )) {
      return cached.mixes;
    }
    final mixes = count < libraryMixMinLibrary
        ? const <LibraryMix>[]
        : await _build(includeLocal, now, runtime);
    await prefs.setString(
      _cacheKey,
      jsonEncode({
        'day': day,
        'includeLocal': includeLocal,
        'count': count,
        'mixes': [for (final mix in mixes) mix.toJson()],
      }),
    );
    return mixes;
  }

  /// The cache as last decoded, so an unchanged cache is not decoded again
  /// and keeps the same mixes.
  static String? _decodedValue;
  static ({String day, bool includeLocal, int count, List<LibraryMix> mixes})?
  _decoded;

  static ({String day, bool includeLocal, int count, List<LibraryMix> mixes})?
  _decode(String? value) {
    if (value == null) return null;
    if (value == _decodedValue) return _decoded;
    final decoded = _decodeJson(value);
    _decodedValue = value;
    _decoded = decoded;
    return decoded;
  }

  static ({String day, bool includeLocal, int count, List<LibraryMix> mixes})?
  _decodeJson(String value) {
    try {
      final json = jsonDecode(value);
      if (json is! Map) return null;
      final day = json['day'], includeLocal = json['includeLocal'];
      final count = json['count'], mixes = json['mixes'];
      if (day is! String ||
          includeLocal is! bool ||
          count is! int ||
          mixes is! List) {
        return null;
      }
      return (
        day: day,
        includeLocal: includeLocal,
        count: count,
        mixes: [for (final mix in mixes) ?LibraryMix.fromJson(mix)],
      );
    } on FormatException {
      return null;
    }
  }

  Future<List<LibraryMix>> _build(
    bool includeLocal,
    DateTime now,
    MusicPlayerRuntime runtime,
  ) async {
    final (:songs, :years, :added) = await _songs(includeLocal);
    final (plays, pastPlays) = await _plays(songs, now);
    if (plays.length < libraryMixFavoritesMinPlayed) {
      // Statistics are off or new: what else the app keeps of the
      // listener's taste stands in, so favorites still have a mix.
      final hinted = libraryMixHintPlays(songs, await _hints(runtime), now);
      for (final MapEntry(:key, :value) in hinted.entries) {
        plays[key] = (plays[key] ?? 0) + value;
      }
    }
    // The most played songs stand for the listener's session, as the
    // songs before a refill do for Autoplay.
    final favorites = songs.where((song) => (plays[song.id] ?? 0) > 0).toList()
      ..sort((a, b) => plays[b.id]!.compareTo(plays[a.id]!));
    final session = favorites.take(16).toList();
    final learning = runtime.personalization.enabled;
    final (sound, taste) = await (
      runtime.songAnalysis.loadSignal(session: session, candidates: songs),
      learning && session.isNotEmpty
          ? runtime.taste.signal(session, songs)
          : Future<AutoplaySignal?>.value(),
    ).wait;
    return compute(
      buildLibraryMixes,
      LibraryMixRequest(
        songs: songs,
        at: now,
        plays: plays,
        pastPlays: pastPlays,
        years: years,
        added: added,
        signals: [?sound, ?taste],
        preference: runtime.personalization.rankingSnapshot,
        weights: learning ? runtime.ranker.weights : const {},
      ),
      debugLabel: 'library-mixes',
    );
  }

  /// Every downloaded and scanned song, by its Library id, with release
  /// years and when each came into the Library.
  static Future<
    ({
      List<PlayableMedia> songs,
      Map<String, int> years,
      Map<String, DateTime> added,
    })
  >
  _songs(bool includeLocal) async {
    final songs = <PlayableMedia>[];
    final years = <String, int>{};
    final added = <String, DateTime>{};
    for (final source in ['downloaded', if (includeLocal) 'local']) {
      String? afterId;
      while (true) {
        final rows = await LibraryDatabase.instance.getMixSongPage(
          source: source,
          afterId: afterId,
          limit: _pageSize,
        );
        for (final row in rows) {
          final seconds = readPositiveInt(row['duration']);
          final id = '${source == 'local' ? 'local' : 'dl'}_${row['id']}';
          if (libraryMixReleaseYear(row['release_date']) case final year?) {
            years[id] = year;
          }
          if (libraryMixAddedAt(row) case final at?) added[id] = at;
          songs.add(
            PlayableMedia(
              id: id,
              source: row['file_path'] as String? ?? '',
              title: row['track_name'] as String? ?? '',
              artist: row['artist_name'] as String? ?? '',
              album: row['album_name'] as String? ?? '',
              genre: row['genre'] as String?,
              duration: seconds == null ? null : Duration(seconds: seconds),
            ),
          );
        }
        afterId = rows.lastOrNull?['id'] as String?;
        if (rows.length < _pageSize || afterId == null) break;
      }
    }
    return (songs: songs, years: years, added: added);
  }

  /// Loved songs, Autoplay's learning log while learning is on, the saved
  /// queue up to its current song and the albums opened lately. A source
  /// that cannot be read adds nothing.
  static Future<LibraryMixHints> _hints(MusicPlayerRuntime runtime) async {
    Future<List<T>> read<T>(Future<List<T>> Function() load) async {
      try {
        return await load();
      } on Object catch (error) {
        _log.w('Could not read a Library mix hint: $error');
        return const [];
      }
    }

    final (loved, liked, queued, albums) = await (
      read(() async {
        final tracks = await LibraryCollectionsDatabase.instance
            .loadLovedTracks();
        return [
          for (final track in tracks)
            (artist: track.artistName, title: track.name),
        ];
      }),
      read(() async {
        if (!runtime.personalization.enabled) {
          return const <({String song, double reward, DateTime at})>[];
        }
        return [
          for (final play in await runtime.taste.readLog())
            (song: play.song, reward: play.reward, at: play.at),
        ];
      }),
      read(() async {
        final session = await AppStateDatabase.instance.getPlaybackSession();
        final media = session?['media'];
        if (media is! List) return const <String>[];
        final index = session?['index'] as int? ?? 0;
        return [
          for (final item in media.take(index + 1))
            if (item case {'source': final String source}) source,
        ];
      }),
      read(() async {
        final rows = await AppStateDatabase.instance.getRecentAccessRows(
          limit: 30,
        );
        return [for (final row in rows) ?_recentAlbum(row['item_json'])];
      }),
    ).wait;
    return LibraryMixHints(
      loved: loved,
      liked: liked,
      queued: queued,
      albums: albums,
    );
  }

  static ({String album, String? artist})? _recentAlbum(Object? json) {
    if (json is! String) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final item = RecentAccessItem.fromJson(decoded);
      return item.type == RecentAccessType.album
          ? (album: item.name, artist: item.subtitle)
          : null;
    } on Object {
      return null;
    }
  }

  /// Plays of the last 90 days by song id, those of the last 14 counting
  /// twice, and plays of the year before those 90 days. A song matches its
  /// played file, or its title and artist when it was played from another
  /// copy.
  static Future<(Map<String, double>, Map<String, double>)> _plays(
    List<PlayableMedia> songs,
    DateTime now,
  ) async {
    await listeningRecorder.flush();
    final store = ListeningStatisticsStore.instance;
    final end = DateTime(now.year, now.month, now.day + 1);
    final seasonStart = DateTime(now.year, now.month, now.day - 89);
    final (season, recent, past) = await (
      store.load(seasonStart, end),
      store.load(DateTime(now.year, now.month, now.day - 13), end),
      store.load(DateTime(now.year, now.month, now.day - 364), seasonStart),
    ).wait;
    String songKey(String artist, String title) =>
        '${normalizeLookupText(artist)}|${normalizeLookupText(title)}';
    Map<String, double> byId(List<ListeningSummary> summaries) {
      final bySource = <String, double>{}, bySong = <String, double>{};
      for (final summary in summaries) {
        for (final total in summary.tracks) {
          if (total.plays <= 0) continue;
          final track = total.track;
          bySource[track.key] = (bySource[track.key] ?? 0) + total.plays;
          final key = songKey(track.artist, track.title);
          bySong[key] = (bySong[key] ?? 0) + total.plays;
        }
      }
      return {
        for (final song in songs)
          song.id:
              ?(bySource[song.source] ??
              bySong[songKey(song.artist, song.title)]),
      };
    }

    return (byId([season, recent]), byId([past]));
  }
}

/// The mixes' songs as their current Library entries. Songs deleted since
/// drop out, and a mix left with too few is hidden.
Future<List<LibraryMixView>> _resolve(
  List<LibraryMix> mixes,
  bool includeLocal,
) async {
  if (mixes.isEmpty) return const [];
  final downloaded = <String>{}, local = <String>{};
  for (final mix in mixes) {
    for (final id in mix.songIds) {
      if (id.startsWith('dl_')) {
        downloaded.add(id.substring(3));
      } else if (id.startsWith('local_') && includeLocal) {
        local.add(id.substring(6));
      }
    }
  }
  final (history, scanned) = await (
    HistoryDatabase.instance.getByIds(downloaded),
    LibraryDatabase.instance.getByIds(local.toList()),
  ).wait;
  // Most Library changes leave the mixes' songs as they were: keep the
  // views, so Home neither decodes them again nor rebuilds the shelf.
  final last = _lastResolved;
  if (last != null &&
      identical(last.mixes, mixes) &&
      last.includeLocal == includeLocal &&
      _sameRowsById(last.history, history) &&
      _sameRows(last.scanned, scanned)) {
    return last.views;
  }
  final items = <String, UnifiedLibraryItem>{
    for (final MapEntry(:key, :value) in history.entries)
      'dl_$key': UnifiedLibraryItem.fromDownloadHistory(
        DownloadHistoryItem.fromJson(value),
      ),
    for (final row in scanned)
      'local_${row['id']}': UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem.fromJson(row),
      ),
  };
  final views = [
    for (final mix in mixes)
      if ([for (final id in mix.songIds) ?items[id]] case final songs
          when songs.length >= _minVisibleSongs)
        LibraryMixView(mix: mix, items: songs),
  ];
  _lastResolved = (
    mixes: mixes,
    includeLocal: includeLocal,
    history: history,
    scanned: scanned,
    views: views,
  );
  return views;
}

/// The last [_resolve] and the rows it read.
({
  List<LibraryMix> mixes,
  bool includeLocal,
  Map<String, Map<String, dynamic>> history,
  List<Map<String, dynamic>> scanned,
  List<LibraryMixView> views,
})?
_lastResolved;

bool _sameRows(
  List<Map<String, dynamic>> first,
  List<Map<String, dynamic>> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (!mapEquals(first[index], second[index])) return false;
  }
  return true;
}

bool _sameRowsById(
  Map<String, Map<String, dynamic>> first,
  Map<String, Map<String, dynamic>> second,
) =>
    first.length == second.length &&
    first.entries.every((entry) => mapEquals(entry.value, second[entry.key]));
