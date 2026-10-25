import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoButton, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/track_card.dart' show TrackCoverPlaceholder;

/// Separates the parts of a transfer's status line.
const _separator = ' · ';

/// The title of [transfer]: "Sending 12 songs to Studio" while it runs or
/// waits, "12 songs to Studio" once it stopped, with the song's title in
/// place of the count when it carries one song.
String linkTransferTitle(AppLocalizations l10n, LinkTransfer transfer) {
  final count = _songCount(transfer);
  final name = transfer.peerName;
  final song = count == 1 ? transfer.entries.firstOrNull?.title : null;
  final title = song == null || song.isEmpty ? null : song;
  final outgoing = transfer.direction == LinkTransferDirection.outgoing;
  if (transfer.active) {
    return switch ((outgoing, title)) {
      (true, final String title) => l10n.linkTransfersSendingSong(title, name),
      (true, null) => l10n.linkTransfersSending(count, name),
      (false, final String title) => l10n.linkTransfersReceivingSong(
        title,
        name,
      ),
      (false, null) => l10n.linkTransfersReceiving(count, name),
    };
  }
  return switch ((outgoing, title)) {
    (true, final String title) => l10n.linkTransfersSongTo(title, name),
    (true, null) => l10n.linkTransfersSongsTo(count, name),
    (false, final String title) => l10n.linkTransfersSongFrom(title, name),
    (false, null) => l10n.linkTransfersSongsFrom(count, name),
  };
}

/// How [transfer] ended: "11 saved · 1 already there · 1 failed", "Stopped
/// after 5 of 12" or why it failed. "Waiting" while it is queued, and the
/// song it copies with its progress while it runs.
String linkTransferStatusText(AppLocalizations l10n, LinkTransfer transfer) {
  final status = transfer.status;
  switch (status.state) {
    case LinkTransferState.queued:
      return l10n.linkTransfersWaiting;
    case LinkTransferState.running:
      final current = _runningSubtitle(transfer);
      return [
        if (current.isNotEmpty) current,
        _runningProgress(l10n, transfer),
      ].join(_separator);
    case LinkTransferState.done:
      return _counts(l10n, status, always: true).join(_separator);
    case LinkTransferState.cancelled:
      return l10n.linkTransfersStopped(status.index, status.total);
    case LinkTransferState.failed:
      final reason = switch (status.reason) {
        'disconnected' => l10n.linkTransfersReasonDisconnected,
        'no_folder' =>
          transfer.direction == LinkTransferDirection.incoming
              ? l10n.linkTransfersReasonNoFolder
              : l10n.linkTransfersReasonNoFolderPeer(transfer.peerName),
        'busy' => l10n.linkTransfersReasonBusy,
        _ => l10n.linkTransfersReasonError,
      };
      return [reason, ..._counts(l10n, status)].join(_separator);
  }
}

/// [fraction] as a whole percentage. An active transfer stays below 100
/// until its last song is saved.
int linkTransferPercent(double fraction, {required bool active}) {
  final percent = (fraction.clamp(0.0, 1.0) * 100).floor();
  return active ? math.min(percent, 99) : percent;
}

int _songCount(LinkTransfer transfer) =>
    transfer.status.total > 0 ? transfer.status.total : transfer.entries.length;

/// The saved, already there and failed counts that are not zero; with
/// [always], "0 saved" when all three are.
List<String> _counts(
  AppLocalizations l10n,
  LinkTransferStatus status, {
  bool always = false,
}) {
  final saved = math.max(0, status.saved);
  return [
    if (saved > 0 || always && status.skipped.isEmpty && status.failed.isEmpty)
      l10n.linkTransfersSavedCount(saved),
    if (status.skipped.isNotEmpty)
      l10n.linkTransfersAlreadyThereCount(status.skipped.length),
    if (status.failed.isNotEmpty)
      l10n.linkTransfersFailedCount(status.failed.length),
  ];
}

/// The song a running transfer copies, or the artist of its only song.
String _runningSubtitle(LinkTransfer transfer) {
  final entries = transfer.entries;
  if (_songCount(transfer) == 1) return entries.firstOrNull?.artist ?? '';
  final index = transfer.status.index;
  return index < entries.length ? entries[index].title : '';
}

