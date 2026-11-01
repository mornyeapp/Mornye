import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';

class _SettingsWithSync extends SettingsNotifier {
  final syncedSettings = <AppSettings>[];

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    syncedSettings.add(settings ?? state);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const retiredKey = 'spotify_client_secret';
  const masterKey = 'extension_storage_master_key_v2';
  const savedSettings = AppSettings(
    isFirstLaunch: false,
    downloadDirectory: '/music/kept',
    audioQuality: 'LOSSLESS',
    lyricsProviders: ['extension:example.provider'],
    downloadFallbackExtensionIds: ['example.provider'],
    allowLocalNetwork: true,
  );
  final savedJson = jsonEncode(savedSettings.toJson());
  late Map<String, String> secrets;
  late List<MethodCall> calls;
  String? failingMethod;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'app_settings': savedJson,
      'settings_migration_version': 15,
    });
    secrets = {
      retiredKey: 'retired-secret',
      masterKey: base64Encode(List.filled(32, 7)),
      'example_network_password': 'example-password',
    };
    calls = [];
    failingMethod = null;
    messenger.setMockMethodCallHandler(secure, (call) async {
      calls.add(call);
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect((args['options'] as Map)['resetOnError'], 'false');
      if (call.method == failingMethod) {
        throw PlatformException(
          code: 'Exception encountered',
          message:
              'Migration failed after algorithm change '
              '(Invalid key, key type incompatible with cipher). '
              'Enable resetOnError=true or call deleteAll().',
          details:
              'Caused by: android.security.keystore.'
              'KeyPermanentlyInvalidatedException: Key permanently invalidated',
        );
      }
      switch (call.method) {
        case 'read':
          return secrets[args['key']];
        case 'delete':
          expect(args['key'], retiredKey);
          secrets.remove(args['key']);
          return null;
        default:
          fail('Unexpected secure storage operation: ${call.method}');
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(secure, null));

  Future<void> expectLoaded(_SettingsWithSync notifier) async {
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider);
    final loading = notifier.ensureLoaded();
    await loading;
    expect(identical(notifier.ensureLoaded(), loading), isTrue);
    final loaded = container.read(settingsProvider);
    expect(loaded.isFirstLaunch, isFalse);
    expect(loaded.downloadDirectory, savedSettings.downloadDirectory);
    expect(loaded.audioQuality, savedSettings.audioQuality);
    expect(loaded.lyricsProviders, savedSettings.lyricsProviders);
    expect(loaded.allowLocalNetwork, isTrue);
    expect(notifier.syncedSettings, [loaded]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_settings'), savedJson);
    expect(prefs.containsKey('app_settings_corrupt_backup'), isFalse);
  }

  for (final method in ['read', 'delete']) {
    test(
      'invalid keystore during retired credential $method does not block settings',
      () async {
        failingMethod = method;
        final before = Map<String, String>.from(secrets);
        await expectLoaded(_SettingsWithSync());
        expect(secrets, before);
        expect(calls.map((call) => call.method), [
          'read',
          if (method == 'delete') 'delete',
        ]);
      },
    );
  }

  test('healthy cleanup removes only the retired credential', () async {
    final before = Map<String, String>.from(secrets)..remove(retiredKey);
    await expectLoaded(_SettingsWithSync());
    expect(secrets, before);
    expect(calls.map((call) => call.method), ['read', 'delete']);
  });

  test('missing retired credential does not mutate secure storage', () async {
    secrets.remove(retiredKey);
    final before = Map<String, String>.from(secrets);
    await expectLoaded(_SettingsWithSync());
    expect(secrets, before);
    expect(calls.map((call) => call.method), ['read']);
  });
}
