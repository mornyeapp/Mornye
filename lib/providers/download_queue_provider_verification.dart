// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueVerificationGate on DownloadQueueNotifier {
  Future<void> _handleVerificationNotificationTap(
    VerificationNotification target,
  ) async {
    await _queueRestored.future;
    if (!ref.mounted) return;
    final item = _findItemById(target.itemId);
    if (item != null &&
        (item.status == DownloadStatus.completed ||
            item.status == DownloadStatus.skipped ||
            _isLocallyCancelled(item.id, item: item))) {
      return;
    }
    // Foregrounding wakes an existing queue waiter. Do not replace it or
    // reopen a browser that the queue already owns.
    if ((item != null &&
            _verificationWaitCoordinator.hasActiveWaiter(item.id)) ||
        _verificationWaitCoordinator.hasActiveFlow(target.extensionId)) {
      return;
    }
    // Older builds did not retain verification failures. The notification
    // still identifies the extension if its queue item is already missing.
    final verified = await _openVerificationAndWait(
      item?.id ?? 'notification:${target.tapId}',
      target.extensionId,
    );
    if (!ref.mounted || !verified || state.isPaused) return;
    final current = _findItemById(target.itemId);
    if (current != null &&
        current.status == DownloadStatus.failed &&
        current.errorType == DownloadErrorType.verificationRequired &&
        !_isLocallyCancelled(current.id, item: current)) {
      await retryItem(current.id);
    }
  }

  /// Completes when the app is in the foreground. Verification challenges
  /// can only be handled there: launching a browser from the background is
  /// blocked by the OS and the challenge would expire unseen.
  Future<bool> _waitForForeground(Future<void> cancellationSignal) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return true;
    }
    final completer = Completer<void>();
    final listener = AppLifecycleListener(
      onResume: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    try {
      return await Future.any<bool>([
        completer.future.then((_) => true),
        cancellationSignal.then((_) => false),
      ]);
    } finally {
      listener.dispose();
    }
  }

  Future<bool> _openVerificationAndWait(String itemId, String extensionId) {
    if (_verificationWaitCoordinator.hasActiveFlow(extensionId)) {
      _log.i(
        'Joining active verification flow for $extensionId instead of opening another challenge',
      );
    }

    return _verificationWaitCoordinator.waitForGrant(
      itemId: itemId,
      service: extensionId,
      startFlow: (cancellationSignal) =>
          _runVerificationFlow(extensionId, cancellationSignal),
    );
  }

  Future<bool> _runVerificationFlow(
    String extensionId,
    Future<void> cancellationSignal,
  ) async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _log.i(
        'Verification required for $extensionId while app is in background; '
        'deferring challenge until the app is foregrounded',
      );
      final reachedForeground = await _waitForForeground(cancellationSignal);
      if (!reachedForeground) {
        _log.i(
          'Verification wait for $extensionId was cancelled before the app returned to the foreground',
        );
        return false;
      }
    }

    // Finish the durable write before handing control to another app; a
    // background lifecycle callback may not finish before Android kills us.
    try {
      await flushQueuePersistence(requireDurable: true);
    } catch (error) {
      _log.e('Could not save downloads before verification: $error');
      return false;
    }
    if (!ref.mounted) return false;
    return openVerificationAndAwaitGrant(
      extensionId,
      browserMode: ref.read(settingsProvider).extensionVerificationBrowserMode,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<bool> _handleVerificationRequiredDownload(
    DownloadItem item,
    String errorMsg,
    String? verificationService,
  ) async {
    final targetService = (verificationService ?? '').trim().isNotEmpty
        ? verificationService!.trim()
        : item.service;
    if (_verificationRetryGuard.hasRetriedAfterGrant(item.id, targetService)) {
      _log.e(
        'Verification was already completed once for ${item.track.name} on $targetService; not opening another challenge',
      );
      _recordFailedDownload(
        item.id,
        error: errorMsg,
        errorType: DownloadErrorType.verificationRequired,
      );
      return true;
    }
    _log.i(
      'Download for ${item.track.name} requires verification; waiting for $targetService grant',
    );
    updateItemStatus(
      item.id,
      DownloadStatus.downloading,
      error: 'Waiting for verification',
      errorType: DownloadErrorType.verificationRequired,
    );

    try {
      await _notificationService.showVerificationRequired(
        extensionId: targetService,
        itemId: item.id,
      );
    } catch (error) {
      _log.w('Failed to show the verification-required notification: $error');
    }

    late final bool verified;
    try {
      verified = await _openVerificationAndWait(item.id, targetService);
    } finally {
      try {
        await _notificationService.cancelVerificationRequired();
      } catch (error) {
        _log.w(
          'Failed to clear the verification-required notification: $error',
        );
      }
    }
    final current = _findItemById(item.id);
    if (current == null || _isLocallyCancelled(item.id, item: current)) {
      _log.i('Verification wait stopped after item was removed or cancelled');
      return true;
    }
    if (_isPausePending(item.id)) {
      _requeueItemForPause(item.id);
      _pausePendingItemIds.remove(item.id);
      _log.i('Verification wait stopped because the queue was paused');
      return true;
    }

    // Only a completed grant consumes the automatic retry. If bootstrap or
    // browser launch failed before a challenge opened, a later attempt must
    // still be allowed after the network changes.
    _verificationRetryGuard.recordVerificationResult(
      item.id,
      targetService,
      granted: verified,
    );
    if (verified) {
      _log.i(
        'Verification complete for $targetService; retrying ${item.track.name}',
      );
      updateItemStatus(
        item.id,
        DownloadStatus.queued,
        progress: 0,
        speedMBps: 0,
        error: 'Retrying after verification',
        errorType: DownloadErrorType.verificationRequired,
      );
      _saveQueueToStorage();
      return true;
    }

    _log.e('Verification did not complete for $targetService');
    _recordFailedDownload(
      item.id,
      error: errorMsg,
      errorType: DownloadErrorType.verificationRequired,
    );
    return true;
  }

  Duration _rateLimitBackoffDelay(String errorMsg) {
    final lower = errorMsg.toLowerCase();
    final retryAfterMatch = RegExp(
      r'retry[- ]?after(?: seconds)?[:= ]+(\d+)',
      caseSensitive: false,
    ).firstMatch(lower);
    final parsedSeconds = retryAfterMatch == null
        ? null
        : int.tryParse(retryAfterMatch.group(1) ?? '');
    final seconds = (parsedSeconds ?? 30).clamp(5, 300).toInt();
    return Duration(seconds: seconds);
  }

  Future<bool> _handleRateLimitedDownload(
    DownloadItem item,
    String errorMsg,
  ) async {
    if (_rateLimitRetriedItemIds.contains(item.id)) {
      return false;
    }
    _rateLimitRetriedItemIds.add(item.id);

    final delay = _rateLimitBackoffDelay(errorMsg);
    _log.i(
      'Rate limited while downloading ${item.track.name}; retrying after ${delay.inSeconds}s',
    );
    updateItemStatus(
      item.id,
      DownloadStatus.downloading,
      error: 'Rate limited, retrying after ${delay.inSeconds}s',
      errorType: DownloadErrorType.rateLimit,
    );

    // A synchronous state listener may already have cancelled or paused when
    // the backoff status was published. Do not register a new wait afterward.
    if (!ref.mounted) return true;
    var current = _findItemById(item.id);
    if (current == null || _isLocallyCancelled(item.id, item: current)) {
      return true;
    }
    if (!_isPausePending(item.id)) {
      await _rateLimitBackoff.wait(item.id, delay);
    }
    if (!ref.mounted) return true;
    current = _findItemById(item.id);
    if (current == null || _isLocallyCancelled(item.id, item: current)) {
      return true;
    }
    if (_isPausePending(item.id)) {
      _requeueItemForPause(item.id);
      await _finishPausedDownload(item.id);
      return true;
    }
    updateItemStatus(
      item.id,
      DownloadStatus.queued,
      progress: 0,
      speedMBps: 0,
      error: 'Retrying after rate limit',
      errorType: DownloadErrorType.rateLimit,
    );
    _saveQueueToStorage();
    return true;
  }
}
