import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/autoplay_personalization.dart'
    show AutoplayFeedbackKind;
import 'package:mornye/services/autoplay_taste.dart' show AutoplayTastePlay;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/sqlite_helpers.dart'
    show normalizeLookupText, readWriteStamp;
import 'package:mornye/utils/audio_format_utils.dart'
    show normalizeAudioFormatValue;
import 'package:mornye/utils/genre_tags.dart';
import 'package:sqflite/sqflite.dart' show Database, DatabaseExecutor;

/// A genre and the time spent listening to its songs.
typedef ProfileGenre = ({String name, int milliseconds});

/// A decade, as its first year, and the time spent on songs released in it.
typedef ProfileDecade = ({int decade, int milliseconds});

/// A file format and the time spent on songs stored in it.
typedef ProfileFormat = ({String name, int milliseconds});

/// How a heard song is stored.
enum ProfileQuality { hiRes, lossless, lossy }

/// The tier of a file of [format] with [bitDepth] and [sampleRate], or null
/// when nothing tells. Hi-Res is lossless past 16 bits or 48 kHz.
ProfileQuality? profileQualityOf({
  String? format,
  int? bitDepth,
  int? sampleRate,
}) {
  final name = normalizeAudioFormatValue(format);
  const lossy = {'aac', 'eac3', 'ac3', 'ac4', 'mp3', 'opus'};
  if (lossy.contains(name)) return ProfileQuality.lossy;
  final depth = bitDepth ?? 0;
  if (depth > 0 || const {'flac', 'alac', 'wav', 'aiff'}.contains(name)) {
    return depth > 16 || (sampleRate ?? 0) > 48000
        ? ProfileQuality.hiRes
        : ProfileQuality.lossless;
  }
  // An MP4 file without a bit depth holds AAC.
  return name == 'm4a' ? ProfileQuality.lossy : null;
}

/// When and how the heard songs were made: release decades, file quality
/// and formats, each by listening time.
class ProfileSound {
  const ProfileSound({
    this.decades = const [],
    this.decadeMilliseconds = 0,
    this.quality = const {},
    this.qualityMilliseconds = 0,
    this.formats = const [],
    this.recentMilliseconds = 0,
  });

  /// Decades by listening time, oldest first.
  final List<ProfileDecade> decades;

  /// Listening time of the songs that came out this year or last year.
  final int recentMilliseconds;

  /// The share of dated listening released before [year].
  double before(int year) {
    if (decadeMilliseconds <= 0) return 0;
    final old = decades
        .where((decade) => decade.decade < year)
        .fold(0, (sum, decade) => sum + decade.milliseconds);
    return old / decadeMilliseconds;
  }

  /// Listening time of the songs whose year is known.
  final int decadeMilliseconds;

  final Map<ProfileQuality, int> quality;

  /// Listening time of the songs whose quality is known.
  final int qualityMilliseconds;

  /// Formats by listening time, longest first.
  final List<ProfileFormat> formats;

  /// The decade with the most listening.
  ProfileDecade? get era => decades.isEmpty
      ? null
      : decades.reduce((a, b) => b.milliseconds > a.milliseconds ? b : a);

  /// The share of known-quality listening in [tier].
  double share(ProfileQuality tier) =>
      qualityMilliseconds <= 0 ? 0 : (quality[tier] ?? 0) / qualityMilliseconds;
}

