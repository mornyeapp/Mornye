import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixed_settings.dart';

/// Search results of every kind from one provider-neutral extension, for
/// the Home search layout suites.

/// The filters an extension may declare: Songs and every collection kind.
const searchFixtureAllFilters = [
  SearchFilter(id: 'track', label: 'Songs filter'),
  SearchFilter(id: 'artist', label: 'Artists filter'),
  SearchFilter(id: 'album', label: 'Albums filter'),
  SearchFilter(id: 'playlist', label: 'Playlists filter'),
];

/// The filters of an extension that offers no Songs filter.
const searchFixtureCollectionFilters = [
  SearchFilter(id: 'artist', label: 'Artists filter'),
  SearchFilter(id: 'album', label: 'Albums filter'),
  SearchFilter(id: 'playlist', label: 'Playlists filter'),
];

class SearchFixtureExtensions extends ExtensionNotifier {
  SearchFixtureExtensions([this.filters = const []]);

  final List<SearchFilter> filters;

  @override
  ExtensionState build() => ExtensionState(
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
        searchBehavior: SearchBehavior(enabled: true, filters: filters),
      ),
    ],
  );
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

/// A result named `Found $kind $index`. Collections carry no source, so
/// opening one shows the missing source notice instead of loading a page.
Track searchFixtureItem(
  String kind,
  int index, {
  String? coverUrl,
  String? source,
}) => Track(
  id: '$kind-$index',
  name: 'Found $kind $index',
  artistName: kind == 'artist' ? '' : 'Example artist $index',
  albumName: kind == 'track' ? 'Example album $index' : '',
  duration: kind == 'track' ? 180 + index : 0,
  itemType: kind,
  coverUrl: coverUrl,
  source: source,
);

/// Answers every search with [count] results per kind, or with the kind of
/// the chosen filter only. Records each filter it was asked for.
class SearchFixtureResults extends TrackNotifier {
  SearchFixtureResults({
    this.count = 2,
    this.songCount = 3,
    this.coverUrl,
    this.holdLoading = false,
  });

  final int count;
  final int songCount;
  final String? coverUrl;

  /// Leaves every search loading, for the skeletons.
  final bool holdLoading;
  final requestedFilters = <String?>[];

  @override
  Future<void> customSearch(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    String? selectedFilter,
    bool allowVerificationRetry = true,
  }) async {
    requestedFilters.add(selectedFilter);
    final currentFilter = selectedFilter ?? state.selectedSearchFilter;
    if (holdLoading) {
      state = TrackState(
        isLoading: true,
        hasSearchText: true,
        selectedSearchFilter: currentFilter,
      );
      return;
    }
    final kinds = switch (selectedFilter) {
      null => const ['artist', 'album', 'playlist', 'track'],
      final filter => [filter],
    };
    state = TrackState(
      hasSearchText: true,
      searchExtensionId: 'example',
      selectedSearchFilter: currentFilter,
      tracks: [
        for (final kind in kinds)
          for (var i = 0; i < (kind == 'track' ? songCount : count); i++)
            searchFixtureItem(
              kind,
              i,
              coverUrl: coverUrl,
              source: kind == 'track' ? 'example' : null,
            ),
      ],
    );
  }
}

/// Pumps the Search tab at [size], searches for "Example" and settles.
Future<void> pumpSearchFixture(
  WidgetTester tester, {
  required Size size,
  required bool mornye,
  bool desktop = false,
  Brightness brightness = Brightness.dark,
  SearchFixtureResults? results,
  List<SearchFilter> filters = const [],
  AppSettings settings = const AppSettings(
    searchProvider: 'example',
    hasSearchedBefore: true,
  ),
  TextDirection textDirection = TextDirection.ltr,
}) async {
  SharedPreferences.setMockInitialValues({});
  debugDesktopPlatformOverride = desktop;
  addTearDown(() => debugDesktopPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // A fresh scope for each call, as its overrides differ.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
        extensionProvider.overrideWith(() => SearchFixtureExtensions(filters)),
        exploreProvider.overrideWith(_Explore.new),
        downloadHistoryProvider.overrideWith(_History.new),
        downloadHistoryBatchExistsProvider.overrideWith(
          (ref, request) async => <String>{},
        ),
        downloadQueueLookupProvider.overrideWith(
          (ref) => DownloadQueueState().lookup,
        ),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(null),
        ),
        recentAccessProvider.overrideWith(_Recent.new),
        trackProvider.overrideWith(() => results ?? SearchFixtureResults()),
      ],
      child: MaterialApp(
        theme: mornye
            ? MornyeTheme.build(brightness)
            : (brightness == Brightness.dark
                  ? AppTheme.dark()
                  : AppTheme.light()),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            Directionality(textDirection: textDirection, child: child!),
        home: const Scaffold(body: HomeTab(mode: HomeTabMode.search)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'Example');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  if (results?.holdLoading ?? false) {
    // Skeletons shimmer until the results arrive, so they never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}
