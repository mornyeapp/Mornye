import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _registry = 'https://example.test/extensions/registry.json';
const _second = 'https://example.test/second/registry.json';

Map<String, dynamic> _manifest(String id, {bool enabled = true}) => {
  'id': id,
  'name': id,
  'display_name': 'Example extension',
  'version': '1.0.0',
  'enabled': enabled,
  'has_download_provider': true,
  'has_metadata_provider': true,
  'settings': [
    {'key': 'api_key', 'type': 'string', 'secret': true},
  ],
};

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(defaultService: 'example-one');
}

class _ReadyExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

class _RepositoryTransport implements NativeBackendTransport {
  late NativeMessageListener _listener;
  bool initialized = false;
  String cacheDir = '';
  List<String> registryUrls = const [];
  final installed = <String, Map<String, dynamic>>{};
  final settings = <String, Map<String, dynamic>>{};
  final downloads = <String>[];

  /// The registry URL each download asked for, by extension id.
  final downloadSources = <String, String>{};
  final unavailable = <String>{};

  @override
  void init(Uint8List configJson, NativeMessageListener listener) {
    _listener = listener;
  }

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    scheduleMicrotask(() {
      try {
        final args = ((jsonDecode(utf8.decode(argsJson)) as Map?) ?? const {})
            .cast<String, dynamic>();
        final result = _invoke(method, args);
        _listener(
          id,
          NativeMessageKind.result,
          utf8.encode(jsonEncode(result)),
        );
      } catch (error) {
        _listener(
          id,
          NativeMessageKind.error,
          utf8.encode(jsonEncode({'code': 'repository', 'message': '$error'})),
        );
      }
    });
  }

  Object? _invoke(String method, Map<String, dynamic> args) {
    final id = args['extension_id'] as String? ?? '';
    switch (method) {
      case 'initExtensionRepo':
        initialized = true;
        cacheDir = args['cache_dir'] as String;
      case 'setRepoRegistryUrls':
        if (!initialized) throw StateError('Repository is not initialized');
        registryUrls = (args['registry_urls'] as List).cast<String>();
      case 'getRepoCatalog':
        if (!initialized) throw StateError('Repository is not initialized');
        return {
          'sources': [
            for (final url in registryUrls)
              {'registry_url': url, 'name': url, 'error': ''},
          ],
          'extensions': const <Map<String, dynamic>>[],
        };
      case 'getInstalledExtensions':
        return installed.values.toList();
      case 'getExtensionSettings':
        return settings[id] ?? const <String, dynamic>{};
      case 'setExtensionSettings':
        settings[id] = (jsonDecode(args['settings'] as String) as Map)
            .cast<String, dynamic>();
      case 'setExtensionEnabled':
        installed[id]!['enabled'] = args['enabled'];
      case 'downloadRepoExtension':
        if (registryUrls.isEmpty) throw StateError('No registry configured');
        final source = args['registry_url'] as String? ?? '';
        if (source.isNotEmpty && !registryUrls.contains(source)) {
          throw StateError('Registry not configured');
        }
        if (unavailable.contains(id)) throw StateError('Extension not in repo');
        downloads.add(id);
        downloadSources[id] = source;
        return '${args['dest_dir']}/$id.sflx';
      case 'loadExtensionFromPath':
        final path = args['file_path'] as String;
        final id = path.split('/').last.replaceFirst('.sflx', '');
        return installed[id] = _manifest(id);
    }
    return null;
  }

  @override
  void subscribe(int kind) {}

  @override
  void unsubscribe(int kind) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late _RepositoryTransport repository;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'store_registry_url': _registry});
    temporary = await Directory.systemTemp.createTemp('extension-backup-');
    messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
    debugDesktopPlatformOverride = true;
    repository = _RepositoryTransport();
    RustFfiBackend.debugShared = RustFfiBackend(
      openTransport: () => repository,
      loadConfig: () async => DesktopBackendConfig(
        appSupportDir: temporary.path,
        documentsDir: temporary.path,
        tempDir: temporary.path,
      ),
    );
    container = ProviderContainer(
      overrides: [
        extensionProvider.overrideWith(_ReadyExtensions.new),
        settingsProvider.overrideWith(_Settings.new),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    RustFfiBackend.debugShared = null;
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(paths, null);
    await temporary.delete(recursive: true);
  });

  ExtensionNotifier notifier() => container.read(extensionProvider.notifier);

  test('export keeps the saved repository before Repo is opened', () async {
    repository.installed['example-one'] = _manifest('example-one');
    final data = await notifier().exportBackup(includeSecrets: false);
    expect(data['registry_urls'], [_registry]);
    expect(data['registry_url'], _registry);
    expect(((data['items'] as List).single as Map)['id'], 'example-one');
    expect(repository.downloads, isEmpty);
  });

  test('export lists every repository and each extension pin', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_registry, _second]),
      'store_extension_sources': jsonEncode({'example-one': _second}),
    });
    repository.installed['example-one'] = _manifest('example-one');
    repository.installed['example-two'] = _manifest('example-two');
    final data = await notifier().exportBackup(includeSecrets: false);
    expect(data['registry_urls'], [_registry, _second]);
    expect(data['registry_url'], _registry);
    final items = {
      for (final item in (data['items'] as List).cast<Map<String, dynamic>>())
        item['id']: item,
    };
    expect(items['example-one']!['registry_url'], _second);
    expect(items['example-two']!.containsKey('registry_url'), isFalse);
  });

  for (final includeSecrets in [false, true]) {
    test(
      'repository fallback preserves secret filtering ($includeSecrets)',
      () async {
        repository.installed['example-one'] = _manifest('example-one');
        repository.settings['example-one'] = {
          'region': 'gb',
          'api_key': 'example-secret',
        };
        final data = await notifier().exportBackup(
          includeSecrets: includeSecrets,
        );
        final item = (data['items'] as List).single as Map;
        expect(data['registry_url'], _registry);
        expect(item['settings'], {
          'region': 'gb',
          if (includeSecrets) 'api_key': 'example-secret',
        });
        expect(item['secrets_omitted'], includeSecrets ? null : true);
      },
    );
  }

  for (final backupUrl in <String?>[null, '', '  ']) {
    test('older backup reuses saved repository (URL=$backupUrl)', () async {
      final result = await notifier().restoreFromBackup({
        'registry_url': ?backupUrl,
        'items': [
          {
            'id': 'example-one',
            'enabled': false,
            'settings': {'region': 'jp'},
          },
        ],
      });
      expect(result.installed, 1);
      expect(result.failedIds, isEmpty);
      expect(result.failed, 0);
      expect(repository.registryUrls, [_registry]);
      expect(repository.downloads, ['example-one']);
      expect(repository.downloadSources['example-one'], '');
      expect(repository.installed['example-one']!['enabled'], isFalse);
      expect(repository.settings['example-one'], {'region': 'jp'});
    });
  }

  test('new backup restores on a fresh device without opening Repo', () async {
    repository.installed['example-one'] = _manifest('example-one');
    repository.settings['example-one'] = {'region': 'gb'};
    final backup = await notifier().exportBackup(includeSecrets: false);
    repository.installed.clear();
    repository.settings.clear();
    await (await SharedPreferences.getInstance()).clear();

    final result = await notifier().restoreFromBackup(backup);
    expect(result.installed, 1);
    expect(result.failed, 0);
    expect(repository.registryUrls, [_registry]);
    expect(repository.settings['example-one'], {'region': 'gb'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('store_registry_urls'), jsonEncode([_registry]));
    expect(prefs.getString('store_registry_url'), _registry);
    // The store keeps its normal cache directory, not a restore temp one.
    expect(repository.cacheDir, temporary.path);
  });

  test('backup repositories are added after the device ones', () async {
    const backupUrl = 'https://example.test/backup/registry.json';
    final result = await notifier().restoreFromBackup({
      'registry_url': backupUrl,
      'items': [
        {'id': 'example-one'},
      ],
    });
    expect(result.installed, 1);
    expect(result.failed, 0);
    expect(repository.registryUrls, [_registry, backupUrl]);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('store_registry_urls'),
      jsonEncode([_registry, backupUrl]),
    );
    expect(prefs.getString('store_registry_url'), _registry);
  });

  test('restore installs from the pinned repository and keeps pins', () async {
    repository.installed['example-two'] = _manifest('example-two');
    final result = await notifier().restoreFromBackup({
      'registry_urls': [_registry, _second],
      'registry_url': _registry,
      'items': [
        {'id': 'example-one', 'registry_url': _second},
        {'id': 'example-two', 'registry_url': _second},
        {
          'id': 'example-three',
          'registry_url': 'https://example.test/gone/registry.json',
        },
      ],
    });
    expect(result.installed, 2);
    expect(result.alreadyPresent, 1);
    expect(repository.registryUrls, [_registry, _second]);
    expect(repository.downloadSources, {
      'example-one': _second,
      // A pin to a repository that is not configured installs from the
      // first repository that lists it.
      'example-three': '',
    });
    final pins =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(
                'store_extension_sources',
              )!,
            )
            as Map<String, dynamic>;
    expect(pins['example-one'], _second);
    expect(pins['example-two'], _second);
    expect(pins.containsKey('example-three'), isFalse);
  });

  test(
    'installed extensions keep current secrets when omitted in backup',
    () async {
      repository.installed['example-one'] = _manifest('example-one');
      repository.settings['example-one'] = {
        'api_key': 'example-existing-secret',
        'region': 'gb',
      };
      final result = await notifier().restoreFromBackup({
        'items': [
          {
            'id': 'example-one',
            'settings': {'region': 'jp'},
          },
        ],
      });
      expect(result.alreadyPresent, 1);
      expect(result.installed, 0);
      expect(result.failed, 0);
      expect(repository.downloads, isEmpty);
      expect(repository.settings['example-one'], {
        'api_key': 'example-existing-secret',
        'region': 'jp',
      });
    },
  );

  test(
    'real download failures still report only the unavailable extension',
    () async {
      repository.unavailable.add('example-missing');
      final result = await notifier().restoreFromBackup({
        'registry_url': _registry,
        'items': [
          {'id': 'example-one'},
          {'id': 'example-missing'},
        ],
      });
      expect(result.installed, 1);
      expect(result.failed, 1);
      expect(result.failedIds, ['example-missing']);
    },
  );

  test(
    'backup without any repository does not invent a download source',
    () async {
      await (await SharedPreferences.getInstance()).clear();
      final result = await notifier().restoreFromBackup({
        'items': [
          {'id': 'example-one'},
        ],
      });
      expect(result.installed, 0);
      expect(result.failedIds, ['example-one']);
      expect(repository.downloads, isEmpty);
    },
  );
}
