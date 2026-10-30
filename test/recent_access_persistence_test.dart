import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/utils/logger.dart';

RecentAccessItem _artist(String id, {String? name}) => RecentAccessItem(
  id: id,
  name: name ?? id,
  type: RecentAccessType.artist,
  providerId: 'example',
  accessedAt: DateTime.utc(2026, 1, 1),
);

class _Database implements AppStateDatabase {
  _Database({Iterable<RecentAccessItem> items = const []})
    : items = {for (final item in items) item.uniqueKey: item};

  final Map<String, RecentAccessItem> items;
  final hiddenIds = <String>{'saved-download'};
  final clearedAt = DateTime.utc(2025, 12, 1);
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();
  final clearStarted = Completer<void>();
  final releaseClear = Completer<void>();
  final operations = <String>[];
  final failures = <String>{};
  final _completed = <String, Completer<void>>{};
  bool holdClear = false;
  bool failRead = false;

  Future<void> whenCompleted(String operation) =>
      (_completed[operation] ??= Completer<void>()).future;

  void _complete(String operation) {
    operations.add(operation);
    if (failures.remove(operation)) throw StateError(operation);
    (_completed[operation] ??= Completer<void>()).complete();
  }

  @override
  Future<bool> migrateRecentAccessFromSharedPreferences() async => true;

  @override
  Future<List<Map<String, dynamic>>> getRecentAccessRows({int? limit}) async {
    final snapshot = items.values
        .take(limit ?? items.length)
        .map((item) => {'item_json': jsonEncode(item.toJson())})
        .toList();
    readStarted.complete();
    await releaseRead.future;
    if (failRead) throw StateError('recent_load_failed');
    return snapshot;
  }

  @override
  Future<Set<String>> getHiddenRecentDownloadIds() async => {...hiddenIds};

  @override
  Future<DateTime?> getRecentDownloadsClearedAt() async => clearedAt;

  @override
  Future<void> upsertRecentAccessRow({
    required String uniqueKey,
    required String itemJson,
    required String accessedAt,
  }) async {
    final operation = 'record:$uniqueKey';
    if (failures.contains(operation)) {
      _complete(operation);
      return;
    }
    items[uniqueKey] = RecentAccessItem.fromJson(
      jsonDecode(itemJson) as Map<String, dynamic>,
    );
    _complete(operation);
  }

  @override
  Future<void> deleteRecentAccessRow(String uniqueKey) async {
    items.remove(uniqueKey);
    _complete('remove:$uniqueKey');
  }

  @override
  Future<void> addHiddenRecentDownloadId(String downloadId) async {
    hiddenIds.add(downloadId);
    _complete('hide:$downloadId');
  }

  @override
  Future<void> clearHiddenRecentDownloadIds() async {
    hiddenIds.clear();
    _complete('clear-hidden');
  }

