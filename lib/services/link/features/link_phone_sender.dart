import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_library.dart';
import 'package:mornye/services/link/features/link_phone_receiver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkPhoneSender');

/// The `reason` codes of a failed transfer (contract section 13.1).
const _reasons = {'disconnected', 'no_folder', 'busy', 'error'};

/// Whether [item] plays from a file on this phone (a path or a content
/// URI), which the desktop can receive. The paired desktop's songs and
/// network sources stream instead.
bool isLinkPhoneSongItem(UnifiedLibraryItem item) {
  final path = item.filePath;
  return path.startsWith('/') || isContentUri(path);
}

/// The Library Songs row of [item], as [mapLinkPhoneRows] maps it.
Map<String, dynamic> linkPhoneRowOf(UnifiedLibraryItem item) => {
  'source': item.source == LibraryItemSource.local ? 'local' : 'downloaded',
  'item':
      item.localItem?.toJson() ??
      item.historyItem?.toJson() ??
      {
        'trackName': item.trackName,
        'artistName': item.artistName,
        'albumName': item.albumName,
        'filePath': item.filePath,
      },
};

/// The songs of [items] the desktop can take, named as the phone's song
/// list names them (contract section 12.1), mapped off the UI isolate:
/// it reads every file's size.
Future<LinkPhoneSongPage> linkPhoneSongsOf(
  Iterable<UnifiedLibraryItem> items, {
  LinkPhoneRowMapper map = _mapInIsolate,
}) => map([
  for (final item in items)
    if (isLinkPhoneSongItem(item)) linkPhoneRowOf(item),
]);

Future<LinkPhoneSongPage> _mapInIsolate(List<Map<String, dynamic>> rows) =>
    compute(mapLinkPhoneRows, rows);

/// One outgoing transfer: the files it offered and what holds it running.
class _Outgoing {
  _Outgoing({required this.client, required this.files});

  final LinkClientApi client;

  /// The file of each offered song, by [LinkPhoneSong.fileId].
  final Map<String, LinkPhoneFile> files;

  /// Set once this phone asked the desktop to stop it.
  Timer? cancelTimer;
  Future<void> Function()? release;
}

/// Sends this phone's songs to the paired desktop (contract section 13.3).
/// [send] offers a choice with `POST transfers/offer`, at most
/// [linkTransferOfferLimit] songs a transfer, each added to [transfers] as
/// an outgoing transfer. The desktop then pulls the files with
/// `files.request`: until a transfer stops, [fileNamed] gives
/// [LinkPhoneFileRequests] the files it offered, even when this phone's
/// song list is not shared. The desktop's `transfers.status` keeps each
/// transfer current; a transfer still running when the session drops
/// fails as `disconnected`.
class LinkPhoneSender {
  LinkPhoneSender({
    required this.transfers,
    this.acquireWork,
    String Function()? newId,
    DateTime Function()? now,
    this.cancelTimeout = const Duration(seconds: 10),
  }) : _newId = newId ?? newLinkTransferId,
       _now = now ?? DateTime.now;

  final LinkTransfers transfers;
  final LinkTransferWork? acquireWork;

  /// How long a transfer this phone cancelled waits for the desktop's
  /// `cancelled` before it is marked so here.
  final Duration cancelTimeout;
  final String Function() _newId;
  final DateTime Function() _now;

  LinkClientApi? _client;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _jobs = <String, _Outgoing>{};
  bool _disposed = false;

  /// Follows [client], the paired desktop's session, or none. Transfers to
  /// the session before stop as `disconnected`.
  void attach(LinkClientApi? client) {
    if (_disposed || identical(client, _client)) return;
    _unsubscribe();
    final previous = _client;
    _client = client;
    if (previous != null) _drop(previous);
    if (client == null) return;
    _subscriptions
      ..add(client.messages.listen(_handle))
      ..add(
        client.connectionStates.listen((state) {
          if (state != LinkConnectionState.connected) _drop(client);
        }),
      );
  }

  void dispose() {
    _disposed = true;
    _unsubscribe();
    for (final id in [..._jobs.keys]) {
      _stop(id, LinkTransferState.failed, reason: 'disconnected');
    }
  }

  void _unsubscribe() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  /// Offers [songs] to [client]'s desktop, split into transfers of at most
  /// [linkTransferOfferLimit] songs; a file listed twice goes once. Returns
  /// the transfers the desktop took. Throws the error of the first offer
  /// when it took none, [LinkException] `disconnected` while the session
  /// is not connected.
  Future<List<LinkTransfer>> send(
    LinkClientApi client,
    LinkPhoneSongPage songs,
  ) async {
    if (_disposed || songs.songs.isEmpty) return const [];
    if (client.connectionState != LinkConnectionState.connected) {
      throw const LinkException('disconnected', 'The computer is offline');
    }
    final picked = <int>[];
    final seen = <String>{};
    for (var i = 0; i < songs.songs.length; i++) {
      if (seen.add(songs.songs[i].fileId)) picked.add(i);
    }
    final started = <LinkTransfer>[];
    Object? firstError;
    for (
      var start = 0;
      start < picked.length;
      start += linkTransferOfferLimit
    ) {
      final end = math.min(start + linkTransferOfferLimit, picked.length);
      try {
        started.add(await _offer(client, songs, picked.sublist(start, end)));
      } on Object catch (error) {
        firstError ??= error;
      }
    }
    if (started.isEmpty && firstError != null) throw firstError;
    return started;
  }

