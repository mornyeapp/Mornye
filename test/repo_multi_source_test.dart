import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _first = 'https://example.com/registry.json';
const _second =
    'https://raw.githubusercontent.com/example/repo/main/registry.json';
const _secondPage = 'https://github.com/example/repo';
const _third = 'https://example.com/third/registry.json';

/// The native repository: ordered sources, each with its own registry, and
/// the installed versions the catalog compares against.
class _FakeRepository {
  bool initialized = false;
  List<String> urls = const [];
  final registries = <String, Map<String, String>>{};
  final failing = <String>{};
  final installed = <String, String>{};
  final calls = <String>[];
  final downloads = <String>[];

  int _compare(String a, String b) {
    final pa = a.split('.').map(int.parse).toList();
    final pb = b.split('.').map(int.parse).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return pa.length.compareTo(pb.length);
  }

  Object? handle(MethodCall call) {
    calls.add(call.method);
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    switch (call.method) {
      case 'initExtensionRepo':
        initialized = true;
        return null;
      case 'setRepoRegistryUrls':
        urls = (args['registry_urls'] as List).cast<String>();
        return null;
      case 'resolveRepoRegistryUrl':
        final url = args['registry_url'] as String;
        return url == _secondPage ? _second : url;
      case 'getRepoCatalog':
        return jsonEncode({
          'sources': [
            for (final url in urls)
              {
                'registry_url': url,
                'name': 'Repository ${urls.indexOf(url) + 1}',
                'extension_count': failing.contains(url)
                    ? 0
                    : registries[url]?.length ?? 0,
                'error': failing.contains(url) ? 'Registry of $url failed' : '',
              },
          ],
          'extensions': [
            for (final url in urls)
              if (!failing.contains(url))
                for (final MapEntry(key: id, value: version)
                    in (registries[url] ?? const <String, String>{}).entries)
                  {
                    'id': id,
                    'name': id,
                    'display_name': 'Example $id',
                    'version': version,
                    'is_installed': installed.containsKey(id),
                    'installed_version': ?installed[id],
                    'has_update':
                        installed.containsKey(id) &&
                        _compare(version, installed[id]!) > 0,
                    'registry_url': url,
                    'registry_name': 'Repository ${urls.indexOf(url) + 1}',
                  },
          ],
        });
      case 'downloadRepoExtension':
        final id = args['extension_id'] as String;
        var url = args['registry_url'] as String? ?? '';
        if (url.isEmpty) {
          url = urls.firstWhere(
            (u) => registries[u]?.containsKey(id) ?? false,
            orElse: () => throw PlatformException(code: 'not_listed'),
          );
        }
        if (!urls.contains(url) || !registries[url]!.containsKey(id)) {
          throw PlatformException(code: 'not_listed');
        }
        downloads.add('$id@$url');
        return '/tmp/$id|${registries[url]![id]}';
    }
    return null;
  }
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.repository);

  final _FakeRepository repository;

  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);

  @override
  Future<void> ensureInitialized() async {}

  bool _apply(String path) {
    final [id, version] = path.split('/').last.split('|');
    repository.installed[id] = version;
    return true;
  }

  @override
  Future<bool> installExtension(String filePath) async => _apply(filePath);

  @override
  Future<bool> upgradeExtension(String filePath, {bool quiet = false}) async =>
      _apply(filePath);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _FakeRepository native;
  late ProviderContainer container;

  setUp(() {
    native = _FakeRepository();
    messenger.setMockMethodCallHandler(backend, (call) async {
      return native.handle(call);
    });
    container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(() => _Extensions(native))],
    );
  });
  tearDown(() {
    container.dispose();
    messenger.setMockMethodCallHandler(backend, null);
  });

  RepoNotifier repo() => container.read(repoProvider.notifier);
  RepoState state() => container.read(repoProvider);
  RepoExtension entry(String id) =>
      state().extensions.singleWhere((e) => e.id == id);
  Future<Map<String, dynamic>> pins() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'store_extension_sources',
    );
    return raw == null ? {} : (jsonDecode(raw) as Map).cast();
  }

  test(
    'the legacy single URL becomes the list and is written at once',
    () async {
      SharedPreferences.setMockInitialValues({'store_registry_url': _first});
      native.registries[_first] = {'ext-a': '1.0.0'};
      await repo().initialize('/cache/store');
      expect(state().registryUrls, [_first]);
      expect(native.urls, [_first]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('store_registry_urls'), jsonEncode([_first]));
      expect(prefs.getString('store_registry_url'), _first);
      expect(state().extensions.single.registryUrl, _first);
    },
  );

  test('an id in two repositories is one entry with both sources', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first, _second]),
    });
    native.registries[_first] = {'ext-a': '1.0.0'};
    native.registries[_second] = {'EXT-A': '2.0.0', 'ext-b': '1.0.0'};
    await repo().initialize('/cache/store');
    expect(state().extensions.map((e) => e.id), ['ext-a', 'ext-b']);
    final merged = entry('ext-a');
    expect(merged.registryUrl, _first);
    expect(merged.version, '1.0.0');
    expect(merged.sources.map((e) => e.registryUrl), [_first, _second]);
    expect(state().hasMultipleRepositories, isTrue);
    expect(state().sources.map((s) => s.extensionCount), [1, 2]);
  });

  test('an installed extension without a pin adopts the first repository '
      'and keeps it when a later repository has a higher version', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first]),
    });
    native.installed['ext-a'] = '1.0.0';
    native.registries[_first] = {'ext-a': '1.0.0'};
    native.registries[_second] = {'ext-a': '3.0.0'};
    await repo().initialize('/cache/store');
    expect(await pins(), {'ext-a': _first});

    final added = await repo().addRegistryUrl(_secondPage);
    expect(added.status, RepoAddStatus.added);
    expect(added.registryUrl, _second);
    expect(state().registryUrls, [_first, _second]);
    expect(entry('ext-a').registryUrl, _first);
    expect(entry('ext-a').hasUpdate, isFalse);
    expect(state().updatesAvailableCount, 0);
    expect(await pins(), {'ext-a': _first});
  });

  test(
    'install and update use the pinned repository and save the pin',
    () async {
      SharedPreferences.setMockInitialValues({
        'store_registry_urls': jsonEncode([_first, _second]),
      });
      native.registries[_first] = {'ext-a': '1.0.0'};
      native.registries[_second] = {'ext-a': '2.0.0'};
      await repo().initialize('/cache/store');

      expect(
        await repo().installExtension(
          'ext-a',
          '/tmp',
          '/ext',
          registryUrl: _second,
        ),
        isTrue,
      );
      expect(native.downloads, ['ext-a@$_second']);
      expect(await pins(), {'ext-a': _second});
      expect(entry('ext-a').registryUrl, _second);
      expect(entry('ext-a').isInstalled, isTrue);

      native.registries[_second] = {'ext-a': '2.1.0'};
      native.registries[_first] = {'ext-a': '9.0.0'};
      await repo().refresh();
      expect(entry('ext-a').hasUpdate, isTrue);
      expect(entry('ext-a').version, '2.1.0');
      expect(state().updatesAvailableCount, 1);
      expect(await repo().updateExtension('ext-a', '/tmp'), isTrue);
      expect(native.downloads.last, 'ext-a@$_second');
      expect(native.installed['ext-a'], '2.1.0');
    },
  );

  test('changing the source moves the pin without reinstalling', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first, _second]),
      'store_extension_sources': jsonEncode({'ext-a': _first}),
    });
    native.installed['ext-a'] = '1.0.0';
    native.registries[_first] = {'ext-a': '1.0.0'};
    native.registries[_second] = {'ext-a': '2.0.0'};
    await repo().initialize('/cache/store');
    expect(entry('ext-a').hasUpdate, isFalse);

    await repo().changeExtensionSource('ext-a', _second);
    expect(native.downloads, isEmpty);
    expect(await pins(), {'ext-a': _second});
    expect(entry('ext-a').registryUrl, _second);
    expect(entry('ext-a').hasUpdate, isTrue);
    expect(state().updatesAvailableCount, 1);
  });

  test('a pinned repository that dropped the id shows no update', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first, _second]),
      'store_extension_sources': jsonEncode({'ext-a': _first}),
    });
    native.installed['ext-a'] = '1.0.0';
    native.registries[_first] = {'ext-b': '1.0.0'};
    native.registries[_second] = {'ext-a': '2.0.0'};
    await repo().initialize('/cache/store');
    final missing = entry('ext-a');
    expect(missing.sourceMissing, isTrue);
    expect(missing.hasUpdate, isFalse);
    expect(missing.registryUrl, _first);
    expect(missing.version, '1.0.0');
    expect(missing.sources.map((e) => e.registryUrl), [_second]);
    expect(state().updatesAvailableCount, 0);
    expect(await pins(), {'ext-a': _first});
  });

  test('removing a repository clears its pins and the next adopts', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first, _second, _third]),
      'store_extension_sources': jsonEncode({
        'ext-a': _second,
        'ext-b': _third,
      }),
    });
    native.installed['ext-a'] = '1.0.0';
    native.installed['ext-b'] = '1.0.0';
    native.registries[_first] = {'ext-c': '1.0.0'};
    native.registries[_second] = {'ext-a': '1.0.0'};
    native.registries[_third] = {'ext-a': '2.0.0', 'ext-b': '1.0.0'};
    await repo().initialize('/cache/store');

    await repo().removeRegistryUrl(_second);
    expect(native.urls, [_first, _third]);
    expect(state().registryUrls, [_first, _third]);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('store_registry_urls'),
      jsonEncode([_first, _third]),
    );
    expect(await pins(), {'ext-b': _third, 'ext-a': _third});
    expect(entry('ext-a').registryUrl, _third);
    expect(entry('ext-a').hasUpdate, isTrue);

    await repo().removeRegistryUrl(_first);
    await repo().removeRegistryUrl(_third);
    expect(state().registryUrls, isEmpty);
    expect(state().extensions, isEmpty);
    expect(prefs.getString('store_registry_url'), isNull);
    expect(await pins(), isEmpty);
  });

  test('adding a repository that is already listed is rejected', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_second]),
    });
    native.registries[_second] = {'ext-a': '1.0.0'};
    await repo().initialize('/cache/store');
    native.calls.clear();
    final result = await repo().addRegistryUrl(_secondPage);
    expect(result.status, RepoAddStatus.duplicate);
    expect(native.calls, ['resolveRepoRegistryUrl']);
    expect(state().registryUrls, [_second]);
  });

  test('adding a repository that fails puts the list back', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first]),
    });
    native.registries[_first] = {'ext-a': '1.0.0'};
    native.failing.add(_third);
    await repo().initialize('/cache/store');
    final result = await repo().addRegistryUrl(_third);
    expect(result.status, RepoAddStatus.failed);
    expect(result.error, contains('Registry of $_third failed'));
    expect(native.urls, [_first]);
    expect(state().registryUrls, [_first]);
    expect(state().isAddingRepository, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('store_registry_urls'), jsonEncode([_first]));
  });

  test('one failed repository shows on its row; all failed is the store '
      'error', () async {
    SharedPreferences.setMockInitialValues({
      'store_registry_urls': jsonEncode([_first, _second]),
    });
    native.registries[_first] = {'ext-a': '1.0.0'};
    native.registries[_second] = {'ext-b': '1.0.0'};
    native.failing.add(_second);
    await repo().initialize('/cache/store');
    expect(state().error, isNull);
    expect(state().sourceFor(_second)?.hasError, isTrue);
    expect(state().sourceFor(_first)?.hasError, isFalse);
    expect(state().extensions.map((e) => e.id), ['ext-a']);

    native.failing.add(_first);
    await repo().refresh(forceRefresh: true);
    expect(state().error, contains('Registry of $_first failed'));
    expect(state().error, contains('Registry of $_second failed'));
    expect(state().extensions, isEmpty);
  });

  test('repositories with the same name are told apart', () {
    const same = 'https://raw.githubusercontent.com/example/repo/main/';
    final names = distinctRepoSourceNames(const [
      RepoSource(registryUrl: '${same}registry.json', name: 'example/repo'),
      RepoSource(registryUrl: '${same}other.json', name: 'example/repo'),
      RepoSource(registryUrl: 'https://a.example/x/r.json', name: 'Store'),
      RepoSource(registryUrl: 'https://b.example/y/r.json', name: 'Store'),
      RepoSource(registryUrl: _first, name: 'example.com'),
    ]).map((s) => s.name);
    expect(names, [
      'example/repo (registry.json)',
      'example/repo (other.json)',
      'https://a.example/x/r.json',
      'https://b.example/y/r.json',
      'example.com',
    ]);
  });
}
