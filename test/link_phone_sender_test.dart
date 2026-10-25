import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/features/link_phone_library_sync.dart';
import 'package:mornye/services/link/features/link_phone_sender.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';

import 'support/link_fakes.dart';

/// Waits, in real time, until [condition] holds.
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// [count] songs at made-up paths, the last [repeated] of them a second
/// listing of the first file.
LinkPhoneSongPage _page(int count, {int repeated = 0}) {
  final songs = <LinkPhoneSong>[];
  final files = <LinkPhoneFile>[];
  for (var i = 0; i < count; i++) {
    final path = '/music/${i < count - repeated ? i : 0}.flac';
    final fileId = linkFileIdFor(path, 10);
    songs.add(
      LinkPhoneSong(
        fileId: fileId,
        suffix: 'flac',
        title: 'Song $i',
        artist: 'Artist',
        album: 'Album',
        coverUrl: 'https://covers.example/$i.jpg',
      ),
    );
    files.add(LinkPhoneFile(fileId: fileId, source: path, extension: 'flac'));
  }
  return LinkPhoneSongPage(
    songs: songs,
    files: files,
    covers: List.filled(count, null),
    lines: List.filled(count, Uint8List(0)),
  );
}

void main() {
  late ProviderContainer container;
  late FakeLinkClient client;
  late LinkPhoneSender sender;
  late List<String> work;
  var ids = 0;

  String id(int n) => n.toRadixString(16).padLeft(32, '0');

  LinkPhoneSender newSender({Duration? cancelTimeout}) => LinkPhoneSender(
    transfers: container.read(linkTransfersProvider.notifier),
    acquireWork: (transfer) async {
      work.add('hold ${transfer.id}');
      return () async => work.add('release ${transfer.id}');
    },
    newId: () => id(++ids),
    now: () => DateTime(2026, 10, 25),
    cancelTimeout: cancelTimeout ?? const Duration(seconds: 10),
  );

  setUp(() {
    container = ProviderContainer();
    client = FakeLinkClient(
      onPost: (op, body) => {'accepted': (body['songs'] as List).length},
    );
    work = [];
    ids = 0;
    sender = newSender()..attach(client);
  });

  tearDown(() {
    sender.dispose();
    container.dispose();
  });

  LinkTransfer stored(String transferId) =>
      container.read(linkTransfersProvider.notifier).byId(transferId)!;

  List<({String op, Map<String, dynamic> body})> offers() => [
    for (final post in client.posts)
      if (post.op == LinkOps.transfersOffer) post,
  ];

  test('offers a choice in transfers of at most the offer limit', () async {
    final page = _page(linkTransferOfferLimit + 2, repeated: 1);
    final started = await sender.send(client, page);

    expect(offers().map((offer) => offer.body['transferId']), [id(1), id(2)]);
    expect(offers().first.body['songs'], hasLength(linkTransferOfferLimit));
    // The second listing of a file goes once.
    expect(offers().last.body['songs'], hasLength(1));
    expect(
      ((offers().last.body['songs'] as List).single as Map)['title'],
      'Song $linkTransferOfferLimit',
    );
    expect(started.map((transfer) => transfer.id), [id(1), id(2)]);

    final transfers = container.read(linkTransfersProvider);
    expect(transfers.map((transfer) => transfer.id), [id(2), id(1)]);
    final first = stored(id(1));
    expect(first.direction, LinkTransferDirection.outgoing);
    expect(first.peerId, linkTestServer.serverId);
    expect(first.peerName, 'Studio PC');
    expect(first.status.state, LinkTransferState.queued);
    expect(first.status.total, linkTransferOfferLimit);
    expect(first.entries.first.title, 'Song 0');
    expect(first.entries.first.album, 'Album');
    expect(first.entries.first.coverPath, 'https://covers.example/0.jpg');
    expect(sender.fileNamed(page.songs.first.name), same(page.files.first));
    expect(
      sender.fileNamed(page.songs[linkTransferOfferLimit].name),
      isNotNull,
    );
    await pumpEventQueue();
    expect(work, ['hold ${id(1)}', 'hold ${id(2)}']);
  });

  test('follows the desktop\'s status and answers its file requests until '
      'the transfer stops', () async {
    final dir = Directory.systemTemp.createTempSync('link_sender_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/Song.flac';
    File(path).writeAsBytesSync(List.filled(32, 3));
    final page = await linkPhoneSongsOf([
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'local-1',
          trackName: 'Mine',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: path,
          scannedAt: DateTime(2026),
        ),
      ),
    ], map: (rows) async => mapLinkPhoneRows(rows));
    final name = page.songs.single.name;
    // Sharing is off: the song list holds nothing.
    final requests = LinkPhoneFileRequests(
      client: client,
      library: FakeLibraryRows().library(),
      files: LinkPhoneFiles(),
      offered: sender.fileNamed,
    )..start();
    addTearDown(requests.dispose);

    final transfer = (await sender.send(client, page)).single;
    client.push({'type': LinkMessageTypes.filesRequest, 'name': name});
    await until(() => client.uploads.isNotEmpty);
    expect(client.uploads.single.name, name);
    expect(
      client.sent.where(
        (message) => message['type'] == LinkMessageTypes.filesSending,
      ),
      hasLength(1),
    );

    client.push({
      'type': LinkMessageTypes.transfersStatus,
      ...LinkTransferStatus(
        transferId: transfer.id,
        state: LinkTransferState.running,
        total: 1,
        received: 16,
        size: 32,
      ).toJson(),
    });
    expect(stored(transfer.id).status.state, LinkTransferState.running);
    expect(stored(transfer.id).status.received, 16);

    client.push({
      'type': LinkMessageTypes.transfersStatus,
      ...LinkTransferStatus(
        transferId: transfer.id,
        state: LinkTransferState.done,
        total: 1,
        index: 1,
      ).toJson(),
    });
    expect(stored(transfer.id).status.state, LinkTransferState.done);
    expect(sender.fileNamed(name), isNull);
    await pumpEventQueue();
    expect(work, ['hold ${transfer.id}', 'release ${transfer.id}']);

    // Stopped: a later request is not this transfer's any more.
    client.push({'type': LinkMessageTypes.filesRequest, 'name': name});
    await until(
      () => client.sent.any(
        (message) => message['type'] == LinkMessageTypes.filesFailed,
      ),
    );
  });

  test('a refused offer fails its transfer and the error comes back', () async {
    client.onPost = (op, body) => const LinkException('busy');
    final page = _page(2);
    await expectLater(
      sender.send(client, page),
      throwsA(isA<LinkException>().having((e) => e.code, 'code', 'busy')),
    );
    expect(stored(id(1)).status.state, LinkTransferState.failed);
    expect(stored(id(1)).status.reason, 'busy');
    expect(sender.fileNamed(page.songs.first.name), isNull);

    client.onPost = (op, body) => {'accepted': 0};
    await expectLater(sender.send(client, page), throwsA(isA<LinkException>()));
    expect(stored(id(2)).status.reason, 'error');
  });

  test('refuses to offer while the session is not connected', () async {
    client.connectionState = LinkConnectionState.connecting;
    await expectLater(
      sender.send(client, _page(1)),
      throwsA(
        isA<LinkException>().having((e) => e.code, 'code', 'disconnected'),
      ),
    );
    expect(offers(), isEmpty);
    expect(container.read(linkTransfersProvider), isEmpty);
  });

  test(
    'running transfers fail as disconnected when the session drops',
    () async {
      final first = (await sender.send(client, _page(1))).single;
      client.push({
        'type': LinkMessageTypes.transfersStatus,
        ...LinkTransferStatus(
          transferId: first.id,
          state: LinkTransferState.done,
          total: 1,
          index: 1,
        ).toJson(),
      });
      final second = (await sender.send(client, _page(1))).single;

      client.setConnection(LinkConnectionState.disconnected);
      expect(stored(first.id).status.state, LinkTransferState.done);
      expect(stored(second.id).status.state, LinkTransferState.failed);
      expect(stored(second.id).status.reason, 'disconnected');

      // Pairing another desktop drops the transfers to the one before.
      client.setConnection(LinkConnectionState.connected);
      final third = (await sender.send(client, _page(1))).single;
      sender.attach(FakeLinkClient());
      expect(stored(third.id).status.reason, 'disconnected');
    },
  );

  test('cancel asks the desktop and waits for its answer', () async {
    final transfer = (await sender.send(client, _page(1))).single;
    container.read(linkTransfersProvider.notifier).cancel(transfer.id);
    expect(client.sent.last, {
      'type': LinkMessageTypes.transfersCancel,
      'transferId': transfer.id,
    });
    expect(stored(transfer.id).active, isTrue);

    client.push({
      'type': LinkMessageTypes.transfersStatus,
      ...LinkTransferStatus(
        transferId: transfer.id,
        state: LinkTransferState.cancelled,
        total: 1,
      ).toJson(),
    });
    expect(stored(transfer.id).status.state, LinkTransferState.cancelled);
  });

  test('cancel stops here without an answer or a connection', () async {
    sender.dispose();
    sender = newSender(cancelTimeout: const Duration(milliseconds: 10))
      ..attach(client);
    final silent = (await sender.send(client, _page(1))).single;
    container.read(linkTransfersProvider.notifier).cancel(silent.id);
    await until(() => !stored(silent.id).active);
    expect(stored(silent.id).status.state, LinkTransferState.cancelled);

    final offline = (await sender.send(client, _page(1))).single;
    // Not yet heard by the sender: the session went down a moment ago.
    client.connectionState = LinkConnectionState.disconnected;
    container.read(linkTransfersProvider.notifier).cancel(offline.id);
    expect(stored(offline.id).status.state, LinkTransferState.cancelled);
  });

  test('only this phone\'s own files are offered', () async {
    final dir = Directory.systemTemp.createTempSync('link_sender_rows_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final local = '${dir.path}/Local.mp3';
    final download = '${dir.path}/Download.flac';
    File(local).writeAsBytesSync(List.filled(8, 1));
    File(download).writeAsBytesSync(List.filled(12, 1));
    final items = [
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'l1',
          trackName: 'Local',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: local,
          scannedAt: DateTime(2026),
        ),
      ),
      UnifiedLibraryItem.fromDownloadHistory(
        DownloadHistoryItem(
          id: 'd1',
          trackName: 'Download',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: download,
          coverUrl: 'https://covers.example/d1.jpg',
          service: 'test',
          downloadedAt: DateTime(2026),
        ),
      ),
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'desktop',
          trackName: 'Desktop',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: linkDesktopSongSource(linkTestServer, 'l:1'),
          scannedAt: DateTime(2026),
        ),
      ),
    ];
    expect(items.map(isLinkPhoneSongItem), [true, true, false]);

    final page = await linkPhoneSongsOf(
      items,
      map: (rows) async => mapLinkPhoneRows(rows),
    );
    expect(page.songs.map((song) => song.title), ['Local', 'Download']);
    expect(page.songs.first.fileId, linkFileIdFor(local, 8));
    expect(page.songs.first.suffix, 'mp3');
    expect(page.songs.last.fileId, linkFileIdFor(download, 12));
    expect(page.songs.last.coverUrl, 'https://covers.example/d1.jpg');
  });
}
