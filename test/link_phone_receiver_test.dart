import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/features/link_phone_receiver.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:path/path.dart' as p;

import 'support/link_fakes.dart';

/// Waits, in real time, until [condition] holds.
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

LocalLibraryItem _row(String songId, {String title = 'Song'}) =>
    LocalLibraryItem(
      id: 'network_$songId',
      trackName: title,
      artistName: 'Artist',
      albumName: 'Album',
      filePath: linkDesktopSongSource(linkTestServer, songId, format: 'flac'),
      scannedAt: DateTime(2026),
      format: 'flac',
    );

List<LinkOfflineSong> _songs(List<String> ids) => linkOfflineSongs([
  for (final id in ids) _row(id, title: 'Song $id'),
], linkTestServer);

/// Downloads that write a few bytes, wait at a gate when the test sets one
/// for the song, and fail for [failing] songs. Closing it fails the
/// download in flight, as closing the connection does.
class _Transport implements LinkOfflineTransport {
  final requested = <String>[];
  final failing = <String>{};
  final gates = <String, Completer<void>>{};

  /// Called before each of the song's progress reports.
  void Function(int chunk)? onChunk;
  int chunks = 2;
  int closed = 0;

  @override
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    requested.add(songId);
    await output.writeAsBytes(List.filled(chunks * 10, 1));
    for (var chunk = 1; chunk <= chunks; chunk++) {
      onChunk?.call(chunk);
      progress(chunk * 10, chunks * 10);
    }
    if (gates[songId] case final gate?) await gate.future;
    checkpoint();
    if (failing.contains(songId)) throw const HttpException('500');
  }

  @override
  void close() {
    closed++;
    for (final gate in gates.values) {
      if (gate.isCompleted) continue;
      // The download may not wait at the gate yet; it fails when it does.
      gate.future.ignore();
      gate.completeError(const SocketException('closed'));
    }
  }
}

class _Destination implements LinkOfflineDestination {
  _Destination(this.root);

  final Directory root;
  bool noFolder = false;

  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) async {
    if (noFolder) throw const LinkOfflineNoFolder();
    final target = File(p.join(root.path, relativeDir, fileName));
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    return LinkOfflineStored(filePath: target.path, storageMode: 'app');
  }
}

