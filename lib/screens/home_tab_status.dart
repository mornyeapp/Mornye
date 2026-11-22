part of 'home_tab.dart';

/// Opens the download queue: Mornye's desktop sidebar page, otherwise the
/// Library's Downloads page.
void _openHomeDownloads(BuildContext context) {
  if (ShellNavigationService.requestLibraryLink('downloads')) return;
  pushPage<void>(
    context,
    (_) => const Scaffold(body: QueueTab(librarySection: 'downloads')),
  );
}

/// One quiet line under Home's greeting: songs added since the last visit
/// and songs downloading. Absent while neither is true.
class _HomeStatusLine extends ConsumerWidget {
  const _HomeStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final arrivals = ref.watch(homeArrivalsProvider);
    // Download focus shows the queue in its own section.
    final downloading = ref.watch(playerUiEnabledProvider)
        ? ref.watch(homeActiveDownloadsProvider)
        : 0;
    final parts = <(String, VoidCallback)>[
      if (arrivals.count > 0)
        (
          arrivals.sinceYesterday
              ? l10n.homeStatusAddedSinceYesterday(arrivals.count)
              : l10n.homeStatusAddedSinceLastVisit(arrivals.count),
          () => ShellNavigationService.requestTab(ShellTab.library),
        ),
      if (downloading > 0)
        (
          l10n.homeStatusDownloading(downloading),
          () => _openHomeDownloads(context),
        ),
    ];
    final inset = 24 + homeContentInset(context);
    return _HomeTabState._resizeSection(
      AppMotion.surface(context),
      parts.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              // Each part's press area reaches 4 past its text.
              padding: EdgeInsetsDirectional.fromSTEB(
                inset - 4,
                0,
                inset - 4,
                4,
              ),
              child: _HomeStatusParts(parts: parts),
            ),
    );
  }
}

/// The parts at their own widths while they fit, otherwise each shortened
/// in proportion to its length.
class _HomeStatusParts extends StatelessWidget {
  const _HomeStatusParts({required this.parts});

  final List<(String, VoidCallback)> parts;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    const separator = ' · ';
    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = [for (final (label, _) in parts) widthOf(label) + 8];
        final total =
            widths.fold(0.0, (sum, width) => sum + width) +
            (parts.length - 1) * widthOf(separator);
        final fits = total <= constraints.maxWidth;
        return Row(
          children: [
            for (final (index, (label, onTap)) in parts.indexed) ...[
              if (index > 0)
                ExcludeSemantics(child: Text(separator, style: style)),
              if (fits)
                _HomeStatusPart(label: label, style: style, onTap: onTap)
              else
                Flexible(
                  flex: widths[index].ceil(),
                  child: _HomeStatusPart(
                    label: label,
                    style: style,
                    onTap: onTap,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _HomeStatusPart extends StatelessWidget {
  const _HomeStatusPart({
    required this.label,
    required this.style,
    required this.onTap,
  });

  final String label;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (context.isMornye) {
      return CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 32),
        onPressed: onTap,
        child: text,
      );
    }
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              alignment: AlignmentDirectional.centerStart,
              child: text,
            ),
          ),
        ),
      ),
    );
  }
}

/// Download focus leads Home with the queue: the song downloading now, then
/// what waits, finished today and failed.
class _HomeDownloadsSection extends ConsumerWidget {
  const _HomeDownloadsSection({required this.inset});

  final double inset;

  /// Only while another app plays, when Home reads as a downloader.
  static bool hasContent(WidgetRef ref) => !ref.watch(playerUiEnabledProvider);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final queue = ref.watch(homeQueueSummaryProvider);
    final finishedToday = ref.watch(homeFinishedTodayProvider);
    final downloading = queue.currentId;
    final counts = [
      if (queue.paused) l10n.homeDownloadsPaused,
      if (queue.waiting > 0) l10n.homeDownloadsWaiting(queue.waiting),
      if (finishedToday > 0) l10n.homeDownloadsFinishedToday(finishedToday),
      if (queue.failed > 0) l10n.homeDownloadsFailed(queue.failed),
    ];
    void open() => _openHomeDownloads(context);

    final List<Widget> rows;
    if (downloading != null) {
      rows = [
        _HomeDownloadingRow(
          key: ValueKey(downloading),
          itemId: downloading,
          onTap: open,
          showDivider: counts.isNotEmpty,
        ),
        if (counts.isNotEmpty)
          SettingsItem(
            title: counts.join(' · '),
            showDivider: false,
            onTap: open,
          ),
      ];
    } else {
      // Nothing downloads now: one row, led by what waits when anything does.
      final waits = queue.active > 0 && counts.isNotEmpty;
      final rest = waits ? counts.skip(1) : counts;
      rows = [
        SettingsItem(
          icon: waits ? Icons.schedule : Icons.download_done_rounded,
          title: waits ? counts.first : l10n.homeDownloadsNothing,
          subtitle: rest.isEmpty ? null : rest.join(' · '),
          showDivider: false,
          onTap: open,
        ),
      ];
    }
    return _HomeSection(
      title: l10n.libraryDownloads,
      inset: inset,
      onShowAll: open,
      child: SettingsGroup(
        margin: EdgeInsets.zero,
        connected: true,
        children: rows,
      ),
    );
  }
}

/// The song downloading now. It follows progress samples on its own, and
/// only when the shown percentage changes, so the sections above keep still.
class _HomeDownloadingRow extends ConsumerWidget {
  const _HomeDownloadingRow({
    super.key,
    required this.itemId,
    required this.onTap,
    required this.showDivider,
  });

  final String itemId;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(
      downloadQueueLookupProvider.select(
        (lookup) => homeDownloadingSong(lookup, itemId),
      ),
    );
    if (item == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final finalizing = item.finalizing;
    final state = finalizing
        ? l10n.queueFinalizingDownload
        : item.percent > 0
        ? '${item.percent}%'
        : l10n.queueDownloadStarting;
    return RepaintBoundary(
      child: SettingsItem(
        icon: Icons.downloading_rounded,
        title: item.title,
        subtitle: item.artist.isEmpty ? state : '${item.artist} · $state',
        showDivider: showDivider,
        onTap: onTap,
        footer: AppProgressIndicator.linear(
          wavy: false,
          value: finalizing ? 1 : item.percent / 100,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
          semanticsLabel: item.title,
        ),
      ),
    );
  }
}
