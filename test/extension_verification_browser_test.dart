import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/fixed_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final uri = Uri.parse('https://example.invalid/verify?state=sample');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(backend, null);
  });

  List<String> mockIosLaunches({
    Future<bool> Function()? startSession,
    Future<bool> Function(bool inApp)? openBrowser,
  }) {
    final attempts = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'getExtensionPendingAuth') {
        return {'auth_url': uri.toString()};
      }
      expect(call.method, 'startWebAuthSession');
      expect(call.arguments, {
        'url': uri.toString(),
        'callback_scheme': 'mornye',
      });
      attempts.add('web-auth');
      return startSession == null ? true : await startSession();
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'launch');
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      expect(arguments['url'], uri.toString());
      final inApp = arguments['useWebView'] as bool;
      attempts.add(inApp ? 'in-app' : 'external');
      return openBrowser == null ? true : await openBrowser(inApp);
    });
    return attempts;
  }

  group('iOS verification browser preference', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test(
      'external preference opens the browser without a web auth sheet',
      () async {
        final attempts = mockIosLaunches();
        expect(
          await launchExtensionAuthUrl(uri, browserMode: ' EXTERNAL_FIRST '),
          isTrue,
        );
        expect(attempts, ['external']);
      },
    );

    test('in-app preference keeps callback capture through web auth', () async {
      final attempts = mockIosLaunches();
      expect(
        await launchExtensionAuthUrl(uri, browserMode: 'in_app_first'),
        isTrue,
      );
      expect(attempts, ['web-auth']);
    });

    for (final throwsError in [false, true]) {
      test(
        'external launch falls back to web auth: throws=$throwsError',
        () async {
          final attempts = mockIosLaunches(
            openBrowser: (inApp) async {
              expect(inApp, isFalse);
              if (throwsError) throw PlatformException(code: 'LAUNCH_FAILED');
              return false;
            },
          );
          expect(
            await launchExtensionAuthUrl(uri, browserMode: 'external_first'),
            isTrue,
          );
          expect(attempts, ['external', 'web-auth']);
        },
      );

      test(
        'failed web auth retains browser fallbacks: throws=$throwsError',
        () async {
          final attempts = mockIosLaunches(
            startSession: () async {
              if (throwsError) throw PlatformException(code: 'SESSION_FAILED');
              return false;
            },
            openBrowser: (inApp) async => !inApp,
          );
          expect(
            await launchExtensionAuthUrl(uri, browserMode: 'in_app_first'),
            isTrue,
          );
          expect(attempts, ['web-auth', 'in-app', 'external']);
        },
      );
    }

    test(
      'external preference can fall back when web auth is unavailable',
      () async {
        final attempts = mockIosLaunches(
          startSession: () async => false,
          openBrowser: (inApp) async => inApp,
        );
        expect(
          await launchExtensionAuthUrl(uri, browserMode: 'external_first'),
          isTrue,
        );
        expect(attempts, ['external', 'web-auth', 'in-app']);
      },
    );

    for (final mode in ['external_first', 'in_app_first']) {
      test('all launch failures allow manual help: $mode', () async {
        final attempts = mockIosLaunches(
          startSession: () async => false,
          openBrowser: (_) async => false,
        );
        expect(await launchExtensionAuthUrl(uri, browserMode: mode), isFalse);
        expect(
          attempts,
          mode == 'external_first'
              ? ['external', 'web-auth', 'in-app']
              : ['web-auth', 'in-app', 'external'],
        );
      });
    }

    test(
      'late web auth failure does not launch a browser after cancellation',
      () async {
        final started = Completer<void>();
        final session = Completer<bool>();
        final cancellation = Completer<void>();
        final attempts = mockIosLaunches(
          startSession: () {
            started.complete();
            return session.future;
          },
        );
        final opening = openPendingExtensionVerification(
          'provider-a',
          browserMode: 'in_app_first',
          cancellationSignal: cancellation.future,
        );
        await started.future.timeout(const Duration(seconds: 1));
        cancellation.complete();
        expect(await opening, isFalse);
        session.complete(false);
        await Future<void>.delayed(Duration.zero);
        expect(attempts, ['web-auth']);
      },
    );
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test('desktop $platform always uses the external browser', () async {
      debugDesktopPlatformOverride = true;
      debugDefaultTargetPlatformOverride = platform;
      final attempts = mockIosLaunches();
      for (final mode in ['external_first', 'in_app_first']) {
        expect(await launchExtensionAuthUrl(uri, browserMode: mode), isTrue);
      }
      expect(attempts, ['external', 'external']);
    });
  }

  for (final inAppFirst in [true, false]) {
    final browserMode = inAppFirst ? 'in_app_first' : 'external_first';
    for (final throwsError in [true, false]) {
      test(
        'browser fallback after launch failure: $browserMode, throws=$throwsError',
        () async {
          final modes = <bool>[];
          messenger.setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'launch');
            final arguments = Map<String, dynamic>.from(call.arguments as Map);
            expect(arguments['url'], uri.toString());
            modes.add(arguments['useWebView'] as bool);
            if (modes.length == 1) {
              if (throwsError) {
                throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
              }
              return false;
            }
            return true;
          });
          expect(
            await launchExtensionAuthUrl(uri, browserMode: browserMode),
            isTrue,
          );
          expect(modes, [inAppFirst, !inAppFirst]);
        },
      );
    }
  }

  test(
    'both browser failures return false so manual help can be shown',
    () async {
      var launches = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        launches++;
        throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
      });
      expect(
        await launchExtensionAuthUrl(uri, browserMode: 'in_app_first'),
        isFalse,
      );
      expect(launches, 2);
    },
  );

  test(
    'direct search verifies through the fallback browser and retries once',
    () async {
      var searches = 0;
      var pendingLookups = 0;
      var launches = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'customSearchWithExtension':
            searches++;
            if (searches == 1) {
              throw PlatformException(
                code: 'ERROR',
                message:
                    "verification_required: extension 'sample-provider' needs signed-session verification: Error: VERIFY_REQUIRED",
              );
            }
            return [
              {
                'id': 'sample-track',
                'name': 'Sample track',
                'artist_name': 'Artist',
              },
            ];
          case 'getExtensionPendingAuth':
            pendingLookups++;
            expect(call.arguments, {'extension_id': 'sample-provider'});
            return {'auth_url': uri.toString()};
          case 'completeExtensionSessionGrant':
            return true;
          default:
            fail('Unexpected backend call: ${call.method}');
        }
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        launches++;
        if (launches == 1) throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
        unawaited(
          PlatformBridge.completeExtensionSessionGrant(
            'sample-provider',
            'test-grant',
          ),
        );
        return true;
      });
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
      );
      addTearDown(container.dispose);
      await container
          .read(trackProvider.notifier)
          .customSearch('sample-provider', 'fallback verification');
      final state = container.read(trackProvider);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);
      expect(state.tracks.single.id, 'sample-track');
      expect(searches, 2);
      expect(pendingLookups, 1);
      expect(launches, 2);
    },
  );
}
