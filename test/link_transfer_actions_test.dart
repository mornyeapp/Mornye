import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';

import 'support/link_fakes.dart';

/// Downloads that never finish, so a transfer stays running.
class _StuckTransport implements LinkOfflineTransport {
  final requested = <String>[];

  @override
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) {
    requested.add(songId);
    return Completer<void>().future;
  }

  @override
  void close() {}
}

class _NoDestination implements LinkOfflineDestination {
  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) => throw UnimplementedError();
}

class _Library extends LocalLibraryNotifier {
  _Library(this.items);

  final Map<String, LocalLibraryItem> items;

  @override
  LocalLibraryState build() => LocalLibraryState();

  @override
  Future<LocalLibraryItem?> getById(String id) async => items[id];
}

class _Downloads extends DownloadHistoryNotifier {
  _Downloads(this.items);

  final Map<String, DownloadHistoryItem> items;

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<DownloadHistoryItem?> getByFilePathAsync(String filePath) async =>
      items[filePath];
}

UnifiedLibraryItem _phoneSong(String title) =>
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'phone-$title',
        trackName: title,
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/$title.flac',
        scannedAt: DateTime(2026),
      ),
    );

UnifiedLibraryItem _desktopSong(String songId, String title) =>
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'desktop-$songId',
        trackName: title,
        artistName: 'Artist',
        albumName: 'Album',
        filePath: linkDesktopSongSource(linkTestServer, songId),
        scannedAt: DateTime(2026),
      ),
    );

void main() {
  late FakeLinkClient client;
  late _StuckTransport transport;

  setUp(() {
    client = FakeLinkClient();
    transport = _StuckTransport();
  });

  Widget app(Widget child) => ProviderScope(
    overrides: [
      linkPhoneClientProvider.overrideWithValue(client),
      linkTransferWorkProvider.overrideWithValue(
        (transfer) async => () async {},
      ),
      linkOfflineSaverProvider.overrideWithValue(
        LinkOfflineSaver(
          serverId: linkTestServer.serverId,
          openTransport: () => transport,
          destination: _NoDestination(),
          record: (_) async {},
          temporaryDirectory: () async => Directory.systemTemp,
        ),
      ),
    ],
    child: MaterialApp(
      navigatorKey: AppNavigationService.rootNavigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Scaffold)));

  /// Lets provider updates rebuild and a snackbar slide in.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('album header actions show only while the desktop is '
      'connected, for the songs each one applies to', (tester) async {
    client.connectionState = LinkConnectionState.disconnected;
    await tester.pumpWidget(
      app(
        LinkTransferButtons(
          items: [_phoneSong('Mine'), _desktopSong('l:1', 'Theirs')],
        ),
      ),
    );
    await settle(tester);
    expect(find.byTooltip('Send to Studio PC'), findsNothing);
    expect(find.byTooltip('Save to this phone'), findsNothing);

    client.setConnection(LinkConnectionState.connected);
    await settle(tester);
    expect(find.byTooltip('Send to Studio PC'), findsOneWidget);
    expect(find.byTooltip('Save to this phone'), findsOneWidget);

    await tester.pumpWidget(
      app(LinkTransferButtons(items: [_phoneSong('Mine')])),
    );
    await settle(tester);
    expect(find.byTooltip('Send to Studio PC'), findsOneWidget);
    expect(find.byTooltip('Save to this phone'), findsNothing);
  });

  testWidgets('save to this phone starts a transfer and offers to view it', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(LinkTransferButtons(items: [_desktopSong('l:7', 'Theirs')])),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('Save to this phone'));
    await settle(tester);

    final transfers = containerOf(tester).read(linkTransfersProvider);
    expect(transfers.single.direction, LinkTransferDirection.incoming);
    expect(transfers.single.entries.single.title, 'Theirs');
    expect(find.text('Saving Theirs from Studio PC'), findsOneWidget);
    expect(transport.requested, ['l:7']);

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.byType(LinkTransfersPage), findsOneWidget);
  });

  testWidgets('the selection toolbar offers both ways and ends the '
      'selection once one starts', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      app(
        LibrarySelectionPlaybackActions(
          items: [
            _phoneSong('Mine'),
            _desktopSong('l:1', 'One'),
            _desktopSong('l:2', 'Two'),
          ],
          onClose: () => closed++,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Send to Studio PC'), findsOneWidget);

    await tester.tap(find.text('Save to this phone'));
    await settle(tester);
    expect(closed, 1);
    final transfer = containerOf(tester).read(linkTransfersProvider).single;
    expect(transfer.entries.map((entry) => entry.title), ['One', 'Two']);
    expect(find.text('Saving 2 songs from Studio PC'), findsOneWidget);

    client.setConnection(LinkConnectionState.disconnected);
    await settle(tester);
    expect(find.text('Send to Studio PC'), findsNothing);
    expect(find.text('Save to this phone'), findsNothing);
  });

  testWidgets('the player menu finds the playing song: the desktop\'s to '
      'save, this phone\'s own or downloaded to send', (tester) async {
    final desktop = _desktopSong('l:5', 'Theirs').localItem!;
    final mine = _phoneSong('Mine').localItem!;
    final download = DownloadHistoryItem(
      id: 'download-1',
      trackName: 'Fetched',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: '/music/Fetched.flac',
      service: 'qobuz',
      downloadedAt: DateTime(2026),
    );
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linkPhoneClientProvider.overrideWithValue(client),
          localLibraryProvider.overrideWith(
            () => _Library({desktop.id: desktop, mine.id: mine}),
          ),
          downloadHistoryProvider.overrideWith(
            () => _Downloads({download.filePath: download}),
          ),
        ],
        child: Consumer(
          builder: (context, widgetRef, _) {
            ref = widgetRef;
            return const SizedBox();
          },
        ),
      ),
    );

    final theirs = await linkTransferSongsOfPlaying(
      ref,
      mediaId: desktop.id,
      source: desktop.filePath,
    );
    expect(theirs.desktop.single.songId, 'l:5');
    expect(theirs.phone, isEmpty);

    final own = await linkTransferSongsOfPlaying(
      ref,
      mediaId: mine.id,
      source: mine.filePath,
    );
    expect(own.desktop, isEmpty);
    expect(own.phone.single.trackName, 'Mine');

    final fetched = await linkTransferSongsOfPlaying(
      ref,
      mediaId: download.id,
      source: download.filePath,
    );
    expect(fetched.phone.single.trackName, 'Fetched');

    client.connectionState = LinkConnectionState.disconnected;
    final offline = await linkTransferSongsOfPlaying(
      ref,
      mediaId: mine.id,
      source: mine.filePath,
    );
    expect(offline.phone, isEmpty);
    expect(offline.desktop, isEmpty);
  });

  testWidgets('an offer from the desktop says so wherever the app is', (
    tester,
  ) async {
    await tester.pumpWidget(app(const SizedBox()));
    final container = containerOf(tester);
    container.listen(linkTransferOfferNoticesProvider, (_, _) {});

    client.push({
      'type': LinkMessageTypes.transfersOffer,
      'transferId': 'a' * 32,
      'songs': [
        for (final id in ['d:1', 'd:2', 'd:3'])
          LinkTransferSong(
            songId: id,
            suffix: 'flac',
            title: 'Song $id',
            artist: 'Artist',
          ).toJson(),
      ],
    });
    await settle(tester);
    expect(
      find.text('Studio PC is sending 3 songs to this phone'),
      findsOneWidget,
    );
    expect(find.text('View'), findsOneWidget);
    expect(
      container.read(linkTransfersProvider).single.direction,
      LinkTransferDirection.incoming,
    );
  });
}
