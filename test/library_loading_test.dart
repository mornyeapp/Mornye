import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';

class _Settings extends SettingsNotifier {
  _Settings({Future<void>? ready, String path = ''})
    : _ready = ready,
      _path = path;

  final Future<void>? _ready;
  final String _path;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {
    await _ready;
    state = state.copyWith(localLibraryPath: _path);
  }
}

class _LibraryDatabase implements LibraryDatabase {
  _LibraryDatabase(this.sources);

  List<LocalLibrarySource> sources;
  Future<int> Function() count = () async => 2;
  Future<LocalLibraryLookupIndex> Function() index = () async =>
      const LocalLibraryLookupIndex(matchKeys: {'song|artist'});
  bool failSources = false;
  int sourceReads = 0;
  int countReads = 0;
  int indexReads = 0;
  int availabilityWrites = 0;

  @override
  Future<List<LocalLibrarySource>> getSources() async {
    sourceReads++;
    if (failSources) throw StateError('database is busy');
    return List.of(sources);
  }

  @override
  Future<int> getCount() {
    countReads++;
    return count();
  }

  @override
  Future<LocalLibraryLookupIndex> getLookupIndex() {
    indexReads++;
    return index();
  }

  @override
  Future<void> removeSource(String sourceId) async {
    sources = sources.where((source) => source.id != sourceId).toList();
  }

  @override
  Future<LocalLibrarySource?> getSourceByPath(String path) async =>
      sources.where((source) => source.path == path).firstOrNull;

