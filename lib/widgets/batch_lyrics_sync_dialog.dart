import 'package:flutter/material.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/batch_lyrics_sync_service.dart';

class BatchLyricsSyncDialog extends StatefulWidget {
  final List<Track> tracks;
  final BatchLyricsSyncService? service;

  const BatchLyricsSyncDialog({super.key, required this.tracks, this.service});

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

  Future<void> _startSync() async {
    final result = await _service.syncTracks(
      widget.tracks,
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

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Icon(
            _isDone
                ? Icons.check_circle_outline_rounded
                : Icons.lyrics_outlined,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _isDone
                  ? 'Sincronizzazione completata'
                  : 'Sincronizzazione testi',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress == null) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Controllo dei brani privi di testo...'),
          ] else if (!_isDone) ...[
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
              '${progress.completed} di ${progress.total} brani verificati',
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
                  '${progress.successful} scaricati',
                  style: TextStyle(
                    color: Colors.green.shade400,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (progress.failed > 0) ...[
                  const SizedBox(width: 12),
                  Text(
                    '${progress.failed} non trovati',
                    style: TextStyle(
                      color: colorScheme.error,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ] else ...[
            if (progress.total == 0)
              const Text('Tutti i brani hanno già i testi sincronizzati.')
            else ...[
              Text(
                '${progress.successful} testi salvati permanentemente nei file e come .lrc.',
                style: const TextStyle(fontSize: 14),
              ),
              if (progress.failed > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${progress.failed} brani non avevano testi disponibili online.',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
      actions: [
        if (!_isDone)
          TextButton(
            onPressed: () {
              setState(() => _cancelled = true);
              Navigator.of(context).pop();
            },
            child: const Text('Annulla'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Chiudi'),
          ),
      ],
    );
  }
}
