import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/logger.dart';

class _Preferences implements SharedPreferences {
  final writes = <Map<String, dynamic>>[];
  final lists = <String, List<String>>{};
  final _started = <int, Completer<void>>{};
  final _released = <int, Completer<bool>>{};

  Future<void> whenStarted(int index) =>
      (_started[index] ??= Completer<void>()).future;

  Completer<bool> release(int index) => _released[index] ??= Completer<bool>();

  @override
  List<String>? getStringList(String key) => lists[key];

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    lists[key] = List.of(value);
    return true;
  }

  @override
  Future<bool> setString(String key, String value) {
    expect(key, 'app_settings');
    final index = writes.length;
    writes.add(jsonDecode(value) as Map<String, dynamic>);
    (_started[index] ??= Completer<void>()).complete();
    return release(index).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends SettingsNotifier {
  _Settings(_Preferences preferences)
    : super(preferences: () async => preferences);

  _Settings.withLoader(Future<SharedPreferences> Function() load)
    : super(preferences: load);

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  test(
    'changing the app folder durably remembers the old root for moved files',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings.withLoader(() async => preferences),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.useAppFolderStorage('/storage/emulated/0/xxx');
      await notifier.useAppFolderStorage('/storage/emulated/0/yyy');
      expect(preferences.getStringList('download_previous_directories_v1'), [
        '/storage/emulated/0/xxx',
      ]);
      expect(
        (jsonDecode(preferences.getString('app_settings')!)
            as Map)['downloadDirectory'],
        '/storage/emulated/0/yyy',
      );
    },
  );

  test(
    'setup completes only after folder and completion flag are durable',
    () async {
      final preferences = _Preferences();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(preferences)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      notifier.setStorageMode('saf');
      await preferences.whenStarted(0);
      notifier.setDownloadTreeUri(
        'content://test/tree/music',
        displayName: 'Music',
      );
      final finish = notifier.setFirstLaunchComplete();
      expect(container.read(settingsProvider).isFirstLaunch, isTrue);
      preferences.release(0).complete(true);
      await preferences.whenStarted(1);
      preferences.release(1).complete(true);
      await preferences.whenStarted(2);
      expect(preferences.writes.last['isFirstLaunch'], isFalse);
      expect(
        preferences.writes.last['downloadTreeUri'],
        'content://test/tree/music',
      );
      expect(container.read(settingsProvider).isFirstLaunch, isTrue);
      preferences.release(2).complete(true);
      await finish;
      expect(container.read(settingsProvider).isFirstLaunch, isFalse);
    },
  );

  test('failed setup persistence keeps the user in setup', () async {
    final preferences = _Preferences();
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => _Settings(preferences))],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    final finish = notifier.setFirstLaunchComplete();
    final failed = expectLater(finish, throwsStateError);
    await preferences.whenStarted(0);
    preferences.release(0).complete(false);
    await failed;
    expect(container.read(settingsProvider).isFirstLaunch, isTrue);
  });

  test(
    'settings changed during setup completion cannot overwrite its flag',
    () async {
      final preferences = _Preferences();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(preferences)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      final finish = notifier.setFirstLaunchComplete();
      await preferences.whenStarted(0);
      notifier.setDownloadTreeUri(
        'content://test/tree/latest',
        displayName: 'Latest',
      );
      preferences.release(0).complete(true);
      await preferences.whenStarted(1);
      expect(container.read(settingsProvider).isFirstLaunch, isTrue);
      expect(preferences.writes.last['isFirstLaunch'], isFalse);
      expect(
        preferences.writes.last['downloadTreeUri'],
        'content://test/tree/latest',
      );
      preferences.release(1).complete(true);
      await finish;
      expect(container.read(settingsProvider).isFirstLaunch, isFalse);
      expect(
        container.read(settingsProvider).downloadTreeUri,
        'content://test/tree/latest',
      );
    },
  );

  test('queued save callers await the complete coalescing drain', () async {
    final preferences = _Preferences();
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => _Settings(preferences))],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    final first = notifier.useAppFolderStorage('/output/first');
    await preferences.whenStarted(0);
    final second = notifier.setNetworkDownloadFolder('remote:first', 'First');
    final third = notifier.setNetworkDownloadFolder('remote:latest', 'Latest');
    var firstCompleted = false;
    var secondCompleted = false;
    var thirdCompleted = false;
    unawaited(first.then((_) => firstCompleted = true));
    unawaited(second.then((_) => secondCompleted = true));
    unawaited(third.then((_) => thirdCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(
      [firstCompleted, secondCompleted, thirdCompleted],
      [false, false, false],
    );

    preferences.release(0).complete(true);
    await preferences.whenStarted(1);
    expect(preferences.writes.length, 2);
    expect(preferences.writes.last['networkDownloadFolder'], 'remote:latest');
    expect(preferences.writes.last['networkDownloadLabel'], 'Latest');
    expect(preferences.writes.last['downloadDirectory'], '/output/first');
    expect(
      [firstCompleted, secondCompleted, thirdCompleted],
      [false, false, false],
    );
    preferences.release(1).complete(true);
    await Future.wait([first, second, third]);
    expect(
      [firstCompleted, secondCompleted, thirdCompleted],
      [true, true, true],
    );
    expect(preferences.writes.length, 2);
  });

  test(
    'failed active save keeps logged-error API and releases its owner',
    () async {
      final preferences = _Preferences();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(preferences)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      final first = notifier.useAppFolderStorage('/output/first');
      await preferences.whenStarted(0);
      final queued = notifier.setNetworkDownloadFolder(
        'remote:queued',
        'Queued',
      );
      preferences.release(0).completeError(StateError('settings_save_failed'));
      await Future.wait([first, queued]);
      expect(
        LogBuffer().entries.any(
          (entry) =>
              entry.tag == 'SettingsProvider' &&
              entry.message.contains('settings_save_failed'),
        ),
        isTrue,
      );

      final retry = notifier.useAppFolderStorage('/output/retry');
      await preferences.whenStarted(1);
      expect(preferences.writes.last['downloadDirectory'], '/output/retry');
      expect(preferences.writes.last['networkDownloadFolder'], 'remote:queued');
      preferences.release(1).complete(true);
      await retry;
    },
  );

  test(
    'synchronous preference failure does not retain a finished drain',
    () async {
      final preferences = _Preferences();
      var loads = 0;
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings.withLoader(() {
              if (loads++ == 0) throw StateError('settings_preferences_failed');
              return Future.value(preferences);
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.useAppFolderStorage('/output/first');
      expect(preferences.writes, isEmpty);

      final retry = notifier.useAppFolderStorage('/output/retry');
      await preferences.whenStarted(0);
      expect(loads, 2);
      expect(preferences.writes.single['downloadDirectory'], '/output/retry');
      preferences.release(0).complete(true);
      await retry;
    },
  );
}
