import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_desktop_transfers.dart';
import 'package:mornye/services/link/desktop/link_transfer_songs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';

/// The phones connected to the desktop's Mornye Link server. The app root
/// starts the host on desktop; a menu never starts it.
List<LinkClientInfo> _connectedPhones(WidgetRef ref) {
  if (!isDesktopPlatform || !ref.exists(linkDesktopHostProvider)) {
    return const [];
  }
  final host = ref.read(linkDesktopHostProvider);
  return host.running ? host.clients : const [];
}

String _phoneName(LinkClientInfo phone) =>
    phone.name.isEmpty ? phone.deviceId : phone.name;

/// Whether a desktop page offers Mornye Link transfers: a phone is
/// connected. Rebuilds the page when that changes.
bool watchDesktopLinkPhones(WidgetRef ref) =>
    isDesktopPlatform &&
    ref.exists(linkDesktopHostProvider) &&
    ref.watch(linkDevicesAvailableProvider);

/// The Mornye Link rows of a desktop song menu acting on [items] (contract
/// 13.5): "Send to (phone)" for each connected phone while [items] hold
/// songs of this computer, and "Save to this computer" while they hold
/// songs of a connected phone. Empty while no phone is connected. [onDone]
/// ends the selection the menu acts on.
List<ContextMenuAction> desktopLinkTransferActions(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items, {
  VoidCallback? onDone,
}) {
  final phones = _connectedPhones(ref);
  if (phones.isEmpty || items.isEmpty) return const [];
  final root = Navigator.of(context, rootNavigator: true).context;
  final sources = {
    for (final phone in phones) linkPhoneSourceId(phone.deviceId),
  };
  final own = items.any((item) => linkDesktopSongIdOf(item) != null);
  final fromPhone = items.any(
    (item) => sources.contains(linkPhoneSongPath(item.filePath)?.sourceId),
  );
  return _actions(
    context,
    phones: own ? phones : const [],
    save: fromPhone,
    send: (phone) {
      onDone?.call();
      unawaited(desktopSendToPhone(root, phone, items));
    },
    saveHere: () {
      onDone?.call();
      unawaited(desktopSaveToComputer(root, items));
    },
  );
}

/// The Mornye Link rows for playlist [tracks], which are looked up in the
/// Library once a row is chosen. "Save to this computer" shows while a
/// track may be a phone song.
List<ContextMenuAction> desktopLinkTransferTrackActions(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  VoidCallback? onDone,
}) {
  final phones = _connectedPhones(ref);
  if (phones.isEmpty || tracks.isEmpty) return const [];
  final root = Navigator.of(context, rootNavigator: true).context;
  Future<List<UnifiedLibraryItem>> items() =>
      linkLibraryItemsForTracks(tracks, ref.read(linkCatalogIndexProvider));
  return _actions(
    context,
    phones: phones,
    save: tracks.any(linkMayBePhoneTrack),
    send: (phone) {
      final found = items();
      onDone?.call();
      unawaited(() async {
        final chosen = await found;
        if (root.mounted) await desktopSendToPhone(root, phone, chosen);
      }());
    },
    saveHere: () {
      final found = items();
      onDone?.call();
      unawaited(() async {
        final chosen = await found;
        if (root.mounted) await desktopSaveToComputer(root, chosen);
      }());
    },
  );
}

List<ContextMenuAction> _actions(
  BuildContext context, {
  required List<LinkClientInfo> phones,
  required bool save,
  required void Function(LinkClientInfo phone) send,
  required VoidCallback saveHere,
}) {
  final l10n = context.l10n;
  return [
    for (final phone in phones)
      ContextMenuAction(
        icon: Icons.phone_android,
        label: l10n.linkTransferDesktopSendTo(_phoneName(phone)),
        onSelected: () => send(phone),
      ),
    if (save)
      ContextMenuAction(
        icon: Icons.computer,
        label: l10n.linkTransferDesktopSaveHere,
        onSelected: saveHere,
      ),
  ];
}