/// "3 of 12 · 45%", or the percentage alone for a single song.
String _runningProgress(AppLocalizations l10n, LinkTransfer transfer) {
  final status = transfer.status;
  final percent = l10n.linkTransfersPercent(
    linkTransferPercent(status.fraction, active: true),
  );
  if (_songCount(transfer) <= 1) return percent;
  final position = math.min(status.index + 1, status.total);
  return [
    l10n.linkTransfersPosition(position, status.total),
    percent,
  ].join(_separator);
}

/// The share of the running song that arrived, when its size is known.
double? _songFraction(LinkTransferStatus status) {
  final size = status.size;
  if (status.state != LinkTransferState.running || size == null || size <= 0) {
    return null;
  }
  return (status.received / size).clamp(0.0, 1.0);
}

/// Eases [value] between status updates, which arrive a few times a second,
/// and jumps under reduced motion.
class _Eased extends StatelessWidget {
  const _Eased({required this.value, required this.builder});

  final double value;
  final Widget Function(double value) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : context.tokens.motionMedium,
    builder: (context, value, _) => builder(value),
  );
}

/// A determinate progress ring that eases between status updates: around a
/// transfer's device glyphs, a song in progress and the player bar button.
class LinkTransferRing extends StatelessWidget {
  const LinkTransferRing({
    super.key,
    required this.value,
    required this.strokeWidth,
  });

  final double value;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    return ExcludeSemantics(
      child: _Eased(
        value: value,
        builder: (value) => AppProgressIndicator.circular(
          value: value,
          strokeWidth: strokeWidth,
          strokeCap: StrokeCap.round,
          wavy: false,
          color: scheme.primary,
          trackColor: mornye
              ? scheme.surfaceContainerHighest
              : scheme.secondaryContainer,
        ),
      ),
    );
  }
}

/// The linear progress of transfers, easing between status updates: the
/// expressive track on Material, a thin capsule on Mornye.
class LinkTransferProgressBar extends StatelessWidget {
  const LinkTransferProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: _Eased(
        value: value,
        builder: (value) => context.isMornye
            ? AppProgressIndicator.linear(
                value: value,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
                trackColor: scheme.surfaceContainerHighest,
              )
            : AppProgressIndicator.linear(value: value),
      ),
    );
  }
}

/// The two devices of [transfer] with an arrow from the one whose songs are
/// copied to the one that keeps them, in a [size] circle: ringed by the
/// progress while it is active, filled by its outcome once it stopped.
class LinkTransferGlyph extends StatelessWidget {
  const LinkTransferGlyph({
    super.key,
    required this.transfer,
    required this.size,
  });