  @override
  Future<void> migrateLegacySource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
    bool available = true,
    DateTime? lastScannedAt,
  }) async {
    sources = [
      ...sources,
      LocalLibrarySource(
        id: LibraryDatabase.legacySourceId,
        path: path,
        displayName: displayName,
        available: available,
      ),
    ];
  }

  @override
  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    if (available != null) availabilityWrites++;
    sources = [
      for (final source in sources)
        source.id == sourceId
            ? source.copyWith(enabled: enabled, available: available)
            : source,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends LocalLibraryNotifier {
  _Library(LibraryDatabase database, LocalLibraryAvailabilityProbe probe)
    : super(database: database, availabilityProbe: probe);

  final List<String> scannedSources = [];

  @override
  Future<void> startSourceScan(
    String sourceId, {
    bool forceFullScan = false,
    bool notify = true,
    bool waitForCurrentScan = false,
  }) async {
    scannedSources.add(sourceId);
  }
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory music;
  late _LibraryDatabase database;
  late ProviderContainer container;
  late LocalLibraryAvailabilityProbe probe;
  late _Library library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    music = await Directory.systemTemp.createTemp('library_loading_');
    database = _LibraryDatabase([
      LocalLibrarySource(
        id: 'music',
        path: music.path,
        displayName: 'Music',
        trackCount: 2,
      ),
    ]);
    probe = (path, {bookmark}) => Directory(path).exists();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localLibraryProvider.overrideWith(
          () => library = _Library(
            database,
            (path, {bookmark}) => probe(path, bookmark: bookmark),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await music.delete(recursive: true);
  });

  test('disposed startup skips the deferred library load', () async {
    final transient = ProviderContainer(
      overrides: [
        localLibraryProvider.overrideWith(
          () => LocalLibraryNotifier(database: database),
        ),
      ],
    );
    transient.read(localLibraryProvider);
    transient.dispose();

    await Future<void>.delayed(Duration.zero);
    expect(database.sourceReads, 0);
    expect(database.countReads, 0);
    expect(database.indexReads, 0);
  });

  test(
    'upgrade waits for saved settings before migrating the old folder',
    () async {
      final ready = Completer<void>();
      container.dispose();
      database.sources = [];
      container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(ready: ready.future, path: music.path),
          ),
          localLibraryProvider.overrideWith(
            () => LocalLibraryNotifier(database: database),
          ),
        ],
      );
      container.read(localLibraryProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(localLibraryProvider).isLoading, isTrue);
      ready.complete();
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      expect(container.read(localLibraryProvider).loadFailed, isFalse);
      expect(
        container.read(localLibraryProvider).sources.single.path,
        music.path,
      );
      expect(
        container.read(localLibraryProvider).sources.single.id,
        LibraryDatabase.legacySourceId,
      );
    },
  );

  test(
    'saved folders appear while a large track index is still loading',
    () async {
      final pending = Completer<LocalLibraryLookupIndex>();
      database.index = () => pending.future;
      container.read(localLibraryProvider);
      await _waitFor(
        () => container.read(localLibraryProvider).sources.isNotEmpty,
      );
      final loading = container.read(localLibraryProvider);
      expect(loading.sources.single.path, music.path);
      expect(loading.isLoading, isTrue);
      pending.complete(const LocalLibraryLookupIndex());
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      expect(container.read(localLibraryProvider).totalCount, 2);
    },
  );

  test(
    'index failure retains folders and retry recovers without reattaching',
    () async {
      database.index = () async => throw StateError('index read failed');
      container.read(localLibraryProvider);
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      final failed = container.read(localLibraryProvider);
      expect(failed.loadFailed, isTrue);
      expect(failed.sources.single.path, music.path);
      database.index = () async => const LocalLibraryLookupIndex();
      await container.read(localLibraryProvider.notifier).reloadFromStorage();
      expect(container.read(localLibraryProvider).loadFailed, isFalse);
      expect(container.read(localLibraryProvider).totalCount, 2);
      expect(container.read(localLibraryProvider).sources.single.id, 'music');
    },
  );

  for (final edit in ['disable', 'enable', 'remove']) {
    test('initial index cannot overwrite a newer source $edit', () async {
      if (edit == 'enable') {
        database.sources = [database.sources.single.copyWith(enabled: false)];
      }
      database.count = () async => database.sources
          .where((source) => source.enabled && source.available)
          .fold<int>(0, (total, source) => total + source.trackCount);
      final pending = Completer<LocalLibraryLookupIndex>();
      database.index = () => pending.future;
      container.read(localLibraryProvider);
      await _waitFor(() => database.indexReads > 0);
      database.index = () async => const LocalLibraryLookupIndex();
      if (edit == 'remove') {
        await library.removeSource('music');
      } else {
        await library.setSourceEnabled('music', edit == 'enable');
      }
      final version = container.read(localLibraryProvider).loadedIndexVersion;
      pending.complete(
        const LocalLibraryLookupIndex(matchKeys: {'stale|song'}),
      );
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      final loaded = container.read(localLibraryProvider);
      expect(loaded.loadFailed, false);
      expect(loaded.loadedIndexVersion, version);
      expect(loaded.hasTrack('stale', 'song'), false);
      expect(loaded.totalCount, edit == 'enable' ? 2 : 0);
      if (edit == 'remove') {
        expect(loaded.sources, isEmpty);
      } else {
        expect(loaded.sources.single.enabled, edit == 'enable');
      }
    });
  }

  test(
    'failed reload keeps the previously loaded folders and song count',
    () async {
      container.read(localLibraryProvider);
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      database.failSources = true;
      await container.read(localLibraryProvider.notifier).reloadFromStorage();
      final failed = container.read(localLibraryProvider);
      expect(failed.loadFailed, isTrue);
      expect(failed.totalCount, 2);
      expect(failed.sources.single.id, 'music');
      database.failSources = false;
      await container.read(localLibraryProvider.notifier).reloadFromStorage();
      expect(container.read(localLibraryProvider).loadFailed, isFalse);
    },
  );

  test('network collection survives local availability checks', () async {
    database.sources = [
      const LocalLibrarySource(
        id: 'nas',
        path: 'network://nas/Music/',
        displayName: 'NAS / Music',
        trackCount: 2,
      ),
    ];
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    await container
        .read(localLibraryProvider.notifier)
        .refreshSourceAvailability();
    final loaded = container.read(localLibraryProvider);
    expect(loaded.sources.single.available, isTrue);
    expect(loaded.sources.single.trackCount, 2);
    expect(loaded.totalCount, 2);
  });

  test(
    'unchanged overlapping availability refreshes share one probe',
    () async {
      container.read(localLibraryProvider);
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      final sourceReads = database.sourceReads;
      final countReads = database.countReads;
      final indexReads = database.indexReads;
      final version = container.read(localLibraryProvider).loadedIndexVersion;
      final refresh = library.refreshSourceAvailability();
      final overlapping = library.refreshSourceAvailability();
      expect(identical(refresh, overlapping), isTrue);
      await Future.wait([refresh, overlapping]);
      expect(database.sourceReads, sourceReads + 1);
      expect(database.countReads, countReads);
      expect(database.indexReads, indexReads);
      expect(container.read(localLibraryProvider).loadedIndexVersion, version);
    },
  );

  test('detach and reconnect each refresh the visible index once', () async {
    database.count = () async => database.sources.single.available ? 2 : 0;
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    final version = container.read(localLibraryProvider).loadedIndexVersion;
    final indexReads = database.indexReads;
    probe = (path, {bookmark}) async => false;
    await library.refreshSourceAvailability();
    expect(
      container.read(localLibraryProvider).sources.single.available,
      false,
    );
    expect(container.read(localLibraryProvider).totalCount, 0);
    expect(
      container.read(localLibraryProvider).loadedIndexVersion,
      version + 1,
    );

    probe = (path, {bookmark}) async => true;
    await Future.wait([
      library.refreshSourceAvailability(),
      library.refreshSourceAvailability(scanReconnected: true),
    ]);
    expect(container.read(localLibraryProvider).sources.single.available, true);
    expect(container.read(localLibraryProvider).totalCount, 2);
    expect(
      container.read(localLibraryProvider).loadedIndexVersion,
      version + 2,
    );
    expect(database.indexReads, indexReads + 2);
    await _waitFor(() => library.scannedSources.isNotEmpty);
    expect(library.scannedSources, ['music']);
  });

  test(
    'an inconclusive probe retains availability and the loaded index',
    () async {
      container.read(localLibraryProvider);
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      final indexReads = database.indexReads;
      final version = container.read(localLibraryProvider).loadedIndexVersion;
      probe = (path, {bookmark}) async => null;
      await library.refreshSourceAvailability();
      expect(
        container.read(localLibraryProvider).sources.single.available,
        true,
      );
      expect(database.indexReads, indexReads);
      expect(container.read(localLibraryProvider).loadedIndexVersion, version);
    },
  );

  test('a newer storage event supersedes a pending detached result', () async {
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    final pending = Completer<bool?>();
    var probes = 0;
    probe = (path, {bookmark}) =>
        ++probes == 1 ? pending.future : Future<bool?>.value(true);
    final indexReads = database.indexReads;
    final refresh = library.refreshSourceAvailability();
    await _waitFor(() => probes == 1);
    final reconnect = library.refreshSourceAvailability(scanReconnected: true);
    pending.complete(false);
    await Future.wait([refresh, reconnect]);
    expect(probes, 2);
    expect(database.availabilityWrites, 0);
    expect(database.indexReads, indexReads);
    expect(container.read(localLibraryProvider).sources.single.available, true);
  });

  for (final remove in [false, true]) {
    test(
      'pending probes do not overwrite ${remove ? 'removal' : 'disable'}',
      () async {
        container.read(localLibraryProvider);
        await _waitFor(() => !container.read(localLibraryProvider).isLoading);
        final pending = Completer<bool?>();
        var probes = 0;
        probe = (path, {bookmark}) =>
            ++probes == 1 ? pending.future : Future<bool?>.value(true);
        final refresh = library.refreshSourceAvailability();
        await _waitFor(() => probes == 1);
        if (remove) {
          await library.removeSource('music');
        } else {
          await library.setSourceEnabled('music', false);
        }
        final indexReads = database.indexReads;
        final version = container.read(localLibraryProvider).loadedIndexVersion;
        pending.complete(false);
        await refresh;
        expect(database.availabilityWrites, 0);
        expect(database.indexReads, indexReads);
        expect(
          container.read(localLibraryProvider).loadedIndexVersion,
          version,
        );
        final sources = container.read(localLibraryProvider).sources;
        if (remove) {
          expect(sources, isEmpty);
        } else {
          expect(sources.single.enabled, false);
          expect(sources.single.available, true);
        }
      },
    );
  }

  test('a superseded summary cannot restore stale lookup sets', () async {
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    final pending = Completer<LocalLibraryLookupIndex>();
    database.index = () => pending.future;
    probe = (path, {bookmark}) async => false;
    final indexReads = database.indexReads;
    final refresh = library.refreshSourceAvailability();
    await _waitFor(() => database.indexReads > indexReads);
    database.index = () async => const LocalLibraryLookupIndex();
    await library.setSourceEnabled('music', false);
    pending.complete(const LocalLibraryLookupIndex(matchKeys: {'stale|song'}));
    await refresh;
    expect(container.read(localLibraryProvider).sources.single.enabled, false);
    expect(
      container.read(localLibraryProvider).hasTrack('stale', 'song'),
      false,
    );
    expect(
      container.read(localLibraryProvider).hasTrack('song', 'artist'),
      false,
    );
  });

  test('an unavailable folder remains attached instead of vanishing', () async {
    await music.delete(recursive: true);
    database.sources = [
      LocalLibrarySource(
        id: 'missing',
        path: music.path,
        displayName: 'Offline music',
        isRemovable: true,
        available: false,
      ),
    ];
    database.count = () async => 0;
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    final loaded = container.read(localLibraryProvider);
    expect(loaded.loadFailed, isFalse);
    expect(loaded.sources.single.available, isFalse);
    expect(loaded.sources.single.path, music.path);
    // Keep teardown simple after deliberately removing the storage above.
    await music.create();
  });
}
