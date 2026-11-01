part of 'files_settings_page.dart';

const _reorganizeExampleCount = 3;

/// Re-applies the folder and filename rules to tracks already on disk:
/// plan → confirm (with sample moves) → move with progress → summary.
Future<void> _reorganizeExistingDownloads(
  BuildContext context,
  WidgetRef ref,
) async {
  // Read up front: the page may be closed while files are still moving.
  final queue = ref.read(downloadQueueProvider.notifier);
  final history = ref.read(downloadHistoryProvider.notifier);
  final library = ref.read(localLibraryProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  if (queue.hasActiveDownloads) {
    messenger.showSnackBar(
      SnackBar(content: Text(context.l10n.reorganizeLibraryBusy)),
    );
    return;
  }

  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ReorganizeScanningDialog(),
    ),
  );
  LibraryReorganizationPlan? plan;
  Object? planError;
  try {
    plan = await queue.planLibraryReorganization();
  } catch (e) {
    planError = e;
  }
  if (navigator.mounted) navigator.pop();
  if (!context.mounted) return;

  if (plan == null) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.reorganizeLibraryFailed(
            context.friendlyError(planError ?? 'unknown'),
          ),
        ),
      ),
    );
    return;
  }
  final ready = plan;

  if (ready.isEmpty) {
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(ctx.l10n.reorganizeLibraryNothingTitle),
        content: Text(
          [
            ctx.l10n.reorganizeLibraryNothingMessage(ready.alreadyOrganized),
            if (ready.outsideDownloadFolder > 0)
              ctx.l10n.reorganizeLibraryOutsideFolder(
                ready.outsideDownloadFolder,
              ),
            if (ready.missing > 0)
              ctx.l10n.reorganizeLibraryMissing(ready.missing),
          ].join('\n\n'),
        ),
        actions: [
          AppDialogAction(
            filled: true,
            isDefault: true,
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.dialogDone),
          ),
        ],
      ),
    );
    return;
  }

  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => _ReorganizeConfirmDialog(plan: ready),
  );
  if (confirmed != true || !context.mounted) return;

  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.reorganizeLibraryMoving,
    total: ready.moves.length,
    icon: Icons.drive_file_move_outlined,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final result = await queue.applyLibraryReorganization(
    ready,
    isCancelled: () => cancelled,
    onProgress: (done, move) =>
        BatchProgressDialog.update(current: done, detail: move.trackName),
  );

  await history.reloadFromStorage();
  await library.reloadFromStorage();

  if (!context.mounted) return;
  if (!cancelled) BatchProgressDialog.dismiss(context);
  final failed = result.failed + result.missing;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? context.l10n.reorganizeLibraryDone(
                  result.moved,
                  ready.moves.length,
                )
              : context.l10n.reorganizeLibraryDoneWithFailures(
                  result.moved,
                  ready.moves.length,
                  failed,
                ),
        ),
      ),
    );
}

class _ReorganizeScanningDialog extends StatelessWidget {
  const _ReorganizeScanningDialog();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AppAlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: AppProgressIndicator.circular(strokeWidth: 3),
            ),
            const SizedBox(width: 20),
            Expanded(child: Text(context.l10n.reorganizeLibraryScanning)),
          ],
        ),
      ),
    );
  }
}

class _ReorganizeConfirmDialog extends StatelessWidget {
  const _ReorganizeConfirmDialog({required this.plan});

  final LibraryReorganizationPlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final examples = plan.moves.take(_reorganizeExampleCount).toList();
    final remaining = plan.moves.length - examples.length;
    final pathStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: colorScheme.onSurfaceVariant,
    );
    final notes = <String>[
      if (plan.alreadyOrganized > 0)
        l10n.reorganizeLibraryAlreadyOrganized(plan.alreadyOrganized),
      if (plan.outsideDownloadFolder > 0)
        l10n.reorganizeLibraryOutsideFolder(plan.outsideDownloadFolder),
      if (plan.missing > 0) l10n.reorganizeLibraryMissing(plan.missing),
    ];
    final warnings = <String>[
      if (plan.keepsPlaylistFolders) l10n.reorganizeLibraryKeepsPlaylistFolders,
      if (plan.dropsPlaylistFolders) l10n.reorganizeLibraryDropsPlaylistFolders,
      if (plan.safMode) l10n.reorganizeLibrarySafNote,
    ];

    return AppAlertDialog(
      title: Text(l10n.reorganizeLibraryConfirmTitle(plan.moves.length)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.reorganizeLibraryConfirmMessage),
            const SizedBox(height: 16),
            Text(
              l10n.reorganizeLibraryExamples,
              style: theme.textTheme.labelLarge,
            ),
            for (final move in examples)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(move.sourceDisplayPath, style: pathStyle),
                    Text(
                      '→ ${move.targetDisplayPath}',
                      style: pathStyle?.copyWith(color: colorScheme.primary),
                    ),
                  ],
                ),
              ),
            if (remaining > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.reorganizeLibraryMoreChanges(remaining),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            for (final note in notes) ...[
              const SizedBox(height: 12),
              Text(note, style: theme.textTheme.bodySmall),
            ],
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(
                      Icons.info_outline,
                      size: 16,
                      color: colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(warning, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        AppDialogAction(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          isDefault: true,
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.reorganizeLibraryConfirmAction),
        ),
      ],
    );
  }
}
