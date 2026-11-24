import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/library_genres_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/profile_overview_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/settings/profile_edit_page.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/app_theme.dart';

import 'support/fixed_settings.dart';

ListeningTotal _song(String title, String artist, int minutes) =>
    ListeningTotal(
      ListeningTrack(
        key: '/music/$title.flac',
        title: title,
        artist: artist,
        album: '$title Album',
      ),
      minutes * 60000,
      minutes ~/ 3,
    );

Map<String, Object?> _tag(ListeningTotal song, String genre) => {
  'match_key': LibraryDatabase.matchKeyFor(song.track.title, song.track.artist),
  'genre_name': genre,
};

final _songs = [
  _song('First', 'Example Artist', 600),
  _song('Second', 'Example Artist', 240),
  _song('Third', 'Another Artist', 120),
  _song('Fourth', 'Third Artist', 40),
];

ListeningRewind _rewind(
  Map<String, int> dayMinutes, {
  int previousMinutes = 0,
  Set<String>? newArtists,
}) {
  final artists = <String, int>{};
  for (final song in _songs) {
    artists[song.track.artist] =
        (artists[song.track.artist] ?? 0) + song.milliseconds;
  }
  return ListeningRewind.compute(
    range: ListeningRewindRange(
      start: DateTime(2000),
      end: DateTime(2026, 11, 20),
      previousStart: DateTime(1999),
      previousEnd: DateTime(2000),
    ),
    summary: ListeningSummary(
      milliseconds: _songs.fold(0, (sum, song) => sum + song.milliseconds),
      plays: _songs.fold(0, (sum, song) => sum + song.plays),
      tracks: _songs,
      artists: artists,
      days: {
        for (final entry in dayMinutes.entries) entry.key: entry.value * 60000,
      },
    ),
    previousMilliseconds: previousMinutes * 60000,
    newArtistNames: newArtists,
    replay: ListeningReplay(_songs.first.track, DateTime(2026, 11, 14), 7),
  );
}

ProfileOverview _overview() {
  final days = {
    '2026-09-05': 200,
    '2026-11-13': 90,
    '2026-11-14': 400,
    '2026-11-17': 60,
    '2026-11-18': 130,
    '2026-11-19': 120,
  };
  final genres = listeningGenres(_songs, [
    _tag(_songs[0], 'Pop'),
    _tag(_songs[1], 'pop; Rock'),
    _tag(_songs[2], 'Jazz'),
  ]);
  return ProfileOverview(
    allTime: _rewind(days),
    month: _rewind(
      days,
      previousMinutes: 500,
      newArtists: {'Another Artist', 'Third Artist'},
    ),
    genres: genres.genres,
    genreMilliseconds: genres.milliseconds,
    habits: ProfileHabits.of({
      for (final entry in days.entries) entry.key: entry.value * 60000,
    }, DateTime(2026, 11, 19, 15)),
    since: DateTime(2026, 9, 5),
  );
}

