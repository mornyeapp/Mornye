import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> load(Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues({
      if (stored.isNotEmpty) 'app_settings': jsonEncode(stored),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ensureLoaded();
    return container;
  }

  Future<String?> savedSort() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_settings');
    if (raw == null) return null;
    return AppSettings.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    ).librarySortMode;
  }

  test('the Library sort defaults to Latest', () async {
    final container = await load(const {});
    expect(container.read(settingsProvider).librarySortMode, 'latest');
    expect(const AppSettings().librarySortMode, 'latest');
    expect(AppSettings.librarySortModes.first, 'latest');
  });

  test('a chosen Library sort is saved and loaded again', () async {
    final first = await load(const {});
    first.read(settingsProvider.notifier).setLibrarySortMode('a-z');
    expect(first.read(settingsProvider).librarySortMode, 'a-z');
    await pumpEventQueue();
    expect(await savedSort(), 'a-z');

    final restarted = await load(const {'librarySortMode': 'a-z'});
    expect(restarted.read(settingsProvider).librarySortMode, 'a-z');
  });

  test('every offered sort is kept as chosen', () async {
    final container = await load(const {});
    for (final mode in AppSettings.librarySortModes) {
      container.read(settingsProvider.notifier).setLibrarySortMode(mode);
      expect(container.read(settingsProvider).librarySortMode, mode);
    }
  });

  test('an unknown or removed sort falls back to Latest', () async {
    final loaded = await load(const {'librarySortMode': 'by-mood'});
    expect(loaded.read(settingsProvider).librarySortMode, 'latest');

    loaded.read(settingsProvider.notifier).setLibrarySortMode('genre-asc');
    loaded.read(settingsProvider.notifier).setLibrarySortMode('');
    expect(loaded.read(settingsProvider).librarySortMode, 'latest');
  });
}
