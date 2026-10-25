import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/link/features/link_downloads.dart';
import 'package:mornye/services/link/features/link_library_lookup.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_sender.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';
import 'package:mornye/widgets/selection_action_button.dart';

export 'package:mornye/services/link/features/link_phone_client.dart'
    show linkDesktopName, linkPhoneClientProvider;

final _log = AppLogger('LinkActions');

/// Up to three [titles], then how many more there are.
String linkTitleList(Iterable<String> titles) {
  final all = titles.where((title) => title.trim().isNotEmpty).toList();
  final shown = all.take(3).join(', ');
  return all.length > 3 ? '$shown +${all.length - 3}' : shown;
}

void _notify(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

void _failed(BuildContext context, LinkClientApi client, Object error) {
  _log.w('Link request failed: $error');
  if (!context.mounted) return;
  _notify(context, context.l10n.linkRequestFailed(linkDesktopName(client)));
}

/// "Play on (desktop)": moves this phone's queue to the desktop, which then
/// plays in the phone's place.
Future<void> linkPlayOnDesktop(BuildContext context, WidgetRef ref) async {
  final handoff = ref.read(linkHandoffProvider);
  if (handoff == null) return;
  final target = ref.read(linkPlaysOnDesktopProvider.notifier);
  final name = linkDesktopName(handoff.client);
  var sending = false;
  try {
    final result = await handoff.playOnDesktop(
      onSending: (_, _) {
        if (sending || !context.mounted) return;
        sending = true;
        _notify(context, context.l10n.linkHandoffSending(name));
      },
    );
    if (result != null && result.started) target.set(true);
    if (!context.mounted) return;
    if (sending) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final l10n = context.l10n;
    if (result == null) {
      _notify(context, l10n.linkHandoffNothingPlaying);
    } else if (!result.started) {
      _notify(context, l10n.linkHandoffNotFound(name));
    } else if (result.missing.isNotEmpty) {
      _notify(
        context,
        l10n.linkHandoffMissing(
          name,
          linkTitleList(result.missingTracks.map((ref) => ref.title)),
        ),
      );
    } else {
      _notify(context, l10n.linkHandoffStarted(name));
    }
  } on Object catch (error) {
    if (context.mounted) _failed(context, handoff.client, error);
  }
}

/// "Continue on this phone": takes over what the desktop plays.
Future<void> linkContinueOnPhone(BuildContext context, WidgetRef ref) async {
  final handoff = ref.read(linkHandoffProvider);
  if (handoff == null) return;
  final target = ref.read(linkPlaysOnDesktopProvider.notifier);
  try {
    final result = await handoff.continueOnPhone();
    if (result.started) target.set(false);
    if (!context.mounted) return;
    final l10n = context.l10n;
    if (!result.started) {
      _notify(context, l10n.linkContinueNotFound);
    } else if (result.skipped.isNotEmpty) {
      _notify(
        context,
        l10n.linkContinueSkipped(
          linkTitleList(result.skipped.map((ref) => ref.title)),
        ),
      );
    }
  } on Object catch (error) {
    if (context.mounted) _failed(context, handoff.client, error);
  }
}

/// Sends a `POST downloads` [body] and reports how many tracks the desktop
/// queued.
Future<void> linkDownloadOnDesktop(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> body,
) async {
  final client = ref.read(linkPhoneClientProvider);
  if (client == null) return;
  try {
    final queued = await linkQueueDesktopDownloads(client, body);
    if (!context.mounted) return;
    _notify(
      context,
      context.l10n.linkDownloadQueuedOnDesktop(queued, linkDesktopName(client)),
    );
  } on Object catch (error) {
    if (context.mounted) _failed(context, client, error);
  }
}

/// "Download on (desktop)" for [tracks] from search results or a link.
Future<void> linkDownloadTracksOnDesktop(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  String? service,
  String? playlistName,
}) {
  if (tracks.isEmpty) return Future.value();
  return linkDownloadOnDesktop(
    context,
    ref,
    linkDownloadTracksBody(
      tracks,
      service: service,
      playlistName: playlistName,
    ),
  );
}

/// "Open on (desktop)" for a shared link.
Future<void> linkOpenUrlOnDesktop(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  final client = ref.read(linkPhoneClientProvider);
  if (client == null) return;
  try {
    await linkOpenOnDesktop(client, url);
    if (context.mounted) {
      _notify(
        context,
        context.l10n.linkOpenedOnDesktop(linkDesktopName(client)),
      );
    }
  } on Object catch (error) {
    if (context.mounted) _failed(context, client, error);
  }
}

