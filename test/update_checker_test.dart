import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/update_checker.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/update_dialog.dart';

Map<String, Object?> release(String version) => {
  'tag_name': 'v$version',
  'prerelease': false,
  'draft': false,
  'body': '- Release notes',
  'published_at': '2026-09-26T06:32:33Z',
  'html_url': 'https://github.com/mornyeapp/Mornye/releases/tag/v$version',
  'assets': [
    for (final abi in ['arm32', 'arm64'])
      {
        'name': 'Mornye-v$version-$abi.apk',
        'browser_download_url':
            'https://example.test/Mornye-v$version-$abi.apk',
        'digest': 'sha256:${List.filled(64, 'a').join()}',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<Map<String, dynamic>> cached() async =>
      jsonDecode(
            await File(
              '${root.path}/preference_blobs/update_releases.json',
            ).readAsString(),
          )
          as Map<String, dynamic>;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('update-blob-');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    SharedPreferences.setMockInitialValues({});
    LogBuffer().clear();
    LogBuffer.loggingEnabled = true;
  });
  tearDown(() async {
    LogBuffer.loggingEnabled = false;
    messenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });

  for (final (abi, asset) in [
    ('arm64-v8a', 'arm64'),
    ('armeabi-v7a', 'arm32'),
  ]) {
    test('5.0.0 discovers 5.0.5 despite a recent cache ($abi)', () async {
      SharedPreferences.setMockInitialValues({
        'update_checker_releases_json': jsonEncode([release('5.0.0')]),
        'update_checker_releases_fetched_at':
            DateTime.now().millisecondsSinceEpoch,
        'update_checker_releases_etag': '"old-release-list"',
      });
      var requests = 0;
      final checker = UpdateChecker(
        installedVersion: '5.0.0',
        isAndroid: true,
        supportedAbis: [abi],
        client: MockClient((request) async {
          requests++;
          expect(request.headers['If-None-Match'], '"old-release-list"');
          return http.Response(
            jsonEncode([release('5.0.5'), release('5.0.0')]),
            200,
            headers: {'etag': '"new-release-list"'},
          );
        }),
      );

      final update = await checker.checkForUpdate();
      expect(requests, 1);
      expect(update?.version, '5.0.5');
      expect(update?.apkDownloadUrl, endsWith('v5.0.5-$asset.apk'));
      expect(update?.releasesBehind, 1);
      expect(update?.apkSha256, List.filled(64, 'a').join());
      final prefs = await SharedPreferences.getInstance();
      expect(
        (await cached())['update_checker_releases_etag'],
        '"new-release-list"',
      );
      expect(
        (await cached())['update_checker_releases_json'],
        contains('v5.0.5'),
      );
      expect(prefs.getKeys(), isEmpty);
    });
  }

  test('discovers Mornye release assets after the app rename', () async {
    final renamedRelease = release('5.2.1')
      ..['assets'] = [
        for (final abi in ['arm32', 'arm64'])
          {
            'name': 'Mornye-5.2.1-$abi.apk',
            'browser_download_url':
                'https://example.test/Mornye-5.2.1-$abi.apk',
            'digest': 'sha256:${List.filled(64, 'a').join()}',
          },
      ];
    final checker = UpdateChecker(
      installedVersion: '5.2.0',
      isAndroid: true,
      supportedAbis: ['arm64-v8a'],
      client: MockClient(
        (_) async => http.Response(jsonEncode([renamedRelease]), 200),
      ),
    );
    final update = await checker.checkForUpdate();
    expect(
      update?.apkDownloadUrl,
      'https://example.test/Mornye-5.2.1-arm64.apk',
    );
    expect(update?.apkSha256, List.filled(64, 'a').join());
  });

  test(
    'checks again immediately and reuses the body only after GitHub 304',
    () async {
      var requests = 0;
      final checker = UpdateChecker(
        installedVersion: '5.0.0',
        isAndroid: true,
        supportedAbis: ['arm64-v8a'],
        client: MockClient((request) async {
          requests++;
          if (requests == 1) {
            expect(request.headers['If-None-Match'], isNull);
            return http.Response(
              jsonEncode([release('5.0.5')]),
              200,
              headers: {'etag': '"fresh"'},
            );
          }
          expect(request.headers['If-None-Match'], '"fresh"');
          return http.Response('', 304);
        }),
      );
      expect((await checker.checkForUpdate())?.version, '5.0.5');
      expect((await checker.checkForUpdate())?.version, '5.0.5');
      expect(requests, 2);
    },
  );

  test('a delayed 304 preserves a newer body and its matching ETag', () async {
    SharedPreferences.setMockInitialValues({
      'update_checker_releases_json': jsonEncode([release('5.0.1')]),
      'update_checker_releases_etag': '"old"',
    });
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final delayed = UpdateChecker(
      isAndroid: true,
      installedVersion: '5.0.0',
      supportedAbis: ['arm64-v8a'],
      client: MockClient((request) {
        expect(request.headers['If-None-Match'], '"old"');
        requestStarted.complete();
        return response.future;
      }),
    );
    final waiting = delayed.checkForUpdate();
    await requestStarted.future;
    final newer = UpdateChecker(
      isAndroid: true,
      installedVersion: '5.0.0',
      supportedAbis: ['arm64-v8a'],
      client: MockClient(
        (_) async => http.Response(
          jsonEncode([release('5.0.6')]),
          200,
          headers: {'etag': '"new"'},
        ),
      ),
    );
    expect((await newer.checkForUpdate())?.version, '5.0.6');
    response.complete(http.Response('', 304));
    await waiting;
    final stored = await cached();
    expect(stored['update_checker_releases_json'], contains('5.0.6'));
    expect(stored['update_checker_releases_etag'], '"new"');
  });

  test(
    'replacing a body without an ETag removes the previous validator',
    () async {
      SharedPreferences.setMockInitialValues({
        'update_checker_releases_json': jsonEncode([release('5.0.0')]),
        'update_checker_releases_etag': '"old"',
      });
      final checker = UpdateChecker(
        installedVersion: '5.0.0',
        isAndroid: true,
        supportedAbis: ['arm64-v8a'],
        client: MockClient(
          (_) async => http.Response(jsonEncode([release('5.0.5')]), 200),
        ),
      );
      expect((await checker.checkForUpdate())?.version, '5.0.5');
      expect((await cached())['update_checker_releases_etag'], isNull);
    },
  );

  for (final failure in ['offline', 'rate limit', 'invalid JSON']) {
    test('$failure does not claim cached 5.0.0 is the latest online', () async {
      final cachedBody = jsonEncode([release('5.0.0')]);
      SharedPreferences.setMockInitialValues({
        'update_checker_releases_json': cachedBody,
        'update_checker_releases_etag': '"cached"',
      });
      final checker = UpdateChecker(
        installedVersion: '5.0.0',
        isAndroid: true,
        supportedAbis: ['arm64-v8a'],
        client: MockClient((_) async {
          if (failure == 'offline') throw http.ClientException('Offline');
          if (failure == 'rate limit') return http.Response('Limited', 403);
          return http.Response('{"message":"Invalid response"}', 200);
        }),
      );
      expect(await checker.checkForUpdate(), isNull);
      final messages = LogBuffer().entries
          .map((entry) => entry.message)
          .join('\n');
      expect(messages, contains('could not be verified'));
      expect(messages, isNot(contains('No update available')));
      final prefs = await SharedPreferences.getInstance();
      expect((await cached())['update_checker_releases_json'], cachedBody);
      expect((await cached())['update_checker_releases_etag'], '"cached"');
      expect(prefs.getKeys(), isEmpty);
    });
  }

  test(
    'an offline check can still offer a previously discovered update',
    () async {
      SharedPreferences.setMockInitialValues({
        'update_checker_releases_json': jsonEncode([release('5.0.5')]),
      });
      final checker = UpdateChecker(
        installedVersion: '5.0.0',
        isAndroid: true,
        supportedAbis: ['armeabi-v7a'],
        client: MockClient((_) async => throw http.ClientException('Offline')),
      );
      expect((await checker.checkForUpdate())?.version, '5.0.5');
    },
  );

  test(
    'invalid stored JSON does not send its ETag or block fresh releases',
    () async {
      SharedPreferences.setMockInitialValues({
        'update_checker_releases_json': '{broken',
        'update_checker_releases_etag': '"broken"',
      });
      final checker = UpdateChecker(
        installedVersion: '5.0.0',
        isAndroid: true,
        supportedAbis: ['arm64-v8a'],
        client: MockClient((request) async {
          expect(request.headers['If-None-Match'], isNull);
          return http.Response(jsonEncode([release('5.0.5')]), 200);
        }),
      );
      expect((await checker.checkForUpdate())?.version, '5.0.5');
    },
  );

  test('stable skips previews and counts only newer stable releases', () async {
    final checker = UpdateChecker(
      installedVersion: '4.9.5',
      isAndroid: true,
      supportedAbis: ['arm64-v8a'],
      client: MockClient(
        (_) async => http.Response(
          jsonEncode([
            {...release('5.0.6-preview'), 'prerelease': true},
            release('5.0.5'),
            release('5.0.0'),
            release('4.9.6'),
            release('4.9.5'),
          ]),
          200,
        ),
      ),
    );
    final stable = await checker.checkForUpdate();
    expect(stable?.version, '5.0.5');
    expect(stable?.releasesBehind, UpdateChecker.forceUpdateThreshold);
    expect(
      (await checker.checkForUpdate(channel: 'preview'))?.version,
      '5.0.6-preview',
    );
  });

  test(
    'an installed 5.0.5 does not prompt to reinstall the same version',
    () async {
      final checker = UpdateChecker(
        installedVersion: '5.0.5',
        isAndroid: true,
        client: MockClient(
          (_) async => http.Response(jsonEncode([release('5.0.5')]), 200),
        ),
      );
      expect(await checker.checkForUpdate(), isNull);
    },
  );

  test('non-Android platforms do not request or offer an APK', () async {
    final checker = UpdateChecker(
      installedVersion: '5.0.0',
      isAndroid: false,
      client: MockClient(
        (_) async => throw StateError('Unexpected network request'),
      ),
    );
    expect(await checker.checkForUpdate(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'freshly discovered release opens the update dialog ($mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final checker = UpdateChecker(
          installedVersion: '5.0.0',
          isAndroid: true,
          supportedAbis: ['arm64-v8a'],
          client: MockClient(
            (_) async => http.Response(jsonEncode([release('5.0.5')]), 200),
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [lowEndDeviceProvider.overrideWithValue(false)],
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      final update = await checker.checkForUpdate();
                      if (context.mounted && update != null) {
                        await showUpdateDialog(
                          context,
                          updateInfo: update,
                          onDisableUpdates: () {},
                        );
                      }
                    },
                    child: const Text('Check now'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Check now'));
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
            if (find.byType(UpdateDialog).evaluate().isNotEmpty) return;
          }
        });
        await tester.pumpAndSettle();
        expect(find.byType(UpdateDialog), findsOneWidget);
        expect(find.text('v5.0.5'), findsOneWidget);
        expect(find.textContaining('Release notes'), findsOneWidget);
        expect(find.text('Download & Install').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('installs without a package offer the release page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lowEndDeviceProvider.overrideWithValue(false)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUpdateDialog(
                  context,
                  updateInfo: UpdateInfo(
                    version: '5.3.0',
                    changelog: '- Desktop builds',
                    downloadUrl: 'https://example.test/releases/v5.3.0',
                    installKind: UpdateInstallKind.releasePage,
                  ),
                  onDisableUpdates: () {},
                ),
                child: const Text('Check now'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(find.text('View Release').hitTestable(), findsOneWidget);
    expect(find.text('Download & Install'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
