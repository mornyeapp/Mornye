import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('ConnectivityMonitor');

/// Windows can reject the Network List Manager's event registration. Flutter
/// reports that EventChannel activation failure globally, outside a stream's
/// onError handler. Query connectivity there without opening the event channel.
class ConnectivityMonitor {
  ConnectivityMonitor({
    Connectivity? connectivity,
    bool? usePolling,
    this.pollInterval = const Duration(seconds: 2),
  }) : assert(pollInterval > Duration.zero),
       _connectivity = connectivity ?? Connectivity(),
       _usePolling = usePolling ?? Platform.isWindows;

  static final ConnectivityMonitor instance = ConnectivityMonitor();

  final Connectivity _connectivity;
  final bool _usePolling;
  final Duration pollInterval;

  late final Stream<List<ConnectivityResult>> changes = _usePolling
      ? _pollingChanges()
      : _connectivity.onConnectivityChanged;

  Stream<List<ConnectivityResult>> _pollingChanges() =>
      Stream<List<ConnectivityResult>>.multi((listener) {
        var cancelled = false;
        var checking = false;
        var failed = false;
        Set<ConnectivityResult>? previous;

        Future<void> check() async {
          if (cancelled || checking) return;
          checking = true;
          try {
            final results = await _connectivity.checkConnectivity();
            if (cancelled) return;
            failed = false;
            final current = results.toSet();
            if (previous == null ||
                previous!.length != current.length ||
                !previous!.containsAll(current)) {
              previous = current;
              listener.add(List<ConnectivityResult>.unmodifiable(results));
            }
          } catch (error) {
            // Unknown connectivity must not become a false offline event or
            // an unhandled error. Keep checking, and log once until recovery.
            if (!cancelled && !failed) {
              _log.w('Connectivity check failed: $error');
            }
            failed = true;
          } finally {
            checking = false;
          }
        }

        final timer = Timer.periodic(pollInterval, (_) => unawaited(check()));
        listener.onCancel = () {
          cancelled = true;
          timer.cancel();
        };
        unawaited(check());
      }, isBroadcast: true);
}
