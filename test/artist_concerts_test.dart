import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/screens/artist_concerts_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/artist_concerts_button.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

import 'support/tooltip_finder.dart';

Map<String, dynamic> event({
  String id = 'event-1',
  String date = '2026-10-07T01:00:00Z',
  String zone = 'America/New_York',
}) => {
  'id': id,
  'location': 'Example City, Region',
  'venue': 'Example Hall',
  'start_at': date,
  'time_zone': zone,
  'url': 'https://example.com/events/$id',
};

Widget app(Widget child, {bool mornye = true, String language = 'en'}) =>
    ProviderScope(
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
        locale: Locale(language),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
  });
  test('venue dates cross UTC midnight and follow daylight saving time', () {
    final summer = ArtistConcert.parseList([event()]).single;
    expect(summer.date.day, 6);
    expect(summer.date.hour, 21);
    final winter = ArtistConcert.parseList([
      event(date: '2026-12-07T01:00:00Z'),
    ]).single;
    expect(winter.date.day, 6);
    expect(winter.date.hour, 20);
  });

  test('date-only and explicit-offset events retain their calendar fields', () {
    for (final zone in ['', 'Unknown/Zone']) {
      final concert = ArtistConcert.parseList([
        event(date: '2026-10-06T21:00:00-04:00', zone: zone),
      ]).single;
      expect(concert.date.day, 6);
      expect(concert.date.hour, 21);
    }
    final dateOnly = ArtistConcert.parseList([
      event(date: '2026-10-06'),
    ]).single;
    expect(dateOnly.hasTime, isFalse);
    expect(dateOnly.date.day, 6);
  });

  test('invalid optional metadata is ignored without losing valid events', () {
    expect(ArtistConcert.parseList(null), isEmpty);
    expect(ArtistConcert.parseList({'unexpected': true}), isEmpty);
    final concerts = ArtistConcert.parseList([
      null,
      'bad',
      event(date: '2026-02-30'),
      event(date: '2026-10-06T25:00'),
      event(date: 'unknown'),
      {...event(), 'location': 5},
      {...event(), 'url': 'javascript:alert(1)'},
    ]);
    expect(concerts, hasLength(1));
    expect(concerts.single.url, isNull);
  });

  test('events are ordered, deduplicated, and bounded', () {
    final concerts = ArtistConcert.parseList([
      event(),
      event(),
      event(id: 'early', date: '2026-10-01'),
      {...event(id: ''), 'venue': ''},
      {...event(id: ''), 'venue': ''},
    ]);
    expect(concerts, hasLength(3));
    expect(concerts.first.id, 'early');
    expect(
      ArtistConcert.parseList(List.generate(600, (i) => event(id: '$i'))),
      hasLength(500),
    );
  });

  for (final mornye in [true, false]) {
    testWidgets(
      'concert badge opens a generic schedule and back restores artist ($mornye)',
      (tester) async {
        final concerts = ArtistConcert.parseList([event()]);
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Center(
                child: ArtistConcertsButton(
                  artistName: 'Example Artist',
                  concerts: concerts,
                ),
              ),
            ),
            mornye: mornye,
          ),
        );
        await tester.tap(find.text('Upcoming Concerts'));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistConcertsScreen), findsOneWidget);
        expect(find.text('Example Artist'), findsOneWidget);
        expect(find.text('All Upcoming Concerts'), findsOneWidget);
        expect(find.text('Example City, Region'), findsOneWidget);
        expect(find.text('6'), findsOneWidget);
        expect(find.textContaining('21:00'), findsOneWidget);
        await tester.tap(findByTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistConcertsScreen), findsNothing);
        expect(find.byType(ArtistConcertsButton), findsOneWidget);
      },
    );
  }

  testWidgets('artist without concerts has no badge', (tester) async {
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: ArtistConcertsButton(
            artistName: 'Example Artist',
            concerts: [],
          ),
        ),
      ),
    );
    expect(find.text('Upcoming Concerts'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets(
    'badge stays above artist identity without pushing actions down',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget header(bool showBadge) => app(
        Scaffold(
          body: CustomScrollView(
            slivers: [
              MornyeArtistHeader(
                name: 'Example Artist',
                artwork: const SizedBox.expand(),
                showTitle: false,
                badge: showBadge
                    ? ArtistConcertsButton(
                        artistName: 'Example Artist',
                        concerts: ArtistConcert.parseList([event()]),
                      )
                    : null,
                actions: const [
                  SizedBox.square(
                    dimension: 74,
                    key: ValueKey('artist-action'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(header(false));
      final actionY = tester
          .getTopLeft(find.byKey(const ValueKey('artist-action')))
          .dy;
      await tester.pumpWidget(header(true));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('artist-action'))).dy,
        actionY,
      );
      expect(
        tester.getBottomLeft(find.byType(ArtistConcertsButton)).dy,
        lessThan(
          tester
              .getTopLeft(
                find.descendant(
                  of: find.byType(FlexibleSpaceBar),
                  matching: find.text('Example Artist'),
                ),
              )
              .dy,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'localized schedule supports large text and clears shell controls',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                padding: const EdgeInsets.only(bottom: 140),
              ),
              child: ArtistConcertsScreen(
                artistName: 'Example Artist With a Long Name',
                concerts: ArtistConcert.parseList([event()]),
              ),
            ),
          ),
          language: 'id',
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(find.text('Semua Konser Mendatang'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Example City, Region'), 200);
      await tester.scrollUntilVisible(find.textContaining('21.00'), 150);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('Example City, Region'), findsOneWidget);
      expect(
        tester.getBottomLeft(find.textContaining('21.00')).dy,
        lessThanOrEqualTo(600),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
