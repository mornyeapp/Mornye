import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneReceiver');

/// Keeps the app working on [transfer] (Android's foreground service, an
/// iOS background task) until the returned callback releases it.
typedef LinkTransferWork =
    Future<Future<void> Function()> Function(LinkTransfer transfer);

/// One incoming transfer: desktop songs this phone saves.
class _Incoming {
  _Incoming({
    required this.client,
    required this.saver,
    required this.songs,
    required this.transfer,
  }) : status = transfer.status;

  /// The desktop session its status goes to.
  final LinkClientApi client;

  /// Taken when it was queued, with the folder settings of that moment.
  final LinkOfflineSaver saver;
  final List<LinkOfflineSong> songs;
  final LinkTransfer transfer;
  final cancel = LinkOfflineCancel();
  final skipped = <int>[];
  final failed = <int>[];

  /// Songs finished: saved, skipped or failed.
  int done = 0;
  LinkTransferStatus status;

  /// When the last status went out; byte progress waits a while after it.
  DateTime? reportedAt;

  String get id => status.transferId;
}

/// Receives the paired desktop's songs on this phone (contract section
/// 13.2). "Save to this phone" and the desktop's `transfers.offer` become
/// incoming transfers that run one at a time, in arrival order. Each one
/// copies its songs with [LinkOfflineSaver], which skips the songs this
/// phone already has, keeps its [LinkTransfers] entry current, and tells
/// the desktop `transfers.status`: once queued, as it starts, after each
/// song, when it stops, and at most every [progressInterval] for the bytes
/// of the song in flight. A drop of the session does not stop it: songs
/// download over Subsonic, those it cannot fetch fail, and the status goes
/// out again once the session is back.
class LinkPhoneReceiver {
  LinkPhoneReceiver({
    required this.transfers,
    required this.saver,
    this.acquireWork,
    String Function()? newId,
    DateTime Function()? now,
    this.progressInterval = const Duration(milliseconds: 250),
  }) : _newId = newId ?? newLinkTransferId,
       _now = now ?? DateTime.now;

  final LinkTransfers transfers;

  /// Saves the paired desktop's songs, or null while none is paired.
  final LinkOfflineSaver? Function() saver;
  final LinkTransferWork? acquireWork;

  /// The shortest time between two byte progress reports.
  final Duration progressInterval;
  final String Function() _newId;
  final DateTime Function() _now;

  LinkClientApi? _client;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _jobs = <String, _Incoming>{};
  final _waiting = Queue<_Incoming>();
  final _offers = StreamController<LinkTransfer>.broadcast();
  _Incoming? _running;
  Future<void>? _loop;
  bool _disposed = false;

  /// The transfers the desktop starts (`transfers.offer`), as they queue.
  Stream<LinkTransfer> get offers => _offers.stream;

  /// Completes when no transfer runs or waits.
  @visibleForTesting
  Future<void> get idle => _loop ?? Future.value();

  /// Follows [client], the paired desktop's session, or none.
  void attach(LinkClientApi? client) {
    if (_disposed || identical(client, _client)) return;
    _unsubscribe();
    _client = client;
    if (client == null) return;
    _subscriptions
      ..add(client.messages.listen((message) => _handle(client, message)))
      ..add(
        client.connectionStates.listen((state) {
          if (state == LinkConnectionState.connected) _resend(client);
        }),
      );
  }

  void dispose() {
    _disposed = true;
    _running?.cancel.cancel();
    _waiting.clear();
    _unsubscribe();
    unawaited(_offers.close());
  }

  void _unsubscribe() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  /// Queues "Save to this phone" for [songs] of the paired desktop. Null
  /// when none is paired or there is nothing to save.
  LinkTransfer? save(List<LinkOfflineSong> songs) {
    final client = _client;
    final saver = this.saver();
    if (_disposed || client == null || saver == null || songs.isEmpty) {
      return null;
    }
    return _queue(client, saver, _newId(), songs);
  }

  /// Stops [transferId]: a waiting transfer at once, the running one once
  /// it has discarded the song in flight.
  void cancel(String transferId) {
    final job = _jobs[transferId];
    if (job == null) return;
    if (identical(job, _running)) {
      job.cancel.cancel();
      return;
    }
    _waiting.remove(job);
    _jobs.remove(transferId);
    _report(job, _status(job, LinkTransferState.cancelled));
  }

  void _handle(LinkClientApi client, Map<String, dynamic> message) {
    if (_disposed) return;
    switch (message['type']) {
      case LinkMessageTypes.transfersOffer:
        _offer(client, message);
      case LinkMessageTypes.transfersCancel:
        // Only incoming transfers are here; the desktop stops its own.
        final id = message['transferId'];
        if (id is String) cancel(id);
    }
  }

