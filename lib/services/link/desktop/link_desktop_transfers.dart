import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/desktop/link_phone_sources.dart';
import 'package:mornye/services/link/desktop/link_transfer_songs.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkDesktopTransfers');

/// The whole file of the phone song `name` from the phone `deviceId`, once
/// it is in the received folder; `onProgress` hears the bytes so far.
typedef LinkPhoneSongFetch =
    Future<String> Function(
      String deviceId,
      String name, {
      void Function(int received, int size)? onProgress,
    });

LinkException _invalid(String message) => LinkException('invalid', message);

enum _Outcome { saved, skipped, failed, stopped }

class _Stopped implements Exception {
  const _Stopped();
}

/// A phone's songs the desktop copies in, queued or running.
class _Incoming {
  _Incoming({required this.id, required this.deviceId, required this.songs}) {
    _stop.future.ignore();
  }

  final String id;
  final String deviceId;
  final List<LinkIncomingSong> songs;
  final skipped = <int>[];
  final failed = <int>[];
  final _stop = Completer<void>();
  int index = 0;
  int received = 0;
  int? size;
  bool cancelled = false;
  bool disconnected = false;
  DateTime? reported;

  /// Completes when the transfer is cancelled or its phone drops.
  Future<void> get stopped => _stop.future;

  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }
}

/// Song transfers between the desktop and connected phones (contract 13).
///
/// Incoming transfers (a phone's `transfers/offer`, or the owner's "Save to
/// this computer") run one at a time in arrival order: each song the
/// desktop does not have yet is asked of the phone, waited for until whole
/// in the received folder, copied into the download folder and recorded as
/// a download, while `transfers.status` keeps the phone informed. Outgoing
/// transfers ("Send to (phone)") offer the desktop's songs to a phone,
/// which runs them and reports back.
class LinkDesktopTransfers {
  LinkDesktopTransfers({
    required LinkTransfers Function() store,
    required Future<int> Function(Map<String, dynamic> message, String deviceId)
    send,
    required LinkPhoneSongFetch fetch,
    required LinkCatalogIndex? Function() index,
    required LinkTransferDownloads Function() downloads,
    required bool Function(String deviceId) connected,
    required String Function(String deviceId) deviceName,
    Future<bool> Function(String deviceId)? isPhone,
    Future<Map<String, String>> Function(String deviceId)? covers,
    void Function(String deviceId)? onSaved,
    void Function(LinkTransfer transfer)? onOffer,
    DateTime Function()? now,
    String Function()? newId,
    this.progressInterval = const Duration(milliseconds: 250),
  }) : _store = store,
       _send = send,
       _fetch = fetch,
       _index = index,
       _downloads = downloads,
       _connected = connected,
       _deviceName = deviceName,
       _isPhone = isPhone ?? ((_) async => true),
       _covers = covers ?? ((_) async => const {}),
       _onSaved = onSaved,
       _onOffer = onOffer,
       _now = now ?? DateTime.now,
       _newId = newId ?? newLinkTransferId;

  /// The shortest time between two byte progress reports (four a second).
  final Duration progressInterval;

  final LinkTransfers Function() _store;
  final Future<int> Function(Map<String, dynamic> message, String deviceId)
  _send;
  final LinkPhoneSongFetch _fetch;
  final LinkCatalogIndex? Function() _index;
  final LinkTransferDownloads Function() _downloads;
  final bool Function(String deviceId) _connected;
  final String Function(String deviceId) _deviceName;
  final Future<bool> Function(String deviceId) _isPhone;
  final Future<Map<String, String>> Function(String deviceId) _covers;
  final void Function(String deviceId)? _onSaved;
  final void Function(LinkTransfer transfer)? _onOffer;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Incoming transfers queued or running, by id.
  final _incoming = <String, _Incoming>{};
  final _waiting = <_Incoming>[];
  _Incoming? _running;

  /// Active outgoing transfers: the phone each was offered to, by id.
  final _outgoing = <String, String>{};
  bool _closed = false;

  /// Registers `transfers/offer` on [router].
  void register(LinkHostRouter router) =>
      router.register(LinkOps.transfersOffer, _offer);

