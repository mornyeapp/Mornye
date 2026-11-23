import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    messenger.setMockMethodCallHandler(secure, (call) async => null);
  });
  tearDownAll(() => messenger.setMockMethodCallHandler(secure, null));

  Future<SharedPreferences> load({
    required int? migration,
    required bool finishedSetup,
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(
        const AppSettings().copyWith(isFirstLaunch: !finishedSetup).toJson(),
      ),
      'settings_migration_version': ?migration,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ensureLoaded();
    return SharedPreferences.getInstance();
  }

  test('an install that ran an earlier build is owed the hint', () async {
    final preferences = await load(migration: 15, finishedSetup: true);
    expect(preferences.getBool(searchMovedHintOwedKey), isTrue);
    expect(preferences.getInt('settings_migration_version'), 17);
  });

  test('a new install on its second launch is not', () async {
    final preferences = await load(migration: null, finishedSetup: true);
    expect(preferences.containsKey(searchMovedHintOwedKey), isFalse);
    expect(preferences.getInt('settings_migration_version'), 17);
  });

  test('nor is an earlier build that never finished setup', () async {
    final preferences = await load(migration: 15, finishedSetup: false);
    expect(preferences.containsKey(searchMovedHintOwedKey), isFalse);
  });

  test('the note is left once, not on every launch', () async {
    final preferences = await load(migration: 16, finishedSetup: true);
    expect(preferences.containsKey(searchMovedHintOwedKey), isFalse);
  });
}