/// "Send to (phone)": offers the desktop's own songs of [items] to [phone]
/// and names the transfer in a snackbar. [context] outlives the menu, such
/// as the root navigator's, since the page that opened it may close.
Future<void> desktopSendToPhone(
  BuildContext context,
  LinkClientInfo phone,
  List<UnifiedLibraryItem> items,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final store = container.read(linkTransfersProvider.notifier);
  final transfers = await container
      .read(linkDesktopHostProvider.notifier)
      .sendToPhone(phone.deviceId, items);
  if (!context.mounted) return;
  final l10n = context.l10n;
  if (transfers.isEmpty) {
    showAppSnackBar(
      context,
      content: Text(l10n.linkTransferDesktopNothingToSend),
    );
    return;
  }
  final delivered = transfers.any(
    (transfer) =>
        store.byId(transfer.id)?.status.state != LinkTransferState.failed,
  );
  if (!delivered) {
    showAppSnackBar(context, content: Text(l10n.linkDesktopNotDelivered));
    return;
  }
  showDesktopLinkTransferSnackBar(
    context,
    linkTransferDesktopMessage(l10n, transfers),
  );
}

/// "Save to this computer": copies the songs of [items] that a connected
/// phone has into the download folder and names the transfer in a
/// snackbar. [context] outlives the menu, as for [desktopSendToPhone].
Future<void> desktopSaveToComputer(
  BuildContext context,
  List<UnifiedLibraryItem> items,
) async {
  final transfers = await ProviderScope.containerOf(
    context,
    listen: false,
  ).read(linkDesktopHostProvider.notifier).saveToComputer(items);
  if (!context.mounted) return;
  if (transfers.isEmpty) {
    showAppSnackBar(
      context,
      content: Text(context.l10n.linkTransferDesktopNothingToSave),
    );
    return;
  }
  showDesktopLinkTransferSnackBar(
    context,
    linkTransferDesktopMessage(context.l10n, transfers),
  );
}

/// The snackbar line naming [transfers] that just started, all with one
/// phone: the song's title when there is one song, else the count.
String linkTransferDesktopMessage(
  AppLocalizations l10n,
  List<LinkTransfer> transfers,
) {
  final first = transfers.first;
  final name = first.peerName;
  final count = transfers.fold<int>(
    0,
    (sum, transfer) => sum + transfer.entries.length,
  );
  final title = count == 1 ? first.entries.single.title : null;
  return switch (first.direction) {
    LinkTransferDirection.outgoing =>
      title == null
          ? l10n.linkTransferDesktopSendingSongs(count, name)
          : l10n.linkTransferDesktopSendingSong(title, name),
    LinkTransferDirection.incoming =>
      title == null
          ? l10n.linkTransferDesktopReceivingSongs(count, name)
          : l10n.linkTransferDesktopReceivingSong(title, name),
  };
}

/// Shows [message] with a "View" action that opens the Transfers list.
void showDesktopLinkTransferSnackBar(BuildContext context, String message) {
  final root = Navigator.of(context, rootNavigator: true).context;
  showAppSnackBar(
    context,
    content: Text(message),
    action: SnackBarAction(
      label: context.l10n.linkTransferDesktopView,
      onPressed: () {
        if (root.mounted) unawaited(showLinkTransfers(root));
      },
    ),
  );
}

/// Names a transfer a phone starts sending to this computer in a snackbar,
/// while the desktop shell is mounted.
class DesktopLinkTransferNotices extends ConsumerWidget {
  const DesktopLinkTransferNotices({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(linkTransferOfferNoticeProvider, (_, transfer) {
      if (transfer == null || !context.mounted) return;
      showDesktopLinkTransferSnackBar(
        context,
        linkTransferDesktopMessage(context.l10n, [transfer]),
      );
    });
    return child;
  }
}
