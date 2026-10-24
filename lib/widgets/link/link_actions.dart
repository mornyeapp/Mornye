import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/features/link_downloads.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';

final _log = AppLogger('LinkActions');

/// The paired desktop's name for labels such as "Play on Studio PC".
String linkDesktopName(LinkClientApi client) {
  final name = client.server.name.trim();
  return name.isEmpty ? 'Mornye' : name;
}

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

/// "Play on (desktop)": moves this phone's queue to the desktop.
Future<void> linkPlayOnDesktop(BuildContext context, WidgetRef ref) async {
  final handoff = ref.read(linkHandoffProvider);
  if (handoff == null) return;
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
  try {
    final result = await handoff.continueOnPhone();
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

/// "Save to this phone": downloads the original files of desktop [songs]
/// into the download folder, with progress and a way to stop.
Future<void> linkSaveSongsToPhone(
  BuildContext context,
  WidgetRef ref,
  List<LinkOfflineSong> songs,
) async {
  final saver = ref.read(linkOfflineSaverProvider);
  if (saver == null || songs.isEmpty) return;
  final root = Navigator.of(context, rootNavigator: true).context;
  final cancel = LinkOfflineCancel();
  var open = true;
  void close() {
    if (!open) return;
    open = false;
    if (root.mounted) BatchProgressDialog.dismiss(root);
  }

  BatchProgressDialog.show(
    context: root,
    title: root.l10n.linkSavingToPhone,
    total: songs.length,
    icon: Icons.phone_android,
    onCancel: () {
      cancel.cancel();
      close();
    },
  );
  final LinkOfflineResult result;
  try {
    result = await saver.save(
      songs,
      cancel: cancel,
      onProgress: (progress) {
        if (!open) return;
        final size = progress.size;
        final percent = size == null || size <= 0
            ? null
            : (progress.received * 100 / size).clamp(0, 100).round();
        BatchProgressDialog.update(
          current: math.min(progress.done + 1, progress.total),
          detail: percent == null
              ? progress.title
              : '${progress.title} ($percent%)',
        );
      },
    );
  } finally {
    close();
  }
  if (!root.mounted) return;
  final l10n = root.l10n;
  final message = result.cancelled
      ? l10n.linkSaveToPhoneCancelled
      : result.failed > 0
      ? l10n.linkSaveToPhoneFailed(result.failed)
      : l10n.linkSavedToPhone(result.saved);
  _notify(root, message);
}

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

/// The app bar action of a Library album that saves its songs from the
/// paired desktop to this phone. Empty when none of [items] come from it.
class LinkSaveToPhoneButton extends ConsumerWidget {
  const LinkSaveToPhoneButton({super.key, required this.items});

  final List<LocalLibraryItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(linkPhoneClientProvider)?.server;
    if (server == null) return const SizedBox.shrink();
    final songs = linkOfflineSongs(items, server);
    if (songs.isEmpty) return const SizedBox.shrink();
    return HeaderCircleButton(
      icon: Icons.phone_android,
      tooltip: context.l10n.linkSaveToPhone,
      onPressed: () => linkSaveSongsToPhone(context, ref, songs),
    );
  }
}

/// Whether [items] hold songs of the paired desktop.
bool linkHasDesktopSongs(WidgetRef ref, Iterable<LocalLibraryItem> items) {
  final server = ref.watch(linkPhoneClientProvider)?.server;
  return server != null && linkOfflineSongs(items, server).isNotEmpty;
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
