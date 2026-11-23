import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
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
import 'package:mornye/screens/lyrics_share_screen.dart'
    show LyricsCardBackground, LyricsCardShape;
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/screens/settings/profile_share_screen.dart';
import 'package:mornye/services/autoplay_personalization.dart'
    show AutoplayFeedbackKind;
import 'package:mornye/services/autoplay_taste.dart' show AutoplayTastePlay;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Map<String, Object?> _file(
  ListeningTotal song, {
  String? date,
  String? format,
  int? bitDepth,
  int? sampleRate,
}) => {
  'match_key': LibraryDatabase.matchKeyFor(song.track.title, song.track.artist),
  'release_date': date,
  'format': format,
  'bit_depth': bitDepth,
  'sample_rate': sampleRate,
};

/// First is Hi-Res from 1994, Second lossy from 2012 and Fourth lossless
/// from 2019. Third has no file.
final _files = [
  _file(
    _songs[0],
    date: '1994-05-01',
    format: 'flac',
    bitDepth: 24,
    sampleRate: 96000,
  ),
  _file(_songs[1], date: '2012', format: 'mp3'),
  _file(
    _songs[3],
    date: '2019-03-02',
    format: 'flac',
    bitDepth: 16,
    sampleRate: 44100,
  ),
];

AutoplayTastePlay _play(int hour, AutoplayFeedbackKind kind) =>
    AutoplayTastePlay(
      song: 'song',
      artist: 'artist',
      at: DateTime(2026, 11, 18, hour, 30),
      kind: kind,
      reward: 1,
    );

