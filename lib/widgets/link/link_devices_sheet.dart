import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_downloads.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Opens the Devices sheet: the paired desktop's player, queue and
/// downloads, and handoff in both directions.
Future<void> showLinkDevicesSheet(BuildContext context) =>
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.linkDevicesTitle,
      builder: (context, controller) =>
          LinkDevicesSheet(scrollController: controller),
    );

/// The Devices entry of the player. Empty while no desktop is paired.
class LinkDevicesButton extends ConsumerWidget {
  const LinkDevicesButton({super.key, this.color, this.expressive = false});

  final Color? color;

  /// Draws an [ExpressiveIconButton], as in the Material player footer.
  final bool expressive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(linkPhoneClientProvider) == null) {
      return const SizedBox.shrink();
    }
    final icon = AppIcon(
      context.isMornye ? CupertinoIcons.desktopcomputer : Icons.computer,
    );
    final tooltip = context.l10n.linkDevicesTitle;
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

/// The body of the Devices sheet.
class LinkDevicesSheet extends ConsumerStatefulWidget {
  const LinkDevicesSheet({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  ConsumerState<LinkDevicesSheet> createState() => _LinkDevicesSheetState();
}

class _LinkDevicesSheetState extends ConsumerState<LinkDevicesSheet> {
  /// How many desktop queue items the sheet lists from the current one.
  static const _queueRows = 50;

  Timer? _ticker;
  double? _seekValue;
  double? _volumeValue;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      linkDesktopRemoteProvider.select(
        (remote) => remote.player?.playing ?? false,
      ),
      (_, playing) => _tick(playing),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Redraws the position once a second while the desktop plays.
  void _tick(bool playing) {
    if (playing == (_ticker != null)) return;
    _ticker?.cancel();
    _ticker = playing
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  Future<void> _run(
    LinkClientApi client,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) linkReportFailure(context, client, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null) {
      return const SizedBox.shrink();
    }
    final remote = ref.watch(linkDesktopRemoteProvider);
    final notifier = ref.read(linkDesktopRemoteProvider.notifier);
    final phonePlaying = ref.watch(
      currentMediaItemProvider.select((state) => state.value != null),
    );
    final player = remote.player;
    final l10n = context.l10n;
    final name = linkDesktopName(client);
    final connected = remote.connection == LinkConnectionState.connected;
    final queueStart = player == null ? 0 : player.index.clamp(0, 1 << 30);
    final queue = player == null
        ? const <TrackRef>[]
        : player.queue.skip(queueStart).take(_queueRows).toList();

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        SettingsGroup(
          children: [
            SettingsItem(
              icon: Icons.computer,
              title: name,
              subtitle: switch (remote.connection) {
                LinkConnectionState.connected => l10n.linkConnectionConnected,
                LinkConnectionState.connecting => l10n.linkConnectionConnecting,
                LinkConnectionState.disconnected =>
                  l10n.linkConnectionDisconnected,
              },
              showDivider: false,
            ),
          ],
        ),
        _LinkRemotePlayer(
          key: const ValueKey('link-remote-player'),
          name: name,
          player: player,
          loading: remote.loading,
          enabled: connected,
          seekValue: _seekValue,
          volumeValue: _volumeValue,
          onSeekChanged: (value) => setState(() => _seekValue = value),
          onSeekEnd: (value) {
            setState(() => _seekValue = null);
            _run(
              client,
              () => notifier.seek(Duration(milliseconds: value.round())),
            );
          },
          onVolumeChanged: (value) => setState(() => _volumeValue = value),
          onVolumeEnd: (value) {
            setState(() => _volumeValue = null);
            _run(client, () => notifier.setVolume(value));
          },
          onToggle: () => _run(client, notifier.toggle),
          onPrevious: () => _run(client, notifier.previous),
          onNext: () => _run(client, notifier.next),
          onShuffle: (enabled) =>
              _run(client, () => notifier.setShuffle(enabled)),
          onRepeat: (mode) => _run(client, () => notifier.setRepeat(mode)),
        ),
        SettingsGroup(
          children: [
            SettingsItem(
              key: const ValueKey('link-continue-on-phone'),
              icon: Icons.phone_android,
              title: l10n.linkContinueOnPhone,
              onTap: connected && player?.track != null
                  ? () {
                      final root = Navigator.of(
                        context,
                        rootNavigator: true,
                      ).context;
                      Navigator.pop(context);
                      linkContinueOnPhone(root, ref);
                    }
                  : null,
              showDivider: phonePlaying,
            ),
            if (phonePlaying)
              SettingsItem(
                key: const ValueKey('link-play-on-desktop'),
                icon: Icons.computer,
                title: l10n.linkPlayOnDesktop(name),
                onTap: connected
                    ? () {
                        final root = Navigator.of(
                          context,
                          rootNavigator: true,
                        ).context;
                        Navigator.pop(context);
                        linkPlayOnDesktop(root, ref);
                      }
                    : null,
                showDivider: false,
              ),
          ],
        ),
        if (queue.isNotEmpty) ...[
          SettingsSectionHeader(title: l10n.linkDesktopQueue(name)),
          SettingsGroup(
            children: [
              for (var i = 0; i < queue.length; i++)
                _LinkQueueRow(
                  key: ValueKey('link-queue-${queueStart + i}'),
                  track: queue[i],
                  current: queueStart + i == player!.index,
                  playing: player.playing,
                  showDivider: i < queue.length - 1,
                  onTap: connected
                      ? () => _run(client, () => notifier.jump(queueStart + i))
                      : null,
                ),
            ],
          ),
        ],
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
    );
  }
}

class _LinkRemotePlayer extends StatelessWidget {
  const _LinkRemotePlayer({
    super.key,
    required this.name,
    required this.player,
    required this.loading,
    required this.enabled,
    required this.seekValue,
    required this.volumeValue,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onVolumeChanged,
    required this.onVolumeEnd,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    required this.onShuffle,
    required this.onRepeat,
  });

