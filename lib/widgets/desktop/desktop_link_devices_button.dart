import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/link_text_input_dialog.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/link/link_transfer_tile.dart';
import 'package:mornye/widgets/link/link_transfers_view.dart';

String _clock(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// The player bar button for phones connected over Mornye Link. It shows
/// only while the server runs and a phone is connected, rings its glyph
/// with the progress of active song transfers, and opens a popover with
/// each phone's playback, its transport and handoff actions, and the
/// transfers.
class DesktopLinkDevicesButton extends ConsumerStatefulWidget {
  const DesktopLinkDevicesButton({super.key});

  @override
  ConsumerState<DesktopLinkDevicesButton> createState() =>
      _DesktopLinkDevicesButtonState();
}

class _DesktopLinkDevicesButtonState
    extends ConsumerState<DesktopLinkDevicesButton> {
  final _menu = MenuController();

  void _toggle() => _menu.isOpen ? _menu.close() : _menu.open();

  /// Closes the popover, then asks for a link to open on [client]. The
  /// dialog belongs to the button, which outlives the popover.
  Future<void> _openLink(LinkClientInfo client) async {
    _menu.close();
    final l10n = context.l10n;
    String initial = '';
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (clip != null && linkOpenableUrl(clip)) initial = clip.trim();
    } on Object {
      // The clipboard is only a convenience.
    }
    if (!mounted) return;
    final url = await showLinkTextInputDialog(
      context,
      title: l10n.linkDesktopOpenLinkTitle(client.name),
      label: l10n.linkDesktopOpenLinkLabel,
      confirmLabel: l10n.linkDesktopOpen,
      initialValue: initial,
      keyboardType: TextInputType.url,
    );
    if (url == null || !mounted) return;
    final sent = await ref
        .read(linkDesktopHostProvider.notifier)
        .openOnPhone(client.deviceId, url);
    if (!mounted) return;
    showAppSnackBar(
      context,
      content: Text(
        sent
            ? l10n.linkDesktopSentToPhone(client.name)
            : l10n.linkDesktopNotDelivered,
      ),
    );
  }

  /// Closes the popover, then opens the Transfers list from the button.
  void _openTransfers() {
    _menu.close();
    unawaited(showLinkTransfers(context));
  }

  /// The phone glyph, ringed by the progress of the active transfers. The
  /// ring draws over the button's padding, so the bar keeps its layout.
  Widget _glyph(double? transfers) {
    final mornye = context.isMornye;
    final size = mornye ? 18.0 : 24.0;
    final glyph = AppIcon(
      mornye ? CupertinoIcons.device_phone_portrait : Icons.phonelink,
      size: transfers == null ? size : size * 0.75,
    );
    if (transfers == null) return glyph;
    final outset = size / 6;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            left: -outset,
            top: -outset,
            right: -outset,
            bottom: -outset,
            child: LinkTransferRing(
              key: const ValueKey('desktop-link-transfers-ring'),
              value: transfers,
              strokeWidth: 2,
            ),
          ),
          glyph,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(linkDevicesAvailableProvider)) {
      return const SizedBox.shrink();
    }
    final transfers = ref.watch(
      linkTransfersProvider.select(linkTransfersProgress),
    );
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _menu,
      consumeOutsideTap: true,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          mornye
              ? colorScheme.surfaceContainerHigh
              : colorScheme.surfaceContainerLow,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(mornye ? 14 : 16),
          ),
        ),
      ),
      menuChildren: [
        DesktopLinkDevicesPopover(
          onDone: _menu.close,
          onOpenLink: (client) => unawaited(_openLink(client)),
          onOpenTransfers: _openTransfers,
        ),
      ],
      child: AppIconButton(
        key: const ValueKey('desktop-link-devices-button'),
        tooltip: context.l10n.linkDesktopDevicesTitle,
        color: mornye ? colorScheme.onSurface : null,
        onPressed: _toggle,
        icon: _glyph(transfers),
      ),
    );
  }
}

/// The popover content: one section per connected phone, then the
/// transfers once one started.
class DesktopLinkDevicesPopover extends ConsumerWidget {
  const DesktopLinkDevicesPopover({
    super.key,
    required this.onDone,
    required this.onOpenLink,
    this.onOpenTransfers,
  });

  static const double width = 360;

