import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/lazy_tab_view.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

import '../test/support/tooltip_finder.dart';
import 'performance_probe.dart';

final _tracks = List.generate(
  2000,
  (index) => Track(
    id: 'fixture-track-$index',
    name: 'Fixture song $index',
    artistName: 'Artist ${index ~/ 100}',
    albumName: 'Album ${(index ~/ 10).toString().padLeft(3, '0')}',
    duration: 240,
    source: 'example',
  ),
);

final _albums = List.generate(
  200,
  (index) => LibraryBrowseEntry(
    source: 'downloaded',
    key: 'fixture-album-$index',
    name: _tracks[index * 10].albumName,
    artist: _tracks[index * 10].artistName,
    samplePath: '',
    trackCount: 10,
    completeness: AlbumCompleteness(
      status: ['complete', 'incomplete', 'unknown'][index % 3],
      present: 10,
      expected: index % 3 == 2
          ? null
          : index % 3 == 1
          ? 12
          : 10,
    ),
  ),
);

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();

  testWidgets('Mornye production screens with deterministic 2000-track data', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: 'mornye_screens');
    final preferences = (await tester.runAsync(SharedPreferences.getInstance))!;
    final settingsBefore = preferences.getString('app_settings');
    const databaseChannel = MethodChannel('com.tekartik.sqflite');
    final databaseCalls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(databaseChannel, (call) async {
      databaseCalls.add(call.method);
      fail('Unexpected database call: ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(databaseChannel, null),
    );
    final index = ValueNotifier(0);
    addTearDown(index.dispose);
    final requests = <LibraryBrowseRequest>[];
    final pageOffsets = <int>[];
    final search = _Search();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          downloadHistoryBatchExistsProvider.overrideWith(
            (ref, request) async => <String>{},
          ),
          downloadQueueProvider.overrideWith(_Queue.new),
          recentAccessProvider.overrideWith(_Recent.new),
          trackProvider.overrideWith(() => search),
          userProfileProvider.overrideWith(_Profile.new),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
          libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
            final request = page.browse;
            requests.add(request);
            pageOffsets.add(page.offset);
            final rows = _albums.where((album) {
              return '${album.name} ${album.artist}'.toLowerCase().contains(
                    request.search.toLowerCase(),
                  ) &&
                  (request.completeness == null ||
                      album.completeness!.status ==
                          (request.completeness == incompleteAlbumFilter
                              ? 'incomplete'
                              : 'unknown'));
            }).toList();
            if (request.sort == 'latest') {
              return LibraryBrowsePage(
                rows.reversed.skip(page.offset).take(request.limit).toList(),
              );
            }
            return LibraryBrowsePage(
              rows.skip(page.offset).take(request.limit).toList(),
            );
          }),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Tabs(index: index),
        ),
      ),
    );
    await tester.runAsync(() => probe.wait(const Duration(seconds: 1)));

    Future<void> select(int value) async {
      FocusManager.instance.primaryFocus?.unfocus();
      index.value = value;
      await probe.wait(const Duration(milliseconds: 350));
    }

    Future<void> scrollRoundTrip() async {
      final scrollable = find.byType(Scrollable).hitTestable().first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(0);
      await probe.wait(const Duration(milliseconds: 100));
      await position.animateTo(
        position.maxScrollExtent.clamp(0.0, 2400.0),
        duration: const Duration(milliseconds: 900),
        curve: Curves.linear,
      );
      await position.animateTo(
        0,
        duration: const Duration(milliseconds: 900),
        curve: Curves.linear,
      );
      await probe.wait(const Duration(milliseconds: 200));
    }

    await tester.runAsync(() async {
      await select(1);
      expect(find.byType(QueueTab), findsOneWidget);
      await tester.tap(find.text('Albums').hitTestable().first);
      await probe.wait(const Duration(milliseconds: 500));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).hitTestable().first)
          .position;
      for (var page = 0; page < 4; page++) {
        position.jumpTo(position.maxScrollExtent);
        await probe.wait(const Duration(milliseconds: 250));
      }
      position.jumpTo(0);
      expect(requests.last.limit, 40);
      expect(pageOffsets.last, 160);
    });
    await probe.measure(
      'library_album_grid_scroll_2000_tracks',
      scrollRoundTrip,
      warmup: scrollRoundTrip,
    );

    Future<void> filterRoundTrip() async {
      for (final label in [
        'Incomplete albums',
        'Album completeness unknown',
        'All',
      ]) {
        await tester.tap(findByTooltip('Filters').hitTestable());
        await probe.wait(const Duration(milliseconds: 350));
        await tester.tap(find.text(label).hitTestable().last);
        await probe.wait(const Duration(milliseconds: 350));
      }
      expect(requests.last.completeness, isNull);
    }

    await probe.measure(
      'library_album_completeness_filters',
      filterRoundTrip,
      warmup: filterRoundTrip,
    );
    await tester.runAsync(() async {
      await tester.tap(findByTooltip('Search your library').hitTestable());
      await probe.wait(const Duration(milliseconds: 400));
      FocusManager.instance.primaryFocus?.unfocus();
    });
    Future<void> librarySearchRoundTrip() async {
      final field = tester.widget<AppSearchField>(
        find.byType(AppSearchField).hitTestable(),
      );
      field.controller.text = 'Album 01';
      field.onChanged?.call('Album 01');
      await probe.wait(const Duration(milliseconds: 500));
      expect(requests.last.search, 'Album 01');
      await tester.tap(findByTooltip('Clear').hitTestable());
      await probe.wait(const Duration(milliseconds: 500));
      expect(requests.last.search, isEmpty);
    }

    await probe.measure(
      'library_album_search_clear',
      librarySearchRoundTrip,
      warmup: librarySearchRoundTrip,
    );
    await tester.runAsync(() async {
      Navigator.of(
        tester.element(find.byType(Scrollable).hitTestable().first),
      ).pop();
      await probe.wait(const Duration(milliseconds: 500));
      await select(3);
    });
    await probe.measure(
      'queue_downloads_scroll_2000_tracks',
      scrollRoundTrip,
      warmup: scrollRoundTrip,
    );

    await tester.runAsync(() => select(2));
    Future<void> searchRoundTrip() async {
      final field = tester.widget<AppSearchField>(
        find.byType(AppSearchField).hitTestable(),
      );
      for (final query in ['Fixture', 'Fixture song', 'Fixture song 1']) {
        field.controller.text = query;
        field.onChanged?.call(query);
        await probe.wait(const Duration(milliseconds: 100));
      }
      await probe.wait(const Duration(milliseconds: 900));
      expect(search._resultCount, greaterThan(0));
      await tester.tap(findByTooltip('Clear').hitTestable());
      await probe.wait(const Duration(milliseconds: 400));
      expect(field.controller.text, isEmpty);
    }

    await probe.measure(
      'home_search_input_results_clear',
      searchRoundTrip,
      warmup: searchRoundTrip,
    );
    Future<void> tabRoundTrip() async {
      for (final value in [0, 1, 2, 3, 0]) {
        await tester.tap(
          find.descendant(
            of: find.byType(MornyeTabBar),
            matching: find.text(
              ['Home', 'Library', 'Search', 'Downloads'][value],
            ),
          ),
        );
        await probe.wait(const Duration(milliseconds: 350));
        expect(index.value, value);
      }
    }

    await probe.measure(
      'lazy_tab_view_retained_production_tabs',
      tabRoundTrip,
      warmup: tabRoundTrip,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await probe.wait(const Duration(milliseconds: 350));
      await preferences.reload();
    });
    expect(preferences.getString('app_settings'), settingsBefore);
    expect(databaseCalls, isEmpty);
    await probe.finish(
      metadata: {
        'scope':
            'Production QueueTab, MornyeLibraryScreen, HomeTab, LazyTabView and MornyeTabBar; synthetic provider data, no artwork/network/database/IME.',
        'trackCount': _tracks.length,
        'albumCount': _albums.length,
        'queueCount': 2000,
        'searchResultLimit': 80,
        'browseRequests': requests.length,
        'maximumBrowseLimit': requests
            .map((request) => request.limit)
            .reduce((a, b) => a > b ? a : b),
        'searchRequests': search._requests,
        'settingsUnchanged': true,
        'databaseCalls': databaseCalls.length,
      },
    );
  });
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.index});
  final ValueNotifier<int> index;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: index,
    builder: (context, value, _) => Scaffold(
      body: LazyTabView(
        index: value,
        preloadKeys: {const ValueKey('search')},
        children: const [
          HomeTab(key: ValueKey('home'), mode: HomeTabMode.browse),
          QueueTab(key: ValueKey('library')),
          HomeTab(key: ValueKey('search'), mode: HomeTabMode.search),
          QueueTab(key: ValueKey('downloads'), librarySection: 'downloads'),
        ],
      ),
      bottomNavigationBar: MornyeTabBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.library_music),
            label: 'Library',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.download), label: 'Downloads'),
        ],
        selectedIndex: value,
        blurEnabled: true,
        onSelected: (value) {
          FocusManager.instance.primaryFocus?.unfocus();
          index.value = value;
        },
      ),
    ),
  );
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    searchProvider: 'example',
    hasSearchedBefore: true,
    defaultLibraryView: 'all',
  );

  @override
  void setHistoryFilterMode(String mode) {
    state = state.copyWith(historyFilterMode: mode);
  }

  @override
  void setHasSearchedBefore() {
    if (!state.hasSearchedBefore) {
      state = state.copyWith(hasSearchedBefore: true);
    }
  }

  @override
  void setSearchProvider(String? provider) {
    state = state.copyWith(
      searchProvider: provider,
      clearSearchProvider: provider == null || provider.isEmpty,
    );
  }
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
        hasMetadataProvider: true,
        searchBehavior: SearchBehavior(enabled: true),
      ),
    ],
  );
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState(
    sections: [
      ExploreSection(
        uri: 'example:featured',
        title: 'Featured albums',
        items: [],
      ),
    ],
  );
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<void> reloadFromStorage() async {}
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState().copyWith(
    items: [
      for (final track in _tracks)
        DownloadItem(
          id: track.id,
          track: track,
          service: 'example',
          createdAt: DateTime(2026),
        ),
    ],
  );
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

class _Profile extends UserProfileNotifier {
  @override
  Future<UserProfile> build() async => const UserProfile();
}

class _Search extends TrackNotifier {
  int _requests = 0;
  int get _resultCount => state.tracks.length;

  @override
  Future<void> customSearch(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    String? selectedFilter,
    bool allowVerificationRetry = true,
  }) async {
    _requests++;
    state = TrackState(
      hasSearchText: true,
      searchExtensionId: 'example',
      tracks: _tracks
          .where(
            (track) => track.name.toLowerCase().contains(query.toLowerCase()),
          )
          .take(80)
          .toList(),
    );
  }
}