  final String name;
  final LinkPlayerState? player;
  final bool loading;
  final bool enabled;
  final double? seekValue;
  final double? volumeValue;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onVolumeEnd;
  final VoidCallback onToggle;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<bool> onShuffle;
  final ValueChanged<LinkRepeatMode> onRepeat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final player = this.player;
    final track = player?.track;
    final mornye = context.isMornye;
    if (track == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: loading
            ? const Center(child: AppProgressIndicator.linear())
            : Text(
                l10n.linkDesktopNothingPlaying(name),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
      );
    }
    final durationMs = (player!.durationMs ?? track.durationMs ?? 0).toDouble();
    final positionMs =
        (seekValue ?? player.positionAt(DateTime.now().millisecondsSinceEpoch))
            .toDouble()
            .clamp(0.0, durationMs <= 0 ? 0.0 : durationMs);
    final playTooltip = player.playing ? l10n.actionPause : l10n.tooltipPlay;
    final repeatNext = switch (player.repeat) {
      LinkRepeatMode.none => LinkRepeatMode.all,
      LinkRepeatMode.all => LinkRepeatMode.one,
      LinkRepeatMode.one => LinkRepeatMode.none,
    };
    final repeatTooltip = switch (player.repeat) {
      LinkRepeatMode.none => l10n.nowPlayingRepeatOff,
      LinkRepeatMode.all => l10n.nowPlayingRepeatAll,
      LinkRepeatMode.one => l10n.nowPlayingRepeatOne,
    };
    final shuffleTooltip = player.shuffle
        ? l10n.nowPlayingShuffleOn
        : l10n.nowPlayingPlayInOrder;
    final shuffleIcon = mornye ? CupertinoIcons.shuffle : Icons.shuffle;
    final repeatIcon = mornye
        ? (player.repeat == LinkRepeatMode.one
              ? CupertinoIcons.repeat_1
              : CupertinoIcons.repeat)
        : (player.repeat == LinkRepeatMode.one
              ? Icons.repeat_one
              : Icons.repeat);

    Widget modeButton({
      required Key key,
      required IconData icon,
      required String tooltip,
      required bool selected,
      required VoidCallback onPressed,
    }) {
      if (!mornye) {
        return ExpressiveIconButton(
          key: key,
          icon: AppIcon(icon),
          tooltip: tooltip,
          selected: selected,
          foregroundColor: selected
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
          backgroundColor: selected ? colorScheme.primaryContainer : null,
          onPressed: enabled ? onPressed : null,
        );
      }
      return AppIconButton(
        key: key,
        icon: AppIcon(icon),
        tooltip: tooltip,
        isSelected: selected,
        color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
        onPressed: enabled ? onPressed : null,
      );
    }

