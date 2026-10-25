import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_desktop_transfers.dart';
import 'package:mornye/services/link/desktop/link_transfer_songs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_desktop_fakes.dart';

const _phone = LinkClientInfo(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);
const _paired = LinkPairedDevice(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeLinkBackend backend;
  late FakeLinkCatalogExporter exporter;
  late FakeTransferDownloads downloads;
  late Directory folder;
  ProviderContainer? container;
  final sourceId = linkPhoneSourceId('p1');
  final fileId = '${'0' * 31}1';
  final transferId = 'a' * 32;

  setUp(() async {
    debugDesktopPlatformOverride = true;
    folder = await Directory.systemTemp.createTemp('link-transfers-host-');
    for (final name in ['phones', 'received', 'music']) {
      Directory('${folder.path}/$name').createSync();
    }
    backend = FakeLinkBackend()
      ..deviceList = [_paired]
      ..receivedDir = '${folder.path}/received';
    exporter = FakeLinkCatalogExporter();
    downloads = FakeTransferDownloads(Directory('${folder.path}/music'));
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    debugDesktopPlatformOverride = null;
    await folder.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 500; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting');
  }

  LinkDesktopHost host() => container!.read(linkDesktopHostProvider.notifier);
  LinkDesktopHostState hostState() => container!.read(linkDesktopHostProvider);
  LinkTransfers store() => container!.read(linkTransfersProvider.notifier);

  Future<void> boot() async {
    SharedPreferences.setMockInitialValues({
      linkDesktopEnabledKey: true,
      linkDesktopNameKey: 'Studio',
    });
    container = ProviderContainer(
      overrides: linkHostOverrides(
        backend: backend,
        player: FakeLinkPlayer(),
        exporter: exporter,
        phoneFolder: Directory('${folder.path}/phones'),
        transferDownloads: downloads,
      ),
    );
    container!.read(linkDesktopHostProvider);
    await until(
      () =>
          hostState().running &&
          hostState().devices.isNotEmpty &&
          container!.read(linkCatalogIndexProvider) != null,
    );
    backend.connect([_phone]);
    await until(() => hostState().clients.isNotEmpty);
  }

  /// Sends a forwarded request and waits for its reply.
  Future<({Object? result, LinkException? error})> request(
    String op,
    Map<String, dynamic> args,
  ) async {
    final requestId = 'r${backend.replies.length + 1}';
    backend.request(op, requestId: requestId, deviceId: 'p1', args: args);
    await until(
      () => backend.replies.any((reply) => reply.requestId == requestId),
    );
    final reply = backend.replies.lastWhere(
      (reply) => reply.requestId == requestId,
    );
    return (result: reply.result, error: reply.error);
  }

  LinkPhoneSong phoneSong() => LinkPhoneSong(
    fileId: fileId,
    suffix: 'flac',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    size: 3,
  );

  /// The phone's upload of its song, already received.
  void received() =>
      File('${backend.receivedDir}/$fileId.flac').writeAsBytesSync([1, 2, 3]);

  bool finished(String id) => store().byId(id)?.active == false;

  test('a phone offer saves its songs as downloads', () async {
    await boot();
    received();
    final reply = await request(LinkOps.transfersOffer, {
      '_method': 'POST',
      'transferId': transferId,
      'songs': [phoneSong().toJson()],
    });
    expect(reply.error, isNull);
    expect(reply.result, {'accepted': 1});
    expect(
      container!.read(linkTransferOfferNoticeProvider)?.id,
      transferId,
      reason: 'the shell shows a notice for an offer',
    );
    await until(() => finished(transferId));
    final transfer = store().byId(transferId)!;
    expect(transfer.direction, LinkTransferDirection.incoming);
    expect(transfer.peerName, 'Pixel');
    expect(transfer.status.state, LinkTransferState.done);
    expect(downloads.records.single.trackName, 'Song');
    expect(
      downloads.records.single.id,
      linkTransferHistoryId('p1', '$fileId.flac'),
    );
    final statuses = backend.sentOfType(LinkMessageTypes.transfersStatus);
    expect(
      [for (final status in statuses) status['state']],
      ['queued', 'running', 'done'],
    );
    expect(
      backend.sent
          .where(
            (entry) =>
                entry.message['type'] == LinkMessageTypes.transfersStatus,
          )
          .every((entry) => entry.deviceId == 'p1'),
      isTrue,
    );
  });

  test('Save to this computer receives a phone song of the Library', () async {
    await boot();
    final commit = await request(LinkOps.phoneCatalog, {
      '_method': 'POST',
      'version': 'v1',
      'offset': 0,
      'total': 1,
      'songs': [phoneSong().toJson()],
    });
    expect(commit.error, isNull);
    received();
    final started = await host().saveToComputer([
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'network_1',
          trackName: 'Row title',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: 'network://$sourceId/$fileId.flac',
          scannedAt: DateTime(2026),
        ),
      ),
    ]);
    expect(started, hasLength(1));
    expect(started.single.entries.single.title, 'Song');
    await until(() => finished(started.single.id));
    expect(downloads.records.single.trackName, 'Song');
    expect(container!.read(linkTransferOfferNoticeProvider), isNull);
  });

  test('Send to a phone offers the exported songs', () async {
    final song = File('${folder.path}/music/a.flac')
      ..writeAsBytesSync([1, 2, 3, 4]);
    exporter.songs = [catalogSong('d:h1', path: song.path, title: 'Mine')];
    await boot();
    final item = UnifiedLibraryItem.fromDownloadHistory(
      DownloadHistoryItem(
        id: 'h1',
        trackName: 'Mine',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: song.path,
        service: 'tidal',
        downloadedAt: DateTime(2026),
      ),
    );
    expect(await host().sendToPhone('p2', [item]), isEmpty);
    final started = await host().sendToPhone('p1', [item]);
    final transfer = started.single;
    expect(transfer.direction, LinkTransferDirection.outgoing);
    final offer = backend.sentOfType(LinkMessageTypes.transfersOffer).single;
    expect(offer['transferId'], transfer.id);
    final offered = (offer['songs'] as List).single as Map<String, dynamic>;
    expect(offered['songId'], 'd:h1');
    expect(offered['size'], 4);

    backend.message('p1', {
      'type': LinkMessageTypes.transfersStatus,
      ...LinkTransferStatus(
        transferId: transfer.id,
        state: LinkTransferState.running,
        total: 1,
      ).toJson(),
    });
    await until(
      () =>
          store().byId(transfer.id)!.status.state == LinkTransferState.running,
    );

    // The phone leaves: its transfer fails.
    backend.connect(const []);
    await until(() => finished(transfer.id));
    expect(store().byId(transfer.id)!.status.reason, 'disconnected');
  });
}
