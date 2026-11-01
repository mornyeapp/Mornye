import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: true);

  void includeLocal(bool value) =>
      state = state.copyWith(localLibraryEnabled: value);
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  void revise() =>
      state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();

  void progress() => state = state.copyWith(scanProgress: .5);

  void revise() =>
      state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
}

LibraryBrowseEntry _entry(int index, {String prefix = ''}) =>
    LibraryBrowseEntry(
      source: 'downloaded',
      key: '$index',
      name: '$prefix Album $index',
      artist: 'Artist $index',
      samplePath: '',
      trackCount: 1,
    );

const _request = (
  artists: false,
  artist: null,
  search: '',
  sort: 'a-z',
  limit: 40,
  completeness: null,
);

void main() {
  late ProviderContainer container;
  late List<LibraryBrowsePageRequest> requests;
  var count = 100;
  var prefix = '';
  Completer<LibraryBrowsePage>? pending;
  Object? failure;

  setUp(() {
    requests = [];
    count = 100;
    prefix = '';
    pending = null;
    failure = null;
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        downloadHistoryProvider.overrideWith(_History.new),
        localLibraryProvider.overrideWith(_Local.new),
        libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
          requests.add(page);
          if (failure != null) throw failure!;
          if (pending != null) return pending!.future;
          return LibraryBrowsePage(
            [
              for (
                var i = page.offset;
                i < count && i < page.offset + page.browse.limit;
                i++
              )
                _entry(i, prefix: prefix),
            ],
            nextCursor: QueueLibraryDbCursor([page.offset + page.browse.limit]),
          );
        }),
      ],
    );
    container.listen(libraryBrowseProvider(_request), (_, _) {});
  });
  tearDown(() => container.dispose());

  test(
    'bounded album pages retain rows and forward cursors exactly once',
    () async {
      final provider = libraryBrowseProvider(_request);
      final first = await container.read(provider.future);
      expect(first.entries, hasLength(40));
      final notifier = container.read(provider.notifier);
      pending = Completer();
      final loading = notifier.loadMore();
      expect(
        container.read(provider).requireValue.entries,
        same(first.entries),
      );
      expect(container.read(provider).requireValue.isLoadingMore, true);
      await notifier.loadMore();
      expect(
        requests,
        hasLength(2),
        reason: 'concurrent loadMore is single flight',
      );
      pending!.complete(
        LibraryBrowsePage(
          List.generate(40, (i) => _entry(i + 40)),
          nextCursor: const QueueLibraryDbCursor([80]),
        ),
      );
      await loading;
      pending = null;
      await notifier.loadMore();
      await notifier.loadMore();
      expect(requests.map((page) => page.offset), [0, 40, 80]);
      expect(requests.map((page) => page.browse.limit), [40, 40, 40]);
      expect(requests[1].cursor, const QueueLibraryDbCursor([40]));
      expect(requests[2].cursor, const QueueLibraryDbCursor([80]));
      final result = container.read(provider).requireValue;
      expect(
        result.entries.map((entry) => entry.key),
        List.generate(100, (i) => '$i'),
      );
      expect(result.hasMore, false);
      expect(result.isLoadingMore, false);
    },
  );

  test(
    'refresh and revisions replace the loaded range with bounded pages',
    () async {
      final provider = libraryBrowseProvider(_request);
      await container.read(provider.future);
      await container.read(provider.notifier).loadMore();
      prefix = 'Refreshed';
      container.invalidate(provider);
      var result = await container.read(provider.future);
      expect(result.entries, hasLength(80));
      expect(result.entries.first.name, startsWith('Refreshed'));
      expect(requests.map((page) => page.offset), [0, 40, 0, 40]);
      (container.read(localLibraryProvider.notifier) as _Local).progress();
      await container.pump();
      expect(
        requests,
        hasLength(4),
        reason: 'scan progress must not refresh rows',
      );
      (container.read(downloadHistoryProvider.notifier) as _History).revise();
      result = await container.read(provider.future);
      expect(result.entries, hasLength(80));
      expect(requests.map((page) => page.offset), [0, 40, 0, 40, 0, 40]);
      (container.read(settingsProvider.notifier) as _Settings).includeLocal(
        false,
      );
      await container.read(provider.future);
      expect(requests.last.includeLocal, false);
      final reads = requests.length;
      (container.read(localLibraryProvider.notifier) as _Local).revise();
      await container.pump();
      expect(
        requests,
        hasLength(reads),
        reason: 'disabled local index is not watched',
      );
    },
  );

  test('failed next page retains rows and retries the same cursor', () async {
    final provider = libraryBrowseProvider(_request);
    final first = await container.read(provider.future);
    failure = StateError('fixture failure');
    await container.read(provider.notifier).loadMore();
    var result = container.read(provider).requireValue;
    expect(result.entries, same(first.entries));
    expect(result.loadMoreError, same(failure));
    failure = null;
    await container.read(provider.notifier).loadMore();
    result = container.read(provider).requireValue;
    expect(result.entries, hasLength(80));
    expect(result.loadMoreError, isNull);
    expect(requests.map((page) => page.offset), [0, 40, 40]);
    expect(requests[1].cursor, requests[2].cursor);
  });

  test(
    'a late batched refresh cannot replace a newer index revision',
    () async {
      count = 1000;
      final provider = libraryBrowseProvider(_request);
      await container.read(provider.future);
      final notifier = container.read(provider.notifier);
      while (container.read(provider).requireValue.entries.length < count) {
        await notifier.loadMore();
      }
      pending = Completer();
      final latePage = pending!;
      container.invalidate(provider);
      final oldRefresh = container.read(provider.future);
      expect(requests.last.browse.limit, 200);

      pending = null;
      prefix = 'Fresh';
      (container.read(downloadHistoryProvider.notifier) as _History).revise();
      final refreshed = await container.read(provider.future);
      latePage.complete(
        LibraryBrowsePage(List.generate(200, (index) => _entry(index))),
      );
      await oldRefresh;
      expect(container.read(provider).requireValue, same(refreshed));
      expect(refreshed.entries, hasLength(1000));
      expect(
        refreshed.entries.every((entry) => entry.name.startsWith('Fresh')),
        true,
      );
    },
  );

  test(
    'refresh keeps partial tails on custom scroll page boundaries',
    () async {
      await container.read(libraryBrowseProvider(_request).future);
      count = 299;
      const request = (
        artists: false,
        artist: null,
        search: '',
        sort: 'a-z',
        limit: 60,
        completeness: null,
      );
      final provider = libraryBrowseProvider(request);
      container.listen(provider, (_, _) {});
      await container.read(provider.future);
      final notifier = container.read(provider.notifier);
      while (container.read(provider).requireValue.hasMore) {
        await notifier.loadMore();
      }
      requests.clear();
      container.invalidate(provider);
      final refreshed = await container.read(provider.future);
      expect(requests.map((page) => page.offset), [0, 180]);
      expect(requests.map((page) => page.browse.limit), [180, 120]);
      expect(refreshed.entries, hasLength(299));
      expect(refreshed.hasMore, false);
    },
  );

  test('index revision rejects a late next-page response', () async {
    final provider = libraryBrowseProvider(_request);
    await container.read(provider.future);
    pending = Completer();
    final latePage = container.read(provider.notifier).loadMore();
    final completer = pending!;
    pending = null;
    prefix = 'Fresh';
    (container.read(downloadHistoryProvider.notifier) as _History).revise();
    final refreshed = await container.read(provider.future);
    completer.complete(LibraryBrowsePage([_entry(999)]));
    await latePage;
    expect(container.read(provider).requireValue, same(refreshed));
    expect(refreshed.entries, hasLength(40));
    expect(refreshed.entries.first.name, startsWith('Fresh'));
  });

  test(
    'failed refresh cannot append from the previous revision cursor',
    () async {
      final provider = libraryBrowseProvider(_request);
      await container.read(provider.future);
      final notifier = container.read(provider.notifier);
      await notifier.loadMore();
      expect(container.read(provider).requireValue.entries, hasLength(80));

      failure = StateError('refresh failed');
      prefix = 'Fresh';
      (container.read(downloadHistoryProvider.notifier) as _History).revise();
      await expectLater(
        container.read(provider.future),
        throwsA(same(failure)),
      );
      final failed = container.read(provider);
      final readsAfterFailure = requests.length;

      failure = null;
      await notifier.loadMore();
      expect(requests, hasLength(readsAfterFailure));
      expect(container.read(provider), same(failed));
      expect(container.read(provider).hasError, true);

      container.invalidate(provider);
      final refreshed = await container.read(provider.future);
      expect(refreshed.entries, hasLength(80));
      expect(
        refreshed.entries.every((entry) => entry.name.startsWith('Fresh')),
        true,
      );
      expect(requests.skip(readsAfterFailure).map((page) => page.offset), [
        0,
        40,
      ]);
      await notifier.loadMore();
      expect(container.read(provider).requireValue.entries, hasLength(100));
      expect(
        container
            .read(provider)
            .requireValue
            .entries
            .every((entry) => entry.name.startsWith('Fresh')),
        true,
      );
    },
  );

  test('artists use bounded offsets and new search resets paging', () async {
    const artists = (
      artists: true,
      artist: null,
      search: 'Artist',
      sort: 'a-z',
      limit: 40,
      completeness: null,
    );
    final provider = libraryBrowseProvider(artists);
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    await container.read(provider.notifier).loadMore();
    expect(requests.last.offset, 40);
    expect(requests.last.cursor, isNull);
    expect(requests.last.browse.search, 'Artist');
    const search = (
      artists: false,
      artist: 'Artist 1',
      search: 'New query',
      sort: 'latest',
      limit: 40,
      completeness: 'album-incomplete',
    );
    final searched = libraryBrowseProvider(search);
    container.listen(searched, (_, _) {});
    expect((await container.read(searched.future)).entries, hasLength(40));
    expect(requests.last.offset, 0);
    expect(requests.last.cursor, isNull);
    expect(requests.last.browse, search);
  });
}
