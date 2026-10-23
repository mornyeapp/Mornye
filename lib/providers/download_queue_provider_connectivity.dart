// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueConnectivity on DownloadQueueNotifier {
  void _startConnectivityMonitoring() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _handleConnectivityResults,
      onError: (Object error, StackTrace stackTrace) {
        _log.w('Connectivity monitoring failed: $error');
      },
      cancelOnError: false,
    );
  }

  void _stopConnectivityMonitoring() {
    _networkPausedByWifiOnly = false;
    // Keep listening while network-failed items remain so the reconnect
    // retry prompt can still fire when the queue is otherwise idle.
    if (_hasNetworkFailedItems) return;
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  bool get _hasNetworkFailedItems => state.items.any(
    (item) =>
        item.status == DownloadStatus.failed &&
        item.errorType == DownloadErrorType.network,
  );

  /// Publishes a retry opportunity; mounted UI consumers choose presentation.
  void _maybeOfferRetryAfterReconnect(List<ConnectivityResult> results) {
    final failedCount = state.items
        .where(
          (item) =>
              item.status == DownloadStatus.failed &&
              item.errorType == DownloadErrorType.network,
        )
        .length;
    if (!_connectivityPolicy.shouldOfferRetry(
      results: results,
      failedCount: failedCount,
      now: DateTime.now(),
    )) {
      return;
    }
    state = state.copyWith(
      reconnectRetry: DownloadQueueReconnectRetry(failedCount),
    );
  }

  void _handleDownloadNetworkModeChanged(String mode) {
    if (mode == 'wifi_only') {
      if (state.isProcessing || _networkPausedByWifiOnly) {
        _startConnectivityMonitoring();
      }
      return;
    }

    final shouldResume = _networkPausedByWifiOnly && state.isPaused;
    // Keep monitoring active in every mode while downloading so idle
    // connections are still recycled when the network switches.
    if (state.isProcessing) {
      _networkPausedByWifiOnly = false;
      _startConnectivityMonitoring();
    } else {
      _stopConnectivityMonitoring();
    }
    if (shouldResume) {
      resumeQueue();
    }
  }

  /// Closes idle backend HTTP connections when the connectivity set changes
  /// (e.g. WiFi <-> cellular). Stale sockets bound to the old interface would
  /// otherwise be reused, stalling the first request after a network switch.
  /// Applies to every download network mode. Fire-and-forget with a light
  /// debounce so network flapping does not spam the bridge.
  void _maybeCleanupOnNetworkChange(List<ConnectivityResult> results) {
    if (!_connectivityPolicy.shouldCleanup(results, DateTime.now())) {
      return;
    }

    _log.i('Network changed, closing idle backend connections');
    unawaited(
      PlatformBridge.cleanupConnections().catchError((Object e) {
        _log.w('Failed to clean up connections after network change: $e');
      }),
    );
  }

  void _handleConnectivityResults(List<ConnectivityResult> results) {
    _maybeCleanupOnNetworkChange(results);
    _maybeOfferRetryAfterReconnect(results);

    final settings = ref.read(settingsProvider);
    if (settings.downloadNetworkMode != 'wifi_only') return;

    if (results.contains(ConnectivityResult.wifi)) {
      if (_networkPausedByWifiOnly && state.isPaused) {
        _networkPausedByWifiOnly = false;
        _log.i('WiFi restored, resuming network-paused queue');
        resumeQueue();
      }
      return;
    }

    if (state.isProcessing && !state.isPaused) {
      _networkPausedByWifiOnly = true;
      _log.w('WiFi connection lost, pausing active queue');
      pauseQueue(persistAcrossRestarts: false);
    }
  }
}
