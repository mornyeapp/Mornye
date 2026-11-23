import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/connected_icon_buttons.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/player_artwork.dart';

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

/// Active count and quantized percentage (0..100) from [DownloadQueueLookup],
/// scanning only active items so large completed queues stay O(active) and
/// fractional progress ticks do not trigger redundant rebuilds.
({int count, int progressPercent}) _desktopDownloadsRing(
  DownloadQueueLookup lookup,
) {
  final activeIds = lookup.activeItemIds;
  if (activeIds.isEmpty) return (count: 0, progressPercent: 0);
  var total = 0.0;
  for (final id in activeIds) {
    final item = lookup.byItemId[id];
    if (item == null) continue;
    total += item.status == DownloadStatus.finalizing
        ? 1
        : item.status == DownloadStatus.downloading
        ? item.progress.clamp(0.0, 1.0)
        : 0;
  }
  return (
    count: activeIds.length,
    progressPercent: ((total / activeIds.length) * 100).round().clamp(0, 100),
  );
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
  // The toolbar ring changes with every progress sample. Keep the open panel
  // mounted with the same widget so those samples do not rebuild its list.
  // The popover inherits from the button, which may be a group segment.
  late final _popover = ConnectedIconSegment.exclude(
    child: DesktopDownloadsPopover(onShowAll: _showAll),
  );

  void _toggle() => _menu.isOpen ? _menu.close() : _menu.open();

  void _showAll() {
    _menu.close();
    // Mornye lists downloads on their own sidebar page; Library would
    // reopen whichever page it showed last, such as Songs.
    if (!ShellNavigationService.requestLibraryLink('downloads')) {
      ShellNavigationService.requestTab(ShellTab.library);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final label = context.l10n.libraryDownloads;
    return MenuAnchor(
      controller: _menu,
      consumeOutsideTap: true,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          mornye ? Colors.transparent : colorScheme.surfaceContainer,
        ),
        elevation: mornye ? const WidgetStatePropertyAll(0) : null,
        shadowColor: mornye
            ? const WidgetStatePropertyAll(Colors.transparent)
            : null,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(mornye ? 14 : 16),
          ),
        ),
      ),
      menuChildren: [
        if (mornye)
          MornyeGlassPanel.overlay(radius: 14, child: _popover)
        else
          _popover,
      ],
      child: Consumer(
        builder: (context, ref, _) {
          // Scope progress updates to the button so MenuAnchor and its glass
          // popover wrapper stay untouched during downloads.
          final (:count, :progressPercent) = ref.watch(
            downloadQueueLookupProvider.select(_desktopDownloadsRing),
          );
          final idle = count == 0;
          return Semantics(
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
                          value: progressPercent / 100.0,
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
          );
        },
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
    final activeIds = ref.watch(
      downloadQueueLookupProvider.select((lookup) => lookup.activeItemIds),
    );
    final rowCount = activeIds.length.clamp(0, _maxRows);
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
          if (activeIds.isEmpty)
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
            // Explicit bounds satisfy the menu's intrinsic measurement
            // without asking the lazy viewport to measure every queue row.
            SizedBox(
              height: (rowCount * _DownloadRow.height).clamp(0.0, 360.0),
              child: ListView.builder(
                key: const ValueKey('desktop-downloads-list'),
                primary: false,
                padding: EdgeInsets.zero,
                itemExtent: _DownloadRow.height,
                itemCount: rowCount,
                itemBuilder: (context, index) => _DownloadRow(
                  key: ValueKey(activeIds[index]),
                  itemId: activeIds[index],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: ExpressiveButton(
                key: const ValueKey('desktop-downloads-show-all'),
                text: true,
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
  const _DownloadRow({super.key, required this.itemId});

  static const double height = 64;

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(
      downloadQueueLookupProvider.select((lookup) => lookup.byItemId[itemId]),
    );
    if (item == null) return const SizedBox(height: height);
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
      height: height,
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