/// The decades and quality of [tracks]. [rows] are `match_key`,
/// `release_date`, `format`, `bit_depth` and `sample_rate` rows from
/// [LibraryDatabase.getDetailsOfSongs]; a song in several files counts once,
/// at its best quality.
ProfileSound listeningSound(
  Iterable<ListeningTotal> tracks,
  Iterable<Map<String, Object?>> rows, {
  DateTime? now,
}) {
  final latest = (now ?? DateTime.now()).year + 1;
  // Last year onward.
  final recentFrom = latest - 2;
  final years = <String, int>{};
  final tiers = <String, ProfileQuality>{};
  final formatOf = <String, String>{};
  for (final row in rows) {
    final key = row['match_key'] as String? ?? '';
    if (key.isEmpty) continue;
    final date = (row['release_date'] as String? ?? '').trim();
    final year = date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
    if (year != null && year >= 1900 && year <= latest) {
      years.putIfAbsent(key, () => year);
    }
    final format = row['format'] as String?;
    final tier = profileQualityOf(
      format: format,
      bitDepth: (row['bit_depth'] as num?)?.toInt(),
      sampleRate: (row['sample_rate'] as num?)?.toInt(),
    );
    final known = tiers[key];
    // ProfileQuality lists the best tier first.
    if (tier != null && (known == null || tier.index < known.index)) {
      tiers[key] = tier;
      final name = normalizeAudioFormatValue(format);
      if (name != null) formatOf[key] = name;
    }
  }
  final decades = <int, int>{};
  final quality = <ProfileQuality, int>{};
  final formats = <String, int>{};
  var dated = 0;
  var rated = 0;
  var recent = 0;
  for (final total in tracks) {
    final key = profileSongKey(total.track);
    final year = years[key];
    if (year != null) {
      final decade = year - year % 10;
      decades[decade] = (decades[decade] ?? 0) + total.milliseconds;
      dated += total.milliseconds;
      if (year >= recentFrom) recent += total.milliseconds;
    }
    final tier = tiers[key];
    if (tier != null) {
      quality[tier] = (quality[tier] ?? 0) + total.milliseconds;
      rated += total.milliseconds;
      final format = formatOf[key];
      if (format != null) {
        formats[format] = (formats[format] ?? 0) + total.milliseconds;
      }
    }
  }
  String formatName(String name) => switch (name) {
    'opus' => 'Opus',
    'm4a' => 'AAC',
    _ => name.toUpperCase(),
  };
  final namedFormats = <String, int>{};
  for (final entry in formats.entries) {
    final name = formatName(entry.key);
    namedFormats[name] = (namedFormats[name] ?? 0) + entry.value;
  }
  return ProfileSound(
    decades: [
      for (final decade in decades.keys.toList()..sort())
        (decade: decade, milliseconds: decades[decade]!),
    ],
    decadeMilliseconds: dated,
    recentMilliseconds: recent,
    quality: quality,
    qualityMilliseconds: rated,
    formats: [
      for (final entry in namedFormats.entries)
        (name: entry.key, milliseconds: entry.value),
    ]..sort((a, b) => b.milliseconds.compareTo(a.milliseconds)),
  );
}

/// The parts of a day, as the hours they start and end at.
enum ProfileDaypart {
  morning(5, 12),
  afternoon(12, 17),
  evening(17, 21),
  night(21, 5);

  const ProfileDaypart(this.start, this.end);

  final int start;
  final int end;

  static ProfileDaypart of(int hour) => values.firstWhere(
    (part) => part.start < part.end
        ? hour >= part.start && hour < part.end
        : hour >= part.start || hour < part.end,
  );
}

/// The hours songs are played at and how often they are played through,
/// read from the recent sessions the player learns from.
class ProfileRhythm {
  const ProfileRhythm({
    this.hours = const [],
    this.playedThrough = 0,
    this.skipped = 0,
    this.since,
  });

  factory ProfileRhythm.of(Iterable<AutoplayTastePlay> plays) {
    final hours = List.filled(24, 0);
    var through = 0;
    var skipped = 0;
    DateTime? since;
    for (final play in plays) {
      switch (play.kind) {
        case AutoplayFeedbackKind.listened || AutoplayFeedbackKind.replayed:
          hours[play.at.hour]++;
          through++;
        case AutoplayFeedbackKind.skipped:
          skipped++;
        case AutoplayFeedbackKind.loved || AutoplayFeedbackKind.playlisted:
          continue;
      }
      if (since == null || play.at.isBefore(since)) since = play.at;
    }
    return ProfileRhythm(
      hours: hours,
      playedThrough: through,
      skipped: skipped,
      since: since,
    );
  }

  /// Songs played on at each hour of the day, midnight first.
  final List<int> hours;

  /// Songs played through at least half of the way.
  final int playedThrough;
  final int skipped;

  /// The oldest session read.
  final DateTime? since;

  /// Fewer sessions than this say little about a listener's day.
  static const enough = 20;

  bool get isEmpty => playedThrough + skipped < enough;

  /// The share of songs played through.
  double get throughShare {
    final all = playedThrough + skipped;
    return all == 0 ? 0 : playedThrough / all;
  }

  /// Songs played on in each part of the day.
  Map<ProfileDaypart, int> get dayparts {
    final parts = {for (final part in ProfileDaypart.values) part: 0};
    for (final (hour, count) in hours.indexed) {
      final part = ProfileDaypart.of(hour);
      parts[part] = parts[part]! + count;
    }
    return parts;
  }

