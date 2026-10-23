import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

void main() {
  const channel = MethodChannel('com.zarz.mornye/backend');
  const browser = MethodChannel('plugins.flutter.io/url_launcher');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, null);
  });

  Future<void> showApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: AppNavigationService.rootNavigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: Text('Library')),
    ),
  );

  testWidgets('missing pending challenge explains why no page opened', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getExtensionPendingAuth');
          return null;
        });
    await showApp(tester);
    expect(await openPendingExtensionVerification('provider-a'), isFalse);
    await tester.pump();
    expect(
      find.text(
        'No verification page is available for provider-a. '
        'Retry the download to request a new challenge.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelled pending lookup does not show a failure message', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    final cancellation = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => pending.future);
    await showApp(tester);
    final result = openPendingExtensionVerification(
      'provider-a',
      cancellationSignal: cancellation.future,
    );
    cancellation.complete();
    expect(await result, isFalse);
    pending.complete();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final blockedStep in [
    'pending lookup',
    'browser launch',
    'manual help',
    'grant wait',
  ]) {
    testWidgets('verification timeout also bounds $blockedStep', (
      tester,
    ) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final blocked = Completer<Object?>();
      var launches = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'completeExtensionSessionGrant') return true;
        expect(call.method, 'getExtensionPendingAuth');
        if (blockedStep == 'pending lookup') return await blocked.future;
        return {'auth_url': 'https://example.invalid/verify?state=sample'};
      });
      messenger.setMockMethodCallHandler(browser, (_) async {
        launches++;
        if (blockedStep == 'browser launch') return await blocked.future;
        return blockedStep == 'grant wait';
      });
      await showApp(tester);
      bool? granted;
      final waiting = openVerificationAndAwaitGrant(
        'provider-a',
        browserMode: 'in_app_first',
      ).then((value) => granted = value);
      await tester.pumpAndSettle();
      expect(granted, isNull);
      expect(
        launches,
        blockedStep == 'pending lookup'
            ? 0
            : blockedStep == 'manual help'
            ? 2
            : 1,
      );
      if (blockedStep == 'manual help') {
        expect(find.byType(AppAlertDialog), findsOneWidget);
      }
      await tester.pump(extensionVerificationGrantTimeout);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(granted, isFalse, reason: 'Every browser step has a deadline');
      await waiting;
      expect(find.byType(AppAlertDialog), findsNothing);

      // A late native/browser response must not reopen the expired flow.
      blocked.complete(
        blockedStep == 'pending lookup'
            ? {'auth_url': 'https://example.invalid/late'}
            : false,
      );
      await tester.pumpAndSettle();
      expect(
        launches,
        blockedStep == 'pending lookup'
            ? 0
            : blockedStep == 'manual help'
            ? 2
            : 1,
        reason: 'Late failure must not launch the fallback browser',
      );
      expect(find.byType(AppAlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      // A fresh attempt can still receive a grant after the timed-out flow.
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'completeExtensionSessionGrant') return true;
        return {'auth_url': 'https://example.invalid/verify?state=retry'};
      });
      messenger.setMockMethodCallHandler(browser, (_) async {
        unawaited(
          PlatformBridge.completeExtensionSessionGrant('provider-a', 'grant'),
        );
        return true;
      });
      expect(
        await tester.runAsync(
          () => openVerificationAndAwaitGrant(
            'provider-a',
            browserMode: 'in_app_first',
          ),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cancelling a wait dismisses its already-visible help dialog', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'auth_url': 'https://example.invalid/verify?state=sample'},
    );
    messenger.setMockMethodCallHandler(browser, (_) async => true);
    await showApp(tester);
    final cancellation = Completer<void>();
    final waiting = openVerificationAndAwaitGrant(
      'provider-a',
      browserMode: 'in_app_first',
      cancellationSignal: cancellation.future,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(find.byType(AppAlertDialog), findsOneWidget);
    cancellation.complete();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(await waiting, isFalse);
    await tester.pumpAndSettle();
    expect(find.byType(AppAlertDialog), findsNothing);
    expect(find.text('Library'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
