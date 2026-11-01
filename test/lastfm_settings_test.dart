import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/lastfm_settings.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/lastfm_fakes.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets(
      'Last.fm account and playback controls follow the selected style ($mornye)',
      (tester) async {
        final store = MemoryLastfmStore()..session = null;
        final api = FakeLastfmApi();
        final opened = <Uri>[];
        final service = LastfmService(
          api: api,
          store: store,
          openBrowser: (url) async {
            opened.add(url);
            return true;
          },
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.dark(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: MornyeSettingsTheme(
                    child: LastfmSettings(service: service),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Connect Last.fm'));
          await tester.pumpAndSettle();
          expect(opened.single.host, 'www.last.fm');
          expect(find.text('Finish connecting'), findsOneWidget);
          await tester.tap(find.text('Finish connecting'));
          await tester.pumpAndSettle();
          expect(find.text('listener'), findsOneWidget);
          expect(find.text('Disconnect Last.fm'), findsOneWidget);
          final switches = tester
              .widgetList<SettingsSwitchItem>(find.byType(SettingsSwitchItem))
              .toList();
          expect(switches.map((widget) => widget.title), [
            'Scrobbling',
            'Show Now Playing',
          ]);
          switches.first.onChanged!(false);
          await tester.pumpAndSettle();
          expect(service.enabled, isFalse);
          await tester.tap(find.text('Disconnect Last.fm'));
          await tester.pumpAndSettle();
          expect(find.text('Connect Last.fm'), findsOneWidget);
          expect(store.session, isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          final closing = service.close();
          await tester.pump();
          await closing;
        }
      },
    );
  }

  testWidgets(
    'unconfigured builds explain availability without exposing developer fields',
    (tester) async {
      final api = FakeLastfmApi(configured: false);
      final service = LastfmService(
        api: api,
        store: MemoryLastfmStore()..session = null,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: LastfmSettings(service: service)),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Last.fm is unavailable in this build.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Connect Last.fm'));
        expect(api.tokenRequests, 0);
        expect(find.byType(TextField), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = service.close();
        await tester.pump();
        await closing;
      }
    },
  );
}
