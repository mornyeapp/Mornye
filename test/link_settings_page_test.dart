import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/link_pairing_dialogs.dart';
import 'package:mornye/screens/settings/link_settings_page.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_client_fakes.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

Widget _app(Widget home, {bool mornye = false}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: mornye ? MornyeTheme.build(Brightness.light) : null,
  home: home,
);

/// Opens [dialog] from a button and keeps what it popped in [results]. The
/// Mornye dialog chrome reads providers, hence the scope.
Widget _dialogHost(
  Widget dialog,
  List<Object?> results, {
  bool mornye = false,
}) => ProviderScope(
  child: _app(
    mornye: mornye,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async => results.add(
              await showAppDialog<Object?>(
                context: context,
                builder: (_) => dialog,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  // Spinners never settle; pump past the dialog and snack bar transitions.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('PIN dialog', () {
    for (final mornye in [false, true]) {
      final style = mornye ? 'Mornye' : 'Material';

      testWidgets('$style: enables Pair at six digits and shows errors', (
        tester,
      ) async {
        final pins = <String>[];
        final answers = [LinkPairingError.badPin, null];
        final results = <Object?>[];
        await tester.pumpWidget(
          _dialogHost(
            LinkPinDialog(
              serverName: 'Studio PC',
              shortFingerprint: 'ab12cd34',
              pairingOpen: true,
              onSubmit: (pin) async {
                pins.add(pin);
                return answers.removeAt(0);
              },
            ),
            results,
            mornye: mornye,
          ),
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        expect(find.text(_l10n.linkPinTitle('Studio PC')), findsOneWidget);
        expect(find.text(_l10n.linkPinCode('ab12cd34')), findsOneWidget);
        expect(find.text(_l10n.linkPinNotOpen), findsNothing);

        final field = find.byKey(LinkPinDialog.fieldKey);
        await tester.enterText(field, 'ab12');
        await tester.pump();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          '12',
        );
        await tester.tap(find.text(_l10n.linkPair));
        await tester.pump();
        expect(pins, isEmpty);

        await tester.enterText(field, '1234567');
        await tester.pump();
        await tester.tap(find.text(_l10n.linkPair));
        await _settle(tester);
        expect(pins, ['123456']);
        expect(find.text(_l10n.linkErrorBadPin), findsOneWidget);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          isEmpty,
        );

        await tester.enterText(field, '654321');
        await tester.pump();
        await tester.tap(find.text(_l10n.linkPair));
        await _settle(tester);
        expect(pins, ['123456', '654321']);
        expect(results, [true]);
        expect(find.byType(LinkPinDialog), findsNothing);
      });
    }

    testWidgets('says when the computer is not ready to pair', (tester) async {
      final results = <Object?>[];
      await tester.pumpWidget(
        _dialogHost(
          LinkPinDialog(
            serverName: 'Studio PC',
            shortFingerprint: 'ab12cd34',
            pairingOpen: false,
            onSubmit: (_) async => LinkPairingError.pairingClosed,
          ),
          results,
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.text(_l10n.linkPinNotOpen), findsOneWidget);
      await tester.enterText(find.byKey(LinkPinDialog.fieldKey), '123456');
      await tester.pump();
      await tester.tap(find.text(_l10n.linkPair));
      await _settle(tester);
      expect(find.text(_l10n.linkErrorPairingClosed), findsOneWidget);
      await tester.tap(find.text(_l10n.dialogCancel));
      await _settle(tester);
      expect(results, [false]);
    });

    test('every pairing error has its own message', () {
      final messages = {
        for (final error in LinkPairingError.values)
          error: linkPairingErrorMessage(_l10n, error),
      };
      expect(messages.values.every((m) => m.isNotEmpty), isTrue);
      expect(
        messages.values.toSet(),
        hasLength(LinkPairingError.values.length),
      );
      expect(
        messages[LinkPairingError.tooManyAttempts],
        _l10n.linkErrorTooManyAttempts,
      );
      expect(
        messages[LinkPairingError.certificateMismatch],
        _l10n.linkErrorCertificate,
      );
    });
  });

  group('manual address', () {
    test('accepts hosts, host:port, URLs and IPv6', () {
      expect(linkParseManualAddress(' 192.168.1.20 ', '47710'), (
        host: '192.168.1.20',
        port: 47710,
      ));
      expect(linkParseManualAddress('studio.local:5000', '47710'), (
        host: 'studio.local',
        port: 5000,
      ));
      expect(linkParseManualAddress('https://10.0.0.2:47711/mornye', '1'), (
        host: '10.0.0.2',
        port: 47711,
      ));
      expect(linkParseManualAddress('[fe80::2]:47712', '1'), (
        host: 'fe80::2',
        port: 47712,
      ));
      expect(linkParseManualAddress('fe80::2', '47710'), (
        host: 'fe80::2',
        port: 47710,
      ));
    });

    test('refuses what is not an address', () {
      for (final (host, port) in [
        ('', '47710'),
        ('10.0.0.2', ''),
        ('10.0.0.2', '0'),
        ('10.0.0.2', '70000'),
        ('my computer', '47710'),
        ('user@10.0.0.2', '47710'),
        ('not:an:address', '47710'),
      ]) {
        expect(linkParseManualAddress(host, port), isNull, reason: host);
      }
    });

    for (final mornye in [false, true]) {
      testWidgets('${mornye ? 'Mornye' : 'Material'}: dialog checks input', (
        tester,
      ) async {
        final results = <Object?>[];
        await tester.pumpWidget(
          _dialogHost(const LinkManualAddDialog(), results, mornye: mornye),
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        await tester.enterText(
          find.byKey(LinkManualAddDialog.hostKey),
          'my computer',
        );
        await tester.tap(find.text(_l10n.linkContinue));
        await tester.pump();
        expect(find.text(_l10n.linkErrorInvalidAddress), findsOneWidget);

        await tester.enterText(
          find.byKey(LinkManualAddDialog.hostKey),
          '10.0.0.5:5000',
        );
        await tester.tap(find.text(_l10n.linkContinue));
        await _settle(tester);
        expect(results, [(host: '10.0.0.5', port: 5000)]);
      });
    }
  });

  group('page', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<LinkClientHarness> pumpPage(
      WidgetTester tester, {
      bool mornye = false,
      bool localNetworkAllowed = true,
      bool onWifi = true,
    }) async {
      final harness = LinkClientHarness()
        ..localNetworkAllowed = localNetworkAllowed
        ..onWifi = onWifi;
      await tester.pumpWidget(
        ProviderScope(
          overrides: harness.overrides,
          child: _app(const LinkSettingsPage(), mornye: mornye),
        ),
      );
      await _settle(tester);
      return harness;
    }

    for (final mornye in [false, true]) {
      testWidgets(
        '${mornye ? 'Mornye' : 'Material'}: pairs a nearby computer',
        (tester) async {
          final harness = await pumpPage(tester, mornye: mornye);
          expect(find.text(_l10n.linkSearching), findsOneWidget);
          expect(harness.browser.started, 1);
          harness.pairing.targets['10.0.0.3'] = linkTestTarget(
            'b',
            host: '10.0.0.3',
          );
          harness.browser.resolve('b', '10.0.0.3');
          await _settle(tester);
          expect(find.text('Desktop b'), findsOneWidget);

          await tester.tap(find.text('Desktop b'));
          await _settle(tester);
          expect(
            harness.pairing.probes.single.expectedFingerprint,
            linkTestFingerprint('b'),
          );
          await tester.enterText(find.byKey(LinkPinDialog.fieldKey), '123456');
          await tester.pump();
          await tester.tap(find.text(_l10n.linkPair));
          await _settle(tester);
          expect(harness.pairing.pins, ['123456']);
          expect(find.byType(LinkPinDialog), findsNothing);
          expect(find.text(_l10n.linkPaired('Desktop b')), findsOneWidget);
          expect(find.text(_l10n.linkPairedSection), findsOneWidget);
          expect(harness.sessions.single.server.serverId, 'b');

          // What this phone does with the computer shows once paired.
          expect(find.text(_l10n.linkPhoneSection), findsOneWidget);
          expect(find.text(_l10n.linkShareSongsTitle), findsOneWidget);
          final follow = find.text(_l10n.linkFollowDesktopTitle);
          await tester.ensureVisible(follow);
          await tester.tap(follow);
          await _settle(tester);
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getBool(LinkPhoneOptionsNotifier.followDesktopKey),
            isFalse,
          );

          // Leaving the page stops discovery.
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        },
      );
    }

    testWidgets('warns when the certificate does not match', (tester) async {
      final harness = await pumpPage(tester);
      harness.pairing.probeError = LinkPairingError.certificateMismatch;
      harness.browser.resolve('b', '10.0.0.3');
      await _settle(tester);
      await tester.tap(find.text('Desktop b'));
      await _settle(tester);
      expect(find.text(_l10n.linkErrorCertificateTitle), findsOneWidget);
      expect(find.text(_l10n.linkErrorCertificate), findsOneWidget);
      expect(find.byType(LinkPinDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('asks for local network access', (tester) async {
      final harness = await pumpPage(tester, localNetworkAllowed: false);
      expect(find.text(_l10n.linkLocalNetworkTitle), findsOneWidget);
      expect(harness.browser.started, 0);

      await tester.tap(find.text(_l10n.linkLocalNetworkAllow));
      await _settle(tester);
      expect(find.text(_l10n.networkErrorLocalPermission), findsOneWidget);

      harness.localNetworkAllowed = true;
      await tester.tap(find.text(_l10n.linkLocalNetworkAllow));
      await _settle(tester);
      expect(harness.browser.started, 1);
      expect(find.text(_l10n.linkLocalNetworkTitle), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('says when Wi-Fi is off', (tester) async {
      await pumpPage(tester, onWifi: false);
      expect(find.text(_l10n.linkWifiOffTitle), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
