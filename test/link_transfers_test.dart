import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';

void main() {
  test('transfer ids are 32 lowercase hex characters', () {
    final id = newLinkTransferId(Random(1));
    expect(isLinkTransferId(id), isTrue);
    expect(isLinkTransferId(newLinkTransferId()), isTrue);
    expect(isLinkTransferId('ABC'), isFalse);
    expect(isLinkTransferId(null), isFalse);
  });

  test('offered desktop songs round-trip and reject bad entries', () {
    const song = LinkTransferSong(
      songId: 'l:42',
      suffix: 'flac',
      title: 'Song',
      artist: 'Artist',
      size: 1234,
      album: 'Album',
      track: 3,
      durationMs: 180000,
      explicit: true,
    );
    final back = LinkTransferSong.fromJson(song.toJson())!;
    expect(back.toJson(), song.toJson());
    expect(
      LinkTransferSong.fromJson({'songId': 'l:1', 'suffix': 'flac'}),
      isNull,
    );
    expect(
      LinkTransferSong.fromJson({
        'songId': 'l:1',
        'suffix': '../x',
        'title': 'T',
      }),
      isNull,
    );
  });

  test('status reports saved songs and the whole transfer', () {
    final id = newLinkTransferId(Random(2));
    final status = LinkTransferStatus(
      transferId: id,
      state: LinkTransferState.running,
      total: 4,
      index: 2,
      received: 50,
      size: 100,
      skipped: const [0],
    );
    expect(status.saved, 1);
    expect(status.fraction, closeTo(2.5 / 4, 1e-9));
    final back = LinkTransferStatus.fromJson(status.toJson())!;
    expect(back.toJson(), status.toJson());
    expect(
      LinkTransferStatus.fromJson({
        'transferId': id,
        'state': 'running',
        'total': 2,
        'index': 9,
      })!.index,
      2,
    );
    expect(LinkTransferStatus.fromJson({'transferId': id, 'total': 1}), isNull);
    expect(
      status.copyWith(state: LinkTransferState.done, index: 4).fraction,
      1,
    );
  });

  test('the store lists, updates, cancels and clears transfers', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final transfers = container.read(linkTransfersProvider.notifier);
    final id = newLinkTransferId(Random(3));
    var cancelled = 0;
    transfers.add(
      LinkTransfer(
        direction: LinkTransferDirection.outgoing,
        peerId: 'server',
        peerName: 'Desk',
        entries: const [
          LinkTransferEntry(title: 'One', artist: 'A'),
          LinkTransferEntry(title: 'Two', artist: 'B'),
        ],
        status: LinkTransferStatus(
          transferId: id,
          state: LinkTransferState.queued,
          total: 2,
        ),
        startedAt: DateTime(2026),
      ),
      cancel: () => cancelled++,
    );
    transfers.update(
      LinkTransferStatus(
        transferId: id,
        state: LinkTransferState.running,
        total: 2,
        index: 1,
        failed: const [0],
      ),
    );
    final running = container.read(linkTransfersProvider).single;
    expect(running.stateOf(0), LinkTransferEntryState.failed);
    expect(running.stateOf(1), LinkTransferEntryState.running);
    transfers.cancel(id);
    expect(cancelled, 1);
    transfers.update(
      running.status.copyWith(state: LinkTransferState.cancelled),
    );
    expect(container.read(linkTransfersProvider).single.finishedAt, isNotNull);
    // A finished transfer has no cancel handler left.
    transfers.cancel(id);
    expect(cancelled, 1);
    transfers.clearFinished();
    expect(container.read(linkTransfersProvider), isEmpty);
  });
}
