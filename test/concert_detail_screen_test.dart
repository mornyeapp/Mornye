import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/screens/artist_concerts_screen.dart';
import 'package:mornye/screens/concert_detail_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';

import 'support/tooltip_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const calendar = MethodChannel('com.zarz.mornye/concert_calendar');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  ArtistConcert event(String id, {bool details = true}) =>
      ArtistConcert.parseList([
        {
          'id': id,
          'location': 'Example City',
          'venue': 'Example Hall',
          'start_at': '2026-10-07T01:00:00Z',
          'time_zone': 'America/New_York',
          if (details) 'detail_id': id,
          'url': 'https://example.com/events/1',
        },
      ]).single;

  Widget app(Widget home, {Brightness brightness = Brightness.light}) =>
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(brightness),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(calendar, null);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'schedule follows $brightness and a row opens an internal dark detail',
      (tester) async {
        await tester.pumpWidget(
          app(
            ArtistConcertsScreen(
              artistName: 'Example Artist',
              concerts: [event('basic-${brightness.name}', details: false)],
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          Theme.of(
            tester.element(find.text('All Upcoming Concerts')),
          ).brightness,
          brightness,
        );
        await tester.tap(find.text('Example City'));
        await tester.pumpAndSettle();
        expect(find.byType(ConcertDetailScreen), findsOneWidget);
        expect(
          Theme.of(tester.element(find.text('Example Artist').last)).brightness,
          Brightness.dark,
        );
        expect(find.textContaining('21:00'), findsOneWidget);
        expect(find.text('Get Tickets'), findsNothing);
        await tester.tap(findByTooltip('Back').last);
        await tester.pumpAndSettle();
        expect(find.byType(ConcertDetailScreen), findsNothing);
      },
    );
  }

  testWidgets(
    'details load on demand with skeleton, retry and calendar action',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<Object?>();
      var requests = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'getProviderMetadata') return null;
        expect(call.arguments, containsPair('resource_type', 'concert'));
        expect(call.arguments, containsPair('provider_id', 'example.metadata'));
        requests++;
        if (requests == 1) return pending.future;
        return {
          'concert': {
            'id': 'load',
            'address': '123 Example Street',
            'start_at': '2026-10-07T01:00:00Z',
            'end_at': '2026-10-07T04:00:00Z',
            'ticket_url': 'https://example.com/tickets/1',
            'set_list': {'id': 'list-1', 'name': 'Example Set List'},
          },
        };
      });
      final calendarCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(calendar, (call) async {
        calendarCalls.add(call);
        return true;
      });
      await tester.pumpWidget(
        app(
          ConcertDetailScreen(
            artistName: 'Example Artist',
            providerId: 'example.metadata',
            concert: event('load'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ShimmerLoading), findsOneWidget);
      pending.completeError(PlatformException(code: 'offline'));
      await tester.pumpAndSettle();
      expect(
        find.text('Concert details are currently unavailable.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Get Tickets'), findsOneWidget);
      expect(find.text('Example Set List'), findsOneWidget);
      expect(find.text('123 Example Street'), findsOneWidget);
      await tester.tap(findByTooltip('Add to Calendar'));
      await tester.pumpAndSettle();
      expect(
        calendarCalls.single.arguments,
        containsPair(
          'start',
          DateTime.utc(2026, 10, 7, 1).millisecondsSinceEpoch,
        ),
      );
      expect(
        calendarCalls.single.arguments,
        containsPair(
          'end',
          DateTime.utc(2026, 10, 7, 4).millisecondsSinceEpoch,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  test(
    'optional fields and unsafe links cannot create bogus detail actions',
    () {
      final detail = ConcertDetail.fromJson({
        'ticket_url': 'javascript:alert(1)',
        'map_url': 'file:///private',
        'set_list': <Object?>[],
        'start_at': 'bad date',
        'artist_name': 42,
      });
      expect(detail.ticketUrl, isNull);
      expect(detail.mapUrl, isNull);
      expect(detail.start, isNull);
      expect(detail.setListId, isNull);
      expect(detail.artistName, isNull);
    },
  );
}
