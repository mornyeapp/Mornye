import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_desktop_transfers.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_link_transfer_actions.dart';
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

String _fileId(int i) => i.toRadixString(16).padLeft(32, '0');

UnifiedLibraryItem _own(String id) => UnifiedLibraryItem.fromDownloadHistory(
  DownloadHistoryItem(
    id: id,
    trackName: 'Mine $id',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: '/music/$id.flac',
    service: 'tidal',
    downloadedAt: DateTime(2026),
  ),
);

UnifiedLibraryItem _phoneSong(String deviceId, int i) =>
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'network_$i',
        trackName: 'Phone $i',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: 'network://${linkPhoneSourceId(deviceId)}/${_fileId(i)}.flac',
        scannedAt: DateTime(2026),
      ),
    );

LinkTransfer _transfer(LinkTransferDirection direction, int songs) =>
    LinkTransfer(
      direction: direction,
      peerId: 'p1',
      peerName: 'Pixel',
      entries: [
        for (var i = 0; i < songs; i++)
          LinkTransferEntry(title: 'Song $i', artist: 'Artist'),
      ],
      status: LinkTransferStatus(
        transferId: '$direction$songs',
        state: LinkTransferState.queued,
        total: songs,
      ),
      startedAt: DateTime(2026),
    );

void main() {
  late FakeLinkBackend backend;
  late BuildContext menuContext;
  late WidgetRef menuRef;

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

  Future<void> pumpPage(WidgetTester tester, {bool enabled = true}) async {
    SharedPreferences.setMockInitialValues({
      linkDesktopEnabledKey: enabled,
      linkDesktopNameKey: 'Studio',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          ...linkHostOverrides(backend: backend, player: FakeLinkPlayer()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopLinkTransferNotices(
            child: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  // The app root runs the host on desktop.
                  ref.watch(linkDesktopHostProvider);
                  menuContext = context;
                  menuRef = ref;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  List<ContextMenuAction> actionsFor(List<UnifiedLibraryItem> items) =>
      desktopLinkTransferActions(menuContext, menuRef, items);

  List<String> labels(List<UnifiedLibraryItem> items) => [
    for (final action in actionsFor(items)) action.label,
  ];

  testWidgets('hidden while the server is off', (tester) async {
    await pumpPage(tester, enabled: false);
    backend.connect([_phone]);
    await settle(tester);
    expect(labels([_own('h1')]), isEmpty);
  });

  testWidgets('shows only while a phone is connected', (tester) async {
    await pumpPage(tester);
    expect(labels([_own('h1')]), isEmpty);
    backend.connect([_phone]);
    await settle(tester);
    expect(labels([_own('h1')]), ['Send to Pixel']);
    backend.connect(const []);
    await settle(tester);
    expect(labels([_own('h1')]), isEmpty);
  });

  testWidgets('offers the rows the chosen songs allow', (tester) async {
    await pumpPage(tester);
    backend.connect([
      _phone,
      const LinkClientInfo(deviceId: 'p2', name: '', platform: 'ios'),
    ]);
    await settle(tester);
    expect(labels([_own('h1')]), ['Send to Pixel', 'Send to p2']);
    expect(labels([_phoneSong('p1', 1)]), ['Save to this computer']);
    expect(labels([_phoneSong('gone', 1)]), isEmpty);
    expect(labels([_own('h1'), _phoneSong('p2', 2)]), [
      'Send to Pixel',
      'Send to p2',
      'Save to this computer',
    ]);
    expect(labels(const []), isEmpty);
  });

  testWidgets('says when none of the songs can be sent', (tester) async {
    await pumpPage(tester);
    backend.connect([_phone]);
    await settle(tester);
    actionsFor([_own('not-exported')]).single.onSelected!();
    await settle(tester);
    expect(find.text('None of these songs can be sent right now'), findsOne);
    expect(backend.sentOfType(LinkMessageTypes.transfersOffer), isEmpty);
  });

  testWidgets('an offer from a phone shows a notice with View', (tester) async {
    await pumpPage(tester);
    ProviderScope.containerOf(menuContext)
        .read(linkTransferOfferNoticeProvider.notifier)
        .show(_transfer(LinkTransferDirection.incoming, 3));
    await settle(tester);
    expect(find.text('Receiving 3 songs from Pixel'), findsOne);
    expect(find.text('View'), findsOne);
  });

  test('the notice names one song by its title, else the count', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(
      linkTransferDesktopMessage(l10n, [
        _transfer(LinkTransferDirection.outgoing, 1),
      ]),
      'Sending "Song 0" to Pixel',
    );
    expect(
      linkTransferDesktopMessage(l10n, [
        _transfer(LinkTransferDirection.outgoing, 1000),
        _transfer(LinkTransferDirection.outgoing, 1),
      ]),
      'Sending 1001 songs to Pixel',
    );
    expect(
      linkTransferDesktopMessage(l10n, [
        _transfer(LinkTransferDirection.incoming, 1),
      ]),
      'Receiving "Song 0" from Pixel',
    );
  });
}
