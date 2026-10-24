import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/link_desktop_settings_page.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_desktop_fakes.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  late FakeLinkBackend backend;

  setUp(() {
    debugDesktopPlatformOverride = true;
    backend = FakeLinkBackend();
  });

  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    bool mornye = false,
    bool enabled = true,
    bool pushed = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      linkDesktopEnabledKey: enabled,
      linkDesktopNameKey: 'Studio',
    });
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          ...linkHostOverrides(backend: backend, player: FakeLinkPlayer()),
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Pushed over a root page, as in the app, so a stray pop shows.
          initialRoute: pushed ? '/link' : '/',
          routes: {
            '/': (_) =>
                pushed ? const SizedBox() : const LinkDesktopSettingsPage(),
            '/link': (_) => const LinkDesktopSettingsPage(),
          },
        ),
      ),
    );
    await settle(tester);
  }

  Finder pin() => find.byKey(const ValueKey('link-pairing-pin'));

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: the switch starts the server and shows its status', (
      tester,
    ) async {
      await pumpPage(tester, mornye: mornye, enabled: false);
      expect(find.text('Share with Mornye on your phone'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('link-enable')),
          matching: find.byType(BetaBadge),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('link-firewall-hint')), findsNothing);
      expect(find.byKey(const ValueKey('link-pair')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('link-enable')));
      await settle(tester);

      expect(backend.calls, contains('start:Studio'));
      expect(find.text('On, no phone connected'), findsOneWidget);
      expect(find.byKey(const ValueKey('link-firewall-hint')), findsOneWidget);
      expect(find.text('https://192.168.1.5:47710'), findsOneWidget);
      expect(find.text('ab12 cd34'), findsOneWidget);
      expect(find.text('0 songs shared'), findsOneWidget);
      expect(find.byKey(const ValueKey('link-pair')), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(linkDesktopEnabledKey), isTrue);

      await tester.tap(find.byKey(const ValueKey('link-enable')));
      await settle(tester);
      expect(backend.calls.last, 'devices');
      expect(backend.calls, contains('stop'));
      expect(find.byKey(const ValueKey('link-pair')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: the pairing dialog closes when a phone pairs', (
      tester,
    ) async {
      await pumpPage(tester, mornye: mornye);
      await tester.tap(find.byKey(const ValueKey('link-pair')));
      await settle(tester);

      expect(backend.calls, contains('beginPairing'));
      expect(pin(), findsOneWidget);
      expect(tester.widget<Text>(pin()).data, '123 456');
      expect(
        find.text('Check that your phone shows security code ab12 cd34.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(RegExp(r'The code expires in [45]:\d\d')),
        findsOneWidget,
      );

      backend.deviceList = [
        const LinkPairedDevice(
          deviceId: 'p1',
          name: 'Pixel',
          platform: 'android',
          connected: true,
        ),
      ];
      backend.pairingEvent(
        const LinkPairedEvent(
          deviceId: 'p1',
          name: 'Pixel',
          platform: 'android',
        ),
      );
      await settle(tester);

      expect(pin(), findsNothing);
      expect(find.text('Paired with Pixel'), findsOneWidget);
      expect(find.byKey(const ValueKey('link-device-p1')), findsOneWidget);
      expect(backend.calls, isNot(contains('endPairing')));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelling the pairing dialog ends the window', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('link-pair')));
    await settle(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(pin(), findsNothing);
    expect(backend.calls, contains('endPairing'));
  });

  testWidgets('the end event after cancelling does not pop the page', (
    tester,
  ) async {
    await pumpPage(tester, pushed: true);
    await tester.tap(find.byKey(const ValueKey('link-pair')));
    await settle(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    // The server reports the cancelled window while the dialog animates out.
    backend.pairingEvent(
      const LinkPairingEndedEvent(LinkPairingEndReason.cancelled),
    );
    await settle(tester);
    expect(pin(), findsNothing);
    expect(find.byType(LinkDesktopSettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an expired or exhausted window is reported', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('link-pair')));
    await settle(tester);
    backend.pairingEvent(
      const LinkPairingEndedEvent(LinkPairingEndReason.expired),
    );
    await settle(tester);
    expect(pin(), findsNothing);
    expect(
      find.text('The code expired. Pair again to get a new one.'),
      findsOneWidget,
    );
    // Let the first message time out; the test app queues snackbars.
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('link-pair')));
    await settle(tester);
    backend.pairingEvent(
      const LinkPairingEndedEvent(LinkPairingEndReason.attempts),
    );
    await settle(tester);
    expect(
      find.text('Too many wrong codes. Pair again to get a new one.'),
      findsOneWidget,
    );
  });

  testWidgets('the countdown closes the dialog when the code expires', (
    tester,
  ) async {
    backend.pairingWindow = LinkPairingWindow(
      pin: '654321',
      expiresMs: DateTime.now().millisecondsSinceEpoch + 2500,
      fingerprint: fakeFingerprint,
    );
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('link-pair')));
    await settle(tester);
    expect(pin(), findsOneWidget);
    // The countdown reads the wall clock; let it pass the expiry.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2600)),
    );
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(pin(), findsNothing);
    expect(
      find.text('The code expired. Pair again to get a new one.'),
      findsOneWidget,
    );
  });

  testWidgets('removing a device asks first', (tester) async {
    backend.deviceList = [
      const LinkPairedDevice(
        deviceId: 'p1',
        name: 'Pixel',
        platform: 'android',
        connected: true,
      ),
      const LinkPairedDevice(
        deviceId: 'app1',
        name: 'Desk player',
        platform: 'subsonic',
        lastSeenMs: 1700000000000,
      ),
    ];
    await pumpPage(tester);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.textContaining('Subsonic app · Last seen'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('link-revoke-p1')));
    await settle(tester);
    expect(find.text('Remove Pixel?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(backend.calls, isNot(contains('revoke:p1')));

    await tester.tap(find.byKey(const ValueKey('link-revoke-p1')));
    await settle(tester);
    await tester.tap(find.text('Remove').last);
    await settle(tester);
    expect(backend.calls, contains('revoke:p1'));
    expect(find.byKey(const ValueKey('link-device-p1')), findsNothing);
    expect(find.text('Pixel removed'), findsOneWidget);
    expect(find.text('No phones paired yet'), findsOneWidget);
  });

  testWidgets('paired devices stay listed while the server is off', (
    tester,
  ) async {
    backend.deviceList = [
      const LinkPairedDevice(deviceId: 'p1', name: 'Pixel', platform: 'ios'),
    ];
    await pumpPage(tester, enabled: false);
    expect(find.byKey(const ValueKey('link-device-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('link-pair')), findsNothing);
    expect(find.byKey(const ValueKey('link-add-app')), findsNothing);
  });

  testWidgets('adds a Subsonic app and shows its key to copy', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('link-add-app')));
    await settle(tester);
    await tester.enterText(find.byType(EditableText), 'Desk player');
    await tester.pump();
    await tester.tap(find.text('Create key'));
    await settle(tester);

    expect(backend.calls, contains('createKey:Desk player'));
    expect(find.text('Connect Desk player'), findsOneWidget);
    expect(find.text('secret-key-1'), findsOneWidget);
    expect(find.text('mornye'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy Password or API key'));
    await settle(tester);
    expect(copied, ['secret-key-1']);
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });
}