class _Profile extends UserProfileNotifier {
  @override
  Future<UserProfile> build() async => const UserProfile(name: 'Example Name');
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

Future<void> _pump(
  WidgetTester tester, {
  bool recording = true,
  Size size = const Size(420, 3200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            AppSettings(listeningStatisticsEnabled: recording),
          ),
        ),
        userProfileProvider.overrideWith(_Profile.new),
        profileOverviewProvider.overrideWith((ref) async => _overview()),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(
            const MediaItem(
              id: 'now',
              title: 'Playing Song',
              artist: 'Playing Artist',
            ),
          ),
        ),
        libraryCountsProvider.overrideWith(
          (ref, request) async => const QueueLibraryCounts(
            allTrackCount: 1523,
            albumCount: 140,
            singleTrackCount: 12,
          ),
        ),
        libraryGenresProvider.overrideWith(
          (ref) async => [
            for (final name in ['Jazz', 'Pop', 'Rock'])
              LibraryBrowseEntry(
                source: '',
                key: name.toLowerCase(),
                name: name,
                artist: '',
                samplePath: '',
                trackCount: 1,
              ),
          ],
        ),
        libraryCollectionsProvider.overrideWith(_Collections.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ProfileSettingsPage(profile: UserProfile()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  test('genres share the listening time of the songs the Library knows', () {
    final result = listeningGenres(_songs, [
      _tag(_songs[0], 'Pop'),
      // Both of its genres get the whole song, and "pop" joins "Pop".
      _tag(_songs[1], 'pop; Rock'),
      _tag(_songs[2], 'Jazz'),
      // A second file of the same song changes nothing.
      _tag(_songs[2], 'Blues'),
    ]);

    expect(result.milliseconds, (600 + 240 + 120) * 60000);
    expect(
      [for (final genre in result.genres) (genre.name, genre.milliseconds)],
      [('Pop', 840 * 60000), ('Rock', 240 * 60000), ('Jazz', 120 * 60000)],
    );
    expect(listeningGenres(_songs, const []).genres, isEmpty);
  });

  test('habits read the streak, the weekdays and an ordinary day', () {
    const minute = 60000;
    final days = {
      '2026-11-14': 400 * minute, // Saturday
      '2026-11-17': 60 * minute, // Tuesday
      '2026-11-18': 130 * minute,
      '2026-11-19': 0,
    };

    // Today has no song yet, so the streak still stands.
    final early = ProfileHabits.of(days, DateTime(2026, 11, 19, 8));
    expect(early.currentStreak, 2);
    expect(early.weekdays, [
      0,
      60 * minute,
      130 * minute,
      0,
      0,
      400 * minute,
      0,
    ]);
    expect(early.averageMilliseconds, (590 * minute) ~/ 3);
    expect(early.recent.length, ProfileHabits.recentDays);
    expect(early.recent.last, 0);
    expect(early.recent[early.recent.length - 2], 130 * minute);

    final played = ProfileHabits.of({
      ...days,
      '2026-11-19': minute,
    }, DateTime(2026, 11, 19, 20));
    expect(played.currentStreak, 3);

    // A day without music ends it.
    expect(ProfileHabits.of(days, DateTime(2026, 11, 21)).currentStreak, 0);
    expect(const ProfileHabits().currentStreak, 0);
  });

  testWidgets('the profile shows the listener, the record and the collection', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Example Name'), findsOneWidget);
    // Pop takes 840 of the 960 minutes whose genre is known.
    expect(find.text('Mostly Pop, with Rock, Jazz'), findsOneWidget);
    expect(find.text('Listening since September 2026'), findsOneWidget);
    expect(find.text('Playing Song'), findsOneWidget);

    // 1000 minutes in all, the same in the last 30 days.
    expect(find.text('17 h'), findsNWidgets(2));
    expect(find.text('Songs played'), findsOneWidget);
    // 17, 18 and 19 November: the current streak, and the longest.
    expect(find.text('3 days'), findsNWidgets(2));
    expect(find.text('6 days'), findsOneWidget);
    expect(find.text('100% more than the period before'), findsOneWidget);
    expect(find.text('Another Artist, Third Artist'), findsOneWidget);

    expect(find.text('88%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('Saturday'), findsOneWidget);
    expect(find.text('You played it 7 times on Nov 14, 2026'), findsOneWidget);
    expect(find.text('Top albums'), findsOneWidget);
    // A phone has room for three covers; the song list has all four.
    expect(find.text('Third Album'), findsOneWidget);
    expect(find.text('Fourth Album'), findsNothing);
    expect(find.text('Fourth'), findsOneWidget);

    expect(find.text('1,523'), findsOneWidget);
    expect(find.text('Favorite Artists'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditPage), findsOneWidget);
  });

  testWidgets('with Record listening off only the collection is shown', (
    tester,
  ) async {
    await _pump(tester, recording: false);

    expect(find.text('Example Name'), findsOneWidget);
    expect(find.textContaining('Record listening is off'), findsOneWidget);
    expect(find.text('All time'), findsNothing);
    expect(find.textContaining('Mostly Pop'), findsNothing);
    expect(find.text('1,523'), findsOneWidget);
    expect(find.text('Listening statistics'), findsOneWidget);
  });

  testWidgets('a wide page keeps every section inside the pane', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1100, 2400));

    expect(find.text('Top albums'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