    final shuffle = modeButton(
      key: const ValueKey('link-remote-shuffle'),
      icon: shuffleIcon,
      tooltip: shuffleTooltip,
      selected: player.shuffle,
      onPressed: () => onShuffle(!player.shuffle),
    );
    final repeat = modeButton(
      key: const ValueKey('link-remote-repeat'),
      icon: repeatIcon,
      tooltip: repeatTooltip,
      selected: player.repeat != LinkRepeatMode.none,
      onPressed: () => onRepeat(repeatNext),
    );

    final Widget transport;
    if (!mornye && materialExpressiveEnabled(context)) {
      transport = ExpressivePlaybackTransport(
        key: const ValueKey('link-remote-transport'),
        colorScheme: colorScheme,
        playing: player.playing,
        loading: false,
        playTooltip: playTooltip,
        previousTooltip: l10n.nowPlayingPreviousTrack,
        nextTooltip: l10n.nowPlayingNextTrack,
        onPlayPause: enabled ? onToggle : () {},
        onPrevious: enabled ? onPrevious : () {},
        onNext: enabled ? onNext : () {},
        leading: shuffle,
        trailing: repeat,
        compact: true,
        fill: true,
      );
    } else {
      transport = Row(
        key: const ValueKey('link-remote-transport'),
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          shuffle,
          AppIconButton(
            key: const ValueKey('link-remote-previous'),
            tooltip: l10n.nowPlayingPreviousTrack,
            iconSize: 32,
            color: colorScheme.onSurface,
            icon: AppIcon(
              mornye ? CupertinoIcons.backward_fill : Icons.skip_previous,
            ),
            onPressed: enabled ? onPrevious : null,
          ),
          AppIconButton(
            key: const ValueKey('link-remote-play'),
            tooltip: playTooltip,
            iconSize: 40,
            color: colorScheme.onSurface,
            icon: AppIcon(
              mornye
                  ? (player.playing
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill)
                  : (player.playing ? Icons.pause : Icons.play_arrow),
            ),
            onPressed: enabled ? onToggle : null,
          ),
          AppIconButton(
            key: const ValueKey('link-remote-next'),
            tooltip: l10n.nowPlayingNextTrack,
            iconSize: 32,
            color: colorScheme.onSurface,
            icon: AppIcon(
              mornye ? CupertinoIcons.forward_fill : Icons.skip_next,
            ),
            onPressed: enabled ? onNext : null,
          ),
          repeat,
        ],
      );
    }

    final volume = volumeValue ?? player.volume;
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            track.title,
            key: const ValueKey('link-remote-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (track.artist.isNotEmpty)
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 8),
          if (durationMs > 0) ...[
            AppSlider(
              key: const ValueKey('link-remote-seek'),
              value: positionMs,
              max: durationMs,
              semanticLabel: track.title,
              onChanged: enabled ? onSeekChanged : null,
              onChangeEnd: enabled ? onSeekEnd : null,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatClock(positionMs / 1000), style: labelStyle),
                Text(formatClock(durationMs / 1000), style: labelStyle),
              ],
            ),
          ],
          const SizedBox(height: 8),
          transport,
          const SizedBox(height: 8),
          Row(
            children: [
              AppIcon(
                mornye
                    ? CupertinoIcons.speaker_fill
                    : Icons.volume_down_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              Expanded(
                child: AppSlider(
                  key: const ValueKey('link-remote-volume'),
                  value: volume.clamp(0.0, 1.0),
                  semanticLabel: l10n.nowPlayingVolume,
                  onChanged: enabled ? onVolumeChanged : null,
                  onChangeEnd: enabled ? onVolumeEnd : null,
                ),
              ),
              AppIcon(
                mornye
                    ? CupertinoIcons.speaker_3_fill
                    : Icons.volume_up_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinkQueueRow extends StatelessWidget {
  const _LinkQueueRow({
    super.key,
    required this.track,
    required this.current,
    required this.playing,
    required this.showDivider,
    required this.onTap,
  });

  final TrackRef track;
  final bool current;
  final bool playing;
  final bool showDivider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SettingsItem(
      title: track.title,
      subtitle: track.artist.isEmpty ? null : track.artist,
      trailing: current
          ? NowPlayingIndicator(playing: playing, color: colorScheme.primary)
          : null,
      selected: current,
      showDivider: showDivider,
      onTap: current ? null : onTap,
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