  /// `transfers/offer`: queues the songs a phone offers.
  Future<Object?> _offer(LinkRequest request) async {
    final deviceId = request.deviceId;
    final transferId = request.args['transferId'];
    final raw = request.args['songs'];
    if (deviceId.isEmpty ||
        transferId is! String ||
        !isLinkTransferId(transferId) ||
        raw is! List) {
      throw _invalid('Pass transferId and songs');
    }
    if (!await _isPhone(deviceId)) {
      throw _invalid('Only a paired phone can send songs');
    }
    final songs = [
      for (final json in raw.take(linkTransferOfferLimit))
        ?LinkPhoneSong.fromJson(json),
    ];
    if (songs.isEmpty) throw _invalid('No song to receive');
    final covers = await _covers(deviceId);
    if (_closed) throw const LinkException('unavailable', 'Link stopped');
    // An offer sent again (a retry) is the same transfer.
    final known = _store().byId(transferId);
    if (known != null) {
      if (known.direction == LinkTransferDirection.incoming &&
          known.peerId == deviceId) {
        return {'accepted': known.status.total};
      }
      throw _invalid('The transfer id is taken');
    }
    final transfer = _enqueue(deviceId, transferId, [
      for (final song in songs)
        (song: song, coverPath: covers[song.coverKey] ?? song.coverUrl),
    ]);
    _onOffer?.call(transfer);
    return {'accepted': songs.length};
  }

  /// "Save to this computer": copies [songs] of the phone [deviceId] into
  /// the download folder, as transfers of at most [linkTransferOfferLimit]
  /// songs each; returns them.
  List<LinkTransfer> receive(String deviceId, List<LinkIncomingSong> songs) {
    if (_closed) return const [];
    return [
      for (var start = 0; start < songs.length; start += linkTransferOfferLimit)
        _enqueue(
          deviceId,
          _newId(),
          songs.sublist(
            start,
            min(start + linkTransferOfferLimit, songs.length),
          ),
        ),
    ];
  }

  LinkTransfer _enqueue(
    String deviceId,
    String id,
    List<LinkIncomingSong> songs,
  ) {
    final job = _Incoming(id: id, deviceId: deviceId, songs: songs);
    final transfer = LinkTransfer(
      direction: LinkTransferDirection.incoming,
      peerId: deviceId,
      peerName: _deviceName(deviceId),
      entries: [for (final song in songs) linkIncomingEntry(song)],
      status: _status(job, LinkTransferState.queued),
      startedAt: _now(),
    );
    _incoming[id] = job;
    _waiting.add(job);
    _store().add(transfer, cancel: () => _cancelIncoming(id));
    _push(job, transfer.status);
    _pump();
    return transfer;
  }

  /// Starts the next queued transfer once none runs.
  void _pump() {
    if (_closed || _running != null || _waiting.isEmpty) return;
    final job = _running = _waiting.removeAt(0);
    unawaited(
      _run(job)
          .catchError((Object error, StackTrace stack) {
            _log.e('A song transfer stopped', error, stack);
            _finish(job, LinkTransferState.failed, reason: 'error');
          })
          .whenComplete(() {
            _incoming.remove(job.id);
            if (identical(_running, job)) _running = null;
            _pump();
          }),
    );
  }

  Future<void> _run(_Incoming job) async {
    _report(job, LinkTransferState.running);
    final LinkTransferDownloads downloads;
    final LinkOfflineDestination destination;
    try {
      downloads = _downloads();
      destination = downloads.destination();
    } on Object catch (error) {
      _log.w('No download folder for a song transfer: $error');
      return _finish(job, LinkTransferState.failed, reason: 'no_folder');
    }
    var saved = 0;
    for (var i = 0; i < job.songs.length; i++) {
      if (job.cancelled) {
        return _finish(job, LinkTransferState.cancelled);
      }
      if (job.disconnected || !_connected(job.deviceId)) {
        job.disconnected = true;
        return _finish(job, LinkTransferState.failed, reason: 'disconnected');
      }
      job
        ..index = i
        ..received = 0
        ..size = job.songs[i].song.size > 0 ? job.songs[i].song.size : null;
      switch (await _receiveSong(job, i, downloads, destination)) {
        case _Outcome.saved:
          saved++;
        case _Outcome.skipped:
          job.skipped.add(i);
        case _Outcome.failed:
          job.failed.add(i);
        case _Outcome.stopped:
          // The song in flight is discarded.
          return job.cancelled
              ? _finish(job, LinkTransferState.cancelled)
              : _finish(job, LinkTransferState.failed, reason: 'disconnected');
      }
      job
        ..index = i + 1
        ..received = 0
        ..size = null;
      if (i + 1 < job.songs.length) _report(job, LinkTransferState.running);
    }
    _finish(job, LinkTransferState.done);
    if (saved > 0) _onSaved?.call(job.deviceId);
  }

