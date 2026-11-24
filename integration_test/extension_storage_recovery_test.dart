import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/secure_storage_options.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'unreadable extension settings do not block the native repository',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = await support.createTemp('extension-storage-test-');
      final sources = Directory('${root.path}/sources');
      final data = Directory('${root.path}/data');
      final key = base64Encode(List.filled(32, 1));
      final wrongKey = base64Encode(List.filled(32, 2));
      const ids = ['example.first', 'example.second'];
      final container = ProviderContainer();
      addTearDown(() async {
        container.dispose();
        await PlatformBridge.cleanupExtensions();
        await root.delete(recursive: true);
      });
      for (final id in ids) {
        final source = Directory('${sources.path}/$id');
        await source.create(recursive: true);
        await File('${source.path}/manifest.json').writeAsString(
          jsonEncode({
            'name': id,
            'displayName': 'Example',
            'version': '1.0.0',
            'description': 'Storage recovery fixture',
            'type': ['metadata_provider'],
          }),
        );
        await File(
          '${source.path}/index.js',
        ).writeAsString('registerExtension({});');
      }
      await data.create(recursive: true);
      await PlatformBridge.initExtensionSystem(
        sources.path,
        data.path,
        masterKey: key,
        lyricsProviders: const [],
        lyricsFetchOptions: const {},
      );
      await PlatformBridge.loadExtensionsFromDir(sources.path);
      final snapshots = <String, List<int>>{};
      for (final id in ids) {
        await PlatformBridge.setExtensionSettings(id, {'region': 'example'});
        snapshots[id] = await File(
          '${data.path}/$id/settings.enc',
        ).readAsBytes();
      }
      await PlatformBridge.cleanupExtensions();

      await container
          .read(extensionProvider.notifier)
          .initialize(sources.path, data.path, masterKey: wrongKey);
      final state = container.read(extensionProvider);
      expect(state.isInitialized, isTrue);
      expect(state.extensions.map((extension) => extension.id), ids);
      for (final extension in state.extensions) {
        expect(extension.enabled, isFalse);
        expect(extension.status, 'error');
        expect(
          extension.errorMessage,
          contains('message authentication failed'),
        );
      }
      await container
          .read(repoProvider.notifier)
          .initialize('${root.path}/cache');
      expect(container.read(repoProvider).isInitialized, isTrue);
      await PlatformBridge.setRepoRegistryUrls([
        'https://example.com/registry.json',
      ]);
      expect(
        await PlatformBridge.resolveRepoRegistryUrl(
          'https://example.com/registry.json',
        ),
        'https://example.com/registry.json',
      );
      for (final id in ids) {
        expect(
          await File('${data.path}/$id/settings.enc').readAsBytes(),
          snapshots[id],
        );
      }
      await PlatformBridge.cleanupExtensions();
      await PlatformBridge.initExtensionSystem(
        sources.path,
        data.path,
        masterKey: key,
        lyricsProviders: const [],
        lyricsFetchOptions: const {},
      );
      await PlatformBridge.loadExtensionsFromDir(sources.path);
      for (final id in ids) {
        expect(
          (await PlatformBridge.getExtensionSettings(id))['region'],
          'example',
        );
      }
      binding.reportData = {
        'unreadable_extensions_visible': 2,
        'repository_initialized': true,
        'encrypted_files_preserved': true,
        'correct_key_reopens_settings': true,
      };
    },
  );

  testWidgets(
    'safe secure storage options read a key written with old defaults',
    (tester) async {
      const oldStorage = FlutterSecureStorage();
      const newStorage = FlutterSecureStorage(
        aOptions: secureStorageAndroidOptions,
      );
      const name = 'example_extension_storage_recovery_test';
      final value = base64Encode(List.filled(32, 3));
      addTearDown(() => newStorage.delete(key: name));
      await oldStorage.write(key: name, value: value);
      expect(await newStorage.read(key: name), value);
      binding.reportData = {
        ...?binding.reportData,
        'secure_storage_options_preserve_key': true,
      };
    },
  );
}
