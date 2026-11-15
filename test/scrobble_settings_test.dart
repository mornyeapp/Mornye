import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_api.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_service.dart';
import 'package:mornye/services/scrobbling/scrobbler.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/lastfm_settings.dart';
import 'package:mornye/widgets/scrobble_settings.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/lastfm_fakes.dart';
import 'support/scrobble_fakes.dart';

Future<void> _pump(WidgetTester tester, Widget child, {required bool mornye}) =>
    tester.pumpWidget(
      // Mornye sheets read the appearance settings.
      ProviderScope(
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: MornyeSettingsTheme(child: child),
            ),
          ),
        ),
      ),
    );

Future<void> _close(WidgetTester tester, Scrobbler service) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final closing = service.close();
  await tester.pump();
  await closing;
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('ListenBrainz signs in with a pasted token ($mornye)', (
      tester,
    ) async {
      final server = FakeListenBrainzServer();
      final store = MemoryScrobbleStore<ListenBrainzAccount>(enabled: false);
      final service = ListenBrainzService(api: server.api(), store: store);
      final opened = <Uri>[];
      try {
        await _pump(
          tester,
          ListenBrainzSettings(
            service: service,
            openBrowser: (url) async {
              opened.add(url);
              return true;
            },
          ),
          mornye: mornye,
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Track your listening and show what is playing on ListenBrainz.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Connect ListenBrainz'));
        await tester.pumpAndSettle();
        final connect = find.widgetWithText(
          AppDialogAction,
          'Connect ListenBrainz',
        );
        final fields = find.byType(EditableText);
        expect(fields, findsNWidgets(2));
        expect(
          tester.widget<EditableText>(fields.first).obscureText,
          isTrue,
          reason: 'the token is a secret',
        );
        await tester.tap(find.text('Open ListenBrainz settings'));
        expect(opened.single.host, 'listenbrainz.org');

        await tester.enterText(fields.first, 'test-token');
        await tester.enterText(fields.last, 'music.example.test');
        await tester.pump();
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(
          find.text('Enter an address that starts with http:// or https://.'),
          findsOneWidget,
        );
        expect(server.urls, isEmpty);

        await tester.enterText(fields.last, 'http://music.example.test');
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Use an https:// address. Plain http:// works only for a server '
            'on this device or your local network.',
          ),
          findsOneWidget,
        );
        expect(server.urls, isEmpty);

        await tester.enterText(fields.last, 'https://music.example.test');
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(find.byType(EditableText), findsNothing);
        expect(find.text('listener'), findsOneWidget);
        expect(find.text('Server: https://music.example.test'), findsOneWidget);
        expect(store.session?.token, 'test-token');
        final switches = tester
            .widgetList<SettingsSwitchItem>(find.byType(SettingsSwitchItem))
            .map((widget) => widget.title);
        expect(switches, ['Scrobbling', 'Show Now Playing']);
        await tester.tap(find.text('Disconnect ListenBrainz'));
        await tester.pumpAndSettle();
        expect(find.text('Connect ListenBrainz'), findsOneWidget);
        expect(store.session, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, service);
      }
    });

    testWidgets('a refused token is reported ($mornye)', (tester) async {
      final server = FakeListenBrainzServer()..tokenValid = false;
      final service = ListenBrainzService(
        api: server.api(),
        store: MemoryScrobbleStore<ListenBrainzAccount>(),
      );
      try {
        await _pump(
          tester,
          ListenBrainzSettings(service: service),
          mornye: mornye,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Connect ListenBrainz'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText).first, 'test-token');
        await tester.pump();
        await tester.tap(
          find.widgetWithText(AppDialogAction, 'Connect ListenBrainz'),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('This token was not accepted. Check it and try again.'),
          findsOneWidget,
        );
        expect(service.connected, isFalse);
      } finally {
        await _close(tester, service);
      }
    });

    testWidgets('Libre.fm uses the browser approval with its own name '
        '($mornye)', (tester) async {
      final opened = <Uri>[];
      final service = LastfmService(
        api: FakeLastfmApi(),
        store: MemoryLastfmStore()..session = null,
        openBrowser: (url) async {
          opened.add(url);
          return true;
        },
      );
      try {
        await _pump(
          tester,
          LastfmSettings(service: service, serviceName: 'Libre.fm'),
          mornye: mornye,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Last.fm'), findsNothing);
        await tester.tap(find.text('Connect Libre.fm'));
        await tester.pumpAndSettle();
        expect(opened, hasLength(1));
        await tester.tap(find.text('Finish connecting'));
        await tester.pumpAndSettle();
        expect(find.text('listener'), findsOneWidget);
        expect(find.text('Disconnect Libre.fm'), findsOneWidget);
        expect(
          find.text(
            'Send songs you listen to in the built-in player to '
            'Libre.fm.',
          ),
          findsOneWidget,
        );
      } finally {
        await _close(tester, service);
      }
    });
  }
}
