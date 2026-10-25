import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_downloads.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Opens the Devices sheet: where the music plays, this phone or the paired
/// desktop, and the desktop's downloads.
Future<void> showLinkDevicesSheet(BuildContext context) =>
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.linkDevicesTitle,
      builder: (context, controller) =>
          LinkDevicesSheet(scrollController: controller),
    );

/// The Devices entry of the player, drawn as the device that plays: this
/// phone, or the desktop playing in its place. Empty while no desktop is
/// paired.
class LinkDevicesButton extends ConsumerWidget {
  const LinkDevicesButton({super.key, this.color, this.expressive = false});

  /// The icon color; while the desktop plays, Material draws `primary`
  /// unless this is set.
  final Color? color;

  /// Draws an [ExpressiveIconButton], as in the Material player footer.
  final bool expressive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(linkPhoneClientProvider) == null) {
      return const SizedBox.shrink();
    }
    final remote = ref.watch(activeRemotePlaybackProvider);
    final color =
        this.color ??
        (remote != null && !context.isMornye
            ? Theme.of(context).colorScheme.primary
            : null);
    final icon = AppIcon(switch ((remote == null, context.isMornye)) {
      (true, true) => CupertinoIcons.device_phone_portrait,
      (true, false) => Icons.phone_android,
      (false, true) => CupertinoIcons.desktopcomputer,
      (false, false) => Icons.computer,
    });
    final tooltip = remote == null
        ? context.l10n.linkDevicesTitle
        : context.l10n.linkPlayingOn(remote.name);
    if (expressive) {
      return ExpressiveIconButton(
        key: const ValueKey('link-devices-button'),
        icon: icon,
        tooltip: tooltip,
        foregroundColor: color,
        onPressed: () => showLinkDevicesSheet(context),
      );
    }
    return AppIconButton(
      key: const ValueKey('link-devices-button'),
      icon: icon,
      tooltip: tooltip,
      color: color,
      onPressed: () => showLinkDevicesSheet(context),
    );
  }
}

/// The body of the Devices sheet: picks where the music plays, this phone
/// or the paired desktop, then lists the desktop's downloads. The device
/// that plays is checked and does nothing when tapped again; the player
/// screens show and drive whichever it is.
class LinkDevicesSheet extends ConsumerWidget {
  const LinkDevicesSheet({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null) {
      return const SizedBox.shrink();
    }
    final remote = ref.watch(linkDesktopRemoteProvider);
    final onDesktop = ref.watch(linkPlaysOnDesktopProvider);
    final phoneHasTrack = ref.watch(
      localMediaItemProvider.select((state) => state.value != null),
    );
    final desktopHasTrack = remote.player?.track != null;
    final l10n = context.l10n;
    final name = linkDesktopName(client);
    final connected = remote.connection == LinkConnectionState.connected;
    final check = AppIcon(
      Icons.check,
      color: Theme.of(context).colorScheme.primary,
    );

    void choose(void Function(BuildContext root) action) {
      final root = Navigator.of(context, rootNavigator: true).context;
      Navigator.pop(context);
      action(root);
    }

    void playHere(BuildContext root) {
      // Takes over what the desktop plays; with nothing to take over, the
      // phone's own queue comes back.
      if (connected && desktopHasTrack) {
        unawaited(linkContinueOnPhone(root, ref));
      } else {
        ref.read(linkPlaysOnDesktopProvider.notifier).set(false);
      }
    }

    void playOnDesktop(BuildContext root) {
      // What plays here moves there. A paused phone leaves the desktop's
      // own song in place unless the desktop has none.
      final phonePlaying = ref.read(playbackPlayingProvider);
      if (phonePlaying || (phoneHasTrack && !desktopHasTrack)) {
        unawaited(linkPlayOnDesktop(root, ref));
      } else {
        ref.read(linkPlaysOnDesktopProvider.notifier).set(true);
      }
    }

    // A column, not a list view, so the sheet fits its few rows instead of
    // opening tall and mostly empty.
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsGroup(
            children: [
              SettingsItem(
                key: const ValueKey('link-device-phone'),
                icon: Icons.phone_android,
                title: l10n.linkThisPhone,
                trailing: onDesktop ? null : check,
                selected: !onDesktop,
                onTap: onDesktop ? () => choose(playHere) : null,
              ),
              SettingsItem(
                key: const ValueKey('link-device-desktop'),
                icon: Icons.computer,
                title: name,
                subtitle: switch (remote.connection) {
                  LinkConnectionState.connected => l10n.linkConnectionConnected,
                  LinkConnectionState.connecting =>
                    l10n.linkConnectionConnecting,
                  LinkConnectionState.disconnected =>
                    l10n.linkConnectionDisconnected,
                },
                trailing: onDesktop ? check : null,
                selected: onDesktop,
                onTap: !onDesktop && connected
                    ? () => choose(playOnDesktop)
                    : null,
                showDivider: false,
              ),
            ],
          ),
          if (remote.downloads.isNotEmpty) ...[
            SettingsSectionHeader(title: l10n.linkDesktopDownloads(name)),
            SettingsGroup(
              children: [
                for (var i = 0; i < remote.downloads.length; i++)
                  LinkDesktopDownloadRow(
                    key: ValueKey('link-download-${remote.downloads[i].id}'),
                    download: remote.downloads[i],
                    showDivider: i < remote.downloads.length - 1,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// "Playing on (desktop)" in the player while the paired desktop plays in
/// the phone's place; tapping it opens the Devices sheet. Empty otherwise.
class LinkPlayingOnLabel extends ConsumerWidget {
  const LinkPlayingOnLabel({super.key, this.color});

  /// The label's color; Material defaults to `primary`.
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(activeRemotePlaybackProvider) == null) {
      return const SizedBox.shrink();
    }
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    final textTheme = Theme.of(context).textTheme;
    final mornye = context.isMornye;
    // Music names the playback route in small footnote type under the
    // player's actions.
    final label = LinkPlayingOnText(
      color: color,
      style: mornye
          ? textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)
          : textTheme.labelLarge,
      glyphSize: mornye ? 13 : 16,
    );
    if (mornye) {
      return CupertinoButton(
        key: const ValueKey('link-playing-on'),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: Size.square(context.tokens.minTouchTarget),
        onPressed: () => showLinkDevicesSheet(context),
        child: label,
      );
    }
    return InkWell(
      key: const ValueKey('link-playing-on'),
      customBorder: const StadiumBorder(),
      onTap: () => showLinkDevicesSheet(context),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: context.tokens.minTouchTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(widthFactor: 1, child: label),
        ),
      ),
    );
  }
}

/// "Playing on (desktop)" with a computer glyph, or "Sending this song to
/// (desktop)..." with its progress while a song only the phone has travels
/// there. Empty while this phone plays.
class LinkPlayingOnText extends ConsumerWidget {
  const LinkPlayingOnText({
    super.key,
    required this.color,
    this.style,
    this.glyphSize = 16,
  });