  void _offer(LinkClientApi client, Map<String, dynamic> message) {
    final id = message['transferId'];
    if (id is! String || !isLinkTransferId(id)) return;
    if (_jobs[id] case final known?) {
      // Offered again: say where it stands.
      _say(known);
      return;
    }
    final raw = message['songs'];
    final songs = [
      if (raw is List)
        for (final json in raw.take(linkTransferOfferLimit))
          if (LinkTransferSong.fromJson(json) case final song?)
            LinkOfflineSong.offered(song, client.server),
    ];
    final saver = this.saver();
    if (songs.isEmpty || saver == null) {
      _log.w('Refused a transfer offer without songs to save');
      client.send({
        'type': LinkMessageTypes.transfersStatus,
        ...LinkTransferStatus(
          transferId: id,
          state: LinkTransferState.failed,
          total: songs.length,
          reason: 'error',
        ).toJson(),
      });
      return;
    }
    _offers.add(_queue(client, saver, id, songs));
  }

  LinkTransfer _queue(
    LinkClientApi client,
    LinkOfflineSaver saver,
    String id,
    List<LinkOfflineSong> songs,
  ) {
    final transfer = LinkTransfer(
      direction: LinkTransferDirection.incoming,
      peerId: client.server.serverId,
      peerName: linkDesktopName(client),
      entries: [
        for (final song in songs)
          LinkTransferEntry(
            title: song.item.trackName,
            artist: song.item.artistName,
            album: song.item.albumName.trim().isEmpty
                ? null
                : song.item.albumName,
            coverPath: song.item.coverPath,
          ),
      ],
      status: LinkTransferStatus(
        transferId: id,
        state: LinkTransferState.queued,
        total: songs.length,
      ),
      startedAt: _now(),
    );
    final job = _Incoming(
      client: client,
      saver: saver,
      songs: songs,
      transfer: transfer,
    );
    _jobs[id] = job;
    _waiting.add(job);
    transfers.add(transfer, cancel: () => cancel(id));
    _say(job);
    _pump();
    return transfer;
  }

  void _pump() {
    if (_disposed || _loop != null || _waiting.isEmpty) return;
    _loop = _drain().whenComplete(() {
      _loop = null;
      // Queued while the last run was finishing.
      _pump();
    });
  }

  Future<void> _drain() async {
    while (!_disposed && _waiting.isNotEmpty) {
      final job = _waiting.removeFirst();
      _running = job;
      try {
        await _run(job);
      } finally {
        _running = null;
        _jobs.remove(job.id);
      }
    }
  }

  Future<void> _run(_Incoming job) async {
    Future<void> Function()? release;
    try {
      release = await acquireWork?.call(job.transfer);
    } on Object catch (error) {
      _log.w('Could not keep a transfer running in the background: $error');
    }
    try {
      _report(job, _status(job, LinkTransferState.running));
      final result = await job.saver.save(
        job.songs,
        cancel: job.cancel,
        onProgress: (progress) => _progress(job, progress),
        onSong: (index, outcome) {
          switch (outcome) {
            case LinkOfflineOutcome.skipped:
              job.skipped.add(index);
            case LinkOfflineOutcome.failed:
              job.failed.add(index);
            case LinkOfflineOutcome.saved:
              break;
          }
          job.done = index + 1;
          // After the last song the final state says it.
          if (job.done < job.songs.length) {
            _report(
              job,
              _status(job, LinkTransferState.running, index: job.done),
            );
          }
        },
      );
      _report(
        job,
        _status(
          job,
          result.cancelled
              ? LinkTransferState.cancelled
              : LinkTransferState.done,
          index: job.done,
        ),
      );
    } on LinkOfflineNoFolder {
      _report(
        job,
        _status(
          job,
          LinkTransferState.failed,
          index: job.done,
          reason: 'no_folder',
        ),
      );
    } on Object catch (error) {
      _log.w('A transfer from the desktop failed: $error');
      _report(
        job,
        _status(
          job,
          LinkTransferState.failed,
          index: job.done,
          reason: 'error',
        ),
      );
    } finally {
      await release?.call();
    }
  }

  /// Reports the bytes of the song in flight, at most every
  /// [progressInterval].
  void _progress(_Incoming job, LinkOfflineProgress progress) {
    if (progress.received <= 0) return;
    final last = job.reportedAt;
    if (last != null && _now().difference(last) < progressInterval) return;
    _report(
      job,
      _status(
        job,
        LinkTransferState.running,
        index: progress.done,
        received: progress.received,
        size: progress.size,
      ),
    );
  }

  LinkTransferStatus _status(
    _Incoming job,
    LinkTransferState state, {
    int index = 0,
    int received = 0,
    int? size,
    String? reason,
  }) => LinkTransferStatus(
    transferId: job.id,
    state: state,
    total: job.songs.length,
    index: index,
    received: received,
    size: size,
    skipped: List.unmodifiable(job.skipped),
    failed: List.unmodifiable(job.failed),
    reason: reason,
  );

  void _report(_Incoming job, LinkTransferStatus status) {
    job
      ..status = status
      ..reportedAt = _now();
    transfers.update(status);
    _say(job);
  }

  /// Sends [job]'s status to its desktop; dropped while disconnected.
  void _say(_Incoming job) => job.client.send({
    'type': LinkMessageTypes.transfersStatus,
    ...job.status.toJson(),
  });

  /// Tells [client]'s desktop again where its transfers stand, after the
  /// session came back.
  void _resend(LinkClientApi client) {
    for (final job in [?_running, ..._waiting]) {
      if (identical(job.client, client)) _say(job);
    }
  }
}