/// Thirty songs played late at night, ten in the afternoon, ten skipped.
final _rhythm = ProfileRhythm.of([
  for (var i = 0; i < 30; i++) _play(23, AutoplayFeedbackKind.listened),
  for (var i = 0; i < 10; i++) _play(14, AutoplayFeedbackKind.replayed),
  for (var i = 0; i < 10; i++) _play(15, AutoplayFeedbackKind.skipped),
  _play(9, AutoplayFeedbackKind.loved),
]);

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
    sound: listeningSound(_songs, _files, now: DateTime(2026, 11, 19)),
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
  Size size = const Size(420, 6400),
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
        profileRhythmProvider.overrideWith((ref) async => _rhythm),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(
            const MediaItem(
              id: 'now',
              title: 'Playing Song',
              artist: 'Playing Artist',
              duration: Duration(minutes: 3, seconds: 45),
            ),
          ),
        ),
        playbackPositionProvider.overrideWithValue(
          const Duration(minutes: 1, seconds: 23, milliseconds: 600),
        ),
        playbackPlayingProvider.overrideWithValue(false),
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

    // Months end with this one; a year back falls off the chart.
    final months = ProfileHabits.of({
      ...days,
      '2026-01-05': 30 * minute,
      '2025-11-30': 90 * minute,
    }, DateTime(2026, 11, 19)).months;
    expect(months.length, ProfileHabits.recentMonths);
    expect(months.last, 590 * minute);
    expect(months.first, 0);
    expect(months[1], 30 * minute);
  });

  test('sound reads decades, quality and formats by listening time', () {
    const minute = 60000;
    final sound = listeningSound(_songs, [
      ..._files,
      // A lossy copy of the Hi-Res song keeps it Hi-Res.
      _file(_songs[0], date: '1994', format: 'aac'),
      // A year past next one says nothing.
      _file(_songs[2], date: '2031'),
    ], now: DateTime(2026, 11, 19));

    expect(
      [for (final d in sound.decades) (d.decade, d.milliseconds)],
      [(1990, 600 * minute), (2010, 280 * minute)],
    );
    expect(sound.decadeMilliseconds, 880 * minute);
    expect(sound.era?.decade, 1990);
    expect(sound.before(2000), closeTo(600 / 880, 1e-9));
    // Nothing came out in 2025 or 2026.
    expect(sound.recentMilliseconds, 0);
    expect(
      listeningSound(_songs, _files, now: DateTime(2020, 6)).recentMilliseconds,
      40 * minute,
    );
    expect(sound.quality, {
      ProfileQuality.hiRes: 600 * minute,
      ProfileQuality.lossy: 240 * minute,
      ProfileQuality.lossless: 40 * minute,
    });
    expect(sound.share(ProfileQuality.hiRes), closeTo(600 / 880, 1e-9));
    expect(
      [for (final f in sound.formats) (f.name, f.milliseconds)],
      [('FLAC', 640 * minute), ('MP3', 240 * minute)],
    );

    expect(profileQualityOf(format: 'm4a'), ProfileQuality.lossy);
    expect(
      profileQualityOf(format: 'm4a', bitDepth: 24, sampleRate: 48000),
      ProfileQuality.hiRes,
    );
    expect(
      profileQualityOf(format: 'flac', bitDepth: 16, sampleRate: 48000),
      ProfileQuality.lossless,
    );
    expect(profileQualityOf(), isNull);
  });

  test('rhythm reads the hours, the part of the day and the skips', () {
    expect(_rhythm.isEmpty, isFalse);
    expect(_rhythm.hours[23], 30);
    expect(_rhythm.hours[15], 0);
    expect(_rhythm.peakHour, 23);
    expect(_rhythm.daypart, ProfileDaypart.night);
    expect(_rhythm.throughShare, closeTo(0.8, 1e-9));
    expect(ProfileDaypart.of(4), ProfileDaypart.night);
    expect(ProfileDaypart.of(5), ProfileDaypart.morning);
    expect(ProfileDaypart.of(17), ProfileDaypart.evening);
    expect(const ProfileRhythm().isEmpty, isTrue);
  });

  test('traits follow what the record bears out', () {
    final traits = profileTraits(
      _overview(),
      rhythm: _rhythm,
      now: DateTime(2026, 11, 19),
    );
    // The most marked first: 84% for one artist is far past its 25%.
    expect(
      [for (final fact in traits) fact.trait],
      [
        ProfileTrait.loyal,
        ProfileTrait.nightOwl,
        ProfileTrait.devotee,
        ProfileTrait.throwback,
        ProfileTrait.weekender,
      ],
    );
    expect(traits.first.subject, 'Example Artist');
    expect(traits[1].share, closeTo(0.75, 1e-9));
    expect(traits[2].subject, 'Pop');
    expect(traits[3].share, closeTo(600 / 880, 1e-9));
    final all = [
      for (final fact in profileTraits(
        _overview(),
        rhythm: _rhythm,
        limit: ProfileTrait.values.length,
        now: DateTime(2026, 11, 19),
      ))
        fact.trait,
    ];
    expect(all, containsAll([ProfileTrait.audiophile, ProfileTrait.onTheRise]));
    // 80% played through is neither patient nor quick to skip.
    expect(all, isNot(contains(ProfileTrait.patient)));
    expect(all, isNot(contains(ProfileTrait.quickSkipper)));
    // Without sessions there is nothing to say about the hours.
    expect([
      for (final fact in profileTraits(_overview())) fact.trait,
    ], isNot(contains(ProfileTrait.nightOwl)));

    // Afternoons with most songs skipped.
    final skipping = ProfileRhythm.of([
      for (var i = 0; i < 10; i++) _play(14, AutoplayFeedbackKind.listened),
      for (var i = 0; i < 20; i++) _play(15, AutoplayFeedbackKind.skipped),
    ]);
    expect([
      for (final fact in profileTraits(
        _overview(),
        rhythm: skipping,
        limit: ProfileTrait.values.length,
      ))
        fact.trait,
    ], containsAll([ProfileTrait.daytime, ProfileTrait.quickSkipper]));
    expect(profileArtistsForHalf(_overview().allTime.topArtists), 1);
    expect(profileArtistsForHalf(const []), 0);
  });

  test('the card style keeps its choices and falls back on unknown ones', () {
    const style = ProfileCardStyle(
      background: LyricsCardBackground.dark,
      shape: LyricsCardShape.square,
      parts: {ProfileCardPart.sound, ProfileCardPart.identity},
    );
    expect(style.encode(), 'dark,square,identity|sound');
    final back = ProfileCardStyle.decode(style.encode());
    expect(back.background, LyricsCardBackground.dark);
    expect(back.shape, LyricsCardShape.square);
    expect(back.parts, {ProfileCardPart.identity, ProfileCardPart.sound});

    // The wide shape has no room for a profile.
    final fallback = ProfileCardStyle.decode('nope,wide,nothing|taste');
    expect(fallback.background, LyricsCardBackground.color);
    expect(fallback.shape, LyricsCardShape.story);
    expect(fallback.parts, {ProfileCardPart.taste});
    expect(ProfileCardStyle.decode(null).parts, ProfileCardStyle.defaultParts);
    expect(ProfileCardStyle.decode('dark,story,').parts, isEmpty);
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
    // Where the song is, in whole seconds played, and how long it runs.
    expect(find.text('1:23'), findsOneWidget);
    expect(find.text('3:45'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '1:23 of 3:45',
      ),
      findsOneWidget,
    );

    // 1000 minutes in all, the same in the last 30 days.
    expect(find.text('17 h'), findsNWidgets(2));
    expect(find.text('Songs played'), findsOneWidget);
    // 17, 18 and 19 November: the current streak, and the longest.
    expect(find.text('3 days'), findsNWidgets(2));
    expect(find.text('6 days'), findsOneWidget);
    expect(find.text('100% more than the period before'), findsOneWidget);
    expect(find.text('Another Artist, Third Artist'), findsOneWidget);

    // Each genre has its own color, from the bar to its legend dot.
    expect(find.text('88%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('Other'), findsNothing);
    expect(find.text('Saturday'), findsOneWidget);
    // Values end at the card's edge, where the genre shares end.
    expect(
      tester.getRect(find.text('Saturday')).right,
      closeTo(tester.getRect(find.text('88%')).right, 0.5),
    );
    expect(find.text('You played it 7 times on Nov 14, 2026'), findsOneWidget);
    expect(find.text('Top albums'), findsOneWidget);
    // A phone has room for three covers; the song list has all four.
    expect(find.text('Third Album'), findsOneWidget);
    expect(find.text('Fourth Album'), findsNothing);
    expect(find.text('Fourth'), findsOneWidget);
    expect(find.text('Example Artist · 200 plays'), findsOneWidget);
    expect(
      find.text('Half of your listening goes to 1 artist.'),
      findsOneWidget,
    );

    expect(find.text('Last 12 months'), findsOneWidget);
    expect(find.text('Best month'), findsOneWidget);
    expect(find.text('Listener type'), findsOneWidget);
    // The two leading types sit under the name too.
    expect(find.text('Loyal fan · Night owl'), findsOneWidget);
    expect(find.text('Loyal fan'), findsOneWidget);
    expect(find.text('Night owl'), findsOneWidget);
    expect(find.text('Pop at heart'), findsOneWidget);
    expect(find.text('Throwback lover'), findsOneWidget);
    expect(find.text('Weekend listener'), findsOneWidget);
    expect(
      find.text('Example Artist takes 84% of your listening'),
      findsOneWidget,
    );
    expect(find.text('1990s · 68%'), findsOneWidget);
    expect(find.text('90s'), findsOneWidget);
    expect(find.text('00s'), findsOneWidget);
    expect(find.text('Sound quality'), findsOneWidget);
    expect(find.text('Hi-Res'), findsOneWidget);
    expect(find.text('68%'), findsOneWidget);
    expect(find.text('FLAC · 73%'), findsOneWidget);
    expect(find.text('Time of day'), findsOneWidget);
    expect(find.text('Night'), findsOneWidget);
    // The locale's own hour, which puts a narrow space before PM.
    expect(
      find.text(DateFormat.j('en').format(DateTime(2024, 1, 1, 23))),
      findsOneWidget,
    );
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('From your last 50 songs.'), findsOneWidget);

    expect(find.text('1,523'), findsOneWidget);
    expect(find.text('Favorite Artists'), findsOneWidget);
    expect(find.text('Share profile'), findsOneWidget);
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
    expect(find.text('Share profile'), findsNothing);
  });

  testWidgets('Share profile opens the card editor', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pump(tester);

    await tester.tap(find.text('Share profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileShareScreen), findsOneWidget);
    final card = tester.widget<ProfileShareCard>(find.byType(ProfileShareCard));
    expect(card.style.parts, ProfileCardStyle.defaultParts);
    // The card carries four traits, the most telling first.
    expect(
      [for (final fact in card.traits) fact.trait],
      [
        ProfileTrait.loyal,
        ProfileTrait.nightOwl,
        ProfileTrait.devotee,
        ProfileTrait.throwback,
      ],
    );
    expect(tester.takeException(), isNull);
  });

  for (final shape in ProfileCardStyle.shapes) {
    testWidgets('the card shows every part and saves (${shape.name})', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final temp = Directory.systemTemp.createTempSync('profile_card_test');
      messenger.setMockMethodCallHandler(paths, (_) async => temp.path);
      addTearDown(() {
        messenger.setMockMethodCallHandler(paths, null);
        temp.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final saved = <(String, int)>[];
      final overview = _overview();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfileShareScreen(
            profile: const UserProfile(name: 'Example: Name'),
            overview: overview,
            traits: profileTraits(overview, rhythm: _rhythm, limit: 4),
            style: ProfileCardStyle(shape: shape),
            saveImage: (name, png) async {
              saved.add((name, png.length));
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sound quality is off at first; turning it on is kept.
      final card = find.byType(ProfileShareCard);
      expect(
        find.descendant(of: card, matching: find.text('Sound quality')),
        findsNothing,
      );
      await tester.ensureVisible(find.text('Sound quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sound quality'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('Sound quality')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Example: Name')),
        findsOneWidget,
      );
      // The leading type is the headline; the others share one line.
      expect(
        find.descendant(of: card, matching: find.text('Loyal fan')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Example Artist takes 84% of your listening'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Night owl · Pop at heart · Throwback lover'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Pop 88%', findRichText: true),
        ),
        findsOneWidget,
      );
      expect((await ProfileCardStyle.load()).parts, {
        ...ProfileCardStyle.defaultParts,
        ProfileCardPart.sound,
      });

      // Without the name the card speaks of the listening.
      await tester.ensureVisible(find.text('Name and photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name and photo'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('My listening')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.runAsync(() async {
        await tester.tap(find.text('Save').hitTestable().first);
        for (var i = 0; i < 40 && saved.isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pump();
      expect(saved, hasLength(1));
      expect(saved.single.$1, 'Example_ Name profile.png');
      expect(saved.single.$2, greaterThan(1000));
      expect(find.text('Profile card saved'), findsOneWidget);
    });
  }

  testWidgets('a wide page keeps every section inside the pane', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1100, 5600));

    expect(find.text('Top albums'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
