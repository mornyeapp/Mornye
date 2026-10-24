import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/theme/mornye_theme.dart';

import 'support/sqlite_process_database.dart';

Map<String, Object?> _row(
  String day,
  String key, {
  String artist = 'Artist',
  String album = 'Album',
  int minutes = 10,
  int plays = 1,
}) => {
  'day': day,
  'track_key': key,
  'title': 'Song $key',
  'artist': artist,
  'album': album,
  'artwork': null,
  'milliseconds': minutes * 60000,
  'plays': plays,
};

final _range = ListeningRewindRange.of(
  ListeningRewindPeriod.weeks,
  DateTime(2026, 10, 14, 21),
);

ListeningRewind _sample({Set<String>? newArtists, ListeningReplay? replay}) =>
    ListeningRewind.compute(
      range: _range,
      summary: ListeningSummary.fromRows([
        _row('2026-10-01', 'a', minutes: 30, plays: 3),
        _row('2026-10-02', 'a', minutes: 20, plays: 2),
        _row('2026-10-03', 'b', album: 'ALBUM', minutes: 15),
        _row('2026-10-05', 'c', artist: 'Other', album: 'Else', minutes: 40),
        _row('2026-10-06', 'd', artist: 'Fresh', album: '', minutes: 5),
      ]),
      previousMilliseconds: 100 * 60000,
      newArtistNames: newArtists,
      replay: replay,
    );

final _yearRange = ListeningRewindRange.of(
  ListeningRewindPeriod.year,
  DateTime(2026, 10, 14, 21),
);

ListeningRewind _yearSample() => ListeningRewind.compute(
  range: _yearRange,
  summary: ListeningSummary.fromRows([
    _row('2026-01-02', 'a', minutes: 30, plays: 3),
    _row('2026-01-03', 'b', artist: 'Other', minutes: 20),
    _row('2026-03-10', 'c', artist: 'Third', album: 'Else', minutes: 90),
    _row('2026-10-01', 'a', minutes: 40, plays: 4),
  ]),
  previousMilliseconds: 0,
  year: ListeningYearDetails(
    monthlyTopArtists: const {1: 'Artist', 3: 'Third', 10: 'Artist'},
    loyalArtist: 'Artist',
    loyalArtistDays: 2,
    firstPlay: ListeningFirstPlay(
      const ListeningTrack(
        key: 'a',
        title: 'Song a',
        artist: 'Artist',
        album: 'Album',
      ),
      DateTime(2026, 1, 2),
    ),
  ),
);

