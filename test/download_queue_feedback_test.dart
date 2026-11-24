import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/widgets/download_queue_feedback.dart';

class _Queue extends DownloadQueueNotifier {
  int _retryCalls = 0;
  bool? _retriedNetworkOnly;

  @override
  DownloadQueueState build() => const DownloadQueueState();

  void reconnect(int count) => state = state.copyWith(
    reconnectRetry: DownloadQueueReconnectRetry(count),
  );

  void progressSnapshot() => state = state.copyWith(isProcessing: true);

  @override
  Future<void> retryAllFailed({bool networkOnly = false}) async {
    _retryCalls++;
    _retriedNetworkOnly = networkOnly;
  }
}

Widget _app(ProviderContainer container, {Key? feedbackKey}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DownloadQueueFeedback(
          key: feedbackKey,
          child: const Scaffold(body: Text('Queue')),
        ),
      ),
    );

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  testWidgets(
    'shows newest retry count, replaces messages, and retries only network failures',
    (tester) async {
      final queue = _Queue();
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(() => queue)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(Scaffold)).l10n;
      queue.reconnect(2);
      await tester.pumpAndSettle();
      expect(find.text(l10n.queueNetworkFailedOffline(2)), findsOneWidget);
      queue.reconnect(3);
      await tester.pumpAndSettle();
      expect(find.text(l10n.queueNetworkFailedOffline(2)), findsNothing);
      expect(find.text(l10n.queueNetworkFailedOffline(3)), findsOneWidget);
      await tester.tap(find.text(l10n.dialogRetry));
      await tester.pumpAndSettle();
      expect(queue._retryCalls, 1);
      expect(queue._retriedNetworkOnly, isTrue);
      queue.progressSnapshot();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'background effects and remounting never replay stale retry prompts',
    (tester) async {
      final queue = _Queue();
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(() => queue)],
      );
      addTearDown(container.dispose);
      container.read(downloadQueueProvider);
      queue.reconnect(2);
      expect(
        container.read(downloadQueueProvider).reconnectRetry!.failedCount,
        2,
      );
      await tester.pumpWidget(
        _app(container, feedbackKey: const ValueKey('first')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      queue.reconnect(3);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold)),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _app(container, feedbackKey: const ValueKey('second')),
      );
      await tester.pumpAndSettle();
      queue.progressSnapshot();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('suspended reconnect effects are never replayed on resume', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    queue.reconnect(2);
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    queue.progressSnapshot();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    queue.reconnect(3);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
