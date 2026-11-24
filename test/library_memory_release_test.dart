import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

import 'support/fixed_settings.dart';
import 'support/vm_service_probe.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

Future<void> _browseAndClose(ProviderContainer container, String search) async {
  final provider = libraryBrowseProvider((
    artists: false,
    artist: null,
    search: search,
    sort: 'a-z',
    limit: 40,
    completeness: null,
  ));
  final subscription = container.listen(provider, (_, _) {});
  try {
    await container.read(provider.future);
    for (var page = 0; page < 9; page++) {
      await container.read(provider.notifier).loadMore();
    }
  } finally {
    subscription.close();
  }
  await container.pump();
  expect(container.read(provider.exists), isFalse);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = (await developer.Service.getInfo()).serverUri;
  test(
    'Library pages and old filter results are collectible after closing',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final entries = <WeakReference<LibraryBrowseEntry>>[];
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          downloadHistoryProvider.overrideWith(_History.new),
          localLibraryProvider.overrideWith(_Local.new),
          libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
            final rows = [
              for (var i = page.offset; i < page.offset + 40 && i < 400; i++)
                LibraryBrowseEntry(
                  source: 'local',
                  key: '$i',
                  name: 'Album $i',
                  artist: 'Artist',
                  samplePath: '/music/$i.flac',
                  trackCount: 1,
                ),
            ];
            entries.addAll(rows.map(WeakReference.new));
            return LibraryBrowsePage(rows);
          }),
        ],
      );
      // Debug DevTools intentionally retain provider event snapshots. Exclude
      // that history to measure the application-owned lifecycle as in release.
      container.observers.clear();
      addTearDown(container.dispose);
      for (var i = 0; i < 5; i++) {
        await _browseAndClose(container, 'filter $i');
      }
      expect(entries, hasLength(2000));
      await collectTestGarbage(service!);
      expect(
        entries.where((entry) => entry.target != null).length,
        0,
        reason: 'Closed Library queries must not retain their loaded rows',
      );
    },
    skip: service == null ? 'Requires flutter test --enable-vmservice' : false,
  );
}
