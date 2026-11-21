part of 'queue_tab.dart';

String _formatDownloadSizeMB(num bytes) => '${formatMegabytes(bytes)} MB';

String _formatDownloadProgressLabel(
  BuildContext context,
  DownloadItem item, {
  double? visualProgress,
}) {
  final progress = (visualProgress ?? item.progress).clamp(0.0, 1.0);
  final speedSuffix = item.speedMBps > 0
      ? ' • ${item.speedMBps.toStringAsFixed(1)} MB/s'
      : '';

  if (item.bytesTotal > 0) {
    final received = visualProgress != null
        ? item.bytesTotal * progress
        : item.bytesReceived > 0
        ? item.bytesReceived
        : item.bytesTotal * progress;
    final percent = (progress * 100).toStringAsFixed(0);
    return '${_formatDownloadSizeMB(received)} / ${_formatDownloadSizeMB(item.bytesTotal)} • $percent%$speedSuffix';
  }

  if (item.bytesReceived > 0) {
    final canEstimateTotal = progress > 0.01 && progress < 0.995;
    if (canEstimateTotal) {
      final estimatedTotal = item.bytesReceived / progress;
      if (estimatedTotal > item.bytesReceived) {
        return '${_formatDownloadSizeMB(item.bytesReceived)} / ~${_formatDownloadSizeMB(estimatedTotal)}$speedSuffix';
      }
    }
    return '${_formatDownloadSizeMB(item.bytesReceived)}$speedSuffix';
  }

  if (progress > 0) {
    final percent = (progress * 100).toStringAsFixed(0);
    return '$percent%$speedSuffix';
  }

  if (item.speedMBps > 0) {
    return context.l10n.queueDownloadSpeedStatus(
      item.speedMBps.toStringAsFixed(1),
    );
  }

  // The marker carries the id of the extension that asked, after a colon.
  const waiting = 'Waiting for verification';
  final marker = item.error;
  if (marker != null && marker.startsWith(waiting)) {
    final id = marker.substring(waiting.length).replaceFirst(':', '').trim();
    if (id.isEmpty) return context.l10n.queueWaitingForVerification;
    return context.l10n.queueWaitingForVerificationNamed(
      extensionVerificationName(id, context),
    );
  }
  switch (item.preparationStage) {
    case 'checking_session':
      return context.l10n.queueCheckingDownloadSession;
    case 'resolving_metadata':
      return context.l10n.queueResolvingDownloadMetadata;
    case 'resolving_stream':
      return context.l10n.queueResolvingDownloadStream;
  }
  if (item.error == 'Retrying after verification') {
    return context.l10n.queueResumingAfterVerification;
  }

  return context.l10n.queueDownloadStarting;
}

String _formatDownloadStatusLine(
  BuildContext context,
  DownloadItem item, {
  double? visualProgress,
}) {
  final base = _formatDownloadProgressLabel(
    context,
    item,
    visualProgress: visualProgress,
  );
  final eta = _formatDownloadEta(item, visualProgress: visualProgress);
  return eta == null ? base : '$base • $eta';
}

String? _formatDownloadEta(DownloadItem item, {double? visualProgress}) {
  if (item.speedMBps <= 0 || item.bytesTotal <= 0) return null;
  final progress = (visualProgress ?? item.progress).clamp(0.0, 1.0);
  final received = visualProgress != null
      ? (item.bytesTotal * progress).round()
      : item.bytesReceived > 0
      ? item.bytesReceived
      : (item.bytesTotal * progress).round();
  final remaining = item.bytesTotal - received;
  if (remaining <= 0) return null;
  final seconds = remaining / (item.speedMBps * 1024 * 1024);
  if (!seconds.isFinite || seconds > 3600) return null;
  if (seconds < 60) return '~${seconds.round()}s';
  final minutes = (seconds / 60).floor();
  final secs = (seconds % 60).round();
  return '~${minutes}m${secs.toString().padLeft(2, '0')}s';
}

bool _shouldAnimateDownloadProgress(BuildContext context, DownloadItem item) {
  final progress = item.progress.clamp(0.0, 1.0);
  final animationsDisabled =
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return item.status == DownloadStatus.downloading &&
      progress > 0 &&
      progress < 1 &&
      !animationsDisabled;
}
