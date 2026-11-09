import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';

class BatchLyricsSyncDialog extends StatefulWidget {
  final List<BatchLyricsItem> items;
  final BatchLyricsSyncService? service;

  const BatchLyricsSyncDialog({super.key, required this.items, this.service});

  static Future<void> show(
    BuildContext context, {
    required List<BatchLyricsItem> items,
    BatchLyricsSyncService? service,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BatchLyricsSyncDialog(items: items, service: service),
    );
  }

  @override
  State<BatchLyricsSyncDialog> createState() => _BatchLyricsSyncDialogState();
}

class _BatchLyricsSyncDialogState extends State<BatchLyricsSyncDialog> {
  late final BatchLyricsSyncService _service;
  BatchLyricsProgress? _progress;
  bool _isDone = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? BatchLyricsSyncService();
    _startSync();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _startSync() async {
    final result = await _service.syncItems(
      widget.items,
      isCancelled: () => _cancelled,
      onProgress: (p) {
        if (mounted) {
          setState(() {
            _progress = p;
          });
        }
      },
    );
    if (mounted) {
      setState(() {
        _progress = result;
        _isDone = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final progress = _progress;

    final isCancelled = progress?.isCancelled == true;

    final titleIcon = isCancelled
        ? Icons.cancel_outlined
        : _isDone
        ? Icons.check_circle_outline_rounded
        : Icons.lyrics_outlined;

    final titleColor = isCancelled ? colorScheme.error : colorScheme.primary;

    final titleText = isCancelled
        ? context.l10n.syncLyricsCancelled
        : _isDone
        ? context.l10n.syncLyricsCompleted
        : context.l10n.syncLyricsAction;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!_isDone) {
          _cancelled = true;
        }
      },
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(titleIcon, color: titleColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                titleText,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (progress == null || progress.isChecking) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                progress != null && progress.checkingTotal > 0
                    ? context.l10n.syncLyricsCheckedCount(
                        progress.checkingCurrent,
                        progress.checkingTotal,
                      )
                    : context.l10n.syncLyricsChecking,
              ),
            ] else if (!_isDone && !isCancelled) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress.total > 0
                      ? progress.completed / progress.total
                      : null,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '${progress.completed} / ${progress.total}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (progress.currentTrackName != null) ...[
                const SizedBox(height: 4),
                Text(
                  progress.currentTrackName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '${progress.successful}',
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.check, size: 14, color: colorScheme.primary),
                  if (progress.failed > 0) ...[
                    const SizedBox(width: 16),
                    Text(
                      '${progress.failed}',
                      style: TextStyle(
                        color: colorScheme.error,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.close, size: 14, color: colorScheme.error),
                  ],
                ],
              ),
            ] else ...[
              if (isCancelled)
                Text(
                  context.l10n.syncLyricsSummary(
                    progress.successful,
                    progress.failed,
                  ),
                  style: const TextStyle(fontSize: 14),
                )
              else if (progress.total == 0)
                Text(context.l10n.syncLyricsAllHaveLyrics)
              else
                Text(
                  context.l10n.syncLyricsSummary(
                    progress.successful,
                    progress.failed,
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
            ],
          ],
        ),
        actions: [
          if (!_isDone && !isCancelled)
            TextButton(
              onPressed: () {
                setState(() => _cancelled = true);
                Navigator.of(context).pop();
              },
              child: Text(context.l10n.dialogCancel),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.actionDismiss),
            ),
        ],
      ),
    );
  }
}