  /// Closes the popover after an action that leaves it.
  final VoidCallback onDone;
  final ValueChanged<LinkClientInfo> onOpenLink;

  /// Opens the Transfers list; without it the popover leaves them out.
  final VoidCallback? onOpenTransfers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (:clients, :phoneStates) = ref.watch(
      linkDesktopHostProvider.select(
        (state) => (clients: state.clients, phoneStates: state.phoneStates),
      ),
    );
    return SizedBox(
      key: const ValueKey('desktop-link-devices-popover'),
      width: width,
      child: _IntrinsicHeightShield(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Semantics(
                header: true,
                child: Text(
                  context.l10n.linkDesktopDevicesTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: SingleChildScrollView(
                // The menu panel already owns the primary controller.
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final client in clients)
                      _PhoneSection(
                        key: ValueKey('link-phone-${client.deviceId}'),
                        client: client,
                        phoneState: phoneStates[client.deviceId],
                        onDone: onDone,
                        onOpenLink: () => onOpenLink(client),
                      ),
                  ],
                ),
              ),
            ),
            if (onOpenTransfers != null)
              _TransfersEntry(onTap: onOpenTransfers!),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Menus measure their panel's intrinsic size before laying it out, and the
/// slider and buttons in a phone section cannot report one. The panel only
/// needs the popover's fixed width from that measurement, so the height is
/// reported as zero instead of measuring the content; layout itself sizes
/// the popover to its content.
class _IntrinsicHeightShield extends SingleChildRenderObjectWidget {
  const _IntrinsicHeightShield({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIntrinsicHeightShield();
}

class _RenderIntrinsicHeightShield extends RenderProxyBox {
  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;
}

/// Transfers with their live summary, shown once one started this run.
class _TransfersEntry extends ConsumerWidget {
  const _TransfersEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(linkTransfersProvider);
    if (transfers.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final progress = linkTransfersProgress(transfers);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: tokens.gapSm, indent: 16, endIndent: 16),
        InkWell(
          key: const ValueKey('link-transfers-entry'),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              16,
              tokens.gapSm,
              12,
              tokens.gapSm,
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 20,
                  child: progress == null
                      ? AppIcon.adaptive(
                          Icons.swap_horiz_rounded,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        )
                      : LinkTransferRing(value: progress, strokeWidth: 2.5),
                ),
                SizedBox(width: tokens.gapSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.linkTransfersTitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        linkTransfersSummary(l10n, transfers),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: tokens.gapSm),
                AppIcon(
                  context.isMornye
                      ? CupertinoIcons.forward
                      : Icons.chevron_right,
                  size: tokens.rowChevronSize,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One phone: what it plays, its transport and the handoff actions.
class _PhoneSection extends ConsumerStatefulWidget {
  const _PhoneSection({
    super.key,
    required this.client,
    required this.phoneState,
    required this.onDone,
    required this.onOpenLink,
  });

  final LinkClientInfo client;
  final LinkPlayerState? phoneState;
  final VoidCallback onDone;
  final VoidCallback onOpenLink;

  @override
  ConsumerState<_PhoneSection> createState() => _PhoneSectionState();
}

class _PhoneSectionState extends ConsumerState<_PhoneSection> {
  Timer? _ticker;
  double? _dragging;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(_PhoneSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// Advances the position once a second while the phone plays.
  void _syncTicker() {
    final playing = widget.phoneState?.playing ?? false;
    if (playing) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _send(String action, [Map<String, dynamic> args = const {}]) {
    unawaited(
      ref
          .read(linkDesktopHostProvider.notifier)
          .sendCommand(widget.client.deviceId, LinkCommand(action, args)),
    );
  }

  Future<void> _continue() async {
    final l10n = context.l10n;
    final notifier = ref.read(linkDesktopHostProvider.notifier);
    final hasTrack = notifier.hasCurrentTrack;
    final sent =
        hasTrack && await notifier.continueOnPhone(widget.client.deviceId);
    // Report before closing the popover, which unmounts this section.
    if (mounted) {
      showAppSnackBar(
        context,
        content: Text(
          !hasTrack
              ? l10n.linkDesktopNothingToContinue
              : sent
              ? l10n.linkDesktopSentToPhone(widget.client.name)
              : l10n.linkDesktopNotDelivered,
        ),
      );
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mornye = context.isMornye;
    final tokens = context.tokens;
    final phone = widget.phoneState;
    final track = phone?.track;
    final playing = phone?.playing ?? false;
    final duration = phone?.durationMs ?? track?.durationMs;
    final position = phone?.positionAt(DateTime.now().millisecondsSinceEpoch);
    final canSeek = phone != null && duration != null && duration > 0;
    // Nothing to hand over once the music already plays on the phone, as
    // after Continue on phone; the phone's state rebuilds this section.
    final host = ref.read(linkDesktopHostProvider.notifier);
    final canContinue = host.hasCurrentTrack && (host.isPlaying || !playing);
    final fraction = canSeek
        ? (_dragging ?? (position! / duration).clamp(0.0, 1.0))
        : 0.0;

    Widget transportButton({
      required String tooltip,
      required IconData material,
      required IconData cupertino,
      required String action,
      String? key,
    }) => AppIconButton(
      key: key == null ? null : ValueKey(key),
      tooltip: tooltip,
      color: colorScheme.onSurface,
      onPressed: phone == null ? null : () => _send(action),
      icon: AppIcon(mornye ? cupertino : material, size: mornye ? 20 : 24),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(16, tokens.gapSm, 16, tokens.gapSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppIcon(
                mornye
                    ? CupertinoIcons.device_phone_portrait
                    : Icons.phone_android,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              SizedBox(width: tokens.gapSm),
              Expanded(
                child: Text(
                  widget.client.name.isEmpty
                      ? widget.client.deviceId
                      : widget.client.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.gapXs),
          Text(
            track == null ? l10n.linkDesktopPhoneNothingPlaying : track.title,
            style: theme.textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (track != null && track.artist.isNotEmpty)
            Text(
              track.artist,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (canSeek) ...[
            AppSlider(
              key: const ValueKey('link-phone-seek'),
              value: fraction,
              semanticLabel: track?.title,
              onChanged: (value) => setState(() => _dragging = value),
              onChangeEnd: (value) {
                setState(() => _dragging = null);
                _send(LinkActions.seek, {
                  'positionMs': (value * duration).round(),
                });
              },
            ),
            Row(
              children: [
                Text(
                  _clock((fraction * duration).round()),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                Text(
                  _clock(duration),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
          // Transport stays left to right in every language.
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                transportButton(
                  key: 'link-phone-previous',
                  tooltip: l10n.nowPlayingPreviousTrack,
                  material: Icons.skip_previous_rounded,
                  cupertino: CupertinoIcons.backward_fill,
                  action: LinkActions.previous,
                ),
                transportButton(
                  key: 'link-phone-play-pause',
                  tooltip: playing ? l10n.actionPause : l10n.tooltipPlay,
                  material: playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  cupertino: playing
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  action: playing ? LinkActions.pause : LinkActions.play,
                ),
                transportButton(
                  key: 'link-phone-next',
                  tooltip: l10n.nowPlayingNextTrack,
                  material: Icons.skip_next_rounded,
                  cupertino: CupertinoIcons.forward_fill,
                  action: LinkActions.next,
                ),
              ],
            ),
          ),
          Wrap(
            spacing: tokens.gapSm,
            runSpacing: tokens.gapXs,
            children: mornye
                ? [
                    if (canContinue)
                      TextButton(
                        key: const ValueKey('link-phone-continue'),
                        onPressed: () => unawaited(_continue()),
                        child: Text(l10n.linkDesktopContinueOnPhone),
                      ),
                    TextButton(
                      key: const ValueKey('link-phone-open'),
                      onPressed: widget.onOpenLink,
                      child: Text(l10n.linkDesktopOpenOnPhone),
                    ),
                  ]
                : [
                    if (canContinue)
                      ExpressiveButton(
                        key: const ValueKey('link-phone-continue'),
                        tonal: true,
                        onPressed: () => unawaited(_continue()),
                        child: Text(l10n.linkDesktopContinueOnPhone),
                      ),
                    ExpressiveButton(
                      key: const ValueKey('link-phone-open'),
                      text: true,
                      onPressed: widget.onOpenLink,
                      child: Text(l10n.linkDesktopOpenOnPhone),
                    ),
                  ],
          ),
        ],
      ),
    );
  }
}
