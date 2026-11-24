import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';

class _DelayedSettingsNotifier extends SettingsNotifier {
  final _ready = Completer<void>();
  int _loads = 0;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {
    _loads++;
    await _ready.future;
  }

  void complete() {
    if (!_ready.isCompleted) _ready.complete();
  }
}

class _RetryingSettingsNotifier extends SettingsNotifier {
  int _syncAttempts = 0;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    _syncAttempts++;
    if (_syncAttempts == 1) {
      throw StateError('Settings load failed');
    }
  }
}

class _FailingSettingsSyncNotifier extends SettingsNotifier {
  int _syncs = 0;

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    if (++_syncs == 1) throw StateError('Settings sync unavailable');
    await super.syncLyricsSettingsToBackend(settings: settings);
  }
}

class _DelayedExtensionNotifier extends ExtensionNotifier {
  final _started = Completer<void>();
  final _ready = Completer<void>();
  int _initializations = 0;
  bool _failInitialization = false;

  @override
  Future<void> initialize(
    String extensionsDir,
    String dataDir, {
    required String masterKey,
  }) async {
    _initializations++;
    expect(await Directory(extensionsDir).exists(), isTrue);
    expect(await Directory(dataDir).exists(), isTrue);
    expect(base64Decode(masterKey), hasLength(32));
    if (!_started.isCompleted) _started.complete();
    await _ready.future;
    state = state.copyWith(
      isInitialized: !_failInitialization,
      error: _failInitialization ? 'Native initialization failed' : null,
    );
  }

