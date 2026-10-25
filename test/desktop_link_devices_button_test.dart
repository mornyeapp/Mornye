import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_button.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_desktop_fakes.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

const _phone = LinkClientInfo(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);

void main() {
  late FakeLinkBackend backend;
  late FakeLinkPlayer player;

  setUp(() {
    debugDesktopPlatformOverride = true;
    backend = FakeLinkBackend();
    player = FakeLinkPlayer()
      ..current = LinkPlayerSnapshot(
        queue: [playerItem('a'), playerItem('b')],
        index: 1,
        positionMs: 12000,
        updatedMs: 0,
      );
  });

  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder button() => find.byKey(const ValueKey('desktop-link-devices-button'));

  Future<void> pumpButton(
    WidgetTester tester, {
    bool mornye = false,
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      linkDesktopEnabledKey: enabled,
      linkDesktopNameKey: 'Studio',
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          ...linkHostOverrides(backend: backend, player: player),
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: DesktopLinkDevicesButton(),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> connectPhone(WidgetTester tester, {bool playing = true}) async {
    backend.connect([_phone]);
    await settle(tester);
    backend.message('p1', {
      'type': LinkMessageTypes.playerState,
      'state': LinkPlayerState(
        track: const TrackRef(
          title: 'Phone song',
          artist: 'Phone artist',
          durationMs: 200000,
        ),
        playing: playing,
        positionMs: 30000,
        durationMs: 200000,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    });
    await settle(tester);
  }

  Map<String, dynamic> lastCommand() => backend.sent
      .lastWhere((entry) => entry.message['type'] == LinkMessageTypes.command)
      .message;

  testWidgets('hidden while the server is off or no phone is connected', (
    tester,
  ) async {
    await pumpButton(tester, enabled: false);
    expect(button(), findsNothing);
    backend.connect([_phone]);
    await settle(tester);
    expect(button(), findsNothing);
  });

  testWidgets('appears with a phone and disappears when it leaves', (
    tester,
  ) async {
    await pumpButton(tester);
    expect(button(), findsNothing);
    await connectPhone(tester);
    expect(button(), findsOneWidget);
    backend.connect(const []);
    await settle(tester);
    expect(button(), findsNothing);
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: shows what the phone plays and sends commands', (
      tester,
    ) async {
      await pumpButton(tester, mornye: mornye);
      await connectPhone(tester);
      await tester.tap(button());
      await settle(tester);

      expect(
        find.byKey(const ValueKey('desktop-link-devices-popover')),
        findsOneWidget,
      );
      expect(find.text('Pixel'), findsOneWidget);
      expect(find.text('Phone song'), findsOneWidget);
      expect(find.text('Phone artist'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('link-phone-next')));
      await tester.pump();
      expect(backend.sent.last.deviceId, 'p1');
      expect(lastCommand(), {
        'type': 'command',
        'action': 'next',
        'args': <String, dynamic>{},
      });

      await tester.tap(find.byKey(const ValueKey('link-phone-previous')));
      await tester.pump();
      expect(lastCommand()['action'], 'previous');

      await tester.tap(find.byKey(const ValueKey('link-phone-play-pause')));
      await tester.pump();
      expect(lastCommand()['action'], 'pause');

      tester
          .widget<AppSlider>(find.byKey(const ValueKey('link-phone-seek')))
          .onChangeEnd!(0.25);
      await tester.pump();
      expect(lastCommand(), {
        'type': 'command',
        'action': 'seek',
        'args': {'positionMs': 50000},
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a paused phone gets play', (tester) async {
    await pumpButton(tester);
    await connectPhone(tester, playing: false);
    await tester.tap(button());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('link-phone-play-pause')));
    await tester.pump();
    expect(lastCommand()['action'], 'play');
  });

  testWidgets('no continue once the music plays on the phone', (tester) async {
    // The desktop holds a paused song, as after Continue on phone.
    await pumpButton(tester);
    await connectPhone(tester);
    await tester.tap(button());
    await settle(tester);
    expect(find.byKey(const ValueKey('link-phone-continue')), findsNothing);
    expect(find.byKey(const ValueKey('link-phone-open')), findsOneWidget);

    backend.message('p1', {
      'type': LinkMessageTypes.playerState,
      'state': LinkPlayerState(
        playing: false,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    });
    await settle(tester);
    expect(find.byKey(const ValueKey('link-phone-continue')), findsOneWidget);
  });

  testWidgets('continue on phone hands off the queue and pauses here', (
    tester,
  ) async {
    await pumpButton(tester);
    await connectPhone(tester, playing: false);
    await tester.tap(button());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('link-phone-continue')));
    await settle(tester);

    final command = lastCommand();
    expect(command['action'], LinkActions.playQueue);
    final args = command['args'] as Map<String, dynamic>;
    expect(args['index'], 1);
    expect(args['positionMs'], 12000);
    expect(args['playing'], isTrue);
    expect((args['queue'] as List).map((ref) => (ref as Map)['title']), [
      'Title a',
      'Title b',
    ]);
    expect(player.calls, ['pause']);
    expect(find.text('Sent to Pixel'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-link-devices-popover')),
      findsNothing,
    );
  });

  testWidgets('opens a link on the phone, prefilled from the clipboard', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {'text': 'https://example.com/album/9'}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpButton(tester);
    await connectPhone(tester);
    await tester.tap(button());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('link-phone-open')));
    await settle(tester);

    expect(find.text('Open a link on Pixel'), findsOneWidget);
    expect(find.text('https://example.com/album/9'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await settle(tester);

    final open = backend.sentOfType(LinkMessageTypes.open).single;
    expect(open, {'type': 'open', 'url': 'https://example.com/album/9'});
    expect(backend.sent.last.deviceId, 'p1');
    expect(find.text('Sent to Pixel'), findsOneWidget);
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: rings while songs transfer and opens Transfers', (
      tester,
    ) async {
      final ring = find.byKey(const ValueKey('desktop-link-transfers-ring'));
      final entry = find.byKey(const ValueKey('link-transfers-entry'));
      await pumpButton(tester, mornye: mornye);
      await connectPhone(tester);
      final size = tester.getSize(button());
      expect(ring, findsNothing);
      await tester.tap(button());
      await settle(tester);
      // No entry until a transfer exists.
      expect(entry, findsNothing);

      final store = ProviderScope.containerOf(
        tester.element(button()),
      ).read(linkTransfersProvider.notifier);
      final status = LinkTransferStatus(
        transferId: List.filled(32, 'a').join(),
        state: LinkTransferState.running,
        total: 4,
        index: 1,
      );
      store.add(
        LinkTransfer(
          direction: LinkTransferDirection.incoming,
          peerId: 'p1',
          peerName: 'Pixel',
          entries: [
            for (var i = 0; i < 4; i++)
              LinkTransferEntry(title: 'Song $i', artist: 'Artist'),
          ],
          status: status,
          startedAt: DateTime(2026),
        ),
      );
      await settle(tester);
      expect(ring, findsOneWidget);
      // The ring sits outside the glyph, so the player bar keeps its layout.
      expect(tester.getSize(button()), size);
      expect(entry, findsOneWidget);
      expect(find.text('Receiving 4 songs from Pixel · 25%'), findsOneWidget);

      store.update(status.copyWith(state: LinkTransferState.done, index: 4));
      await settle(tester);
      expect(ring, findsNothing);
      expect(find.text('1 transfer finished'), findsOneWidget);

      await tester.tap(entry);
      await settle(tester);
      expect(
        find.byKey(const ValueKey('desktop-link-devices-popover')),
        findsNothing,
      );
      expect(find.byType(LinkTransfersDialog), findsOneWidget);
      expect(find.text('4 songs from Pixel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
