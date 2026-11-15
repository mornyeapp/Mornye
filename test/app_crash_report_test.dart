import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/app_crash_report.dart';
import 'package:mornye/providers/app_crash_provider.dart';
import 'package:mornye/services/app_crash_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_crash_banner.dart';

Map<String, dynamic> _report() => {
  'id': '123456',
  'timestamp': 123456,
  'reason': 'Native crash',
  'description': 'Fatal signal 6 (SIGABRT)',
  'version': '5.2.0 (2162)',
  'device': 'Example Phone',
  'android': '15',
  'sdk': 35,
  'trace': 'Abort message: invalid pointer\n#0 pc 1234 libdecoder.so',
  'runtime_error': 'StateError: request failed access_token=secret-value',
  'runtime_stack': '#0 Example.decode (example.dart:12)',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, dynamic>? stored;
  Map<Object?, Object?>? runtimeError;
  String? clipboard;
  var failDismiss = false;
  String? dismissedId;
  String? shownId;
  var shownCalls = 0;

  setUp(() {
    stored = _report();
    runtimeError = null;
    clipboard = null;
    failDismiss = false;
    dismissedId = null;
    shownId = null;
    shownCalls = 0;
    messenger.setMockMethodCallHandler(backend, (call) async {
      switch (call.method) {
        case 'getPendingAppCrash':
          if (stored?['id'] == shownId || stored?['id'] == dismissedId) {
            return null;
          }
          return stored;
        case 'getLatestAppCrash':
          return stored;
        case 'markAppCrashShown':
          shownCalls++;
          if ((call.arguments as Map)['id'] == stored?['id']) {
            shownId = stored?['id'] as String?;
          }
          return null;
        case 'dismissAppCrash':
          if (failDismiss) throw PlatformException(code: 'disk_full');
          if ((call.arguments as Map)['id'] == stored?['id']) {
            dismissedId = stored?['id'] as String?;
          }
          return null;
        case 'recordAppRuntimeError':
          runtimeError = call.arguments as Map<Object?, Object?>;
          return null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    LogBuffer().clear();
  });

  test(
    'report contains original error, native and Dart stacks, and device info',
    () {
      final report = AppCrashReport.fromMap(_report());
      expect(report.report, contains('Example Phone'));
      expect(report.report, contains('5.2.0 (2162)'));
      expect(report.report, contains('Fatal signal 6 (SIGABRT)'));
      expect(report.report, contains('#0 pc 1234 libdecoder.so'));
      expect(report.report, contains('example.dart:12'));
      expect(report.report, contains('[REDACTED]'));
      expect(report.report, isNot(contains('secret-value')));
    },
  );

  test('missing OS trace is explicit and does not fabricate a cause', () {
    final report = AppCrashReport.fromMap(_report()..remove('trace'));
    expect(report.report, contains('Android did not provide a stack trace'));
    expect(report.report, contains('Fatal signal 6 (SIGABRT)'));
  });

  test('crash reports preserve process importance and session duration', () {
    final values = _report()
      ..remove('trace')
      ..addAll({
        'reason_code': 5,
        'process_name': 'example.app',
        'process_id': 123,
        'importance_code': 100,
        'importance_label': 'Foreground activity',
        'session_duration_ms': 65000,
        'pss_kb': 0,
        'rss_kb': 245104,
      });
    final report = AppCrashReport.fromMap(values).report;
    expect(report, contains('Process state before exit: Foreground activity'));
    expect(
      report,
      contains('Process importance before exit (Android code): 100'),
    );
    expect(report, contains('Session duration before exit (ms): 65000'));
    expect(report, contains('Last sampled PSS (KB): 0'));
    expect(report, contains('Last sampled RSS (KB): 245104'));
    expect(report, contains('Android did not provide a stack trace'));
  });

  test(
    'reading alone does not consume a notice and dismissal preserves diagnostics',
    () async {
      var container = ProviderContainer();
      expect((await container.read(appCrashProvider.future))?.id, '123456');
      container.dispose();
      container = ProviderContainer();
      addTearDown(container.dispose);
      expect((await container.read(appCrashProvider.future))?.id, '123456');
      await container.read(appCrashProvider.notifier).dismiss('123456');
      expect(container.read(appCrashProvider).value, isNull);
      expect(stored, isNotNull);
      expect(
        (await container.read(latestAppCrashProvider.future))?.id,
        '123456',
      );
    },
  );

  test('ANR classification uses the native reason code', () {
    expect(AppCrashReport.fromMap(_report()).isAnr, isFalse);
    expect(
      AppCrashReport.fromMap(_report()..['reason_code'] = 6).isAnr,
      isTrue,
    );
  });

  testWidgets(
    'rendered notice stays usable but does not return on next launch',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(child: AppCrashBanner()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(shownId, '123456');
      expect(shownCalls, 1);
      expect(find.text('The app previously crashed'), findsOneWidget);
      await tester.tap(find.text('Copy report for developer'));
      await tester.pumpAndSettle();
      expect(clipboard, contains('invalid pointer'));
      expect(shownCalls, 1);
      final nextLaunch = ProviderContainer();
      expect(await nextLaunch.read(appCrashProvider.future), isNull);
      expect(
        (await nextLaunch.read(latestAppCrashProvider.future))?.id,
        '123456',
      );
      nextLaunch.dispose();
    },
  );

  testWidgets('diagnostics can open a seen ANR without another notification', (
    tester,
  ) async {
    shownId = '123456';
    stored!['reason_code'] = 6;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('id'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: AppCrashBanner(diagnostic: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Aplikasi sebelumnya berhenti merespons'), findsOneWidget);
    expect(find.text('Aplikasi sebelumnya mengalami crash'), findsNothing);
    expect(find.text('Tutup'), findsNothing);
    expect(shownCalls, 0);
    await tester.tap(find.text('Salin laporan untuk developer'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('Android exit reason code: 6'));
  });

  testWidgets('an inactive tab does not consume its crash notice', (
    tester,
  ) async {
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (context, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: const SingleChildScrollView(child: AppCrashBanner()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(shownCalls, 0);
    active.value = true;
    await tester.pumpAndSettle();
    expect(shownCalls, 1);
  });

  test('failed dismissal retains the report for another attempt', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(appCrashProvider.future);
    failDismiss = true;
    await expectLater(
      container.read(appCrashProvider.notifier).dismiss('123456'),
      throwsA(isA<PlatformException>()),
    );
    expect(container.read(appCrashProvider).value?.id, '123456');
  });

  test(
    'global Dart error capture preserves stacks and redacted recent logs',
    () async {
      LogBuffer().add(
        LogEntry(
          timestamp: DateTime(2026),
          level: 'ERROR',
          tag: 'Player',
          message: 'decoder failed',
        ),
      );
      await AppCrashService.recordRuntimeError(
        StateError('api_key=hidden-key'),
        StackTrace.fromString('player.dart:42'),
      );
      expect(runtimeError?['error'], contains('[REDACTED]'));
      expect(runtimeError?['error'], isNot(contains('hidden-key')));
      expect(runtimeError?['stack'], contains('player.dart:42'));
      expect(runtimeError?['logs'], contains('decoder failed'));
      // Context capture alone does not create a confirmed crash report.
      stored = null;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(await container.read(appCrashProvider.future), isNull);
    },
  );

  for (final mornye in [false, true]) {
    testWidgets('Home crash card copies full report and dismisses ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            locale: const Locale('id'),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(child: AppCrashBanner()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Aplikasi sebelumnya mengalami crash'), findsOneWidget);
      expect(find.text('Fatal signal 6 (SIGABRT)'), findsOneWidget);
      await tester.tap(find.text('Salin laporan untuk developer'));
      await tester.pumpAndSettle();
      expect(clipboard, contains('Abort message: invalid pointer'));
      expect(clipboard, contains('Example Phone'));
      expect(clipboard, isNot(contains('secret-value')));
      expect(find.text('Aplikasi sebelumnya mengalami crash'), findsOneWidget);
      // The full report opens in a sheet rather than expanding on Home.
      expect(find.textContaining('Abort message'), findsNothing);
      await tester.tap(find.text('Lihat error dan log'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Abort message: invalid pointer'), findsOne);
      Navigator.of(tester.element(find.byType(AppCrashBanner))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tutup'));
      await tester.pumpAndSettle();
      expect(find.text('Aplikasi sebelumnya mengalami crash'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no crash means no Home card', (tester) async {
    stored = null;
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: AppCrashBanner())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppCrashBanner), findsOneWidget);
    expect(find.text('The app previously crashed'), findsNothing);
    expect(find.byType(AppContentCard), findsNothing);
  });
}
