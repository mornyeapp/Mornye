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

  test('the removed rebrand tour leaves no flag behind', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(const AppSettings().toJson()),
      'settings_migration_version': 14,
      'upgrade_intro_mornye_seen': true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ensureLoaded();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('upgrade_intro_mornye_seen'), isFalse);
    expect(preferences.getInt('settings_migration_version'), 17);
  });
}
