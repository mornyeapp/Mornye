import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:sqflite/sqflite.dart';

/// Windows a Rewind can look back over. Rolling windows end today; [year]
/// covers the calendar year so far.
enum ListeningRewindPeriod {
  weeks(28),
  quarter(91),
  halfYear(182),
  year(0);

  const ListeningRewindPeriod(this.days);

  final int days;
}

/// The Rewind the Library advertises right now, if any.
enum ListeningRewindSpotlight {
  /// The last four weeks, offered for a week at the start of every four-week
  /// cycle.
  monthly(ListeningRewindPeriod.weeks),

  /// The calendar year, offered through December.
  yearly(ListeningRewindPeriod.year);

  const ListeningRewindSpotlight(this.period);

  final ListeningRewindPeriod period;

  static const cycleDays = 28;
  static const visibleDays = 7;

  /// December shows the year; otherwise the monthly Rewind appears during the
  /// first [visibleDays] of each [cycleDays] cycle and is hidden in between.
  static ListeningRewindSpotlight? at(DateTime now) {
    if (now.month == DateTime.december) return yearly;
    // Cycles start on Mondays counted from Monday 1 January 2024. UTC dates
    // count calendar days, immune to daylight-saving hour shifts.
    final days = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(2024)).inDays;
    return days % cycleDays < visibleDays ? monthly : null;
  }
}

/// Local calendar days. Both ends are exclusive of [end] and [previousEnd].
///
/// The previous window is the same span immediately before a rolling window,
/// or the same dates last year for [ListeningRewindPeriod.year].
class ListeningRewindRange {
  const ListeningRewindRange({
    required this.start,
    required this.end,
    required this.previousStart,
    required this.previousEnd,
  });

  factory ListeningRewindRange.of(ListeningRewindPeriod period, DateTime now) {
    final end = DateTime(now.year, now.month, now.day + 1);
    if (period == ListeningRewindPeriod.year) {
      return ListeningRewindRange(
        start: DateTime(now.year),
        end: end,
        previousStart: DateTime(now.year - 1),
        previousEnd: DateTime(now.year - 1, now.month, now.day + 1),
      );
    }
    final start = DateTime(end.year, end.month, end.day - period.days);
    return ListeningRewindRange(
      start: start,
      end: end,
      previousStart: DateTime(start.year, start.month, start.day - period.days),
      previousEnd: start,
    );
  }

  final DateTime start;
  final DateTime end;
  final DateTime previousStart;
  final DateTime previousEnd;

  /// The last day inside the window.
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);
}

class ListeningAlbumTotal {
  const ListeningAlbumTotal({
    required this.album,
    required this.artist,
    required this.milliseconds,
    required this.plays,
    this.artwork,
  });

  final String album;
  final String artist;
  final String? artwork;
  final int milliseconds;
  final int plays;
}

/// The most plays one song received on a single day.
class ListeningReplay {
  const ListeningReplay(this.track, this.day, this.plays);

  final ListeningTrack track;
  final DateTime day;
  final int plays;
}

/// The first song heard in a window: the most played on its first day.
class ListeningFirstPlay {
  const ListeningFirstPlay(this.track, this.day);

  final ListeningTrack track;
  final DateTime day;
}

/// Year-in-review extras, read only for a calendar-year Rewind.
class ListeningYearDetails {
  const ListeningYearDetails({
    this.monthlyTopArtists = const {},
    this.loyalArtist,
    this.loyalArtistDays = 0,
    this.firstPlay,
  });

  /// Month (1 to 12) to the artist heard longest that month.
  final Map<int, String> monthlyTopArtists;

  /// The artist heard on the most different days, and on how many.
  final String? loyalArtist;
  final int loyalArtistDays;
  final ListeningFirstPlay? firstPlay;
}

/// Highlights of one Rewind window, derived from the daily listening table.
class ListeningRewind {
  const ListeningRewind({
    required this.range,
    required this.summary,
    required this.previousMilliseconds,
    required this.topArtists,
    required this.topAlbums,
    required this.newArtists,
    required this.longestStreak,
    this.peakDay,
    this.peakDayMilliseconds = 0,
    this.favoriteWeekday,
    this.replay,
    this.monthlyMilliseconds = const {},
    this.year,
  });

  /// Songs replayed fewer times than this in one day are not highlighted.
  static const minimumReplays = 3;

