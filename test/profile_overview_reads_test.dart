import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/profile_overview_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import 'support/fixed_settings.dart';

/// Bumps the download index version as a finished download or edit does.
class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  void changed() =>
      state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
}

void _libraryChanged(ProviderContainer container) =>
    (container.read(downloadHistoryProvider.notifier) as _History).changed();

ListeningTrack _track(String title, String artist) => ListeningTrack(
  key: '/music/$title.flac',
  title: title,
  artist: artist,
  album: '$title Album',
);

String _dayBefore(int days) {
  final now = DateTime.now();
  return listeningDay(DateTime(now.year, now.month, now.day - days));
}

Map<String, dynamic> _download(String id, String title, String genre) => {
  'id': id,
  'trackName': title,
  'artistName': 'Example Artist',
  'albumName': '$title Album',
  'filePath': '/downloads/$id.flac',
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(2026, 11, 1).toIso8601String(),
  'genre': genre,
};

/// The values read from the listening record alone.
List<Object?> _record(ProfileOverview overview) {
  List<Object?> rewind(ListeningRewind rewind) => [
    rewind.summary.milliseconds,
    rewind.summary.plays,
    [
      for (final total in rewind.summary.tracks)
        (
          total.track.key,
          total.track.title,
          total.track.artist,
          total.track.artwork,
          total.milliseconds,
          total.plays,
        ),
    ],
    rewind.summary.artists,
    rewind.summary.days,
    rewind.previousMilliseconds,
    rewind.changePercent,
    [for (final artist in rewind.topArtists) (artist.key, artist.value)],
    rewind.newArtists,
    rewind.peakDay,
    rewind.peakDayMilliseconds,
    rewind.longestStreak,
    rewind.replay?.track.title,
    rewind.replay?.plays,
  ];
  final habits = overview.habits;
  return [
    ...rewind(overview.allTime),
    ...rewind(overview.month),
    habits.currentStreak,
    habits.weekdays,
    habits.averageMilliseconds,
    habits.recent,
    habits.months,
    overview.since,
  ];
}

/// Every value the profile screens and traits show.
List<Object?> _shown(ProfileOverview overview) => [
  ..._record(overview),
  overview.genres,
  overview.genreMilliseconds,
  overview.sound.decades,
  overview.sound.quality,
  overview.sound.formats,
  profileTraits(overview),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Database listening;
  late int reads;

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            const AppSettings(localLibraryEnabled: false),
          ),
        ),
        downloadHistoryProvider.overrideWith(_History.new),
        profileListeningSourceProvider.overrideWith(
          (ref) => ProfileListeningSource(
            database: () async => listening,
            read: (db, now) {
              reads++;
              return readProfileListening(db, now);
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(profileOverviewProvider, (_, _) {});
    return container;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('profile-overview-');
    sqfliteFfiInit();
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    listening = await ListeningStatisticsStore.openWithFactory(
      databaseFactoryFfi,
      '${root.path}/listening.db',
    );
    addTearDown(() async {
      await listening.close();
      await LibraryDatabase.instance.close();
      await HistoryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previousFactory;
      await root.delete(recursive: true);
    });
    reads = 0;
    await writeListeningDeltas(listening, [
      ListeningDelta(
        _dayBefore(0),
        _track('First', 'Example Artist'),
        900000,
        3,
      ),
      ListeningDelta(
        _dayBefore(3),
        _track('Second', 'Example Artist'),
        600000,
        2,
      ),
      ListeningDelta(
        _dayBefore(45),
        _track('Third', 'Another Artist'),
        300000,
        1,
      ),
      ListeningDelta(
        _dayBefore(400),
        _track('First', 'Example Artist'),
        200000,
        1,
      ),
    ]);
    await HistoryDatabase.instance.upsertBatch([
      _download('d1', 'First', 'Rock'),
    ]);
  });

  test(
    'a Library change reads only the Library and shows the same record',
    () async {
      final profile = container();
      final before = await profile.read(profileOverviewProvider.future);
      expect(reads, 1);
      expect(before.genres.map((genre) => genre.name), ['Rock']);

      await HistoryDatabase.instance.upsertBatch([
        _download('d2', 'Second', 'Jazz'),
      ]);
      _libraryChanged(profile);
      final after = await profile.read(profileOverviewProvider.future);
      expect(reads, 1);
      // The Library part follows the change.
      expect(after.genres.map((genre) => genre.name), ['Rock', 'Jazz']);

      // A fresh read of everything gives the same profile.
      final fresh = await container().read(profileOverviewProvider.future);
      expect(reads, 2);
      expect(_shown(after), _shown(fresh));
      expect(_record(after), _record(before));
    },
  );

  test('the record matches the full reads the profile made before', () async {
    final overview = await container().read(profileOverviewProvider.future);
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day + 1);
    final monthStart = DateTime(end.year, end.month, end.day - 30);
    final allTime = await readListeningRewind(
      listening,
      ListeningRewindRange(
        start: DateTime(2000),
        end: end,
        previousStart: DateTime(1999),
        previousEnd: DateTime(2000),
      ),
    );
    final month = await readListeningRewind(
      listening,
      ListeningRewindRange(
        start: monthStart,
        end: end,
        previousStart: DateTime(end.year, end.month, end.day - 60),
        previousEnd: monthStart,
      ),
    );
    final expected = ProfileOverview(
      allTime: allTime,
      month: month,
      genres: overview.genres,
      genreMilliseconds: overview.genreMilliseconds,
      habits: ProfileHabits.of(allTime.summary.days, now),
      sound: overview.sound,
      since: DateTime.parse(_dayBefore(400)),
    );
    expect(_shown(overview), _shown(expected));
    expect(overview.month.newArtists, isEmpty);
    expect(overview.allTime.summary.tracks, hasLength(3));
  });

  test(
    'new listening shows on the next read, and only then reads again',
    () async {
      final profile = container();
      await profile.read(profileOverviewProvider.future);
      profile.invalidate(profileOverviewProvider);
      await profile.read(profileOverviewProvider.future);
      expect(reads, 1);

      await writeListeningDeltas(listening, [
        ListeningDelta(
          _dayBefore(0),
          _track('Fourth', 'New Artist'),
          120000,
          1,
        ),
      ]);
      _libraryChanged(profile);
      final overview = await profile.read(profileOverviewProvider.future);
      expect(reads, 2);
      expect(
        overview.allTime.summary.tracks.map((total) => total.track.title),
        contains('Fourth'),
      );
      expect(overview.month.newArtists, contains('New Artist'));
    },
  );

  test('a new day reads the record again', () async {
    final source = ProfileListeningSource(
      database: () async => listening,
      read: (db, now) {
        reads++;
        return readProfileListening(db, now);
      },
    );
    final now = DateTime.now();
    await source.listeningOn(now);
    await source.listeningOn(now.add(const Duration(seconds: 1)));
    expect(reads, 1);
    await source.listeningOn(DateTime(now.year, now.month, now.day + 1, 1));
    expect(reads, 2);
  });
}
