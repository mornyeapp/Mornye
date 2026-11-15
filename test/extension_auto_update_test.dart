import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_auto_update_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _registryUrl = 'https://example.com/registry.json';

RepoExtension _store(
  String id, {
  String version = '2.0.0',
  bool hasUpdate = true,
  String? minAppVersion,
}) => RepoExtension(
  id: id,
  name: id,
  displayName: 'Example $id',
  version: version,
  description: '',
  category: RepoCategory.metadata,
  updatedAt: '2026-01-01',
  minAppVersion: minAppVersion,
  isInstalled: true,
  hasUpdate: hasUpdate,
);

Extension _installed(String id, {String version = '1.0.0', bool on = true}) =>
    Extension(
      id: id,
      name: id,
      displayName: 'Example $id',
      version: version,
      description: '',
      enabled: on,
      status: 'loaded',
    );

class _Settings extends SettingsNotifier {
  _Settings(this._initial);

  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  void setAutoUpdate(bool enabled) =>
      state = state.copyWith(autoUpdateExtensions: enabled);
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this._initial);

  final List<Extension> _initial;

  @override
  ExtensionState build() =>
      ExtensionState(isInitialized: true, extensions: _initial);

  void setVersion(String id, String version) => state = state.copyWith(
    extensions: [
      for (final ext in state.extensions)
        ext.id == id ? ext.copyWith(version: version) : ext,
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState();

  void setBusy(bool busy) => state = busy
      ? state.copyWith(
          isProcessing: true,
          items: [
            DownloadItem(
              id: 'queued',
              track: const Track(
                id: 'track',
                name: 'Song',
                artistName: 'Artist',
                albumName: 'Album',
                duration: 1000,
              ),
              service: 'example-provider',
              createdAt: DateTime(2026),
            ),
          ],
        )
      : const DownloadQueueState();
}

class _Repo extends RepoNotifier {
  _Repo(this._store, this._extensions);

  final List<RepoExtension> _store;
  final _Extensions Function() _extensions;
  final calls = <String>[];
  final failing = <String>{};

  @override
  RepoState build() => const RepoState();

  @override
  Future<void> initializeToDefaultPaths() async {
    calls.add('initialize');
    state = state.copyWith(
      isInitialized: true,
      registryUrls: const [_registryUrl],
      extensions: _store,
    );
  }

  @override
  Future<void> refresh({bool forceRefresh = false}) async {
    calls.add('refresh');
  }

  @override
  Future<bool> updateExtensionToDefaultPaths(
    String extensionId, {
    bool quiet = false,
  }) async {
    calls.add('update:$extensionId:$quiet');
    if (failing.contains(extensionId)) return false;
    final target = state.extensions.firstWhere((e) => e.id == extensionId);
    _extensions().setVersion(extensionId, target.version);
    state = state.copyWith(
      extensions: [
        for (final ext in state.extensions)
          ext.id == extensionId ? _storeCopy(ext, hasUpdate: false) : ext,
      ],
    );
    return true;
  }

  List<String> get _updates =>
      calls.where((call) => call.startsWith('update:')).toList();
}

RepoExtension _storeCopy(RepoExtension ext, {required bool hasUpdate}) =>
    _store(
      ext.id,
      version: ext.version,
      hasUpdate: hasUpdate,
      minAppVersion: ext.minAppVersion,
    );

class _Harness {
  _Harness({
    List<RepoExtension>? store,
    List<Extension>? installed,
    AppSettings settings = const AppSettings(),
  }) {
    extensions = _Extensions(
      installed ?? [_installed('ext-a'), _installed('ext-b')],
    );
    repo = _Repo(store ?? [_store('ext-a'), _store('ext-b')], () => extensions);
    this.settings = _Settings(settings);
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => this.settings),
        extensionProvider.overrideWith(() => extensions),
        downloadQueueProvider.overrideWith(() => queue),
        repoProvider.overrideWith(() => repo),
        extensionAutoUpdateProvider.overrideWith(
          () => ExtensionAutoUpdateNotifier(clock: () => now),
        ),
      ],
    );
    container.read(extensionAutoUpdateProvider);
  }

  late final _Extensions extensions;
  late final _Repo repo;
  late final _Settings settings;
  final queue = _Queue();
  late final ProviderContainer container;
  DateTime now = DateTime(2026, 11, 8, 9);

  ExtensionAutoUpdateNotifier get notifier =>
      container.read(extensionAutoUpdateProvider.notifier);

  ExtensionAutoUpdateNotice? get notice =>
      container.read(extensionAutoUpdateProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'store_registry_url': _registryUrl,
    });
  });

  group('selectExtensionAutoUpdates', () {
    test('picks installed, enabled extensions with a compatible update', () {
      final picked = selectExtensionAutoUpdates(
        storeExtensions: [
          _store('ext-ready'),
          _store('ext-disabled'),
          _store('ext-newer-app', minAppVersion: '999.0.0'),
          _store('ext-current', version: '1.0.0', hasUpdate: false),
          _store('ext-same-version', version: '1.0.0'),
          _store('ext-missing'),
          _store('ext-failed'),
        ],
        installed: [
          _installed('ext-ready'),
          _installed('ext-disabled', on: false),
          _installed('ext-newer-app'),
          _installed('ext-current'),
          _installed('ext-same-version'),
          _installed('ext-failed'),
        ],
        attemptedTargets: {'ext-failed@2.0.0'},
      );
      expect(picked.map((e) => e.id), ['ext-ready']);
    });

    test('a failed target is tried again once a newer version ships', () {
      final picked = selectExtensionAutoUpdates(
        storeExtensions: [_store('ext-failed', version: '2.1.0')],
        installed: [_installed('ext-failed')],
        attemptedTargets: {'ext-failed@2.0.0'},
      );
      expect(picked.map(extensionUpdateTarget), ['ext-failed@2.1.0']);
    });

    test('updates come only from the pinned repository', () {
      const pinned = 'https://example.com/pinned/registry.json';
      const other = 'https://example.com/other/registry.json';
      RepoExtension entry(String id, String url, String version) =>
          RepoExtension.fromJson({
            'id': id,
            'name': id,
            'version': version,
            'is_installed': true,
            'installed_version': '1.0.0',
            'has_update': version != '1.0.0',
            'registry_url': url,
          });
      final merged = mergeRepoCatalog(
        entries: [
          entry('ext-pinned', pinned, '1.0.0'),
          entry('ext-pinned', other, '3.0.0'),
          entry('ext-gone', other, '3.0.0'),
        ],
        sources: const [
          RepoSource(registryUrl: pinned),
          RepoSource(registryUrl: other),
        ],
        pins: {'ext-pinned': pinned, 'ext-gone': pinned},
      ).extensions;
      final picked = selectExtensionAutoUpdates(
        storeExtensions: merged,
        installed: [_installed('ext-pinned'), _installed('ext-gone')],
      );
      expect(picked, isEmpty);
    });
  });

  test('the download queue is idle only with nothing queued or running', () {
    expect(isDownloadQueueIdle(const DownloadQueueState()), isTrue);
    expect(
      isDownloadQueueIdle(const DownloadQueueState(isProcessing: true)),
      isFalse,
    );
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    queue.setBusy(true);
    final busy = container.read(downloadQueueProvider);
    expect(busy.queuedCount, 1);
    expect(isDownloadQueueIdle(busy.copyWith(isProcessing: false)), isFalse);
  });

  group('background check', () {
    test('does no store work without a saved registry URL', () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _Harness();
      addTearDown(harness.container.dispose);
      await harness.notifier.checkAfterStartup();
      expect(harness.repo.calls, isEmpty);
      expect(harness.notice, isNull);
    });

    test('startup initializes the store and updates enabled extensions '
        'one at a time, quietly', () async {
      final harness = _Harness();
      addTearDown(harness.container.dispose);
      await harness.notifier.checkAfterStartup();
      expect(harness.repo.calls, [
        'initialize',
        'update:ext-a:true',
        'update:ext-b:true',
      ]);
      expect(harness.notice?.count, 2);
      expect(harness.container.read(repoProvider).updatesAvailableCount, 0);
    });

    test('a second startup call does not check again', () async {
      final harness = _Harness();
      addTearDown(harness.container.dispose);
      await harness.notifier.checkAfterStartup();
      await harness.notifier.checkAfterStartup();
      expect(harness.repo.calls.where((c) => c == 'initialize'), hasLength(1));
    });

    test('resuming checks again only after six hours', () async {
      final harness = _Harness(
        settings: const AppSettings().copyWith(autoUpdateExtensions: false),
      );
      addTearDown(harness.container.dispose);

      await harness.notifier.checkOnResume();
      expect(harness.repo.calls, isEmpty, reason: 'startup has not run');

      await harness.notifier.checkAfterStartup();
      expect(harness.repo.calls, ['initialize']);

      harness.now = harness.now.add(const Duration(hours: 5, minutes: 59));
      await harness.notifier.checkOnResume();
      expect(harness.repo.calls, ['initialize']);

      harness.now = harness.now.add(const Duration(minutes: 1));
      await harness.notifier.checkOnResume();
      expect(harness.repo.calls, ['initialize', 'refresh']);

      harness.now = harness.now.add(const Duration(hours: 1));
      await harness.notifier.checkOnResume();
      expect(harness.repo.calls, ['initialize', 'refresh']);
    });

    test('with the setting off the badge fills but nothing updates', () async {
      final harness = _Harness(
        settings: const AppSettings().copyWith(autoUpdateExtensions: false),
      );
      addTearDown(harness.container.dispose);
      await harness.notifier.checkAfterStartup();
      expect(harness.repo._updates, isEmpty);
      expect(harness.container.read(repoProvider).updatesAvailableCount, 2);
      expect(harness.notice, isNull);
    });

    test('a failure keeps the old version and is not retried', () async {
      final harness = _Harness();
      addTearDown(harness.container.dispose);
      harness.repo.failing.add('ext-a');

      await harness.notifier.checkAfterStartup();
      expect(harness.repo._updates, ['update:ext-a:true', 'update:ext-b:true']);
      expect(harness.notice?.count, 1);
      expect(harness.container.read(repoProvider).updatesAvailableCount, 1);

      final firstNotice = harness.notice;
      harness.now = harness.now.add(extensionUpdateCheckInterval);
      await harness.notifier.checkOnResume();
      expect(harness.repo.calls.last, 'refresh');
      expect(harness.repo._updates, hasLength(2));
      expect(identical(harness.notice, firstNotice), isTrue);
    });

    test('no notice when nothing was updated', () async {
      final harness = _Harness(
        store: [_store('ext-a', version: '1.0.0', hasUpdate: false)],
        installed: [_installed('ext-a')],
      );
      addTearDown(harness.container.dispose);
      await harness.notifier.checkAfterStartup();
      expect(harness.repo._updates, isEmpty);
      expect(harness.notice, isNull);
    });

    test('waits for downloads to finish before updating', () async {
      final harness = _Harness();
      addTearDown(harness.container.dispose);
      harness.container.read(downloadQueueProvider);
      harness.queue.setBusy(true);

      final check = harness.notifier.checkAfterStartup();
      await pumpEventQueue();
      expect(harness.repo.calls, ['initialize']);

      harness.queue.setBusy(false);
      await check;
      expect(harness.repo._updates, ['update:ext-a:true', 'update:ext-b:true']);
      expect(harness.notice?.count, 2);
    });

    test('turning the setting off while waiting cancels the run', () async {
      final harness = _Harness();
      addTearDown(harness.container.dispose);
      harness.container.read(downloadQueueProvider);
      harness.queue.setBusy(true);

      final check = harness.notifier.checkAfterStartup();
      await pumpEventQueue();
      harness.settings.setAutoUpdate(false);
      harness.queue.setBusy(false);
      await check;
      expect(harness.repo._updates, isEmpty);
      expect(harness.notice, isNull);
    });
  });

  testWidgets('the notice uses plural forms', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    expect(l10n.extensionsAutoUpdatedCount(1), 'Updated 1 extension');
    expect(l10n.extensionsAutoUpdatedCount(2), 'Updated 2 extensions');
    final id = lookupAppLocalizations(const Locale('id'));
    expect(id.extensionsAutoUpdatedCount(1), '1 ekstensi diperbarui');
    expect(id.extensionsAutoUpdatedCount(3), '3 ekstensi diperbarui');
  });
}