  /// Builds the highlights from the window's [summary].
  ///
  /// [newArtistNames] holds artists first heard inside the window; pass null
  /// when nothing was recorded before it, since every artist would be "new".
  factory ListeningRewind.compute({
    required ListeningRewindRange range,
    required ListeningSummary summary,
    required int previousMilliseconds,
    Set<String>? newArtistNames,
    ListeningReplay? replay,
    ListeningYearDetails? year,
  }) {
    final artists = summary.artists.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final albums = <(String, String), ListeningAlbumTotal>{};
    for (final total in summary.tracks) {
      final album = total.track.album.trim();
      if (album.isEmpty) continue;
      final key = (album.toLowerCase(), total.track.artist.toLowerCase());
      final existing = albums[key];
      albums[key] = ListeningAlbumTotal(
        album: existing?.album ?? album,
        artist: existing?.artist ?? total.track.artist,
        // Tracks arrive most listened first, so the first cover wins.
        artwork:
            existing?.artwork ??
            normalizeStoredCoverReference(total.track.artwork),
        milliseconds: (existing?.milliseconds ?? 0) + total.milliseconds,
        plays: (existing?.plays ?? 0) + total.plays,
      );
    }
    final topAlbums = albums.values.toList()
      ..sort((a, b) => b.milliseconds.compareTo(a.milliseconds));

    final days = <DateTime, int>{
      for (final entry in summary.days.entries)
        if (entry.value > 0) DateTime.parse(entry.key): entry.value,
    };
    final ordered = days.keys.toList()..sort();
    DateTime? peakDay;
    var peakMilliseconds = 0;
    final weekdays = <int, int>{};
    final months = <int, int>{};
    var longestStreak = 0;
    var streak = 0;
    DateTime? previous;
    for (final day in ordered) {
      final time = days[day]!;
      if (time > peakMilliseconds) {
        peakDay = day;
        peakMilliseconds = time;
      }
      weekdays[day.weekday] = (weekdays[day.weekday] ?? 0) + time;
      months[day.month] = (months[day.month] ?? 0) + time;
      final expected = previous == null
          ? null
          : DateTime(previous.year, previous.month, previous.day + 1);
      streak = expected == day ? streak + 1 : 1;
      if (streak > longestStreak) longestStreak = streak;
      previous = day;
    }
    int? favoriteWeekday;
    for (final entry in weekdays.entries) {
      if (favoriteWeekday == null || entry.value > weekdays[favoriteWeekday]!) {
        favoriteWeekday = entry.key;
      }
    }

    return ListeningRewind(
      range: range,
      summary: summary,
      previousMilliseconds: previousMilliseconds,
      topArtists: artists,
      topAlbums: topAlbums,
      newArtists: newArtistNames == null
          ? const []
          : [
              for (final artist in artists)
                if (newArtistNames.contains(artist.key)) artist.key,
            ],
      longestStreak: longestStreak,
      peakDay: peakDay,
      peakDayMilliseconds: peakMilliseconds,
      favoriteWeekday: favoriteWeekday,
      replay: replay != null && replay.plays >= minimumReplays ? replay : null,
      monthlyMilliseconds: months,
      year: year,
    );
  }

  final ListeningRewindRange range;
  final ListeningSummary summary;
  final int previousMilliseconds;

  /// Artists by listening time, most first.
  final List<MapEntry<String, int>> topArtists;
  final List<ListeningAlbumTotal> topAlbums;

  /// Artists first heard in this window, most listened first.
  final List<String> newArtists;
  final DateTime? peakDay;
  final int peakDayMilliseconds;

  /// [DateTime.monday] to [DateTime.sunday].
  final int? favoriteWeekday;
  final int longestStreak;
  final ListeningReplay? replay;

  /// Month (1 to 12) to listening time. Only meaningful within one year.
  final Map<int, int> monthlyMilliseconds;

  /// Present for a calendar-year Rewind.
  final ListeningYearDetails? year;

  bool get isEmpty => summary.milliseconds <= 0;

  /// The month with the most listening, or null without any.
  int? get biggestMonth {
    int? best;
    for (final entry in monthlyMilliseconds.entries) {
      if (best == null || entry.value > monthlyMilliseconds[best]!) {
        best = entry.key;
      }
    }
    return best;
  }

  /// Calendar days the window covers, up to today. Rounded so a
  /// daylight-saving day of 23 or 25 hours still counts once.
  int get dayCount => (range.end.difference(range.start).inHours / 24).round();

  /// Share of the window's days with any listening, in percent.
  int get activeDayShare =>
      dayCount <= 0 ? 0 : (activeDays * 100 / dayCount).round().clamp(0, 100);

  int get activeDays => summary.days.values.where((time) => time > 0).length;

  int get minutes => (summary.milliseconds / 60000).round();

  /// Signed change from the previous window, or null without earlier
  /// listening to compare against.
  int? get changePercent => previousMilliseconds <= 0
      ? null
      : ((summary.milliseconds - previousMilliseconds) *
                100 /
                previousMilliseconds)
            .round();

  /// The top artist's share of all listening, in percent.
  int get topArtistShare => topArtists.isEmpty || summary.milliseconds <= 0
      ? 0
      : (topArtists.first.value * 100 / summary.milliseconds).round();
}