  @override
  Future<void> refreshExtensions() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const backend = MethodChannel('com.zarz.mornye/backend');
  late Directory root;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('extension-initialization-');
    messenger.setMockMethodCallHandler(paths, (call) async {
      return call.method == 'getApplicationSupportDirectory'
          ? '${root.path}/support'
          : '${root.path}/documents';
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'read') return base64Encode(List.filled(32, 1));
      return null;
    });
  });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(backend, null);
    await root.delete(recursive: true);
  });

  testWidgets(
    'activity detach releases idle memory without closing extensions',
    (tester) async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(backend, (call) async {
        methods.add(call.method);
        return null;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(extensionProvider);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();
      expect(methods, contains('releaseMemory'));
      expect(methods, isNot(contains('cleanupExtensions')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  test(
    'storage preparation retries a transient failure and coalesces callers',
    () async {
      var supportReads = 0;
      messenger.setMockMethodCallHandler(paths, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          supportReads++;
          if (supportReads == 1) {
            throw PlatformException(code: 'temporarily_unavailable');
          }
          return '${root.path}/support';
        }
        return '${root.path}/documents';
      });
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<PlatformException>()),
      );
      final first = ExtensionStorageService.prepare();
      final second = ExtensionStorageService.prepare();
      expect(identical(first, second), isTrue);
      final storage = await first;
      expect(supportReads, 2);
      expect(storage.extensionsDir, '${root.path}/support/extensions');
      expect(storage.dataDir, '${root.path}/support/extension_data');
    },
  );

  test(
    'delayed settings load gates startup, install, upgrade, and repository init',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = _DelayedSettingsNotifier();
      final notifier = _DelayedExtensionNotifier();
      final container = ProviderContainer(
        overrides: [
          extensionProvider.overrideWith(() => notifier),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);
      container.read(extensionProvider);
      final calls = <String>[];
      messenger.setMockMethodCallHandler(backend, (call) async {
        calls.add(call.method);
        return {
          'name': 'example-extension',
          'display_name': 'Example',
          'version': '1.0.0',
        };
      });

      final startup = notifier.ensureInitialized();
      final install = notifier.installExtension(
        '/cache/example-extension.sflx',
      );
      final upgrade = notifier.upgradeExtension(
        '/cache/example-extension.sflx',
      );
      final repository = container
          .read(repoProvider.notifier)
          .initialize('/cache/store');
      await Future<void>.delayed(Duration.zero);

      expect(settings._loads, 1);
      expect(notifier._initializations, 0);
      expect(notifier._started.isCompleted, isFalse);
      expect(calls, isEmpty);

      settings.complete();
      await notifier._started.future;
      expect(notifier._initializations, 1);
      expect(calls, isEmpty);

      notifier._ready.complete();
      await startup;
      expect(await install, isTrue);
      expect(await upgrade, isTrue);
      await repository;
      expect(container.read(repoProvider).isInitialized, isTrue);
      expect(settings._loads, 1);
      expect(notifier._initializations, 1);
      expect(
        calls,
        containsAll([
          'loadExtensionFromPath',
          'upgradeExtension',
          'initExtensionRepo',
        ]),
      );
    },
  );

  test('startup, install and upgrade wait for one initialization', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = _DelayedExtensionNotifier();
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(extensionProvider);
    final calls = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'setLoggingEnabled') return null;
      expect(container.read(extensionProvider).isInitialized, isTrue);
      calls.add(call.method);
      return {
        'name': 'example-extension',
        'display_name': 'Example',
        'version': '1.0.0',
      };
    });

    final startup = notifier.ensureInitialized();
    await notifier._started.future;
    final install = notifier.installExtension('/cache/example-extension.sflx');
    final batch = notifier.installExtensions(['/cache/example-b.sflx']);
    final check = notifier.checkExtensionUpgrade(
      '/cache/example-extension.sflx',
    );
    final upgrade = notifier.upgradeExtension('/cache/example-extension.sflx');
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    notifier._ready.complete();
    await startup;
    expect(await install, isTrue);
    expect((await batch).installed, 1);
    expect((await check)['error'], isNull);
    expect(await upgrade, isTrue);
    expect(notifier._initializations, 1);
    expect(
      calls,
      containsAll([
        'loadExtensionFromPath',
        'checkExtensionUpgrade',
        'upgradeExtension',
      ]),
    );
  });

  test(
    'failed initialization prevents installation and can be retried',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _DelayedExtensionNotifier().._failInitialization = true;
      notifier._ready.complete();
      final container = ProviderContainer(
        overrides: [extensionProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      container.read(extensionProvider);
      var installs = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'setLoggingEnabled') return null;
        expect(call.method, 'loadExtensionFromPath');
        installs++;
        return {'name': 'example-extension'};
      });
      expect(await notifier.installExtension('/cache/example.sflx'), isFalse);
      expect(installs, 0);
      expect(
        container.read(extensionProvider).error,
        contains('Native initialization failed'),
      );
      notifier._failInitialization = false;
      expect(await notifier.installExtension('/cache/example.sflx'), isTrue);
      expect(installs, 1);
      expect(notifier._initializations, 2);
    },
  );

  test('repository waits for a successful owner and retries failure', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = _DelayedExtensionNotifier().._failInitialization = true;
    notifier._ready.complete();
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    var repositoryInitializations = 0;
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'setLoggingEnabled') return null;
      expect(call.method, 'initExtensionRepo');
      expect(container.read(extensionProvider).isInitialized, isTrue);
      repositoryInitializations++;
      return null;
    });
    final repository = container.read(repoProvider.notifier);
    await repository.initialize('/cache/store');
    expect(repositoryInitializations, 0);
    expect(container.read(repoProvider).isInitialized, isFalse);
    expect(
      container.read(repoProvider).error,
      contains('Native initialization failed'),
    );
    notifier._failInitialization = false;
    await repository.initialize('/cache/store');
    expect(repositoryInitializations, 1);
    expect(container.read(repoProvider).isInitialized, isTrue);
    expect(container.read(repoProvider).error, isNull);
  });

  test(
    'adding a repository retries initialization before changing the URL',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _DelayedExtensionNotifier().._failInitialization = true;
      notifier._ready.complete();
      final container = ProviderContainer(
        overrides: [extensionProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      final calls = <String>[];
      const url = 'https://example.com/registry.json';
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'setLoggingEnabled') return null;
        calls.add(call.method);
        switch (call.method) {
          case 'initExtensionRepo':
            expect(container.read(extensionProvider).isInitialized, isTrue);
            return null;
          case 'resolveRepoRegistryUrl':
            expect(container.read(repoProvider).isInitialized, isTrue);
            return url;
          case 'setRepoRegistryUrls':
            return null;
          case 'getRepoCatalog':
            return {
              'sources': [
                {'registry_url': url, 'name': 'example', 'error': ''},
              ],
              'extensions': <Map<String, dynamic>>[],
            };
          default:
            throw StateError('Unexpected backend call: ${call.method}');
        }
      });
      final repository = container.read(repoProvider.notifier);
      await repository.initialize('/cache/store');
      final failed = await repository.addRegistryUrl(url);
      expect(failed.status, RepoAddStatus.failed);
      expect(failed.error, contains('Native initialization failed'));
      expect(
        container.read(repoProvider).error,
        contains('Native initialization failed'),
      );
      expect(calls, isEmpty);
      notifier._failInitialization = false;
      final added = await repository.addRegistryUrl(url);
      expect(added.status, RepoAddStatus.added);
      expect(calls, [
        'initExtensionRepo',
        'resolveRepoRegistryUrl',
        'setRepoRegistryUrls',
        'getRepoCatalog',
      ]);
      expect(container.read(repoProvider).registryUrls, [url]);
      expect(container.read(repoProvider).error, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('store_registry_urls'), jsonEncode([url]));
      expect(prefs.getString('store_registry_url'), url);
    },
  );

  test(
    'concurrent repository startup shares one native initialization',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _DelayedExtensionNotifier();
      final container = ProviderContainer(
        overrides: [extensionProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      var initializations = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'initExtensionRepo') initializations++;
        return null;
      });
      final repository = container.read(repoProvider.notifier);
      final first = repository.initialize('/cache/store');
      expect(identical(first, repository.initialize('/cache/store')), isTrue);
      await notifier._started.future;
      expect(initializations, 0);
      notifier._ready.complete();
      await first;
      expect(initializations, 1);
      expect(container.read(repoProvider).isInitialized, isTrue);
    },
  );

  for (final hasWorkingExtension in [false, true]) {
    test('native package load errors stay visible and recover on retry '
        '(partial=$hasWorkingExtension)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(extensionProvider.notifier);
      var fail = true;
      const loadError =
          'example-unreadable: cipher: message authentication failed';
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'loadExtensionsFromDir':
            return {
              'loaded': hasWorkingExtension ? ['example-working'] : null,
              'errors': fail ? [loadError] : <String>[],
            };
          case 'getInstalledExtensions':
            return <Map<String, dynamic>>[
              if (hasWorkingExtension)
                {
                  'id': 'example-working',
                  'name': 'example-working',
                  'display_name': 'Example Working',
                  'version': '1.0.0',
                  'enabled': false,
                },
            ];
          case 'getProviderPriority':
          case 'getMetadataProviderPriority':
            return <String>[];
          default:
            return null;
        }
      });

      await container.read(settingsProvider.notifier).ensureLoaded();
      final loaded = await notifier.loadExtensions('${root.path}/sources');
      expect(notifier.state.error, contains(loadError));
      expect(loaded, hasWorkingExtension);
      expect(notifier.state.isLoading, isFalse);
      expect(
        notifier.state.extensions.map((extension) => extension.id),
        hasWorkingExtension ? ['example-working'] : isEmpty,
      );

      fail = false;
      expect(await notifier.loadExtensions('${root.path}/sources'), isTrue);
      expect(notifier.state.error, isNull);
    });
  }

  for (final failureMethod in const [
    'loadExtensionsFromDir',
    'getInstalledExtensions',
  ]) {
    test('extension refresh failure remains visible and can be retried '
        '($failureMethod)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(extensionProvider.notifier);
      final extensionsDir = Directory('${root.path}/production-$failureMethod');
      await extensionsDir.create(recursive: true);

      var targetAttempts = 0;
      var loadAttempts = 0;
      var refreshAttempts = 0;
      final expectedError = failureMethod == 'loadExtensionsFromDir'
          ? 'transient_load'
          : 'transient_refresh';
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'loadExtensionsFromDir':
            loadAttempts++;
            if (failureMethod == call.method && ++targetAttempts == 1) {
              throw PlatformException(code: 'transient_load');
            }
            return {'loaded': <String>[], 'errors': <Map<String, dynamic>>[]};
          case 'getInstalledExtensions':
            refreshAttempts++;
            if (failureMethod == call.method && ++targetAttempts == 1) {
              throw PlatformException(code: 'transient_refresh');
            }
            return <Map<String, dynamic>>[];
          default:
            throw StateError('Unexpected backend method: ${call.method}');
        }
      });

      await notifier.loadExtensions(extensionsDir.path);
      expect(notifier.state.isInitialized, isFalse);
      expect(notifier.state.error, contains(expectedError));
      expect(targetAttempts, 1);

      await notifier.loadExtensions(extensionsDir.path);
      expect(notifier.state.isInitialized, isFalse);
      expect(notifier.state.error, isNull);
      expect(loadAttempts, 2);
      expect(
        refreshAttempts,
        failureMethod == 'getInstalledExtensions' ? 2 : 1,
      );
      expect(targetAttempts, 2);
    });
  }

  test(
    'settings load failure prevents initialization and a retry works',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = _RetryingSettingsNotifier();
      final notifier = _DelayedExtensionNotifier().._ready.complete();
      final container = ProviderContainer(
        overrides: [
          extensionProvider.overrideWith(() => notifier),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);
      container.read(extensionProvider);
      var installs = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'loadExtensionFromPath') installs++;
        return {'name': 'example-extension'};
      });

      await expectLater(
        notifier.ensureInitialized(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Settings load failed',
          ),
        ),
      );
      expect(settings._syncAttempts, 1);
      expect(notifier._initializations, 0);
      expect(container.read(extensionProvider).isInitialized, isFalse);
      expect(
        container.read(extensionProvider).error,
        contains('Settings load failed'),
      );
      expect(installs, 0);

      expect(
        await notifier.installExtension('/cache/example-extension.sflx'),
        isTrue,
      );
      expect(settings._syncAttempts, 2);
      expect(notifier._initializations, 1);
      expect(installs, 1);
    },
  );

  test(
    'SettingsNotifier coalesces load and restores persisted lyrics settings',
    () async {
      const providers = [
        'extension:example.provider.primary',
        'extension:example.provider.fallback',
      ];
      const persisted = AppSettings(
        lyricsProviders: providers,
        lyricsPreferBestTiming: false,
        lyricsIncludeTranslationNetease: true,
        lyricsIncludeRomanizationNetease: true,
        lyricsMultiPersonWordByWord: true,
        lyricsAppleElrcWordSync: true,
        musixmatchLanguage: 'id',
      );
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(persisted.toJson()),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(settingsProvider.notifier);
      final first = notifier.ensureLoaded();
      final second = notifier.ensureLoaded();
      expect(identical(first, second), isTrue);

      await first;
      final loaded = container.read(settingsProvider);
      expect(loaded.lyricsProviders, providers);
      expect(loaded.lyricsPreferBestTiming, isFalse);
      expect(loaded.lyricsIncludeTranslationNetease, isTrue);
      expect(loaded.lyricsIncludeRomanizationNetease, isTrue);
      expect(loaded.lyricsMultiPersonWordByWord, isTrue);
      expect(loaded.lyricsAppleElrcWordSync, isTrue);
      expect(loaded.musixmatchLanguage, 'id');
      expect(loaded.lyricsFetchOptions, {
        'include_translation_netease': true,
        'include_romanization_netease': true,
        'multi_person_word_by_word': true,
        'apple_elrc_word_sync': true,
        'musixmatch_language': 'id',
        'prefer_best_timing': false,
      });
    },
  );

  test('real settings loader retries a failed shared future', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = _FailingSettingsSyncNotifier();
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider);
    final failed = notifier.ensureLoaded();
    expect(identical(failed, notifier.ensureLoaded()), isTrue);
    await expectLater(
      failed,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Settings sync unavailable',
        ),
      ),
    );
    final retry = notifier.ensureLoaded();
    expect(identical(failed, retry), isFalse);
    expect(identical(retry, notifier.ensureLoaded()), isTrue);
    await retry;
    expect(notifier._syncs, 2);
    expect(identical(retry, notifier.ensureLoaded()), isTrue);
  });

  test(
    'init channel encodes nondefault lyrics providers and options',
    () async {
      late Map<String, dynamic> arguments;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'initExtensionSystem');
        arguments = Map<String, dynamic>.from(call.arguments as Map);
        return null;
      });
      const providers = [
        'extension:example.provider.primary',
        'extension:example.provider.fallback',
      ];
      const options = <String, dynamic>{
        'include_translation_netease': true,
        'musixmatch_language': 'id',
      };
      final masterKey = base64Encode(List.filled(32, 7));

      await PlatformBridge.initExtensionSystem(
        '/tmp/example-extensions',
        '/tmp/example-extension-data',
        masterKey: masterKey,
        lyricsProviders: providers,
        lyricsFetchOptions: options,
        allowedDirectories: const ['/tmp/example-output'],
      );

      expect(arguments['extensions_dir'], '/tmp/example-extensions');
      expect(arguments['data_dir'], '/tmp/example-extension-data');
      expect(arguments['master_key'], masterKey);
      expect(arguments['allowed_directories'], ['/tmp/example-output']);
      expect(
        jsonDecode(arguments['lyrics_providers_json'] as String),
        providers,
      );
      expect(jsonDecode(arguments['lyrics_options_json'] as String), options);
    },
  );
}