  final Color color;

  /// The text style, drawn in [color].
  final TextStyle? style;
  final double glyphSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remote = ref.watch(activeRemotePlaybackProvider);
    if (remote == null) return const SizedBox.shrink();
    final transfer = ref.watch(activeRemoteTransferProvider).value;
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (transfer == null)
          AppIcon(
            context.isMornye ? CupertinoIcons.desktopcomputer : Icons.computer,
            size: glyphSize,
            color: color,
          )
        else
          SizedBox.square(
            dimension: glyphSize,
            child: AppProgressIndicator.circular(
              key: const ValueKey('link-sending-progress'),
              value: transfer.fraction,
              color: color,
              strokeWidth: 2,
              wavy: false,
            ),
          ),
        SizedBox(width: glyphSize * 0.375),
        Flexible(
          child: Text(
            transfer == null
                ? l10n.linkPlayingOn(remote.name)
                : l10n.linkHandoffSending(remote.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(color: color) ?? TextStyle(color: color),
          ),
        ),
      ],
    );
  }
}

/// One download in the desktop's queue, with its status and progress.
class LinkDesktopDownloadRow extends StatelessWidget {
  const LinkDesktopDownloadRow({
    super.key,
    required this.download,
    this.showDivider = true,
  });

  final LinkDesktopDownload download;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final status = download.failed
        ? l10n.linkDownloadStatusFailed
        : download.finished
        ? l10n.linkDownloadStatusDone
        : download.status == 'downloading' || (download.progress ?? 0) > 0
        ? l10n.linkDownloadStatusDownloading
        : l10n.linkDownloadStatusQueued;
    final progress = download.progress;
    final running = !download.failed && !download.finished;
    final percent = running && progress != null
        ? ' ${(progress * 100).round()}%'
        : '';
    return SettingsItem(
      title: download.title,
      subtitle: [
        if (download.artist.isNotEmpty) download.artist,
        '$status$percent',
      ].join(' · '),
      footer: running && progress != null
          ? AppProgressIndicator.linear(
              value: progress,
              trackColor: colorScheme.surfaceContainerHighest,
            )
          : null,
      trailing: download.failed
          ? AppIcon.adaptive(Icons.error_outline, color: colorScheme.error)
          : download.finished
          ? AppIcon.adaptive(
              Icons.check_circle_outline,
              color: colorScheme.primary,
            )
          : null,
      showDivider: showDivider,
    );
  }
}