  /// Receives song [index] of [job]: skipped when the desktop has it, else
  /// fetched whole from the phone, copied into [destination] and recorded.
  Future<_Outcome> _receiveSong(
    _Incoming job,
    int index,
    LinkTransferDownloads downloads,
    LinkOfflineDestination destination,
  ) async {
    final song = job.songs[index].song;
    final historyId = linkTransferHistoryId(job.deviceId, song.name);
    if (await _has(song, historyId, downloads)) return _Outcome.skipped;
    final String path;
    try {
      final fetch = _fetch(
        job.deviceId,
        song.name,
        onProgress: (received, size) => _progress(job, index, received, size),
      );
      fetch.ignore();
      path = await Future.any([
        fetch,
        job.stopped.then<String>((_) => throw const _Stopped()),
      ]);
    } on _Stopped {
      return _Outcome.stopped;
    } on Object catch (error) {
      _log.w('Could not receive ${song.name}: $error');
      if (job.cancelled) return _Outcome.stopped;
      if (!_connected(job.deviceId)) {
        job.disconnected = true;
        return _Outcome.stopped;
      }
      return _Outcome.failed;
    }
    if (job.cancelled) return _Outcome.stopped;
    try {
      await _save(job, song, path, historyId, downloads, destination);
      return _Outcome.saved;
    } on Object catch (error) {
      _log.w('Could not save ${song.name}: $error');
      return _Outcome.failed;
    }
  }

  /// Whether the desktop already has [song]: its identity index resolves it
  /// (as phone songs are hidden, contract 12.3), or an earlier transfer
  /// saved it and the file is still there.
  Future<bool> _has(
    LinkPhoneSong song,
    String historyId,
    LinkTransferDownloads downloads,
  ) async {
    if (_index()?.songIdForRef(linkPhoneSongRef(song)) != null) return true;
    try {
      return await downloads.has(historyId);
    } on Object catch (error) {
      _log.w('Could not look up a received song: $error');
      return false;
    }
  }

  /// Copies the received file at [path] into the download folder as
  /// `<Album artist>/<Album>/<Title> - <Artist>.<ext>` and records it.
  Future<void> _save(
    _Incoming job,
    LinkPhoneSong song,
    String path,
    String historyId,
    LinkTransferDownloads downloads,
    LinkOfflineDestination destination,
  ) async {
    final item = linkReceivedItem(song, path);
    final fileName = LinkOfflineSaver.fileNameFor(item);
    final stored = await destination.store(
      File(path),
      relativeDir: LinkOfflineSaver.relativeDirFor(item),
      fileName: fileName,
      mimeType: networkContentType(fileName),
    );
    try {
      await downloads.record(
        linkReceivedHistory(
          song,
          id: historyId,
          path: path,
          stored: stored,
          downloadedAt: _now(),
        ),
      );
    } on Object {
      // A copy without its record is no download; leave nothing behind.
      try {
        await File(stored.filePath).delete();
      } on FileSystemException {
        // Already gone.
      }
      rethrow;
    }
  }

  /// Byte progress of song [index], reported at most every
  /// [progressInterval].
  void _progress(_Incoming job, int index, int received, int size) {
    if (_closed || job.cancelled || job.disconnected || job.index != index) {
      return;
    }
    job
      ..received = received
      ..size = size > 0 ? size : job.size;
    final now = _now();
    final last = job.reported;
    if (last != null && now.difference(last) < progressInterval) return;
    _report(job, LinkTransferState.running);
  }

  LinkTransferStatus _status(
    _Incoming job,
    LinkTransferState state, {
    String? reason,
  }) => LinkTransferStatus(
    transferId: job.id,
    state: state,
    total: job.songs.length,
    index: job.index,
    received: state.active ? job.received : 0,
    size: state.active ? job.size : null,
    skipped: List.unmodifiable(job.skipped),
    failed: List.unmodifiable(job.failed),
    reason: reason,
  );

  /// Shows [state] of [job] here and tells its phone.
  void _report(_Incoming job, LinkTransferState state, {String? reason}) {
    if (_closed) return;
    final status = _status(job, state, reason: reason);
    job.reported = _now();
    _store().update(status);
    // A phone that dropped hears nothing more.
    if (!job.disconnected) _push(job, status);
  }

  void _push(_Incoming job, LinkTransferStatus status) => unawaited(
    _send({
      'type': LinkMessageTypes.transfersStatus,
      ...status.toJson(),
    }, job.deviceId).catchError((Object _) => 0),
  );

  void _finish(_Incoming job, LinkTransferState state, {String? reason}) =>
      _report(job, state, reason: reason);

  /// Stops the incoming transfer [id]: a queued one at once, the running
  /// one after discarding the song in flight.
  void _cancelIncoming(String id) {
    final job = _incoming[id];
    if (job == null || job.cancelled) return;
    job.cancelled = true;
    if (_waiting.remove(job)) {
      _incoming.remove(id);
      _finish(job, LinkTransferState.cancelled);
    } else {
      job.stop();
    }
  }