void main() {
  group('yearly database aggregates', () {
    late SqliteProcessDatabase db;

    setUp(() async {
      db = await SqliteProcessDatabase.open();
      await db.execute('''
        CREATE TABLE listening (
          day TEXT, track_key TEXT, title TEXT, artist TEXT, album TEXT,
          artwork TEXT, milliseconds INTEGER, plays INTEGER,
          PRIMARY KEY(day, track_key)
        )
      ''');
    });
    tearDown(() async => db.close());

    test(
      'yearly highlights exclude unplayed rows and out-of-window history',
      () async {
        final rows = [
          _row('2025-12-31', 'old', minutes: 1000, plays: 50),
          _row('2026-01-01', 'empty-day', minutes: 0, plays: 99),
          _row('2026-01-02', 'unplayed', minutes: 0, plays: 99),
          _row('2026-01-02', 'first', minutes: 1, plays: 2),
          _row('2026-01-02', 'longer', artist: 'Other', minutes: 5),
          _row('2026-03-10', 'third', artist: 'Third', minutes: 6),
          _row('2026-10-01', 'first', minutes: 1),
          _row('2026-10-15', 'future', minutes: 1000, plays: 50),
        ];
        for (final row in rows) {
          await db.rawInsert(
            'INSERT INTO listening '
            '(day, track_key, title, artist, album, artwork, milliseconds, plays) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [
              row['day'],
              row['track_key'],
              row['title'],
              row['artist'],
              row['album'],
              row['artwork'],
              row['milliseconds'],
              row['plays'],
            ],
          );
        }
        final rewind = await readListeningRewind(db, _yearRange, yearly: true);
        expect(rewind.year?.monthlyTopArtists, {
          1: 'Other',
          3: 'Third',
          10: 'Artist',
        });
        expect(rewind.year?.loyalArtist, 'Artist');
        expect(rewind.year?.loyalArtistDays, 2);
        expect(rewind.year?.firstPlay?.track.key, 'first');
        expect(rewind.year?.firstPlay?.day, DateTime(2026, 1, 2));
        expect(rewind.activeDays, 3);
        expect(rewind.activeDayShare, 1);
        expect(rewind.monthlyMilliseconds, {
          1: 6 * 60000,
          3: 6 * 60000,
          10: 60000,
        });
      },
    );

    test('empty history has no invented yearly highlights', () async {
      final rewind = await readListeningRewind(db, _yearRange, yearly: true);
      expect(rewind.isEmpty, isTrue);
      expect(rewind.year?.monthlyTopArtists, isEmpty);
      expect(rewind.year?.loyalArtist, isNull);
      expect(rewind.year?.firstPlay, isNull);
      expect(rewind.activeDays, 0);
    });

    test(
      'yearly artist rankings merge collaborations and count distinct days',
      () async {
        final rows = [
          _row('2026-01-02', 'ab', artist: 'Artist A, Artist B', minutes: 3),
          _row('2026-01-02', 'ac', artist: 'Artist A; Artist C', minutes: 4),
          _row('2026-01-02', 'b', artist: 'Artist B', minutes: 2),
          _row('2026-01-03', 'a', artist: 'Artist A', minutes: 1),
          _row('2026-01-04', 'b', artist: 'Artist B', minutes: 1),
          _row(
            '2026-03-01',
            'cd',
            artist: 'Artist C feat. Artist D',
            minutes: 3,
          ),
          _row('2026-03-01', 'd', artist: 'Artist D', minutes: 4),
        ];
        for (final row in rows) {
          await db.insert('listening', row);
        }
        final rewind = await readListeningRewind(db, _yearRange, yearly: true);
        expect(rewind.year?.monthlyTopArtists, {1: 'Artist A', 3: 'Artist D'});
        expect(rewind.year?.loyalArtist, 'Artist A');
        expect(rewind.year?.loyalArtistDays, 2);
        expect(rewind.summary.milliseconds, 18 * 60000);
        expect(rewind.summary.plays, 7);
        expect(rewind.topArtists.first.key, 'Artist A');
        expect(rewind.topArtistShare, 44);
        // Album and song credits still describe the original full credit.
        expect(rewind.year?.firstPlay?.track.artist, 'Artist A; Artist C');
      },
    );

    test(
      'discoveries use each artist first heard across all credits',
      () async {
        final rows = [
          _row('2026-09-01', 'old-duet', artist: 'Artist A, Artist B'),
          _row('2026-09-02', 'old-solo', artist: 'Artist C'),
          _row('2026-10-01', 'solo', artist: 'Artist B', minutes: 2),
          _row(
            '2026-10-01',
            'new-duet',
            artist: 'Artist C & Artist D',
            minutes: 3,
          ),
          _row('2026-10-02', 'new-solo', artist: 'Artist D', minutes: 1),
          _row('2026-09-01', 'unplayed', artist: 'Artist D', minutes: 0),
          _row('2026-10-15', 'future', artist: 'Artist E'),
        ];
        for (final row in rows) {
          await db.insert('listening', row);
        }
        final rewind = await readListeningRewind(db, _range);
        expect(rewind.newArtists, ['Artist D']);
        expect(rewind.summary.artists, {
          'Artist B': 2 * 60000,
          'Artist C': 3 * 60000,
          'Artist D': 4 * 60000,
        });
        expect(rewind.summary.milliseconds, 6 * 60000);
      },
    );
  });

  test('the Library offers the monthly Rewind one week in four', () {
    ListeningRewindSpotlight? at(int year, int month, int day) =>
        ListeningRewindSpotlight.at(DateTime(year, month, day, 18));
    // Cycles start on Monday 1 January 2024 and repeat every 28 days.
    expect(at(2024, 1, 1), ListeningRewindSpotlight.monthly);
    expect(at(2024, 1, 7), ListeningRewindSpotlight.monthly);
    expect(at(2024, 1, 8), isNull);
    expect(at(2024, 1, 28), isNull);
    expect(at(2024, 1, 29), ListeningRewindSpotlight.monthly);
    // 5 October 2026 starts a cycle; the 15th falls between offers.
    expect(at(2026, 10, 5), ListeningRewindSpotlight.monthly);
    expect(at(2026, 10, 11), ListeningRewindSpotlight.monthly);
    expect(at(2026, 10, 15), isNull);
    expect(at(2026, 11, 2), ListeningRewindSpotlight.monthly);
  });

  test('December offers the year instead of the monthly Rewind', () {
    expect(
      ListeningRewindSpotlight.at(DateTime(2026, 12)),
      ListeningRewindSpotlight.yearly,
    );
    expect(
      ListeningRewindSpotlight.at(DateTime(2026, 12, 31, 23)),
      ListeningRewindSpotlight.yearly,
    );
    expect(ListeningRewindSpotlight.yearly.period, ListeningRewindPeriod.year);
    expect(
      ListeningRewindSpotlight.monthly.period,
      ListeningRewindPeriod.weeks,
    );
  });

  test('a year groups listening by month and counts days with music', () {
    final rewind = _yearSample();
    expect(rewind.monthlyMilliseconds, {
      1: 50 * 60000,
      3: 90 * 60000,
      10: 40 * 60000,
    });
    expect(rewind.biggestMonth, 3);
    // 1 January to 14 October 2026.
    expect(rewind.dayCount, 287);
    // Four days with music out of 287.
    expect(rewind.activeDayShare, 1);
    expect(rewind.year?.loyalArtist, 'Artist');
  });

  test('rolling and yearly windows compare with the span before them', () {
    expect(_range.start, DateTime(2026, 9, 17));
    expect(_range.end, DateTime(2026, 10, 15));
    expect(_range.lastDay, DateTime(2026, 10, 14));
    expect(_range.previousStart, DateTime(2026, 8, 20));
    expect(_range.previousEnd, DateTime(2026, 9, 17));

    final year = ListeningRewindRange.of(
      ListeningRewindPeriod.year,
      DateTime(2026, 10, 14),
    );
    expect(year.start, DateTime(2026));
    expect(year.previousStart, DateTime(2025));
    expect(year.previousEnd, DateTime(2025, 10, 15));
  });

  test('highlights rank artists, merge albums and read listening rhythm', () {
    final rewind = _sample();
    expect(rewind.minutes, 110);
    expect(rewind.changePercent, 10);
    expect(rewind.topArtists.map((e) => e.key), ['Artist', 'Other', 'Fresh']);
    expect(rewind.topArtistShare, 59);
    // Album names match case-insensitively and empty albums are skipped.
    expect(rewind.topAlbums.first.album, 'Album');
    expect(rewind.topAlbums.first.milliseconds, 65 * 60000);
    expect(rewind.topAlbums.length, 2);
    expect(rewind.peakDay, DateTime(2026, 10, 5));
    expect(rewind.peakDayMilliseconds, 40 * 60000);
    // 1–3 October run three days in a row; 5–6 October two.
    expect(rewind.longestStreak, 3);
    expect(rewind.favoriteWeekday, DateTime(2026, 10, 5).weekday);
    // Without earlier history every artist would be new, so none are shown.
    expect(rewind.newArtists, isEmpty);
    expect(rewind.replay, isNull);
  });

  test('discoveries follow listening order and replays need repeats', () {
    const track = ListeningTrack(
      key: 'a',
      title: 'Song a',
      artist: 'Artist',
      album: 'Album',
    );
    final rewind = _sample(
      newArtists: {'Fresh', 'Other', 'Elsewhere'},
      replay: ListeningReplay(track, DateTime(2026, 10, 1), 4),
    );
    expect(rewind.newArtists, ['Other', 'Fresh']);
    expect(rewind.replay?.plays, 4);
    expect(
      _sample(replay: ListeningReplay(track, DateTime(2026, 10, 1), 2)).replay,
      isNull,
    );
    expect(
      ListeningRewind.compute(
        range: _range,
        summary: const ListeningSummary(),
        previousMilliseconds: 0,
      ).changePercent,
      isNull,
    );
  });

  for (final mornye in [false, true]) {
    testWidgets('Rewind story steps through highlights ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            listeningRewindProvider.overrideWith(
              (ref, period) async => _sample(newArtists: {'Fresh'}),
            ),
          ],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            // Reduced motion: no auto-advance, so the story waits for taps.
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const ListeningRewindScreen(
              period: ListeningRewindPeriod.weeks,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your Rewind'), findsOneWidget);
      expect(find.text('Last 4 weeks'), findsOneWidget);

      final story = tester.getRect(find.byType(PageView));
      Future<void> next() async {
        await tester.tapAt(Offset(story.right - 40, story.center.dy));
        await tester.pumpAndSettle();
      }

      await next();
      expect(find.text('110'), findsOneWidget);
      expect(find.text('10% more than the period before'), findsOneWidget);
      await next();
      expect(find.text('Your top artist'), findsOneWidget);
      expect(find.text('65 min · 59% of your listening time'), findsOneWidget);
      await tester.tapAt(Offset(story.left + 20, story.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('110'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a year-end Rewind adds its year-in-review slides', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningRewindProvider.overrideWith(
            (ref, period) async => _yearSample(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const ListeningRewindScreen(period: ListeningRewindPeriod.year),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your 2026 in Music'), findsOneWidget);

    final story = tester.getRect(find.byType(PageView));
    final seen = <String>{};
    const expected = [
      'Your year in numbers',
      'Month by month',
      'Your biggest month was March',
      'Artist of the month',
      'Always by your side',
      'With you on 2 different days',
      'Where your year began',
      'That was your 2026',
    ];
    for (var i = 0; i < 20; i++) {
      for (final text in expected) {
        if (find.text(text).evaluate().isNotEmpty) seen.add(text);
      }
      await tester.tapAt(Offset(story.right - 40, story.center.dy));
      await tester.pumpAndSettle();
    }
    expect(seen, containsAll(expected));
    expect(tester.takeException(), isNull);
  });

  for (final spotlight in ListeningRewindSpotlight.values) {
    testWidgets('the Library banner follows the $spotlight spotlight', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            listeningRewindSpotlightProvider.overrideWith(
              (ref) async => spotlight,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: ListeningRewindBanner()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final year = DateTime.now().year;
      expect(
        find.text('Your $year in Music'),
        spotlight == ListeningRewindSpotlight.yearly
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        find.text('Your last 4 weeks are ready to replay'),
        spotlight == ListeningRewindSpotlight.monthly
            ? findsOneWidget
            : findsNothing,
      );
    });
  }

  testWidgets('months without listening have no activity bars', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningRewindProvider.overrideWith(
            (ref, period) async => _yearSample(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const ListeningRewindScreen(period: ListeningRewindPeriod.year),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final story = tester.getRect(find.byType(PageView));
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(story.right - 40, story.center.dy));
      await tester.pumpAndSettle();
    }
    expect(find.text('Month by month'), findsOneWidget);
    final bars = tester
        .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .where(
          (widget) => widget.heightFactor != null && widget.widthFactor == null,
        );
    expect(bars.length, 12);
    expect(bars.where((widget) => widget.heightFactor == 0).length, 9);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets('yearly slides fit landscape with large text ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(780, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sample = _yearSample();
      final rewind = ListeningRewind.compute(
        range: sample.range,
        summary: sample.summary,
        previousMilliseconds: 0,
        year: ListeningYearDetails(
          monthlyTopArtists: {
            for (var month = 1; month <= 12; month++) month: 'Artist $month',
          },
          loyalArtist: sample.year?.loyalArtist,
          loyalArtistDays: sample.year!.loyalArtistDays,
          firstPlay: sample.year?.firstPlay,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            listeningRewindProvider.overrideWith((ref, period) async => rewind),
          ],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: const TextScaler.linear(1.6),
              ),
              child: child!,
            ),
            home: const ListeningRewindScreen(
              period: ListeningRewindPeriod.year,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final story = tester.getRect(find.byType(PageView));
      for (var i = 0; i < 20; i++) {
        expect(tester.takeException(), isNull);
        await tester.tapAt(Offset(story.right - 40, story.center.dy));
        await tester.pumpAndSettle();
      }
      expect(find.text('That was your 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no spotlight leaves no banner', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningRewindSpotlightProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: ListeningRewindBanner()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Rewind'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('empty windows explain how to fill a Rewind', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningRewindProvider.overrideWith(
            (ref, period) async => ListeningRewind.compute(
              range: _range,
              summary: const ListeningSummary(),
              previousMilliseconds: 0,
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ListeningRewindScreen(period: ListeningRewindPeriod.year),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Not enough listening'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });
}