  Future<LinkTransfer> _offer(
    LinkClientApi client,
    LinkPhoneSongPage songs,
    List<int> chunk,
  ) async {
    final id = _newId();
    final job = _Outgoing(
      client: client,
      files: {for (final i in chunk) songs.songs[i].fileId: songs.files[i]},
    );
    final transfer = LinkTransfer(
      direction: LinkTransferDirection.outgoing,
      peerId: client.server.serverId,
      peerName: linkDesktopName(client),
      entries: [
        for (final i in chunk)
          LinkTransferEntry(
            title: songs.songs[i].title,
            artist: songs.songs[i].artist,
            album: songs.songs[i].album,
            coverPath: songs.covers[i]?.path ?? songs.songs[i].coverUrl,
          ),
      ],
      status: LinkTransferStatus(
        transferId: id,
        state: LinkTransferState.queued,
        total: chunk.length,
      ),
      startedAt: _now(),
    );
    // Known before the offer goes, so the desktop's first status and file
    // requests find it.
    _jobs[id] = job;
    transfers.add(transfer, cancel: () => cancel(id));
    unawaited(_hold(id, job, transfer));
    try {
      final reply = await client.post(LinkOps.transfersOffer, {
        'transferId': id,
        'songs': [for (final i in chunk) songs.songs[i].toJson()],
      });
      final accepted = reply is Map ? reply['accepted'] : null;
      if (accepted is num && accepted <= 0) {
        throw const LinkException('invalid', 'The computer took no song');
      }
      return transfer;
    } on Object catch (error) {
      _log.w('Could not offer songs to the desktop: $error');
      _stop(
        id,
        LinkTransferState.failed,
        reason: error is LinkException && _reasons.contains(error.code)
            ? error.code
            : 'error',
      );
      rethrow;
    }
  }

  Future<void> _hold(String id, _Outgoing job, LinkTransfer transfer) async {
    final Future<void> Function()? release;
    try {
      release = await acquireWork?.call(transfer);
    } on Object catch (error) {
      _log.w('Could not keep a transfer running in the background: $error');
      return;
    }
    if (identical(_jobs[id], job)) {
      job.release = release;
    } else {
      await release?.call();
    }
  }

  /// The file a running transfer offered as [name] (`<fileId>.<suffix>`).
  LinkPhoneFile? fileNamed(String name) {
    final dot = name.indexOf('.');
    final fileId = dot < 0 ? name : name.substring(0, dot);
    for (final job in _jobs.values) {
      if (job.files[fileId] case final file?) return file;
    }
    return null;
  }

  /// Asks the desktop to stop [transferId], and marks it cancelled when the
  /// desktop does not answer within [cancelTimeout] or is not connected.
  void cancel(String transferId) {
    final job = _jobs[transferId];
    if (job == null || job.cancelTimer != null) return;
    if (job.client.connectionState != LinkConnectionState.connected) {
      _stop(transferId, LinkTransferState.cancelled);
      return;
    }
    job.client.send({
      'type': LinkMessageTypes.transfersCancel,
      'transferId': transferId,
    });
    job.cancelTimer = Timer(
      cancelTimeout,
      () => _stop(transferId, LinkTransferState.cancelled),
    );
  }

  void _handle(Map<String, dynamic> message) {
    if (_disposed || message['type'] != LinkMessageTypes.transfersStatus) {
      return;
    }
    final status = LinkTransferStatus.fromJson(message);
    if (status == null) return;
    final job = _jobs[status.transferId];
    if (job == null) return;
    transfers.update(status);
    if (!status.state.active) {
      _jobs.remove(status.transferId);
      _release(job);
    }
  }

  /// The session to [client] dropped: its transfers fail.
  void _drop(LinkClientApi client) {
    for (final entry in [..._jobs.entries]) {
      if (identical(entry.value.client, client)) {
        _stop(entry.key, LinkTransferState.failed, reason: 'disconnected');
      }
    }
  }

  void _stop(String id, LinkTransferState state, {String? reason}) {
    final job = _jobs.remove(id);
    if (job == null) return;
    _release(job);
    final status = transfers.byId(id)?.status;
    if (status == null || !status.state.active) return;
    transfers.update(status.copyWith(state: state, reason: reason));
  }

  void _release(_Outgoing job) {
    job.cancelTimer?.cancel();
    final release = job.release;
    job.release = null;
    if (release != null) unawaited(release());
  }
}
