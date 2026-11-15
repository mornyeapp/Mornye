import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/widgets/view_queue_snackbar_action.dart';

void main() {
  for (final (separateSearch, showRepo) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'first search request reaches the lazy page (separate=$separateSearch, repo=$showRepo)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: _SearchShell(
              separateSearch: separateSearch,
              showRepo: showRepo,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);

        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      },
    );

    testWidgets(
      'search returns from an album to its own tab (separate=$separateSearch, repo=$showRepo)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: _SearchShell(
              separateSearch: separateSearch,
              showRepo: showRepo,
            ),
          ),
        );
        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        final navigator =
            (separateSearch
                    ? ShellNavigationService.searchTabNavigatorKey
                    : ShellNavigationService.homeTabNavigatorKey)
                .currentState!;
        expect(ShellNavigationService.activeTabNavigator(), same(navigator));
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Album')),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        expect(find.text('Album'), findsNothing);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      },
    );
  }

  testWidgets(
    'search selects its tab before requesting focus and stops when shell is absent',
    (tester) async {
      final owner = Object();
      ShellNavigationService.syncState(currentTabIndex: 0, showRepoTab: false);
      var selectedSearch = false;
      var focusRequests = 0;
      void onSearch() {
        expect(selectedSearch, isTrue);
        focusRequests++;
      }

      ShellNavigationService.searchRequests.addListener(onSearch);
      addTearDown(() {
        ShellNavigationService.searchRequests.removeListener(onSearch);
        ShellNavigationService.unregisterTabSelectionHandler(owner);
      });
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => selectedSearch = tab == ShellTab.search,
      );
      ShellNavigationService.requestSearch();
      expect(focusRequests, 0);
      await tester.pump();
      expect(focusRequests, 1);
      ShellNavigationService.unregisterTabSelectionHandler(owner);
      ShellNavigationService.requestSearch();
      expect(focusRequests, 1);
    },
  );

  group('ShellNavigationService tab requests', () {
    test('forwards a named tab request to the registered shell', () {
      final owner = Object();
      ShellTab? requestedTab;
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );

      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => requestedTab = tab,
      );

      expect(ShellNavigationService.requestTab(ShellTab.library), isTrue);
      expect(requestedTab, ShellTab.library);
    });

    test('does not remove a newer shell handler', () {
      final oldOwner = Object();
      final currentOwner = Object();
      ShellTab? requestedTab;
      addTearDown(
        () =>
            ShellNavigationService.unregisterTabSelectionHandler(currentOwner),
      );

      ShellNavigationService.registerTabSelectionHandler(
        owner: oldOwner,
        handler: (_) {},
      );
      ShellNavigationService.registerTabSelectionHandler(
        owner: currentOwner,
        handler: (tab) => requestedTab = tab,
      );

      ShellNavigationService.unregisterTabSelectionHandler(oldOwner);

      expect(ShellNavigationService.requestTab(ShellTab.settings), isTrue);
      expect(requestedTab, ShellTab.settings);
    });

    test('reports when no shell can handle the request', () {
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (_) {},
      );
      ShellNavigationService.unregisterTabSelectionHandler(owner);

      expect(ShellNavigationService.requestTab(ShellTab.library), isFalse);
    });

    testWidgets('View Queue snackbar action requests the Library tab', (
      tester,
    ) async {
      final owner = Object();
      ShellTab? requestedTab;
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => requestedTab = tab,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => buildViewQueueSnackBarAction(context),
            ),
          ),
        ),
      );

      await tester.tap(find.text('View Queue'));

      expect(requestedTab, ShellTab.library);
    });
  });
}

class _SearchShell extends StatefulWidget {
  const _SearchShell({required this.separateSearch, required this.showRepo});

  final bool separateSearch;
  final bool showRepo;

  @override
  State<_SearchShell> createState() => _SearchShellState();
}

class _SearchShellState extends State<_SearchShell> {
  final _pages = PageController(initialPage: 1);
  GlobalKey<NavigatorState> get _navigatorKey => widget.separateSearch
      ? ShellNavigationService.searchTabNavigatorKey
      : ShellNavigationService.homeTabNavigatorKey;
  int get _searchIndex => widget.separateSearch ? (widget.showRepo ? 3 : 2) : 0;
  late final _observer = ShellChromeObserver(_navigatorKey);

  @override
  void initState() {
    super.initState();
    ShellNavigationService.syncState(
      currentTabIndex: 1,
      showRepoTab: widget.showRepo,
      showSearchTab: widget.separateSearch,
    );
    ShellNavigationService.registerTabSelectionHandler(
      owner: this,
      handler: (_) {
        ShellNavigationService.syncState(
          currentTabIndex: _searchIndex,
          showRepoTab: widget.showRepo,
          showSearchTab: widget.separateSearch,
        );
        _pages.jumpToPage(_searchIndex);
      },
    );
  }

  @override
  void dispose() {
    ShellNavigationService.unregisterTabSelectionHandler(this);
    _observer.detach();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: ShellNavigationService.requestSearch,
          child: const Text('Search'),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: widget.separateSearch ? _searchIndex + 1 : 2,
            itemBuilder: (_, index) => index != _searchIndex
                ? const Text('Library')
                : Navigator(
                    key: _navigatorKey,
                    observers: [_observer],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const _SearchHome(),
                    ),
                  ),
          ),
        ),
      ],
    ),
  );
}

class _SearchHome extends StatefulWidget {
  const _SearchHome();

  @override
  State<_SearchHome> createState() => _SearchHomeState();
}

class _SearchHomeState extends State<_SearchHome> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    ShellNavigationService.searchRequests.addListener(_onSearch);
  }

  void _onSearch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    ShellNavigationService.searchRequests.removeListener(_onSearch);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: TextField(focusNode: _focus));
}
