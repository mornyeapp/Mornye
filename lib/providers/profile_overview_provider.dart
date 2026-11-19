import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/genre_tags.dart';

/// A genre and the time spent listening to its songs.
typedef ProfileGenre = ({String name, int milliseconds});

/// The days a listener plays music on, read from the daily totals.
class ProfileHabits {
  const ProfileHabits({
    this.currentStreak = 0,
    this.weekdays = const [0, 0, 0, 0, 0, 0, 0],
    this.averageMilliseconds = 0,
    this.recent = const [],
  });

  /// [days] maps a [listeningDay] to its listening time; [now] is today.
  factory ProfileHabits.of(Map<String, int> days, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    int time(DateTime day) => days[listeningDay(day)] ?? 0;
    DateTime before(DateTime day, int count) =>
        DateTime(day.year, day.month, day.day - count);

    // A day that has only begun does not break the streak.
    var last = time(today) > 0 ? today : before(today, 1);
    var streak = 0;
    while (time(last) > 0) {
      streak++;
      last = before(last, 1);
    }

    final weekdays = List.filled(7, 0);
    var total = 0;
    var active = 0;
    for (final entry in days.entries) {
      final day = DateTime.tryParse(entry.key);
      if (day == null || entry.value <= 0) continue;
      weekdays[day.weekday - 1] += entry.value;
      total += entry.value;
      active++;
    }
    return ProfileHabits(
      currentStreak: streak,
      weekdays: weekdays,
      averageMilliseconds: active == 0 ? 0 : total ~/ active,
      recent: [
        for (var back = recentDays - 1; back >= 0; back--)
          time(before(today, back)),
      ],
    );
  }

  /// How many days [recent] covers, today included.
  static const recentDays = 30;

  /// Days in a row with listening, up to today or, before today's first
  /// song, up to yesterday.
  final int currentStreak;

  /// Listening time by weekday, Monday first.
  final List<int> weekdays;

  /// The average listening time of a day with any.
  final int averageMilliseconds;

  /// Listening time of each of the last [recentDays] days, oldest first.
  final List<int> recent;
}

/// Everything the listening record tells about its listener.
class ProfileOverview {
  const ProfileOverview({
    required this.allTime,
    required this.month,
    this.genres = const [],
    this.genreMilliseconds = 0,
    this.habits = const ProfileHabits(),
    this.since,
  });

  /// The whole record.
  final ListeningRewind allTime;

  /// The last [ProfileHabits.recentDays] days against those before.
  final ListeningRewind month;

  /// Genres by listening time, longest first.
  final List<ProfileGenre> genres;

  /// Listening time of the songs whose genre is known, the whole that
  /// [genres] are shares of.
  final int genreMilliseconds;

  final ProfileHabits habits;

  /// The first day with any listening.
  final DateTime? since;

  ListeningSummary get summary => allTime.summary;
}

/// The songs the genres are read for, by listening time. Past these a song
/// adds too little to move a share.
const profileGenreSongLimit = 800;

/// The genres of [tracks] by listening time and the time those songs add up
/// to. [rows] are `match_key` and `genre_name` pairs from
/// [LibraryDatabase.getGenresOfSongs]. A song whose tag lists several genres
/// counts in full under each, and every genre takes its most heard spelling.
({List<ProfileGenre> genres, int milliseconds}) listeningGenres(
  Iterable<ListeningTotal> tracks,
  Iterable<Map<String, Object?>> rows, {
  String separator = '',
}) {
  final tags = <String, String>{};
  for (final row in rows) {
    final key = row['match_key'] as String? ?? '';
    final tag = row['genre_name'] as String? ?? '';
    if (key.isNotEmpty && tag.isNotEmpty) tags.putIfAbsent(key, () => tag);
  }
  final time = <String, int>{};
  final spellings = <String, Map<String, int>>{};
  var known = 0;
  for (final total in tracks) {
    final tag = tags[profileSongKey(total.track)];
    if (tag == null) continue;
    final names = splitGenreTag(tag, separator: separator);
    if (names.isEmpty) continue;
    known += total.milliseconds;
    for (final name in names) {
      final key = normalizeLookupText(name);
      time[key] = (time[key] ?? 0) + total.milliseconds;
      final spelling = spellings.putIfAbsent(key, () => {});
      spelling[name] = (spelling[name] ?? 0) + total.milliseconds;
    }
  }
  String name(String key) => spellings[key]!.entries.reduce((best, next) {
    final order = next.value.compareTo(best.value);
    return order > 0 || (order == 0 && next.key.compareTo(best.key) < 0)
        ? next
        : best;
  }).key;
  final genres = [
    for (final entry in time.entries)
      (name: name(entry.key), milliseconds: entry.value),
  ];
  genres.sort((a, b) {
    final order = b.milliseconds.compareTo(a.milliseconds);
    return order != 0 ? order : a.name.compareTo(b.name);
  });
  return (genres: genres, milliseconds: known);
}

/// How the Library names [track]: its title and artist as compared there.
/// Empty without a title.
String profileSongKey(ListeningTrack track) =>
    normalizeLookupText(track.title).isEmpty
    ? ''
    : LibraryDatabase.matchKeyFor(track.title, track.artist);

/// The whole listening record with the genres of the songs in it. Songs are
/// matched to the Library by title and artist, since a record carried over
/// from another device knows them by other paths.
final profileOverviewProvider = FutureProvider.autoDispose<ProfileOverview>((
  ref,
) async {
  final includeLocal = watchLibrarySongs(ref);
  final separator = ref.watch(
    settingsProvider.select((s) => s.metadataSeparators.genre),
  );
  await listeningRecorder.flush();
  final now = DateTime.now();
  final end = DateTime(now.year, now.month, now.day + 1);
  final monthStart = DateTime(
    end.year,
    end.month,
    end.day - ProfileHabits.recentDays,
  );
  final store = ListeningStatisticsStore.instance;
  final allTime = await store.read(
    (db) => readListeningRewind(
      db,
      ListeningRewindRange(
        start: DateTime(2000),
        end: end,
        previousStart: DateTime(1999),
        previousEnd: DateTime(2000),
      ),
    ),
  );
  final month = await store.read(
    (db) => readListeningRewind(
      db,
      ListeningRewindRange(
        start: monthStart,
        end: end,
        previousStart: DateTime(
          monthStart.year,
          monthStart.month,
          monthStart.day - ProfileHabits.recentDays,
        ),
        previousEnd: monthStart,
      ),
    ),
  );
  final summary = allTime.summary;
  final heard = summary.tracks.take(profileGenreSongLimit).toList();
  final keys = {for (final total in heard) profileSongKey(total.track)}
    ..remove('');
  final rows = keys.isEmpty
      ? const <Map<String, Object?>>[]
      : await LibraryDatabase.instance.getGenresOfSongs(
          keys.toList(),
          includeLocal: includeLocal,
        );
  final genres = listeningGenres(heard, rows, separator: separator);
  final days = [
    for (final entry in summary.days.entries)
      if (entry.value > 0) entry.key,
  ]..sort();
  return ProfileOverview(
    allTime: allTime,
    month: month,
    genres: genres.genres,
    genreMilliseconds: genres.milliseconds,
    habits: ProfileHabits.of(summary.days, now),
    since: days.isEmpty ? null : DateTime.tryParse(days.first),
  );
});
