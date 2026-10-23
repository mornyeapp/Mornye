import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/lazy_tab_view.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';

void main() {
  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('Home keeps its feed layout through slow startup '
          '(desktop: $desktop, Mornye: $mornye)', (tester) async {
        debugDesktopPlatformOverride = desktop;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = desktop
            ? const Size(1280, 800)
            : const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final extensions = _StartupExtensions();
        final explore = _StartupExplore();
        await _pumpStartupHome(tester, extensions, explore, mornye: mornye);

        expect(find.text('Shortcuts'), findsNothing);
        expect(find.byType(ShimmerLoading), findsOneWidget);
        // Artwork placeholders stay square: a card's side padding narrows
        // them, so their height must shrink with it.
        final artwork = find
            .byType(SkeletonBox)
            .evaluate()
            .map((element) => element.size!)
            .where((size) => size.height > 40)
            .toList();
        expect(artwork, isNotEmpty);
        for (final size in artwork) {
          expect(size.width, size.height);
        }
        final searchRect = mornye
            ? null
            : tester.getRect(find.byType(TextField));
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('Shortcuts'), findsNothing);

        extensions.update(
          const ExtensionState(
            extensions: [_feedExtension],
            isInitialized: true,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('Shortcuts'), findsNothing);
        expect(find.byType(ShimmerLoading), findsOneWidget);

        explore.update(
          const ExploreState(
            sections: [
              ExploreSection(
                uri: 'example:featured',
                title: 'Featured albums',
                items: [],
              ),
            ],
          ),
        );
        await tester.pump();
        expect(find.text('Featured albums'), findsOneWidget);
        expect(find.text('Shortcuts'), findsNothing);
        expect(find.byType(ShimmerLoading), findsNothing);
        if (searchRect != null) {
          expect(tester.getRect(find.byType(TextField)), searchRect);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final result in [
    'no extensions',
    'initialization error',
    'feed error',
    'empty feed',
  ]) {
    testWidgets('Home leaves startup loading after $result', (tester) async {
      final extensions = _StartupExtensions();
      final explore = _StartupExplore();
      await _pumpStartupHome(tester, extensions, explore);
      expect(find.byType(ShimmerLoading), findsOneWidget);
      extensions.update(
        ExtensionState(
          isInitialized: result != 'initialization error',
          error: result == 'initialization error'
              ? 'Unable to initialize'
              : null,
          extensions: result == 'feed error' || result == 'empty feed'
              ? const [_feedExtension]
              : const [],
        ),
      );
      explore.update(
        ExploreState(
          error: result == 'feed error' ? 'Offline' : null,
          lastFetched: result == 'empty feed' ? DateTime(2026, 10, 22) : null,
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(ShimmerLoading), findsNothing);
      expect(find.text('Shortcuts'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Home with its feed disabled shows local sections immediately', (
    tester,
  ) async {
    await _pumpStartupHome(
      tester,
      _StartupExtensions(),
      _StartupExplore(),
      feedDisabled: true,
    );
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.byType(ShimmerLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home can show restored feed content before extensions finish', (
    tester,
  ) async {
    final explore = _StartupExplore();
    await _pumpStartupHome(tester, _StartupExtensions(), explore);
    explore.update(
      const ExploreState(
        sections: [
          ExploreSection(
            uri: 'example:cached',
            title: 'Cached albums',
            items: [],
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Cached albums'), findsOneWidget);
    expect(find.text('Shortcuts'), findsNothing);
    expect(find.byType(ShimmerLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final desktop in [false, true]) {
    testWidgets('first search extension collapses the empty Home prompt '
        '(desktop: $desktop)', (tester) async {
      debugDesktopPlatformOverride = desktop;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = desktop
          ? const Size(1280, 800)
          : const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final extensions = _StartupExtensions();
      final homeVisible = ValueNotifier(true);
      addTearDown(homeVisible.dispose);
      final pages = PageController();
      addTearDown(pages.dispose);
      await _pumpStartupHome(
        tester,
        extensions,
        _StartupExplore(),
        mornye: false,
        homeVisible: homeVisible,
        pages: pages,
      );
      extensions.update(const ExtensionState(isInitialized: true));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);

      homeVisible.value = false;
      pages.jumpToPage(1);
      await tester.pump();
      extensions.update(
        const ExtensionState(
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
              searchBehavior: SearchBehavior(enabled: true),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      homeVisible.value = true;
      pages.jumpToPage(0);
      await tester.pump();

      expect(find.text('Shortcuts'), findsOneWidget);
      expect(tester.getTopLeft(find.byType(TextField)).dy, lessThan(300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, layout) in [
    for (final layout in ['shelf', 'featured', 'quick-pick', 'quick-pick-menu'])
      (const Size(430, 932), layout),
    (const Size(1024, 768), 'featured'),
  ]) {
    testWidgets(
      'Home $layout menu follows its source after scrolling at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              extensionProvider.overrideWith(_Extensions.new),
              exploreProvider.overrideWith(
                () => _Explore(
                  sections: List.generate(
                    6,
                    (index) => ExploreSection(
                      uri: 'example:section:$index',
                      title: 'Section $index',
                      isFeatured: layout == 'featured',
                      isYTMusicQuickPicks: layout.startsWith('quick-pick'),
                      items: [
                        ExploreItem(
                          id: 'track-$index',
                          uri: 'example:track:$index',
                          type: 'track',
                          name: 'Feed track $index',
                          artists: '',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              downloadHistoryProvider.overrideWith(_History.new),
              recentAccessProvider.overrideWith(_Recent.new),
              trackProvider.overrideWith(_Search.new),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const HomeTab(mode: HomeTabMode.browse),
            ),
          ),
        );
        await tester.pumpAndSettle();

        for (final index in [0, 5]) {
          final title = find.text('Feed track $index');
          if (index > 0) {
            await tester.scrollUntilVisible(
              title,
              300,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
          }
          final card = find
              .ancestor(
                of: title,
                matching: layout.startsWith('quick-pick')
                    ? find.byType(InkWell)
                    : find.byType(GestureDetector),
              )
              .first;
          await Scrollable.ensureVisible(tester.element(card), alignment: 0.3);
          await tester.pumpAndSettle();
          final control = layout == 'quick-pick-menu'
              ? find.descendant(of: card, matching: find.byType(IconButton))
              : card;
          final anchor = tester.getRect(control);
          await tester.tap(control);
          await tester.pumpAndSettle();

          expect(find.text('Download'), findsOneWidget);
          expect(find.text('Go to Album'), findsOneWidget);
          final menu = tester.getRect(find.byType(MornyeContextMenu));
          if (anchor.bottom + 8 + menu.height > size.height - 16 &&
              anchor.top - menu.height - 8 < 16) {
            // A tall featured card can leave no room on either side. The menu
            // stays at the bottom safe margin instead of covering the viewport.
            expect(menu.bottom, closeTo(size.height - 16, 1));
          } else {
            expect(
              menu.top,
              anyOf(
                closeTo(anchor.bottom + 8, 1),
                closeTo(anchor.top - menu.height - 8, 1),
              ),
            );
          }
          expect(menu.left, greaterThanOrEqualTo(16));
          expect(menu.right, lessThanOrEqualTo(size.width - 16));
          expect(menu.top, greaterThanOrEqualTo(16));
          expect(menu.bottom, lessThanOrEqualTo(size.height - 16));
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
          expect(find.byType(MornyeContextMenu), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Home keeps its feed while Search retains its query and results',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final search = _Search();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            extensionProvider.overrideWith(_Extensions.new),
            exploreProvider.overrideWith(_Explore.new),
            downloadHistoryProvider.overrideWith(_History.new),
            recentAccessProvider.overrideWith(_Recent.new),
            trackProvider.overrideWith(() => search),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const _Tabs(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Featured albums'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Recently visited artist'), findsNothing);

      await tester.tap(find.text('Open Search'));
      await tester.pumpAndSettle();
      expect(find.text('Search'), findsWidgets);
      expect(find.text('Featured albums').hitTestable(), findsNothing);
      expect(find.text('Recently visited artist'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Example');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Example',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(search._requests, 1);
      expect(find.text('Found artist'), findsOneWidget);

      await tester.tap(find.text('Open Home'));
      await tester.pumpAndSettle();
      expect(find.text('Featured albums'), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(find.text('Found artist').hitTestable(), findsNothing);

      await tester.tap(find.text('Open Search'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Example',
      );
      expect(find.text('Found artist'), findsOneWidget);
      expect(search._requests, 1);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Found artist'), findsNothing);
      expect(find.text('Recently visited artist'), findsOneWidget);
      expect(find.text('Featured albums').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed verification search can retry the same query', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final search = _Search(failFirst: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          trackProvider.overrideWith(() => search),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const _Tabs(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Example');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(search._requests, 1);
    expect(find.text('Found artist'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(search._requests, 2);
    expect(find.text('Found artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Search lists collection sections and guards missing sources', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          trackProvider.overrideWith(_CollectionSearch.new),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: HomeTab(mode: HomeTabMode.search)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Example');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // The filter chips repeat these labels above the section headers.
    final headers = [
      for (final title in ['Artists', 'Albums', 'Playlists'])
        tester.getTopLeft(find.text(title).last).dy,
    ];
    expect(headers, orderedEquals([...headers]..sort()));
    expect(find.text('Sort'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Sort')).dy,
      closeTo(tester.getCenter(find.text('Artists').last).dy, 24),
    );
    for (final kind in ['artist', 'album', 'playlist']) {
      expect(find.byKey(ValueKey('$kind-$kind-0')), findsOneWidget);
      await tester.tap(find.text('Found $kind'));
      await tester.pump();
      expect(
        find.text('Cannot load $kind: missing extension source'),
        findsOneWidget,
      );
      ScaffoldMessenger.of(
        tester.element(find.byType(HomeTab)),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }
    expect(find.byType(HomeTab), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (brightness, itemType) in [
    for (final brightness in Brightness.values)
      for (final itemType in ['artist', 'track']) (brightness, itemType),
  ]) {
    testWidgets(
      'Search keeps field glass and scrolls $itemType results without blur in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(430, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final search = _Search(resultCount: 120, itemType: itemType);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              extensionProvider.overrideWith(_Extensions.new),
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
              trackProvider.overrideWith(() => search),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(brightness),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const HomeTab(mode: HomeTabMode.search),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AppSearchField),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        await tester.enterText(find.byType(TextField), 'Example');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('Found $itemType 0'), findsOneWidget);
        expect(find.text('Found $itemType 119'), findsNothing);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('Found $itemType 0'),
              matching: find.byType(MornyeGlassPanel),
            ),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );

        await tester.scrollUntilVisible(
          find.text('Found $itemType 119'),
          500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Found $itemType 119').hitTestable(), findsOneWidget);
        expect(search._requests, 1);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('Found $itemType 119'),
              matching: find.byType(MornyeGlassPanel),
            ),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Search builds recent items as they enter the viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(() => _Recent(itemCount: 10)),
          trackProvider.overrideWith(_Search.new),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeTab(mode: HomeTabMode.search),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recent artist 0'), findsOneWidget);
    expect(find.text('Recent artist 9'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Recent artist 9'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Recent artist 9').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mornye desktop Search centers the field over a row of recent '
      'cards and can search the library instead', (tester) async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final libraryQueries = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(
            () => _Explore(
              sections: [
                for (final title in ['New releases', 'Empty section'])
                  ExploreSection(
                    uri: 'example:$title',
                    title: title,
                    items: [
                      if (title == 'New releases')
                        for (var index = 0; index < 3; index++)
                          ExploreItem(
                            id: 'album-$index',
                            uri: 'example:album:$index',
                            type: 'album',
                            name: 'Browse album $index',
                            artists: '',
                          ),
                    ],
                  ),
              ],
            ),
          ),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(() => _Recent(itemCount: 6)),
          trackProvider.overrideWith(_Search.new),
          librarySearchProvider.overrideWith((ref, request) async {
            libraryQueries.add(request.query);
            return switch (request.kind) {
              LibrarySearchKind.songs || LibrarySearchKind.artists => [
                LibrarySearchHit(
                  kind: request.kind,
                  id: 'owned',
                  title: 'Owned ${request.kind.name} ${request.query}',
                ),
              ],
              _ => [],
            };
          }),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeTab(mode: HomeTabMode.search),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search'), findsNothing);
    final field = tester.getRect(find.byType(AppSearchField));
    expect(field.center.dx, closeTo(640, 1));
    expect(find.text('Recently Searched'), findsOneWidget);

    final cards = find.byKey(const ValueKey('recent-access-cards'));
    expect(cards, findsOneWidget);
    final first = tester.getRect(find.text('Recent artist 0'));
    final second = tester.getRect(find.text('Recent artist 1'));
    expect(second.top, closeTo(first.top, 1));
    expect(second.left, greaterThan(first.right));

    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Empty section'), findsNothing);
    expect(find.text('New releases'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browse-example:New releases')));
    await tester.pumpAndSettle();
    expect(find.text('Browse album 2'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('search-scope')),
        matching: find.text('Library'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Search Your Library'), findsOneWidget);
    expect(find.text('Recently Searched'), findsNothing);
    expect(find.text('Browse'), findsNothing);

    await tester.enterText(find.byType(TextField), 'song');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(libraryQueries, contains('song'));
    expect(find.text('Search Your Library'), findsNothing);
    // Artists lead as artwork; songs follow as rows, with no filter chips.
    final artist = tester.getRect(find.text('Owned artists song'));
    final song = tester.getRect(find.text('Owned songs song'));
    expect(artist.top, lessThan(song.top));
    expect(find.text('All'), findsNothing);

    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Owned songs song'), findsNothing);
    expect(find.text('Found artist'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final withSearchExtension in [false, true]) {
    testWidgets('Mornye Home without a feed shows its sections '
        '(search extension: $withSearchExtension)', (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            extensionProvider.overrideWith(
              withSearchExtension ? _Extensions.new : _NoExtensions.new,
            ),
            exploreProvider.overrideWith(() => _Explore(sections: const [])),
            downloadHistoryProvider.overrideWith(_History.new),
            recentAccessProvider.overrideWith(_Recent.new),
            trackProvider.overrideWith(_Search.new),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const HomeTab(mode: HomeTabMode.browse),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Shortcuts'), findsOneWidget);
      expect(find.text('No search providers yet'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Tabs extends StatefulWidget {
  const _Tabs();

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int _index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LazyTabView(
      index: _index,
      children: [
        TickerMode(
          key: const ValueKey('home'),
          enabled: _index == 0,
          child: const HomeTab(mode: HomeTabMode.browse),
        ),
        TickerMode(
          key: const ValueKey('search'),
          enabled: _index == 1,
          child: const HomeTab(mode: HomeTabMode.search),
        ),
      ],
    ),
    bottomNavigationBar: Row(
      children: [
        for (final (index, label) in [(0, 'Open Home'), (1, 'Open Search')])
          TextButton(
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _index = index);
            },
            child: Text(label),
          ),
      ],
    ),
  );
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(searchProvider: 'example', hasSearchedBefore: true);
}

const _feedExtension = Extension(
  id: 'example',
  name: 'example',
  displayName: 'Example',
  version: '1.0.0',
  description: '',
  enabled: true,
  status: 'loaded',
  capabilities: {'homeFeed': true},
  searchBehavior: SearchBehavior(enabled: true),
);

Future<void> _pumpStartupHome(
  WidgetTester tester,
  _StartupExtensions extensions,
  _StartupExplore explore, {
  bool mornye = true,
  bool feedDisabled = false,
  ValueNotifier<bool>? homeVisible,
  PageController? pages,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      settingsProvider.overrideWith(() => _StartupSettings(feedDisabled)),
      extensionProvider.overrideWith(() => extensions),
      exploreProvider.overrideWith(() => explore),
      downloadHistoryProvider.overrideWith(_History.new),
      recentAccessProvider.overrideWith(_Recent.new),
      trackProvider.overrideWith(_Search.new),
    ],
    child: MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: homeVisible == null
          ? HomeTab(mode: mornye ? HomeTabMode.browse : HomeTabMode.combined)
          : ValueListenableBuilder(
              valueListenable: homeVisible,
              builder: (context, visible, _) => PageView(
                controller: pages,
                children: [
                  TickerMode(
                    enabled: visible,
                    child: HomeTab(
                      key: const ValueKey('home'),
                      mode: mornye ? HomeTabMode.browse : HomeTabMode.combined,
                    ),
                  ),
                  const Scaffold(key: ValueKey('other')),
                ],
              ),
            ),
    ),
  ),
);

class _StartupSettings extends _Settings {
  _StartupSettings(this.feedDisabled);

  final bool feedDisabled;

  @override
  AppSettings build() => super.build().copyWith(
    homeFeedProvider: feedDisabled ? AppSettings.homeFeedProviderOff : null,
  );
}

class _StartupExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();

  void update(ExtensionState next) => state = next;
}

class _StartupExplore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();

  void update(ExploreState next) => state = next;

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
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

class _NoExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

class _Explore extends ExploreNotifier {
  _Explore({List<ExploreSection>? sections})
    : _sections =
          sections ??
          const [
            ExploreSection(
              uri: 'example:featured',
              title: 'Featured albums',
              items: [],
            ),
          ];

  final List<ExploreSection> _sections;

  @override
  ExploreState build() => ExploreState(sections: _sections);
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  _Recent({this.itemCount = 1});

  final int itemCount;

  @override
  RecentAccessState build() => RecentAccessState(
    isLoaded: true,
    items: List.generate(
      itemCount,
      (index) => RecentAccessItem(
        id: 'recent-$index',
        name: itemCount == 1
            ? 'Recently visited artist'
            : 'Recent artist $index',
        type: RecentAccessType.artist,
        accessedAt: DateTime(2026, 1, itemCount - index),
        providerId: 'example',
      ),
    ),
  );
}

class _CollectionSearch extends TrackNotifier {
  @override
  Future<void> customSearch(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    String? selectedFilter,
    bool allowVerificationRetry = true,
  }) async {
    state = TrackState(
      hasSearchText: true,
      searchExtensionId: 'example',
      tracks: [
        for (final kind in ['playlist', 'album', 'artist'])
          Track(
            id: '$kind-0',
            name: 'Found $kind',
            artistName: '',
            albumName: '',
            duration: 0,
            itemType: kind,
          ),
      ],
    );
  }
}

class _Search extends TrackNotifier {
  _Search({
    bool failFirst = false,
    this.resultCount = 1,
    this.itemType = 'artist',
  }) : _failFirst = failFirst;

  final bool _failFirst;
  final int resultCount;
  final String itemType;
  int _requests = 0;

  @override
  Future<void> customSearch(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    String? selectedFilter,
    bool allowVerificationRetry = true,
  }) async {
    _requests++;
    if (_failFirst && _requests == 1) {
      state = const TrackState(
        hasSearchText: true,
        error: 'verification_required',
      );
      return;
    }
    state = TrackState(
      hasSearchText: true,
      searchExtensionId: 'example',
      tracks: List.generate(
        resultCount,
        (index) => Track(
          id: '$itemType-$index',
          name: resultCount == 1 ? 'Found $itemType' : 'Found $itemType $index',
          artistName: '',
          albumName: '',
          duration: 0,
          itemType: itemType,
          source: 'example',
        ),
      ),
    );
  }
}