  /// "Send to (phone)": offers [songs] to the phone [deviceId], as
  /// transfers of at most [linkTransferOfferLimit] songs each; returns them.
  /// The phone runs them and reports their status.
  Future<List<LinkTransfer>> send(
    String deviceId,
    List<LinkOutgoingSong> songs,
  ) async {
    final transfers = <LinkTransfer>[];
    for (
      var start = 0;
      start < songs.length && !_closed;
      start += linkTransferOfferLimit
    ) {
      final chunk = songs.sublist(
        start,
        min(start + linkTransferOfferLimit, songs.length),
      );
      final id = _newId();
      final transfer = LinkTransfer(
        direction: LinkTransferDirection.outgoing,
        peerId: deviceId,
        peerName: _deviceName(deviceId),
        entries: [for (final song in chunk) linkOutgoingEntry(song)],
        status: LinkTransferStatus(
          transferId: id,
          state: LinkTransferState.queued,
          total: chunk.length,
        ),
        startedAt: _now(),
      );
      _outgoing[id] = deviceId;
      _store().add(transfer, cancel: () => unawaited(_cancelOutgoing(id)));
      transfers.add(transfer);
      final delivered = await _send({
        'type': LinkMessageTypes.transfersOffer,
        'transferId': id,
        'songs': [for (final song in chunk) song.song.toJson()],
      }, deviceId).catchError((Object _) => 0);
      if (delivered == 0) _endOutgoing(id, LinkTransferState.failed);
    }
    return transfers;
  }

  /// Asks the phone to stop the outgoing transfer [id]; it reports
  /// `cancelled`. Without the phone it is marked cancelled here.
  Future<void> _cancelOutgoing(String id) async {
    final deviceId = _outgoing[id];
    if (deviceId == null) return;
    final delivered = await _send({
      'type': LinkMessageTypes.transfersCancel,
      'transferId': id,
    }, deviceId).catchError((Object _) => 0);
    if (delivered == 0) _endOutgoing(id, LinkTransferState.cancelled);
  }

  /// Ends the outgoing transfer [id] here: `failed` means the phone is gone.
  void _endOutgoing(String id, LinkTransferState state) {
    _outgoing.remove(id);
    if (_closed) return;
    final store = _store();
    final transfer = store.byId(id);
    if (transfer == null || !transfer.active) return;
    store.update(
      transfer.status.copyWith(
        state: state,
        reason: state == LinkTransferState.failed ? 'disconnected' : null,
      ),
    );
  }

  /// Takes `transfers.status` and `transfers.cancel` from the phone
  /// [deviceId]; returns whether [message] was one of them.
  bool onMessage(String deviceId, Map<String, dynamic> message) {
    switch (message['type']) {
      case LinkMessageTypes.transfersStatus:
        final status = LinkTransferStatus.fromJson(message);
        if (status == null ||
            _closed ||
            _outgoing[status.transferId] != deviceId) {
          return true;
        }
        if (!status.state.active) _outgoing.remove(status.transferId);
        _store().update(status);
        return true;
      case LinkMessageTypes.transfersCancel:
        final id = message['transferId'];
        if (id is String && _incoming[id]?.deviceId == deviceId) {
          _cancelIncoming(id);
        }
        return true;
    }
    return false;
  }

  /// Fails the transfers of phones that are no longer connected: incoming
  /// ones stop, outgoing ones are marked `failed` (`disconnected`).
  void keepConnected(Set<String> deviceIds) {
    for (final job in _incoming.values.toList()) {
      if (deviceIds.contains(job.deviceId) || job.disconnected) continue;
      job.disconnected = true;
      if (_waiting.remove(job)) {
        _incoming.remove(job.id);
        _finish(job, LinkTransferState.failed, reason: 'disconnected');
      } else {
        job.stop();
      }
    }
    for (final MapEntry(key: id, value: deviceId)
        in _outgoing.entries.toList()) {
      if (!deviceIds.contains(deviceId)) {
        _endOutgoing(id, LinkTransferState.failed);
      }
    }
  }

  /// Stops every transfer; the host is going away.
  void close() {
    _closed = true;
    for (final job in _incoming.values) {
      job.cancelled = true;
      job.stop();
    }
    _waiting.clear();
    _outgoing.clear();
  }
}

/// The latest transfer a phone offered the desktop, for its notice.
class LinkTransferOfferNotice extends Notifier<LinkTransfer?> {
  @override
  LinkTransfer? build() => null;

  void show(LinkTransfer transfer) => state = transfer;
}

final linkTransferOfferNoticeProvider =
    NotifierProvider<LinkTransferOfferNotice, LinkTransfer?>(
      LinkTransferOfferNotice.new,
    );
