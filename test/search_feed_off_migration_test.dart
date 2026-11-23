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

  Future<String?> feedAfter({
    required int? migration,
    required String? feed,
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(
        const AppSettings()
            .copyWith(isFirstLaunch: false, homeFeedProvider: feed)
            .toJson(),
      ),
      'settings_migration_version': ?migration,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = container.read(settingsProvider.notifier);
    await settings.ensureLoaded();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt('settings_migration_version'), 17);
    // What is stored must agree with what the app holds.
    final stored =
        jsonDecode(preferences.getString('app_settings')!)
            as Map<String, dynamic>;
    expect(
      AppSettings.fromJson(stored).homeFeedProvider,
      container.read(settingsProvider).homeFeedProvider,
    );
    return container.read(settingsProvider).homeFeedProvider;
  }

  test('a feed turned off while it filled Home comes back on Search', () async {
    for (final migration in [15, 16]) {
      expect(
        await feedAfter(
          migration: migration,
          feed: AppSettings.homeFeedProviderOff,
        ),
        isNull,
        reason: 'from migration $migration',
      );
    }
  });

  test('a chosen extension stays chosen', () async {
    expect(
      await feedAfter(migration: 15, feed: 'example-provider'),
      'example-provider',
    );
  });

  test('a feed turned off after the move stays off', () async {
    expect(
      await feedAfter(migration: 17, feed: AppSettings.homeFeedProviderOff),
      AppSettings.homeFeedProviderOff,
    );
  });

  test('a new install keeps what it chose', () async {
    expect(
      await feedAfter(migration: null, feed: AppSettings.homeFeedProviderOff),
      AppSettings.homeFeedProviderOff,
    );
  });
}
