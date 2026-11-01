import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_protocol.dart';

export 'package:mornye/services/link/link_protocol.dart'
    show LinkTransferState, LinkTransferStatus;

/// Which way a transfer goes for this device.
enum LinkTransferDirection {
  /// The other device's songs are copied here.
  incoming,

  /// This device's songs are copied to the other one.
  outgoing,
}

/// One song of a transfer, as the Transfers list shows it.
class LinkTransferEntry {
  const LinkTransferEntry({
    required this.title,
    required this.artist,
    this.album,
    this.coverPath,
  });

  final String title;
  final String artist;
  final String? album;

  /// A local cover file or an `http(s)` address, when this device knows one.
  final String? coverPath;
}

/// How one song of a transfer stands.
enum LinkTransferEntryState { pending, running, saved, skipped, failed }

/// A transfer between this device and a linked one (contract section 13):
/// the songs in offer order and the latest status the receiving device
/// reported, or this device's own when it receives.
class LinkTransfer {
  const LinkTransfer({
    required this.direction,
    required this.peerId,
    required this.peerName,
    required this.entries,
    required this.status,
    required this.startedAt,
    this.finishedAt,
  });

  final LinkTransferDirection direction;

  /// The other device: a phone's device id on the desktop, the desktop's
  /// server id on the phone.
  final String peerId;
  final String peerName;
  final List<LinkTransferEntry> entries;
  final LinkTransferStatus status;
  final DateTime startedAt;

  /// When the transfer stopped running (done, cancelled or failed).
  final DateTime? finishedAt;

  String get id => status.transferId;
  bool get active => status.state.active;

  LinkTransferEntryState stateOf(int index) {
    if (index < status.index) {
      if (status.failed.contains(index)) return LinkTransferEntryState.failed;
      if (status.skipped.contains(index)) {
        return LinkTransferEntryState.skipped;
      }
      return LinkTransferEntryState.saved;
    }
    if (index == status.index && status.state == LinkTransferState.running) {
      return LinkTransferEntryState.running;
    }
    return LinkTransferEntryState.pending;
  }

  LinkTransfer withStatus(LinkTransferStatus status, DateTime now) =>
      LinkTransfer(
        direction: direction,
        peerId: peerId,
        peerName: peerName,
        entries: entries,
        status: status,
        startedAt: startedAt,
        finishedAt: status.state.active ? null : (finishedAt ?? now),
      );
}

/// The transfers of this app run, newest first. Engines add theirs with a
/// cancel handler and report status; the UI lists them and cancels or
/// clears them. Nothing is kept across launches.
class LinkTransfers extends Notifier<List<LinkTransfer>> {
  final _cancels = <String, void Function()>{};

  DateTime Function() now = DateTime.now;

  @override
  List<LinkTransfer> build() => const [];

  LinkTransfer? byId(String id) {
    for (final transfer in state) {
      if (transfer.id == id) return transfer;
    }
    return null;
  }

  /// Adds [transfer] in front; [cancel] stops it (and tells the other
  /// device) when the listener asks to.
  void add(LinkTransfer transfer, {void Function()? cancel}) {
    if (cancel != null) _cancels[transfer.id] = cancel;
    state = [
      transfer,
      for (final other in state)
        if (other.id != transfer.id) other,
    ];
  }

  /// Takes [status] for the transfer it names; unknown ids are ignored.
  void update(LinkTransferStatus status) {
    var found = false;
    final next = [
      for (final transfer in state)
        if (transfer.id == status.transferId)
          () {
            found = true;
            return transfer.withStatus(status, now());
          }()
        else
          transfer,
    ];
    if (!found) return;
    if (!status.state.active) _cancels.remove(status.transferId);
    state = next;
  }

  /// Asks the engine running [id] to stop it.
  void cancel(String id) => _cancels[id]?.call();

  /// Removes the transfers that stopped.
  void clearFinished() {
    state = [
      for (final transfer in state)
        if (transfer.active) transfer,
    ];
  }
}

final linkTransfersProvider =
    NotifierProvider<LinkTransfers, List<LinkTransfer>>(LinkTransfers.new);
