import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/connectivity_monitor.dart';

class _Connectivity implements Connectivity {
  _Connectivity(this.read);

  final Future<List<ConnectivityResult>> Function() read;
  final events = StreamController<List<ConnectivityResult>>.broadcast();
  int checks = 0;
  int watches = 0;

  Future<void> dispose() => events.close();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    checks++;
    return read();
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    watches++;
    return events.stream;
  }
}

void main() {
  const interval = Duration(seconds: 1);

  testWidgets('polling never activates the failing Windows event channel', (
    tester,
  ) async {
    const methods = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const events = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    var checks = 0;
    var listens = 0;
    final methodCalls = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      methodCalls.add(call.method);
      checks++;
      return ['wifi'];
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == 'listen') {
        listens++;
        throw PlatformException(
          code: '-2147024809',
          message: 'NetworkManager::StartListen',
        );
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final monitor = ConnectivityMonitor(
      usePolling: true,
      pollInterval: interval,
    );
    final results = <List<ConnectivityResult>>[];
    final subscription = monitor.changes.listen(results.add);
    addTearDown(subscription.cancel);
    await tester.pump();
    await tester.pump(interval);
    expect(checks, 2);
    expect(methodCalls, ['check', 'check']);
    expect(listens, 0);
    expect(results, [
      [ConnectivityResult.wifi],
    ]);
    expect(tester.takeException(), isNull);
    unawaited(subscription.cancel());
    await tester.pump();
  });

  testWidgets('polling reports initial status and changed interface sets', (
    tester,
  ) async {
    var current = [ConnectivityResult.wifi];
    final connectivity = _Connectivity(() async => current);
    addTearDown(connectivity.dispose);
    final monitor = ConnectivityMonitor(
      connectivity: connectivity,
      usePolling: true,
      pollInterval: interval,
    );
    final results = <List<ConnectivityResult>>[];
    final subscription = monitor.changes.listen(results.add);
    addTearDown(subscription.cancel);
    await tester.pump();
    current = [ConnectivityResult.ethernet, ConnectivityResult.vpn];
    await tester.pump(interval);
    current = [ConnectivityResult.vpn, ConnectivityResult.ethernet];
    await tester.pump(interval);
    current = [ConnectivityResult.none];
    await tester.pump(interval);
    expect(results, [
      [ConnectivityResult.wifi],
      [ConnectivityResult.ethernet, ConnectivityResult.vpn],
      [ConnectivityResult.none],
    ]);
    expect(connectivity.watches, 0);
    expect(() => results.first.clear(), throwsUnsupportedError);
    unawaited(subscription.cancel());
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(connectivity.checks, 4);
  });

  testWidgets('failed checks recover without false offline or global errors', (
    tester,
  ) async {
    var failing = true;
    var current = [ConnectivityResult.wifi];
    final connectivity = _Connectivity(() async {
      if (failing) throw PlatformException(code: 'network-unavailable');
      return current;
    });
    addTearDown(connectivity.dispose);
    final monitor = ConnectivityMonitor(
      connectivity: connectivity,
      usePolling: true,
      pollInterval: interval,
    );
    final results = <List<ConnectivityResult>>[];
    final subscription = monitor.changes.listen(results.add);
    addTearDown(subscription.cancel);
    await tester.pump();
    await tester.pump(interval);
    expect(results, isEmpty);
    failing = false;
    await tester.pump(interval);
    failing = true;
    await tester.pump(interval);
    expect(results, [
      [ConnectivityResult.wifi],
    ]);
    failing = false;
    current = [ConnectivityResult.ethernet];
    await tester.pump(interval);
    expect(results.last, [ConnectivityResult.ethernet]);
    expect(tester.takeException(), isNull);
    unawaited(subscription.cancel());
    await tester.pump();
  });

  testWidgets('a slow connectivity check cannot overlap another poll', (
    tester,
  ) async {
    final pending = Completer<List<ConnectivityResult>>();
    final connectivity = _Connectivity(() => pending.future);
    addTearDown(connectivity.dispose);
    final monitor = ConnectivityMonitor(
      connectivity: connectivity,
      usePolling: true,
      pollInterval: interval,
    );
    final results = <List<ConnectivityResult>>[];
    final subscription = monitor.changes.listen(results.add);
    addTearDown(subscription.cancel);
    await tester.pump(const Duration(seconds: 5));
    expect(connectivity.checks, 1);
    pending.complete([ConnectivityResult.wifi]);
    await tester.pump();
    expect(results.single, [ConnectivityResult.wifi]);
    await tester.pump(interval);
    expect(connectivity.checks, 2);
    unawaited(subscription.cancel());
    await tester.pump();
  });

  for (final fail in [false, true]) {
    testWidgets('cancelling discards a pending check (failure: $fail)', (
      tester,
    ) async {
      final pending = Completer<List<ConnectivityResult>>();
      final connectivity = _Connectivity(() => pending.future);
      addTearDown(connectivity.dispose);
      final monitor = ConnectivityMonitor(
        connectivity: connectivity,
        usePolling: true,
        pollInterval: interval,
      );
      final results = <List<ConnectivityResult>>[];
      final subscription = monitor.changes.listen(results.add);
      await tester.pump();
      unawaited(subscription.cancel());
      await tester.pump();
      if (fail) {
        pending.completeError(PlatformException(code: 'late-error'));
      } else {
        pending.complete([ConnectivityResult.wifi]);
      }
      await tester.pump(const Duration(seconds: 5));
      expect(results, isEmpty);
      expect(connectivity.checks, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a fresh subscription checks again and ignores old results', (
    tester,
  ) async {
    final pending = Completer<List<ConnectivityResult>>();
    var first = true;
    final connectivity = _Connectivity(() {
      if (first) {
        first = false;
        return pending.future;
      }
      return Future.value([ConnectivityResult.ethernet]);
    });
    addTearDown(connectivity.dispose);
    final monitor = ConnectivityMonitor(
      connectivity: connectivity,
      usePolling: true,
      pollInterval: interval,
    );
    final oldResults = <List<ConnectivityResult>>[];
    final firstSubscription = monitor.changes.listen(oldResults.add);
    await tester.pump();
    unawaited(firstSubscription.cancel());
    await tester.pump();
    final results = <List<ConnectivityResult>>[];
    final subscription = monitor.changes.listen(results.add);
    addTearDown(subscription.cancel);
    await tester.pump();
    pending.complete([ConnectivityResult.wifi]);
    await tester.pump();
    expect(oldResults, isEmpty);
    expect(results, [
      [ConnectivityResult.ethernet],
    ]);
    await tester.pump(interval);
    expect(connectivity.checks, 3);
    unawaited(subscription.cancel());
    await tester.pump();
  });

  testWidgets('native monitoring keeps its stream and does not poll', (
    tester,
  ) async {
    final connectivity = _Connectivity(() => throw StateError('must not poll'));
    addTearDown(connectivity.dispose);
    final monitor = ConnectivityMonitor(
      connectivity: connectivity,
      usePolling: false,
      pollInterval: interval,
    );
    final results = <List<ConnectivityResult>>[];
    final errors = <Object>[];
    final subscription = monitor.changes.listen(
      results.add,
      onError: errors.add,
    );
    addTearDown(subscription.cancel);
    connectivity.events.add([ConnectivityResult.wifi]);
    connectivity.events.addError(StateError('native stream error'));
    await tester.pump(const Duration(seconds: 5));
    expect(results, [
      [ConnectivityResult.wifi],
    ]);
    expect(errors, hasLength(1));
    expect(connectivity.checks, 0);
    expect(connectivity.watches, 1);
    unawaited(subscription.cancel());
    await tester.pump();
    expect(connectivity.events.hasListener, isFalse);
  });
}