  final LinkTransfer transfer;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final status = transfer.status;
    final active = transfer.active;
    final failed =
        status.state == LinkTransferState.failed ||
        status.state == LinkTransferState.done &&
            status.total > 0 &&
            status.failed.length >= status.total;
    // Mornye's accent may be red, so only a failure is colored once the
    // transfer stopped.
    final (Color fill, Color ink) = active
        ? (Colors.transparent, scheme.primary)
        : failed
        ? mornye
              ? (scheme.surfaceContainerHighest, scheme.error)
              : (scheme.errorContainer, scheme.onErrorContainer)
        : status.state == LinkTransferState.done
        ? mornye
              ? (scheme.surfaceContainerHighest, scheme.onSurface)
              : (scheme.secondaryContainer, scheme.onSecondaryContainer)
        : (scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    // This device and the linked one: a computer and a phone.
    final here = isDesktopPlatform ? Icons.computer : Icons.phone_android;
    final there = isDesktopPlatform ? Icons.phone_android : Icons.computer;
    final outgoing = transfer.direction == LinkTransferDirection.outgoing;
    final device = size * 0.28;
    final effects = AppMotion.effects(
      context,
      AppMotionSpec(
        MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : context.tokens.motionMedium,
        Curves.easeOut,
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: effects.duration,
                curve: effects.curve,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              ),
            ),
            if (active)
              Positioned.fill(
                child: LinkTransferRing(
                  key: const ValueKey('link-transfer-ring'),
                  value: status.fraction,
                  strokeWidth: size / 16,
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon.adaptive(
                  outgoing ? here : there,
                  size: device,
                  color: ink,
                ),
                AppIcon(
                  mornye ? mornyeArrowForward : Icons.arrow_forward_rounded,
                  size: size * 0.2,
                  color: ink,
                ),
                AppIcon.adaptive(
                  outgoing ? there : here,
                  size: device,
                  color: ink,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One transfer as a row: its devices, what it copies and how it stands,
/// with its progress and a stop button while it is active. Tapping it calls
/// [onTap], which shows or hides its songs.
class LinkTransferTile extends ConsumerWidget {
  const LinkTransferTile({
    super.key,
    required this.transfer,
    this.expanded = false,
    this.onTap,
    this.inkRadius = BorderRadius.zero,
  });

  final LinkTransfer transfer;
  final bool expanded;
  final VoidCallback? onTap;

  /// Clips the tap feedback to the row's surface.
  final BorderRadius inkRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mornye = context.isMornye;
    final status = transfer.status;
    final active = transfer.active;
    final running = status.state == LinkTransferState.running;
    final subtitleStyle =
        (mornye ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
            ?.copyWith(
              color: status.state == LinkTransferState.failed
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            );
    final subtitle = running
        ? _runningSubtitle(transfer)
        : linkTransferStatusText(l10n, transfer);
    final turn = AppMotion.spatialFast(
      context,
      AppMotionSpec(
        MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : tokens.motionFast,
        Curves.easeOutCubic,
      ),
    );

    return Semantics(
      container: true,
      expanded: onTap == null ? null : expanded,
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(borderRadius: inkRadius),
        splashColor: scheme.primary.withValues(alpha: 0.12),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.rowPaddingH,
            vertical: tokens.rowPaddingV,
          ),
          child: Row(
            children: [
              LinkTransferGlyph(transfer: transfer, size: tokens.coverCompact),
              SizedBox(width: tokens.rowIconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      linkTransferTitle(l10n, transfer),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: running ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleStyle,
                      ),
                    ],
                    if (active) ...[
                      SizedBox(height: tokens.gapSm),
                      Row(
                        children: [
                          Expanded(
                            child: LinkTransferProgressBar(
                              key: const ValueKey('link-transfer-progress'),
                              value: status.fraction,
                            ),
                          ),
                          if (running) ...[
                            SizedBox(width: tokens.gapSm),
                            Text(
                              _runningProgress(l10n, transfer),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (active) ...[
                SizedBox(width: tokens.gapXs),
                _StopButton(
                  onPressed: () => ref
                      .read(linkTransfersProvider.notifier)
                      .cancel(transfer.id),
                ),
              ],
              if (onTap != null) ...[
                SizedBox(width: active ? 0 : tokens.gapSm),
                ExcludeSemantics(
                  child: AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: turn.duration,
                    curve: turn.curve,
                    child: AppIcon(
                      mornye
                          ? CupertinoIcons.chevron_down
                          : Icons.expand_more_rounded,
                      size: tokens.rowChevronSize,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tooltip = context.l10n.linkTransfersStop;
    if (!context.isMornye) {
      return AppIconButton(
        key: const ValueKey('link-transfer-stop'),
        tooltip: tooltip,
        icon: const AppIcon(Icons.close_rounded),
        onPressed: onPressed,
      );
    }
    return Tooltip(
      message: tooltip,
      child: CupertinoButton(
        key: const ValueKey('link-transfer-stop'),
        padding: EdgeInsets.zero,
        minimumSize: Size.square(context.tokens.minTouchTarget),
        onPressed: onPressed,
        child: Icon(
          CupertinoIcons.xmark_circle_fill,
          size: 24,
          semanticLabel: tooltip,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One transfer as slivers: its [LinkTransferTile] and, while [expanded],
/// its songs, built only near the viewport so a long transfer opens as
/// quickly as a short one. The songs grow open with a spatial spring.
class LinkTransferSliver extends StatefulWidget {
  const LinkTransferSliver({
    super.key,
    required this.transfer,
    required this.expanded,
    required this.onToggle,
    this.color,
    this.borderRadius = BorderRadius.zero,
  });

  final LinkTransfer transfer;
  final bool expanded;
  final VoidCallback onToggle;

  /// The transfer's own surface; null when its group draws one.
  final Color? color;

  /// The corners of the transfer's surface, which also clip its feedback.
  final BorderRadius borderRadius;

  @override
  State<LinkTransferSliver> createState() => _LinkTransferSliverState();
}

class _LinkTransferSliverState extends State<LinkTransferSliver>
    with SingleTickerProviderStateMixin {
  late final _reveal = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );

  @override
  void didUpdateWidget(LinkTransferSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    final tokens = context.tokens;
    final reduced = MediaQuery.disableAnimationsOf(context);
    // Exits are shorter than entrances.
    final motion = widget.expanded
        ? AppMotion.spatial(
            context,
            AppMotionSpec(
              reduced ? Duration.zero : tokens.motionMedium,
              Curves.easeOutCubic,
            ),
          )
        : AppMotion.spatialFast(
            context,
            AppMotionSpec(
              reduced ? Duration.zero : tokens.motionFast,
              Curves.easeOutCubic,
            ),
          );
    _reveal.animateTo(
      widget.expanded ? 1 : 0,
      duration: motion.duration,
      curve: motion.curve,
    );
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transfer = widget.transfer;
    final tokens = context.tokens;
    final radius = widget.borderRadius;
    final songs = SliverPadding(
      padding: EdgeInsets.only(bottom: tokens.gapSm),
      sliver: SliverList.builder(
        itemCount: transfer.entries.length,
        itemBuilder: (context, index) => _TransferSongRow(
          entry: transfer.entries[index],
          state: transfer.stateOf(index),
          stopped: !transfer.active,
          fraction: index == transfer.status.index
              ? _songFraction(transfer.status)
              : null,
          indent: tokens.rowPaddingH + tokens.coverCompact + tokens.rowIconGap,
        ),
      ),
    );
    Widget sliver = SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Material(
            type: MaterialType.transparency,
            child: LinkTransferTile(
              transfer: transfer,
              expanded: widget.expanded,
              onTap: transfer.entries.isEmpty ? null : widget.onToggle,
              inkRadius: widget.expanded
                  ? radius.copyWith(
                      bottomLeft: Radius.zero,
                      bottomRight: Radius.zero,
                    )
                  : radius,
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _reveal,
          child: songs,
          builder: (context, songs) => _reveal.value == 0
              ? const SliverToBoxAdapter()
              : _SliverReveal(factor: _reveal.value, sliver: songs!),
        ),
      ],
    );
    final color = widget.color;
    if (color != null) {
      sliver = DecoratedSliver(
        decoration: BoxDecoration(color: color, borderRadius: radius),
        sliver: sliver,
      );
    }
    return sliver;
  }
}

/// One song of an open transfer: its cover, title, artist and state.
class _TransferSongRow extends StatelessWidget {
  const _TransferSongRow({
    required this.entry,
    required this.state,
    required this.stopped,
    required this.indent,
    this.fraction,
  });

  final LinkTransferEntry entry;
  final LinkTransferEntryState state;

  /// The transfer stopped, so songs it did not reach stay where they are.
  final bool stopped;

  /// Lines the song up with the transfer's title.
  final double indent;

  /// The share of this song that arrived, while it is copied.
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mornye = context.isMornye;
    final fraction = this.fraction;
    final label = switch (state) {
      LinkTransferEntryState.saved => l10n.linkTransfersSongSaved,
      LinkTransferEntryState.skipped => l10n.linkTransfersSongAlreadyThere,
      LinkTransferEntryState.failed => l10n.linkTransfersSongFailed,
      LinkTransferEntryState.running =>
        fraction == null
            ? l10n.linkTransfersSongCopying
            : [
                l10n.linkTransfersSongCopying,
                l10n.linkTransfersPercent(
                  linkTransferPercent(fraction, active: true),
                ),
              ].join(_separator),
      LinkTransferEntryState.pending =>
        stopped ? l10n.linkTransfersSongNotCopied : l10n.linkTransfersWaiting,
    };
    const glyph = 20.0;
    final Widget? trailing = switch (state) {
      // Mornye's accent may be red, which would read as a failure.
      LinkTransferEntryState.saved => AppIcon(
        mornye ? CupertinoIcons.checkmark_circle_fill : Icons.check_circle,
        size: glyph,
        color: mornye ? scheme.onSurface : scheme.primary,
      ),
      LinkTransferEntryState.skipped => AppIcon(
        mornye ? CupertinoIcons.checkmark_circle : Icons.check_circle_outline,
        size: glyph,
        color: scheme.onSurfaceVariant,
      ),
      LinkTransferEntryState.failed => AppIcon(
        mornye
            ? CupertinoIcons.exclamationmark_circle_fill
            : Icons.error_outline,
        size: glyph,
        color: scheme.error,
      ),
      LinkTransferEntryState.running => SizedBox.square(
        dimension: glyph,
        child: fraction != null
            ? LinkTransferRing(value: fraction, strokeWidth: 2.5)
            : mornye
            ? const CupertinoActivityIndicator(radius: glyph / 2)
            : const AppProgressIndicator.circular(strokeWidth: 2.5),
      ),
      LinkTransferEntryState.pending => null,
    };
    return MergeSemantics(
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          indent,
          tokens.gapXs,
          tokens.rowPaddingH,
          tokens.gapXs,
        ),
        child: Row(
          children: [
            _TransferCover(path: entry.coverPath, size: tokens.coverMini),
            SizedBox(width: tokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    [
                      if (entry.artist.isNotEmpty) entry.artist,
                      label,
                    ].join(_separator),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: state == LinkTransferEntryState.failed
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: tokens.gapSm),
              ExcludeSemantics(child: trailing),
            ],
          ],
        ),
      ),
    );
  }
}

/// A song's cover from a local file or an `http(s)` address, else the
/// shared placeholder.
class _TransferCover extends StatelessWidget {
  const _TransferCover({required this.path, required this.size});

  final String? path;
  final double size;

  static bool _usable(String path) =>
      path.startsWith('http://') ||
      path.startsWith('https://') ||
      File(path).isAbsolute;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    final placeholder = TrackCoverPlaceholder(size: size);
    if (path == null || path.isEmpty || !_usable(path)) return placeholder;
    return ClipRRect(
      borderRadius: context.tokens.borderRadiusThumb,
      child: LocalOrNetworkCoverImage(
        url: path,
        width: size,
        height: size,
        networkCacheWidth: (size * 2).toInt(),
        placeholder: (_) => placeholder,
      ),
    );
  }
}

/// Shows the leading [factor] of its sliver's extent and clips the rest, so
/// a lazily built list can grow open. Expects a downward vertical scroll.
class _SliverReveal extends SingleChildRenderObjectWidget {
  const _SliverReveal({required this.factor, required Widget sliver})
    : super(child: sliver);

  final double factor;

  @override
  _RenderSliverReveal createRenderObject(BuildContext context) =>
      _RenderSliverReveal(factor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverReveal renderObject,
  ) {
    renderObject.factor = factor;
  }
}

class _RenderSliverReveal extends RenderProxySliver {
  _RenderSliverReveal(this._factor);

  double _factor;
  set factor(double value) {
    if (value == _factor) return;
    _factor = value;
    markNeedsLayout();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    final full = child.geometry!;
    if (_factor >= 1 || full.scrollOffsetCorrection != null) {
      geometry = full;
      return;
    }
    final extent = full.scrollExtent * math.max(0.0, _factor);
    final paintExtent = calculatePaintOffset(constraints, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      maxPaintExtent: extent,
      hitTestExtent: paintExtent,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: extent),
      hasVisualOverflow: true,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !geometry!.visible) {
      _clip.layer = null;
      return;
    }
    if (_factor >= 1) {
      _clip.layer = null;
      context.paintChild(child, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Rect.fromLTWH(0, 0, constraints.crossAxisExtent, geometry!.paintExtent),
      (context, offset) => context.paintChild(child, offset),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
