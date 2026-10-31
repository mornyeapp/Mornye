import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_phone_playback.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_button.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';
import 'package:mornye/widgets/settings_group.dart';
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
  Finder sheet() => find.byKey(const ValueKey('desktop-link-devices-sheet'));
  Finder phone() => find.byKey(const ValueKey('link-device-phone-p1'));

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
          activeRemotePlaybackProvider.overrideWith(
            (ref) => ref.watch(linkFollowedPhonePlaybackProvider),
          ),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [LinkPlayingOnLabel(), DesktopLinkDevicesButton()],
              ),
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });
    await settle(tester);
  }

  Future<void> connectPhone(WidgetTester tester, {bool playing = false}) async {
    backend.connect([_phone]);
    await settle(tester);
    backend.message('p1', {
      'type': LinkMessageTypes.playerState,
      'state': LinkPlayerState(
        track: const TrackRef(title: 'Phone song', artist: 'Phone artist'),
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

  testWidgets('hidden while server is off or no phone has connected', (
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

    testWidgets('$style: device choices replace the phone command menu', (
      tester,
    ) async {
      await pumpButton(tester, mornye: mornye);
      await connectPhone(tester);
      await tester.tap(button());
      await settle(tester);
      expect(sheet(), findsOneWidget);
      expect(find.text('This computer'), findsOneWidget);
      expect(find.text('Pixel'), findsOneWidget);
      expect(find.text('File changes'), findsOneWidget);
      expect(tester.widget<SettingsItem>(phone()).selected, isFalse);
      expect(find.text('Open link'), findsNothing);
      expect(find.byKey(const ValueKey('link-phone-seek')), findsNothing);

      await tester.tap(phone());
      await settle(tester);
      expect(sheet(), findsNothing);
      expect(find.text('Playing on Pixel'), findsOneWidget);
      final args = lastCommand()['args'] as Map<String, dynamic>;
      expect(lastCommand()['action'], LinkActions.playQueue);
      expect(args['index'], 1);
      expect(args['positionMs'], 12000);
      expect(args['playing'], isTrue);
      expect((args['queue'] as List).map((ref) => (ref as Map)['title']), [
        'Title a',
        'Title b',
      ]);
      expect(player.calls, ['pause']);
      await tester.tap(button());
      await settle(tester);
      expect(tester.widget<SettingsItem>(phone()).selected, isTrue);
      final before = backend.sent.length;
      await tester.tap(phone());
      await settle(tester);
      expect(backend.sent.length, before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: This computer requests the phone current queue', (
      tester,
    ) async {
      await pumpButton(tester, mornye: mornye);
      await connectPhone(tester, playing: true);
      expect(find.text('Playing on Pixel'), findsOneWidget);
      await tester.tap(button());
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('link-device-computer')));
      await settle(tester);
      expect(lastCommand()['action'], LinkActions.playOnDesktop);
      // Until the computer really starts, keep controlling the phone.
      expect(find.text('Playing on Pixel'), findsOneWidget);
      player.emit(
        LinkPlayerSnapshot(
          queue: [playerItem('phone-song')],
          index: 0,
          playing: true,
          updatedMs: 0,
        ),
      );
      await settle(tester);
      expect(find.text('Playing on Pixel'), findsNothing);
    });

    testWidgets('$style: File changes opens the activity sheet', (
      tester,
    ) async {
      await pumpButton(tester, mornye: mornye);
      await connectPhone(tester);
      await tester.tap(button());
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('link-file-changes-entry')));
      await settle(tester);
      expect(sheet(), findsNothing);
      expect(find.text('No file changes yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: transfer ring keeps its size and opens Transfers', (
      tester,
    ) async {
      await pumpButton(tester, mornye: mornye);
      await connectPhone(tester);
      final size = tester.getSize(button());
      final store = ProviderScope.containerOf(
        tester.element(button()),
      ).read(linkTransfersProvider.notifier);
      store.add(
        LinkTransfer(
          direction: LinkTransferDirection.incoming,
          peerId: 'p1',
          peerName: 'Pixel',
          entries: [LinkTransferEntry(title: 'Song', artist: 'Artist')],
          status: LinkTransferStatus(
            transferId: List.filled(32, 'a').join(),
            state: LinkTransferState.running,
            total: 1,
            index: 0,
          ),
          startedAt: DateTime(2026),
        ),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey('desktop-link-transfers-ring')),
        findsOneWidget,
      );
      expect(tester.getSize(button()), size);
      await tester.tap(button());
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('link-transfers-entry')));
      await settle(tester);
      expect(sheet(), findsNothing);
      expect(find.byType(LinkTransfersDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed phone delivery preserves the computer selection', (
    tester,
  ) async {
    await pumpButton(tester);
    await connectPhone(tester);
    backend.delivered = 0;
    await tester.tap(button());
    await settle(tester);
    await tester.tap(phone());
    await settle(tester);
    expect(find.text('Playing on Pixel'), findsNothing);
    expect(player.calls, isEmpty);
    expect(find.text('The phone did not receive it'), findsOneWidget);
  });
}
