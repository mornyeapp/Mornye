import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

/// One-tap offline save for the Hi-Fi listening layout.
///
/// Streaming and saving are intentionally separate actions. Offline saving
/// always goes through Mornye's existing download provider, its permissions,
/// preferred format, and its download queue.
class OfflineDownloadButton extends ConsumerWidget {
  const OfflineDownloadButton({
    super.key,
    required this.track,
    this.onDownload,
    this.onChooseQuality,
  });

  final Track track;
  final VoidCallback? onDownload;
  final VoidCallback? onChooseQuality;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queued = ref.watch(
      downloadQueueLookupProvider.select(
        (lookup) => lookup.byTrackId.containsKey(track.id),
      ),
    );
    return Semantics(
      button: true,
      label: queued ? 'Saving for offline use' : 'Save track for offline use',
      child: GestureDetector(
        onLongPress: queued
            ? null
            : () => onChooseQuality != null
                  ? onChooseQuality!()
                  : downloadSingleTrack(
                      context,
                      ref,
                      track,
                      forceQualityPicker: true,
                    ),
        child: IconButton(
          tooltip: queued
              ? 'Already in download queue'
              : 'Download for offline listening · hold to select quality',
          onPressed: queued
              ? null
              : () => onDownload != null
                    ? onDownload!()
                    : downloadSingleTrack(context, ref, track),
          icon: Icon(
            queued ? Icons.downloading_rounded : Icons.download_rounded,
            size: 23,
          ),
        ),
      ),
    );
  }
}