/// Year-in-review extras, splitting credits from SQLite's daily artist totals.
Future<ListeningYearDetails> readListeningYearDetails(
  DatabaseExecutor db,
  ListeningRewindRange range,
) async {
  final window = [listeningDay(range.start), listeningDay(range.end)];
  final artistDays = await db.rawQuery('''
    SELECT day, artist, SUM(milliseconds) AS milliseconds
    FROM listening WHERE day >= ? AND day < ? AND milliseconds > 0
    GROUP BY day, artist
  ''', window);
  final monthly = <int, Map<String, int>>{};
  final days = <String, Set<String>>{};
  final listeningTime = <String, int>{};
  for (final row in artistDays) {
    final day = row['day'] as String;
    final month = int.parse(day.substring(5, 7));
    final time = row['milliseconds'] as int;
    final totals = monthly.putIfAbsent(month, () => <String, int>{});
    for (final artist in splitArtistTagValues(row['artist'] as String)) {
      totals[artist] = (totals[artist] ?? 0) + time;
      days.putIfAbsent(artist, () => <String>{}).add(day);
      listeningTime[artist] = (listeningTime[artist] ?? 0) + time;
    }
  }
  final monthlyTopArtists = <int, String>{};
  for (final month in monthly.entries) {
    for (final artist in month.value.entries) {
      final best = monthlyTopArtists[month.key];
      if (best == null || artist.value > month.value[best]!) {
        monthlyTopArtists[month.key] = artist.key;
      }
    }
  }
  String? loyalArtist;
  var loyalDays = 0;
  var loyalTime = 0;
  for (final artist in days.entries) {
    final time = listeningTime[artist.key]!;
    if (artist.value.length > loyalDays ||
        (artist.value.length == loyalDays && time > loyalTime)) {
      loyalArtist = artist.key;
      loyalDays = artist.value.length;
      loyalTime = time;
    }
  }
  final first = await db.rawQuery('''
    SELECT day, track_key, title, artist, album, artwork
    FROM listening
    WHERE milliseconds > 0 AND day = (
      SELECT MIN(day) FROM listening
      WHERE day >= ? AND day < ? AND milliseconds > 0
    )
    ORDER BY plays DESC, milliseconds DESC LIMIT 1
  ''', window);
  final firstRow = first.firstOrNull;
  return ListeningYearDetails(
    monthlyTopArtists: monthlyTopArtists,
    loyalArtist: loyalArtist,
    loyalArtistDays: loyalDays,
    firstPlay: firstRow == null
        ? null
        : ListeningFirstPlay(
            ListeningTrack.fromRow(firstRow),
            DateTime.parse(firstRow['day'] as String),
          ),
  );
}

/// Reads one Rewind window, aggregating in SQLite like the statistics screen.
/// [yearly] adds the year-in-review extras.
Future<ListeningRewind> readListeningRewind(
  DatabaseExecutor db,
  ListeningRewindRange range, {
  bool yearly = false,
}) async {
  final summary = await readListeningSummary(db, range.start, range.end);
  final start = listeningDay(range.start);
  final end = listeningDay(range.end);
  final previous = await db.rawQuery(
    '''
    SELECT COALESCE(SUM(milliseconds), 0) AS milliseconds
    FROM listening WHERE day >= ? AND day < ?
  ''',
    [listeningDay(range.previousStart), listeningDay(range.previousEnd)],
  );
  final earlier = await db.rawQuery(
    'SELECT COUNT(*) AS count FROM listening WHERE day < ?',
    [start],
  );
  final hasHistory = (earlier.first['count'] as int? ?? 0) > 0;
  Set<String>? newArtistNames;
  if (hasHistory) {
    final firstHeard = await db.rawQuery(
      '''
      SELECT artist, MIN(day) AS first_day FROM listening
      WHERE day < ? AND milliseconds > 0 GROUP BY artist
    ''',
      [end],
    );
    final firstDays = <String, String>{};
    for (final row in firstHeard) {
      final day = row['first_day'] as String;
      for (final artist in splitArtistTagValues(row['artist'] as String)) {
        final previous = firstDays[artist];
        if (previous == null || day.compareTo(previous) < 0) {
          firstDays[artist] = day;
        }
      }
    }
    newArtistNames = {
      for (final artist in firstDays.entries)
        if (artist.value.compareTo(start) >= 0) artist.key,
    };
  }
  final replays = await db.rawQuery(
    '''
    SELECT day, track_key, title, artist, album, artwork, plays
    FROM listening WHERE day >= ? AND day < ?
    ORDER BY plays DESC, milliseconds DESC LIMIT 1
  ''',
    [start, end],
  );
  final replay = replays.isEmpty ? null : replays.first;
  final year = yearly ? await readListeningYearDetails(db, range) : null;
  return ListeningRewind.compute(
    year: year,
    range: range,
    summary: summary,
    previousMilliseconds: previous.first['milliseconds'] as int? ?? 0,
    newArtistNames: newArtistNames,
    replay: replay == null
        ? null
        : ListeningReplay(
            ListeningTrack.fromRow(replay),
            DateTime.parse(replay['day'] as String),
            replay['plays'] as int,
          ),
  );
}
