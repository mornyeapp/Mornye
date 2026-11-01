import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// Downloads that are waiting, running or finalizing, in queue order.
List<DownloadItem> activeDesktopDownloads(List<DownloadItem> items) => [
  for (final item in items)
    if (item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing)
      item,
];

/// How many of [items] are active and their overall progress: waiting items
/// count as not started. One pass, so a progress sample allocates nothing.
({int count, double progress}) desktopDownloadsSummary(
  List<DownloadItem> items,
) {
  var count = 0;
  var total = 0.0;
  for (final item in items) {
    final status = item.status;
    if (status != DownloadStatus.queued &&
        status != DownloadStatus.downloading &&
        status != DownloadStatus.finalizing) {
      continue;
    }
    count++;
    total += status == DownloadStatus.finalizing
        ? 1
        : status == DownloadStatus.downloading
        ? item.progress.clamp(0.0, 1.0)
        : 0;
  }
  return (count: count, progress: count == 0 ? 0 : total / count);
}

/// The desktop toolbar button for downloads: a ring shows overall progress
/// while anything downloads, and clicking opens a popover that lists the
/// active downloads with cancel buttons and a link to the full queue.
class DesktopDownloadsButton extends ConsumerStatefulWidget {
  const DesktopDownloadsButton({super.key});

  @override
  ConsumerState<DesktopDownloadsButton> createState() =>
      _DesktopDownloadsButtonState();
}

class _DesktopDownloadsButtonState
    extends ConsumerState<DesktopDownloadsButton> {
  final _menu = MenuController();

  void _toggle() => _menu.isOpen ? _menu.close() : _menu.open();

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    // Rebuilds only when the count or the ring value changes.
    final (:count, :progress) = ref.watch(
      downloadQueueProvider.select(
        (state) => desktopDownloadsSummary(state.items),
      ),
    );
    final idle = count == 0;
    final label = context.l10n.libraryDownloads;
    return MenuAnchor(
      controller: _menu,
      consumeOutsideTap: true,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          mornye
              ? colorScheme.surfaceContainerHigh
              : colorScheme.surfaceContainer,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(mornye ? 14 : 16),
          ),
        ),
      ),
      menuChildren: [
        DesktopDownloadsPopover(
          onShowAll: () {
            _menu.close();
            // Mornye lists downloads on their own sidebar page; Library
            // would reopen whichever page it showed last, such as Songs.
            if (!ShellNavigationService.requestLibraryLink('downloads')) {
              ShellNavigationService.requestTab(ShellTab.library);
            }
          },
        ),
      ],
      child: Semantics(
        value: idle ? null : '$count',
        child: AppIconButton(
          key: const ValueKey('desktop-downloads-button'),
          tooltip: label,
          color: mornye ? colorScheme.onSurface : null,
          onPressed: _toggle,
          // Mornye sizes it with the other glyphs in the player capsule.
          icon: SizedBox.square(
            dimension: mornye ? 20 : 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (!idle)
                  Positioned.fill(
                    child: AppProgressIndicator.circular(
                      key: const ValueKey('desktop-downloads-progress'),
                      wavy: false,
                      value: progress,
                      strokeWidth: mornye ? 2 : 2.5,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                AppIcon(
                  mornye
                      ? (idle
                            ? CupertinoIcons.arrow_down_circle
                            : CupertinoIcons.arrow_down)
                      : Icons.download_rounded,
                  size: switch ((mornye, idle)) {
                    (true, true) => 18,
                    (true, false) => 11,
                    (false, true) => 24,
                    (false, false) => 14,
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The popover content: active downloads with progress and cancel, then
/// "Show all", which opens the full queue in Library.
class DesktopDownloadsPopover extends ConsumerWidget {
  const DesktopDownloadsPopover({super.key, required this.onShowAll});

  static const double width = 360;
  static const int _maxRows = 50;

  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final active = activeDesktopDownloads(
      ref.watch(downloadQueueProvider.select((state) => state.items)),
    );
    return SizedBox(
      key: const ValueKey('desktop-downloads-popover'),
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Semantics(
              header: true,
              child: Text(
                l10n.libraryDownloads,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (active.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                l10n.libraryNoActiveDownloads,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            // Menus measure their intrinsic size, which a lazy list cannot
            // report; a long queue is better read in Library anyway.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                // The menu panel already owns the primary controller.
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in active.take(_maxRows))
                      _DownloadRow(key: ValueKey(item.id), item: item),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const ValueKey('desktop-downloads-show-all'),
                onPressed: onShowAll,
                child: Text(l10n.desktopDownloadsShowAll),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({super.key, required this.item});

  static const double _rowHeight = 64;

  final DownloadItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mornye = context.isMornye;
    final progress = item.progress.clamp(0.0, 1.0);
    final status = switch (item.status) {
      DownloadStatus.queued => l10n.desktopDownloadsQueued,
      DownloadStatus.finalizing => l10n.queueFinalizingDownload,
      _ =>
        progress > 0
            ? '${(progress * 100).round()}%'
            : l10n.queueDownloadStarting,
    };
    final track = item.track;
    // A fixed height answers the menu's intrinsic measurement without
    // laying out the artwork and progress bar speculatively.
    return Container(
      height: _rowHeight,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 4, 0),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(mornye ? 6 : 8),
            child: SizedBox.square(
              dimension: 40,
              child: PlayerArtwork(
                artUri: track.coverUrl,
                colorScheme: colorScheme,
                cacheWidth: 120,
                iconSize: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${track.artistName} · $status',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                AppProgressIndicator.linear(
                  wavy: false,
                  value: item.status == DownloadStatus.queued
                      ? 0
                      : item.status == DownloadStatus.finalizing
                      ? 1
                      : progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  semanticsLabel: track.name,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          AppIconButton(
            tooltip: l10n.desktopDownloadsCancel,
            color: colorScheme.onSurfaceVariant,
            icon: AppIcon(
              mornye ? CupertinoIcons.xmark_circle_fill : Icons.close,
              size: 20,
            ),
            onPressed: () =>
                ref.read(downloadQueueProvider.notifier).cancelItem(item.id),
          ),
        ],
      ),
    );
  }
}