  @override
  Future<DateTime> clearAllRecentAccess() async {
    clearStarted.complete();
    if (holdClear) await releaseClear.future;
    items.clear();
    hiddenIds.clear();
    _complete('clear');
    return DateTime.utc(2026, 10, 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container(_Database database) => ProviderContainer(
  overrides: [
    recentAccessProvider.overrideWith(
      () => RecentAccessNotifier(database: database),
    ),
  ],
);

Future<void> _waitUntilLoaded(ProviderContainer container) async {
  if (container.read(recentAccessProvider).isLoaded) return;
  final loaded = Completer<void>();
  final subscription = container.listen(recentAccessProvider, (_, next) {
    if (next.isLoaded && !loaded.isCompleted) loaded.complete();
  });
  await loaded.future;
  subscription.close();
}

void main() {
  test(
    'delayed startup replays edits without discarding saved recents',
    () async {
      final removed = _artist('removed');
      final database = _Database(
        items: [
          _artist('edited', name: 'Old name'),
          _artist('kept'),
          removed,
        ],
      );
      final container = _container(database);
      addTearDown(container.dispose);
      final notifier = container.read(recentAccessProvider.notifier);
      await database.readStarted.future;

      notifier.recordArtistAccess(
        id: 'edited',
        name: 'New name',
        providerId: 'example',
      );
      notifier.removeItem(removed);
      notifier.hideDownloadFromRecents('new-download');
      expect(
        container.read(recentAccessProvider).items.single.name,
        'New name',
      );
      expect(database.operations, isEmpty);

      database.releaseRead.complete();
      await _waitUntilLoaded(container);
      final state = container.read(recentAccessProvider);
      expect(state.items.map((item) => item.id), ['edited', 'kept']);
      expect(state.items.first.name, 'New name');
      expect(state.hiddenDownloadIds, {'saved-download', 'new-download'});
      expect(state.downloadsClearedAt, database.clearedAt);
      await database.whenCompleted('hide:new-download');
      expect(database.items.keys, [
        _artist('edited').uniqueKey,
        _artist('kept').uniqueKey,
      ]);
      expect(database.items[_artist('edited').uniqueKey]!.name, 'New name');
    },
  );

  test('early hidden clear is replayed before a later hide', () async {
    final database = _Database();
    final container = _container(database);
    addTearDown(container.dispose);
    final notifier = container.read(recentAccessProvider.notifier);
    await database.readStarted.future;
    notifier.clearHiddenDownloads();
    notifier.hideDownloadFromRecents('new-download');
    database.releaseRead.complete();
    await _waitUntilLoaded(container);
    await database.whenCompleted('hide:new-download');
    expect(container.read(recentAccessProvider).hiddenDownloadIds, {
      'new-download',
    });
    expect(database.hiddenIds, {'new-download'});
    expect(database.operations, ['clear-hidden', 'hide:new-download']);
  });

  test(
    'startup clear preserves accesses made after the clear request',
    () async {
      final database = _Database(items: [_artist('old')])..holdClear = true;
      final container = _container(database);
      addTearDown(container.dispose);
      final notifier = container.read(recentAccessProvider.notifier);
      await database.readStarted.future;
      final clearing = notifier.clearHistory();
      notifier.recordArtistAccess(
        id: 'later',
        name: 'Later',
        providerId: 'example',
      );
      database.releaseRead.complete();
      await database.clearStarted.future;
      database.releaseClear.complete();
      await clearing;
      await database.whenCompleted('record:${_artist('later').uniqueKey}');
      expect(container.read(recentAccessProvider).items.single.id, 'later');
      expect(database.items.values.single.id, 'later');
      expect(
        container.read(recentAccessProvider).downloadsClearedAt,
        DateTime.utc(2026, 10, 1),
      );
      expect(database.operations, [
        'clear',
        'record:${_artist('later').uniqueKey}',
      ]);
    },
  );

  test('owned write failure is logged and permits later writes', () async {
    final database = _Database();
    final container = _container(database);
    addTearDown(container.dispose);
    final notifier = container.read(recentAccessProvider.notifier);
    await database.readStarted.future;
    database.releaseRead.complete();
    await _waitUntilLoaded(container);
    final failedOperation = 'record:${_artist('failed').uniqueKey}';
    database.failures.add(failedOperation);
    notifier.recordArtistAccess(
      id: 'failed',
      name: 'Failed',
      providerId: 'example',
    );
    notifier.hideDownloadFromRecents('after-failure');
    await database.whenCompleted('hide:after-failure');
    expect(container.read(recentAccessProvider).items.single.id, 'failed');
    expect(database.items, isEmpty);
    expect(database.hiddenIds, contains('after-failure'));
    expect(
      LogBuffer().entries.any(
        (entry) =>
            entry.tag == 'RecentAccess' &&
            entry.error?.contains(failedOperation) == true,
      ),
      isTrue,
    );
  });

  test(
    'albums and artists opened from the player store no temporary cover',
    () async {
      final database = _Database();
      final container = _container(database);
      addTearDown(container.dispose);
      final notifier = container.read(recentAccessProvider.notifier);
      database.releaseRead.complete();
      await _waitUntilLoaded(container);
      const kept = 'https://example.com/album.jpg';
      for (final (id, cover) in [
        ('temporary', '/data/user/0/app/cache/network_metadata/a1.jpg'),
        ('loopback', 'http://127.0.0.1:41234/7f3a'),
        ('kept', kept),
      ]) {
        notifier
          ..recordAlbumAccess(id: id, name: id, imageUrl: cover)
          ..recordArtistAccess(id: id, name: id, imageUrl: cover);
      }
      await database.whenCompleted('record:artist:default:kept');
      expect(
        {
          for (final item in database.items.values)
            '${item.type.name}:${item.id}': item.imageUrl,
        },
        {
          'album:temporary': null,
          'artist:temporary': null,
          'album:loopback': null,
          'artist:loopback': null,
          'album:kept': kept,
          'artist:kept': kept,
        },
      );
    },
  );

  test('failed load preserves early state and still owns its writes', () async {
    final database = _Database()..failRead = true;
    final container = _container(database);
    addTearDown(container.dispose);
    final notifier = container.read(recentAccessProvider.notifier);
    await database.readStarted.future;
    notifier.recordArtistAccess(
      id: 'early',
      name: 'Early',
      providerId: 'example',
    );
    database.releaseRead.complete();
    await _waitUntilLoaded(container);
    await database.whenCompleted('record:${_artist('early').uniqueKey}');
    expect(container.read(recentAccessProvider).items.single.id, 'early');
    expect(database.items.values.single.id, 'early');
    expect(
      LogBuffer().entries.any(
        (entry) =>
            entry.tag == 'RecentAccess' &&
            entry.error?.contains('recent_load_failed') == true,
      ),
      isTrue,
    );
  });
}