/// The choices for a link shared to the app while a desktop is paired:
/// open it in the desktop app, or let the desktop download it.
Future<void> showLinkSharedUrlSheet(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  final client = ref.read(linkPhoneClientProvider);
  if (client == null) return;
  final name = linkDesktopName(client);
  final root = Navigator.of(context, rootNavigator: true).context;
  await showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.linkSendToDesktop(name),
    subtitle: url,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppSheetOption(
          leading: const AppIcon.adaptive(Icons.open_in_new),
          title: Text(sheetContext.l10n.linkOpenOnDesktop(name)),
          onTap: () {
            Navigator.pop(sheetContext);
            linkOpenUrlOnDesktop(root, ref, url);
          },
        ),
        AppSheetOption(
          leading: const AppIcon.adaptive(Icons.download),
          title: Text(sheetContext.l10n.linkDownloadOnDesktop(name)),
          onTap: () {
            Navigator.pop(sheetContext);
            linkDownloadOnDesktop(root, ref, linkDownloadUrlBody(url));
          },
        ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

/// Shows that a transfer started, named by [message], with a View action
/// that opens the Transfers list.
void _showTransfer(BuildContext context, String message) {
  if (!context.mounted) return;
  final navigator = Navigator.of(context, rootNavigator: true).context;
  showAppSnackBar(
    context,
    content: Text(message),
    action: SnackBarAction(
      label: context.l10n.linkTransferPhoneView,
      onPressed: () {
        if (navigator.mounted) unawaited(showLinkTransfers(navigator));
      },
    ),
  );
}

/// Whether the paired desktop's session is connected, which the transfer
/// actions need. Rebuilds the widget when it connects or drops.
bool _watchConnected(WidgetRef ref) =>
    ref.watch(linkPhoneClientProvider) != null &&
    ref.watch(linkConnectionStateProvider).value ==
        LinkConnectionState.connected;

/// [_watchConnected] for menus built once, outside a widget's build.
bool linkTransfersAvailable(WidgetRef ref) =>
    ref.read(linkPhoneClientProvider)?.connectionState ==
    LinkConnectionState.connected;

/// "Save to this phone": queues a transfer that copies the original files
/// of desktop [songs] into the download folder, and says it started.
void linkSaveSongsToPhone(
  BuildContext context,
  WidgetRef ref,
  List<LinkOfflineSong> songs,
) {
  if (songs.isEmpty) return;
  final transfer = ref.read(linkPhoneReceiverProvider).save(songs);
  if (transfer == null || !context.mounted) return;
  _showTransfer(context, linkTransferTitle(context.l10n, transfer));
}

/// "Send to (desktop)": offers this phone's own songs among [items] to the
/// paired desktop, which copies them into its download folder, and says it
/// started.
Future<void> linkSendSongsToDesktop(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
) async {
  final client = ref.read(linkPhoneClientProvider);
  if (client == null) return;
  final sender = ref.read(linkPhoneSenderProvider);
  final root = Navigator.of(context, rootNavigator: true).context;
  final name = linkDesktopName(client);
  try {
    final songs = await linkPhoneSongsOf(items);
    if (!root.mounted) return;
    if (songs.songs.isEmpty) {
      _notify(root, root.l10n.linkSendNothing(name));
      return;
    }
    final started = await sender.send(client, songs);
    if (!root.mounted || started.isEmpty) return;
    final count = started.fold(0, (sum, next) => sum + next.entries.length);
    final title = count == 1 ? started.single.entries.single.title : '';
    _showTransfer(root, root.l10n.linkSendSending(count, title, name));
  } on Object catch (error) {
    if (root.mounted) _failed(root, client, error);
  }
}

/// Says when the paired desktop starts sending songs to this phone, with
/// the View action. Watched at the app root on phones; the snackbar shows
/// over whatever page is open.
final linkTransferOfferNoticesProvider = Provider<void>((ref) {
  final subscription = ref.watch(linkPhoneReceiverProvider).offers.listen((
    transfer,
  ) {
    final context = AppNavigationService.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final count = transfer.entries.length;
    _showTransfer(
      context,
      context.l10n.linkTransferPhoneOffered(
        count,
        count == 1 ? transfer.entries.single.title : '',
        transfer.peerName,
      ),
    );
  });
  ref.onDispose(subscription.cancel);
});

/// The app bar action of an album or playlist that queues its [tracks] on
/// the paired desktop. Empty while no desktop is paired.
class LinkDownloadOnDesktopButton extends ConsumerWidget {
  const LinkDownloadOnDesktopButton({
    super.key,
    required this.tracks,
    this.service,
    this.playlistName,
  });

  final List<Track> tracks;
  final String? service;
  final String? playlistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null) return const SizedBox.shrink();
    return HeaderCircleButton(
      icon: Icons.computer,
      tooltip: context.l10n.linkDownloadOnDesktop(linkDesktopName(client)),
      onPressed: tracks.isEmpty
          ? null
          : () => linkDownloadTracksOnDesktop(
              context,
              ref,
              tracks,
              service: service,
              playlistName: playlistName,
            ),
    );
  }
}

/// This phone's own songs among [items], which it can send to the desktop.
List<UnifiedLibraryItem> linkPhoneSongItemsOf(
  Iterable<UnifiedLibraryItem> items,
) => [
  for (final item in items)
    if (isLinkPhoneSongItem(item)) item,
];

/// The app bar actions of a Library album: "Send to (desktop)" when [items]
/// hold this phone's own songs and "Save to this phone" when they hold the
/// paired desktop's, while that desktop is connected. Empty otherwise.
class LinkTransferButtons extends ConsumerWidget {
  const LinkTransferButtons({super.key, required this.items});