  /// The part of the day with the most songs played on.
  ProfileDaypart? get daypart {
    if (playedThrough == 0) return null;
    return dayparts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// The hour with the most songs played on.
  int? get peakHour {
    if (playedThrough == 0) return null;
    var best = 0;
    for (var hour = 1; hour < hours.length; hour++) {
      if (hours[hour] > hours[best]) best = hour;
    }
    return best;
  }
}

/// How few of [artists], most heard first, take half of the time they add
/// up to. 0 without listening.
int profileArtistsForHalf(List<MapEntry<String, int>> artists) {
  final total = artists.fold(0, (sum, artist) => sum + artist.value);
  if (total <= 0) return 0;
  var sum = 0;
  for (final (index, artist) in artists.indexed) {
    sum += artist.value;
    if (sum * 2 >= total) return index + 1;
  }
  return artists.length;
}

/// A word for a listener that the record bears out.
enum ProfileTrait {
  onAStreak,
  dailyRitual,
  marathon,
  onTheRise,
  audiophile,
  losslessPurist,
  nightOwl,
  earlyBird,
  daytime,
  sunset,
  weekender,
  workday,
  loyal,
  devotee,
  explorer,
  songHunter,
  eclectic,
  throwback,
  freshEars,
  onRepeat,
  patient,
  quickSkipper,
}

/// A trait with what bears it out: a [share] of the listening, a [count] or
/// the [subject] it is about, as the trait needs.
typedef ProfileTraitFact = ({
  ProfileTrait trait,
  double share,
  int count,
  String subject,
});

/// The traits [overview] and [rhythm] bear out, at most [limit], the most
/// marked first. [now] is today.
List<ProfileTraitFact> profileTraits(
  ProfileOverview overview, {
  ProfileRhythm? rhythm,
  int limit = 5,
  DateTime? now,
}) {
  final found = <(ProfileTraitFact, double)>[];
  // A trait holds from [threshold]; its rank grows from 1 there to 2 at
  // [full], so traits with different measures compare fairly.
  void add(
    ProfileTrait trait,
    num value, {
    required num threshold,
    required num full,
    double share = 0,
    int count = 0,
    String subject = '',
  }) {
    if (value < threshold) return;
    final rank = 1 + ((value - threshold) / (full - threshold)).clamp(0.0, 1.0);
    found.add((
      (trait: trait, share: share, count: count, subject: subject),
      rank,
    ));
  }

  const hour = 3600000;
  final habits = overview.habits;
  final all = overview.allTime;

  add(
    ProfileTrait.onAStreak,
    habits.currentStreak,
    threshold: 7,
    full: 30,
    count: habits.currentStreak,
  );
  final since = overview.since;
  if (since != null) {
    final today = now ?? DateTime.now();
    final span =
        DateTime(
          today.year,
          today.month,
          today.day,
        ).difference(DateTime(since.year, since.month, since.day)).inDays +
        1;
    if (span >= 30) {
      final daily = math.min(all.activeDays / span, 1.0);
      add(
        ProfileTrait.dailyRitual,
        daily,
        threshold: 0.8,
        full: 1,
        share: daily,
      );
    }
  }
  add(
    ProfileTrait.marathon,
    all.peakDayMilliseconds,
    threshold: 5 * hour,
    full: 12 * hour,
    count: all.peakDayMilliseconds,
  );
  final change = overview.month.changePercent;
  if (change != null && overview.month.summary.milliseconds >= 2 * hour) {
    add(
      ProfileTrait.onTheRise,
      change,
      threshold: 50,
      full: 200,
      share: change / 100,
    );
  }

  final sound = overview.sound;
  if (sound.qualityMilliseconds >= hour) {
    final hiRes = sound.share(ProfileQuality.hiRes);
    final lossless = hiRes + sound.share(ProfileQuality.lossless);
    if (hiRes >= 0.5) {
      add(
        ProfileTrait.audiophile,
        hiRes,
        threshold: 0.5,
        full: 1,
        share: hiRes,
      );
    } else {
      add(
        ProfileTrait.losslessPurist,
        lossless,
        threshold: 0.95,
        full: 1,
        share: lossless,
      );
    }
  }

  if (rhythm != null && !rhythm.isEmpty) {
    final busiest = rhythm.daypart!;
    final share = rhythm.dayparts[busiest]! / rhythm.playedThrough;
    // Afternoon and evening are long or common, so they need more.
    final (trait, threshold) = switch (busiest) {
      ProfileDaypart.night => (ProfileTrait.nightOwl, 0.35),
      ProfileDaypart.morning => (ProfileTrait.earlyBird, 0.35),
      ProfileDaypart.afternoon => (ProfileTrait.daytime, 0.45),
      ProfileDaypart.evening => (ProfileTrait.sunset, 0.45),
    };
    add(trait, share, threshold: threshold, full: 0.8, share: share);
    final through = rhythm.throughShare;
    add(ProfileTrait.patient, through, threshold: 0.9, full: 1, share: through);
    add(
      ProfileTrait.quickSkipper,
      1 - through,
      threshold: 0.4,
      full: 0.8,
      share: 1 - through,
    );
  }

  final week = habits.weekdays.fold(0, (sum, time) => sum + time);
  if (week >= 2 * hour) {
    final weekend = (habits.weekdays[5] + habits.weekdays[6]) / week;
    // Two days of seven are 29% of an even week.
    add(
      ProfileTrait.weekender,
      weekend,
      threshold: 0.45,
      full: 0.8,
      share: weekend,
    );
    add(
      ProfileTrait.workday,
      1 - weekend,
      threshold: 0.88,
      full: 1,
      share: 1 - weekend,
    );
  }

  final artists = all.topArtists;
  final artistTime = artists.fold(0, (sum, artist) => sum + artist.value);
  if (artists.length >= 3 && artistTime > 0) {
    final share = artists.first.value / artistTime;
    add(
      ProfileTrait.loyal,
      share,
      threshold: 0.25,
      full: 0.7,
      share: share,
      subject: artists.first.key,
    );
  }
  final genres = overview.genres;
  if (genres.isNotEmpty && overview.genreMilliseconds > 0) {
    final top = genres.first.milliseconds / overview.genreMilliseconds;
    add(
      ProfileTrait.devotee,
      top,
      threshold: 0.6,
      full: 1,
      share: top,
      subject: genres.first.name,
    );
    if (top < 0.3) {
      add(
        ProfileTrait.eclectic,
        genres.length,
        threshold: 8,
        full: 24,
        share: top,
        count: genres.length,
      );
    }
  }
  final newArtists = overview.month.newArtists.length;
  add(
    ProfileTrait.explorer,
    newArtists,
    threshold: 10,
    full: 50,
    count: newArtists,
  );
  final monthSongs = overview.month.summary.tracks.length;
  add(
    ProfileTrait.songHunter,
    monthSongs,
    threshold: 200,
    full: 800,
    count: monthSongs,
  );

  if (sound.decadeMilliseconds >= hour) {
    final old = sound.before(2000);
    final fresh = sound.recentMilliseconds / sound.decadeMilliseconds;
    add(ProfileTrait.throwback, old, threshold: 0.4, full: 0.9, share: old);
    add(ProfileTrait.freshEars, fresh, threshold: 0.4, full: 0.9, share: fresh);
  }

  final replay = all.replay;
  if (replay != null) {
    add(
      ProfileTrait.onRepeat,
      replay.plays,
      threshold: 8,
      full: 40,
      count: replay.plays,
      subject: replay.track.title,
    );
  }

  // Equals keep [ProfileTrait] order.
  found.sort((a, b) {
    final rank = b.$2.compareTo(a.$2);
    return rank != 0 ? rank : a.$1.trait.index.compareTo(b.$1.trait.index);
  });
  return [for (final (fact, _) in found.take(limit)) fact];
}

/// What the record says about the listener, for the Settings profile row
/// and the share card. Empty while it is off or says nothing yet.
final profileTraitsProvider =
    FutureProvider.autoDispose<List<ProfileTraitFact>>((ref) async {
      final player = ref.watch(playerUiEnabledProvider);
      final recording = ref.watch(
        settingsProvider.select((s) => s.listeningStatisticsEnabled),
      );
      if (!player || !recording) return const [];
      final overview = await ref.watch(profileOverviewProvider.future);
      if (overview.allTime.isEmpty) return const [];
      final rhythm = await ref.watch(profileRhythmProvider.future);
      return profileTraits(overview, rhythm: rhythm);
    });

/// The days a listener plays music on, read from the daily totals.
class ProfileHabits {
  const ProfileHabits({
    this.currentStreak = 0,
    this.weekdays = const [0, 0, 0, 0, 0, 0, 0],
    this.averageMilliseconds = 0,
    this.recent = const [],
    this.months = const [],
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
    final months = List.filled(recentMonths, 0);
    var total = 0;
    var active = 0;
    for (final entry in days.entries) {
      final day = DateTime.tryParse(entry.key);
      if (day == null || entry.value <= 0) continue;
      weekdays[day.weekday - 1] += entry.value;
      total += entry.value;
      active++;
      final back = (today.year - day.year) * 12 + today.month - day.month;
      if (back >= 0 && back < recentMonths) {
        months[recentMonths - 1 - back] += entry.value;
      }
    }
    return ProfileHabits(
      currentStreak: streak,
      weekdays: weekdays,
      averageMilliseconds: active == 0 ? 0 : total ~/ active,
      recent: [
        for (var back = recentDays - 1; back >= 0; back--)
          time(before(today, back)),
      ],
      months: months,
    );
  }

  /// How many days [recent] covers, today included.
  static const recentDays = 30;

  /// How many months [months] covers, this one included.
  static const recentMonths = 12;

  /// Days in a row with listening, up to today or, before today's first
  /// song, up to yesterday.
  final int currentStreak;

  /// Listening time by weekday, Monday first.
  final List<int> weekdays;

  /// The average listening time of a day with any.
  final int averageMilliseconds;

  /// Listening time of each of the last [recentDays] days, oldest first.
  final List<int> recent;

  /// Listening time of each of the last [recentMonths] months, oldest
  /// first.
  final List<int> months;
}

/// Everything the listening record tells about its listener.
class ProfileOverview {
  const ProfileOverview({
    required this.allTime,
    required this.month,
    this.genres = const [],
    this.genreMilliseconds = 0,
    this.habits = const ProfileHabits(),
    this.sound = const ProfileSound(),
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

  /// Release decades and file quality of the heard songs.
  final ProfileSound sound;

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

/// The parts of [ProfileOverview] the listening record alone gives.
typedef ProfileListening = ({
  ListeningRewind allTime,
  ListeningRewind month,
  ProfileHabits habits,
  DateTime? since,
});

/// Reads the listening parts of the profile from [db] for the day of [now].
Future<ProfileListening> readProfileListening(
  DatabaseExecutor db,
  DateTime now,
) async {
  final end = DateTime(now.year, now.month, now.day + 1);
  final monthStart = DateTime(
    end.year,
    end.month,
    end.day - ProfileHabits.recentDays,
  );
  final allTime = await readListeningRewind(
    db,
    ListeningRewindRange(
      start: DateTime(2000),
      end: end,
      previousStart: DateTime(1999),
      previousEnd: DateTime(2000),
    ),
  );
  final month = await readListeningRewind(
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
  );
  final summary = allTime.summary;
  final days = [
    for (final entry in summary.days.entries)
      if (entry.value > 0) entry.key,
  ]..sort();
  return (
    allTime: allTime,
    month: month,
    habits: ProfileHabits.of(summary.days, now),
    since: days.isEmpty ? null : DateTime.tryParse(days.first),
  );
}

/// Gives the listening parts of the profile, read again only after a write
/// to the record or on a new day, so a Library change reads only the Library.
class ProfileListeningSource {
  ProfileListeningSource({
    Future<Database> Function()? database,
    this.read = readProfileListening,
  }) : _database =
           database ?? (() => ListeningStatisticsStore.instance.database);

  final Future<Database> Function() _database;
  final Future<ProfileListening> Function(DatabaseExecutor db, DateTime now)
  read;
  ({Database db, String stamp, ProfileListening listening})? _last;

  Future<ProfileListening> listeningOn(DateTime now) async {
    final db = await _database();
    // Read before the record, so a write in between reads it again next time.
    final written = await readWriteStamp(db, const ['main']);
    final stamp = written == null ? null : '${listeningDay(now)}:$written';
    final last = _last;
    if (stamp != null &&
        last != null &&
        identical(last.db, db) &&
        last.stamp == stamp) {
      return last.listening;
    }
    final listening = await read(db, now);
    _last = stamp == null ? null : (db: db, stamp: stamp, listening: listening);
    return listening;
  }
}

/// Lives as long as [profileOverviewProvider] watches it.
final profileListeningSourceProvider =
    Provider.autoDispose<ProfileListeningSource>(
      (ref) => ProfileListeningSource(),
    );

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
  final source = ref.watch(profileListeningSourceProvider);
  await listeningRecorder.flush();
  final now = DateTime.now();
  final listening = await source.listeningOn(now);
  final summary = listening.allTime.summary;
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
  final details = keys.isEmpty
      ? const <Map<String, Object?>>[]
      : await LibraryDatabase.instance.getDetailsOfSongs(
          keys.toList(),
          includeLocal: includeLocal,
        );
  return ProfileOverview(
    allTime: listening.allTime,
    month: listening.month,
    genres: genres.genres,
    genreMilliseconds: genres.milliseconds,
    habits: listening.habits,
    sound: listeningSound(heard, details, now: now),
    since: listening.since,
  );
});

/// The hours of the day and the play-through rate, from the sessions the
/// player keeps for learning. Empty while learning has seen too little.
final profileRhythmProvider = FutureProvider.autoDispose<ProfileRhythm>((
  ref,
) async {
  try {
    final taste = ref.read(musicPlayerRuntimeProvider).taste;
    return ProfileRhythm.of(await taste.readLog());
  } catch (_) {
    return const ProfileRhythm();
  }
});