void main() {
  late Directory temp;
  late Directory root;
  late ProviderContainer container;
  late _Transport transport;
  late _Destination destination;
  late List<DownloadHistoryItem> records;
  late Set<String> saved;
  late DateTime clock;
  late FakeLinkClient client;
  late LinkPhoneReceiver receiver;
  late List<String> work;
  var ids = 0;

  String id(int n) => n.toRadixString(16).padLeft(32, '0');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('link_receiver_temp');
    root = await Directory.systemTemp.createTemp('link_receiver_root');
    container = ProviderContainer();
    transport = _Transport();
    destination = _Destination(root);
    records = [];
    saved = {};
    clock = DateTime(2026, 10, 25);
    client = FakeLinkClient();
    work = [];
    ids = 0;
    final saver = LinkOfflineSaver(
      serverId: linkTestServer.serverId,
      openTransport: () => transport,
      destination: destination,
      record: (item) async => records.add(item),
      temporaryDirectory: () async => temp,
      exists: (historyId) async => saved.contains(historyId),
    );
    receiver = LinkPhoneReceiver(
      transfers: container.read(linkTransfersProvider.notifier),
      saver: () => saver,
      acquireWork: (transfer) async {
        work.add('hold ${transfer.id}');
        return () async => work.add('release ${transfer.id}');
      },
      newId: () => id(++ids),
      now: () => clock,
    )..attach(client);
  });

  tearDown(() async {
    receiver.dispose();
    container.dispose();
    await temp.delete(recursive: true);
    await root.delete(recursive: true);
  });

  List<LinkTransferStatus> statuses([String? transferId]) => [
    for (final message in client.sent)
      if (message['type'] == LinkMessageTypes.transfersStatus)
        if (LinkTransferStatus.fromJson(message) case final status?)
          if (transferId == null || status.transferId == transferId) status,
  ];

  List<String> states([String? transferId]) => [
    for (final status in statuses(transferId))
      '${status.state.name} ${status.index}',
  ];

  LinkTransfer stored(String transferId) =>
      container.read(linkTransfersProvider.notifier).byId(transferId)!;

  test('save to this phone queues, reports and saves the songs', () async {
    final historyId = LinkOfflineSaver(
      serverId: linkTestServer.serverId,
      openTransport: _Transport.new,
      destination: destination,
      record: (_) async {},
      temporaryDirectory: () async => temp,
    ).historyId;
    saved.add(historyId('2'));
    transport.failing.add('3');

    final transfer = receiver.save(_songs(['1', '2', '3']))!;
    expect(transfer.id, id(1));
    expect(transfer.direction, LinkTransferDirection.incoming);
    expect(transfer.peerId, linkTestServer.serverId);
    expect(transfer.peerName, 'Studio PC');
    expect(transfer.entries.map((entry) => entry.title), [
      'Song 1',
      'Song 2',
      'Song 3',
    ]);
    expect(transfer.entries.first.album, 'Album');
    expect(container.read(linkTransfersProvider).single.id, transfer.id);

    await until(() => !stored(transfer.id).active);
    await receiver.idle;
    expect(states(), [
      'queued 0',
      'running 0',
      'running 1',
      'running 2',
      'done 3',
    ]);
    final last = statuses().last;
    expect(last.skipped, [1]);
    expect(last.failed, [2]);
    expect(transport.requested, ['1', '3']);
    expect(records.single.id, historyId('1'));
    final done = stored(transfer.id);
    expect(done.status.state, LinkTransferState.done);
    expect(done.status.saved, 1);
    expect(done.finishedAt, isNotNull);
    expect(work, ['hold ${id(1)}', 'release ${id(1)}']);
  });

  test('transfers run one at a time, in arrival order', () async {
    final gate = transport.gates['1'] = Completer<void>();
    final first = receiver.save(_songs(['1']))!;
    final second = receiver.save(_songs(['2']))!;
    await until(() => transport.requested.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(stored(first.id).status.state, LinkTransferState.running);
    expect(stored(second.id).status.state, LinkTransferState.queued);
    expect(states(second.id), ['queued 0']);
    expect(transport.requested, ['1']);

    gate.complete();
    await until(() => !stored(second.id).active);
    expect(transport.requested, ['1', '2']);
    expect(states(first.id).last, 'done 1');
    expect(states(second.id), ['queued 0', 'running 0', 'done 1']);
  });

  test('reports byte progress at most four times a second', () async {
    transport
      ..chunks = 10
      ..onChunk = (_) => clock = clock.add(const Duration(milliseconds: 100));
    final transfer = receiver.save(_songs(['1', '2']))!;
    await until(() => !stored(transfer.id).active);

    final bytes = [
      for (final status in statuses())
        if (status.received > 0) (status.index, status.received),
    ];
    // Every 300 ms of the 100 ms chunks, counted from the last report.
    expect(bytes, [(0, 30), (0, 60), (0, 90), (1, 30), (1, 60), (1, 90)]);
    expect(statuses().firstWhere((s) => s.received > 0).size, 100);
  });

  test('takes the desktop\'s offer, says it is queued and runs it', () async {
    final offers = <LinkTransfer>[];
    receiver.offers.listen(offers.add);
    const song = LinkTransferSong(
      songId: 'd:7',
      suffix: 'flac',
      title: 'Offered',
      artist: 'Artist',
      album: 'Album',
    );

    client
      ..push({
        'type': LinkMessageTypes.transfersOffer,
        'transferId': 'not-an-id',
        'songs': [song.toJson()],
      })
      ..push({
        'type': LinkMessageTypes.transfersOffer,
        'transferId': id(90),
        'songs': [
          song.toJson(),
          {'title': 'No id'},
        ],
      });
    await until(() => offers.isNotEmpty);
    expect(offers.single.id, id(90));
    expect(offers.single.entries.single.title, 'Offered');
    expect(statuses(id(90)).first.state, LinkTransferState.queued);
    expect(statuses(id(90)).first.total, 1);

    await until(() => !stored(id(90)).active);
    expect(transport.requested, ['d:7']);
    expect(records.single.trackName, 'Offered');
    expect(states(id(90)).last, 'done 1');

    // Offered again: the status goes out again, nothing runs twice.
    client.push({
      'type': LinkMessageTypes.transfersOffer,
      'transferId': id(91),
      'songs': [
        {'title': 'No id'},
      ],
    });
    expect(statuses(id(91)).single.state, LinkTransferState.failed);
    expect(statuses(id(91)).single.reason, 'error');
    expect(container.read(linkTransfersProvider), hasLength(1));
    expect(offers, hasLength(1));
  });

  test('repeats the status of an offer it already queued', () async {
    final gate = transport.gates['d:1'] = Completer<void>();
    final offer = {
      'type': LinkMessageTypes.transfersOffer,
      'transferId': id(80),
      'songs': [
        const LinkTransferSong(
          songId: 'd:1',
          suffix: 'mp3',
          title: 'One',
          artist: 'Artist',
        ).toJson(),
      ],
    };
    client.push(offer);
    await until(() => transport.requested.isNotEmpty);
    final before = statuses(id(80)).length;
    client.push(offer);
    expect(statuses(id(80)), hasLength(before + 1));
    expect(container.read(linkTransfersProvider), hasLength(1));
    gate.complete();
    await until(() => !stored(id(80)).active);
    expect(transport.requested, ['d:1']);
  });

  test('cancel stops a waiting transfer at once, a running one after '
      'discarding the song in flight', () async {
    transport.gates['2'] = Completer<void>();
    final first = receiver.save(_songs(['1', '2', '3']))!;
    final second = receiver.save(_songs(['4']))!;
    await until(() => transport.requested.length == 2);

    // The desktop cancels the waiting one; it never starts.
    client.push({
      'type': LinkMessageTypes.transfersCancel,
      'transferId': second.id,
    });
    expect(states(second.id), ['queued 0', 'cancelled 0']);

    // The listener cancels the running one from the Transfers list.
    container.read(linkTransfersProvider.notifier).cancel(first.id);
    await until(() => !stored(first.id).active);
    await receiver.idle;
    expect(states(first.id).last, 'cancelled 1');
    expect(stored(first.id).status.state, LinkTransferState.cancelled);
    expect(transport.requested, ['1', '2']);
    expect(records, hasLength(1));
    expect(temp.listSync(), isEmpty);
  });

  test('fails as no_folder without a download folder', () async {
    destination.noFolder = true;
    final transfer = receiver.save(_songs(['1', '2']))!;
    await until(() => !stored(transfer.id).active);
    final last = statuses().last;
    expect(last.state, LinkTransferState.failed);
    expect(last.reason, 'no_folder');
    expect(last.index, 0);
    expect(transport.requested, ['1']);
  });

  test('keeps saving through a drop and repeats the status after it', () async {
    final gate = transport.gates['1'] = Completer<void>();
    final transfer = receiver.save(_songs(['1', '2']))!;
    await until(() => transport.requested.isNotEmpty);

    client.setConnection(LinkConnectionState.disconnected);
    final sentBefore = client.sent.length;
    client.setConnection(LinkConnectionState.connected);
    expect(client.sent, hasLength(sentBefore + 1));
    expect(statuses().last.state, LinkTransferState.running);

    gate.complete();
    await until(() => !stored(transfer.id).active);
    expect(states(transfer.id).last, 'done 2');
  });

  test('ignores everything without a paired desktop', () {
    receiver.attach(null);
    expect(receiver.save(_songs(['1'])), isNull);
    expect(receiver.save(const []), isNull);
    client.push({
      'type': LinkMessageTypes.transfersOffer,
      'transferId': id(70),
      'songs': [
        const LinkTransferSong(
          songId: 'd:1',
          suffix: 'mp3',
          title: 'One',
          artist: 'Artist',
        ).toJson(),
      ],
    });
    expect(container.read(linkTransfersProvider), isEmpty);
  });
}