  final List<UnifiedLibraryItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null || !_watchConnected(ref)) {
      return const SizedBox.shrink();
    }
    final phoneSongs = linkPhoneSongItemsOf(items);
    final desktopSongs = linkOfflineSongs([
      for (final item in items) ?item.localItem,
    ], client.server);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (phoneSongs.isNotEmpty)
          HeaderCircleButton(
            icon: Icons.computer,
            tooltip: context.l10n.linkSendToDesktop(linkDesktopName(client)),
            onPressed: () => linkSendSongsToDesktop(context, ref, phoneSongs),
          ),
        if (desktopSongs.isNotEmpty)
          HeaderCircleButton(
            icon: Icons.phone_android,
            tooltip: context.l10n.linkSaveToPhone,
            onPressed: () => linkSaveSongsToPhone(context, ref, desktopSongs),
          ),
      ],
    );
  }
}

/// The app bar action of a Library playlist: a sheet that sends this
/// phone's own songs among [tracks] to the paired desktop or saves the
/// desktop's to this phone, while that desktop is connected. The songs are
/// looked up when one is chosen. Empty otherwise.
class LinkTrackTransferButton extends ConsumerWidget {
  const LinkTrackTransferButton({super.key, required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null || tracks.isEmpty || !_watchConnected(ref)) {
      return const SizedBox.shrink();
    }
    return HeaderCircleButton(
      icon: Icons.devices,
      iconSize: 20,
      tooltip: context.l10n.linkTransferPhoneWith(linkDesktopName(client)),
      onPressed: () => _showSheet(context, ref, client),
    );
  }

  Future<void> _showSheet(
    BuildContext context,
    WidgetRef ref,
    LinkClientApi client,
  ) async {
    final name = linkDesktopName(client);
    final root = Navigator.of(context, rootNavigator: true).context;
    Future<List<UnifiedLibraryItem>> items() => linkLibraryItemsFor(
      tracks,
      includeLocal: ref.read(settingsProvider).localLibraryEnabled,
    );
    await showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      title: context.l10n.linkTransferPhoneWith(name),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSheetOption(
            leading: const AppIcon.adaptive(Icons.computer),
            title: Text(sheetContext.l10n.linkSendToDesktop(name)),
            onTap: () async {
              Navigator.pop(sheetContext);
              final found = await items();
              if (root.mounted) await linkSendSongsToDesktop(root, ref, found);
            },
          ),
          AppSheetOption(
            leading: const AppIcon.adaptive(Icons.phone_android),
            title: Text(sheetContext.l10n.linkSaveToPhone),
            onTap: () async {
              Navigator.pop(sheetContext);
              final found = await items();
              if (!root.mounted) return;
              final songs = linkOfflineSongs([
                for (final item in found) ?item.localItem,
              ], client.server);
              if (songs.isEmpty) {
                _notify(root, root.l10n.linkTransferPhoneNothing(name));
              } else {
                linkSaveSongsToPhone(root, ref, songs);
              }
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// The Library selection toolbar's Mornye Link actions for the selected
/// [items]: "Send to (desktop)" for this phone's own songs and "Save to
/// this phone" for the paired desktop's, while that desktop is connected.
/// [onClose] ends the selection once one starts.
List<Widget> linkTransferSelectionActions(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items, {
  required VoidCallback onClose,
}) {
  final client = ref.watch(linkPhoneClientProvider);
  if (client == null || !_watchConnected(ref)) return const [];
  final colors = Theme.of(context).colorScheme;
  final phoneSongs = linkPhoneSongItemsOf(items);
  final desktopSongs = linkOfflineSongs([
    for (final item in items) ?item.localItem,
  ], client.server);
  return [
    if (phoneSongs.isNotEmpty)
      SelectionActionButton(
        icon: Icons.computer,
        label: context.l10n.linkSendToDesktop(linkDesktopName(client)),
        colorScheme: colors,
        onPressed: () {
          final root = Navigator.of(context, rootNavigator: true).context;
          unawaited(linkSendSongsToDesktop(root, ref, phoneSongs));
          onClose();
        },
      ),
    if (desktopSongs.isNotEmpty)
      SelectionActionButton(
        icon: Icons.phone_android,
        label: context.l10n.linkSaveToPhone,
        colorScheme: colors,
        onPressed: () {
          final root = Navigator.of(context, rootNavigator: true).context;
          linkSaveSongsToPhone(root, ref, desktopSongs);
          onClose();
        },
      ),
  ];
}

/// The paired desktop's songs among [items], or none.
List<LinkOfflineSong> linkDesktopSongsOf(
  WidgetRef ref,
  Iterable<LocalLibraryItem> items,
) {
  final server = ref.read(linkPhoneClientProvider)?.server;
  return server == null ? const [] : linkOfflineSongs(items, server);
}

/// Reports a request to the paired desktop that failed.
void linkReportFailure(
  BuildContext context,
  LinkClientApi client,
  Object error,
) => _failed(context, client, error);
