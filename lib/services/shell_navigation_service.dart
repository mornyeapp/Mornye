import 'package:flutter/widgets.dart';

enum ShellTab { home, library, repository, settings, search }

class ShellNavigationService {
  static final searchRequests = ValueNotifier<int>(0);
  static final chromeBrightness = ValueNotifier<Brightness?>(null);
  static final chromeSurface = ValueNotifier<Color?>(null);

  /// The artwork of the visible page's hero, which the desktop sidebar shows
  /// blurred under its tint.
  static final chromeBackdrop = ValueNotifier<String?>(null);

  /// How far the visible page has scrolled its hero.
  static final chromeBackdropOffset = ValueNotifier<double>(0);
  static final _visiblePages = <GlobalKey<NavigatorState>, Route<dynamic>?>{};
  static final _chromeScopes =
      <
        Object,
        ({
          ModalRoute<dynamic> route,
          Brightness brightness,
          Color? surface,
          String? backdrop,
        })
      >{};
  static final _backdropOffsets = <Object, double>{};
  static Object? _chromeOwner;
  static bool _chromeUpdateScheduled = false;
  static int _searchGeneration = 0;

  static void setChromeBrightness({
    required Object owner,
    required ModalRoute<dynamic> route,
    required Brightness brightness,
    Color? surface,
    String? backdrop,
  }) {
    final scope = (
      route: route,
      brightness: brightness,
      surface: surface,
      backdrop: backdrop,
    );
    if (_chromeScopes[owner] == scope) return;
    _chromeScopes[owner] = scope;
    _scheduleChromeUpdate();
  }

  static void clearChromeBrightness(Object owner) {
    _chromeScopes.remove(owner);
    _backdropOffsets.remove(owner);
    _scheduleChromeUpdate();
  }

  /// Records a page's scroll, kept per page so returning to a scrolled page
  /// puts the sidebar's artwork back where the hero is.
  static void setChromeBackdropOffset(Object owner, double offset) {
    _backdropOffsets[owner] = offset;
    if (identical(owner, _chromeOwner)) chromeBackdropOffset.value = offset;
  }

  static void _scheduleChromeUpdate() {
    if (_chromeUpdateScheduled) return;
    _chromeUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chromeUpdateScheduled = false;
      final activePage = _visiblePages[_activeTabNavigatorKey()];
      Brightness? brightness;
      Color? surface;
      String? backdrop;
      Object? owner;
      for (final MapEntry(key: scopeOwner, value: scope)
          in _chromeScopes.entries) {
        if (identical(scope.route, activePage)) {
          brightness = scope.brightness;
          surface = scope.surface;
          backdrop = scope.backdrop;
          owner = scopeOwner;
        }
      }
      _chromeOwner = owner;
      chromeBrightness.value = brightness;
      chromeSurface.value = surface;
      chromeBackdrop.value = backdrop;
      chromeBackdropOffset.value = _backdropOffsets[owner] ?? 0;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static void requestSearch() {
    if (!requestTab(ShellTab.search)) return;
    final generation = ++_searchGeneration;
    final owner = _tabSelectionOwner;
    // PageView creates Search lazily. Deliver the request after its navigator
    // and focus listener mount, rather than losing the first tap on another tab.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _searchGeneration ||
          !identical(owner, _tabSelectionOwner) ||
          _currentTabIndex != (_showSearchTab ? (_showRepoTab ? 3 : 2) : 0)) {
        return;
      }
      final navigatorKey = _showSearchTab
          ? searchTabNavigatorKey
          : homeTabNavigatorKey;
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
      searchRequests.value++;
      // Search scrolls to its field and requests focus after layout.
      // Scheduling that frame avoids waiting for another tap to wake it up.
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static final GlobalKey<NavigatorState> homeTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> libraryTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> repoTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> searchTabNavigatorKey =
      GlobalKey<NavigatorState>();

  static int _currentTabIndex = 0;
  static bool _showRepoTab = false;
  static bool _showSearchTab = false;
  static Object? _tabSelectionOwner;
  static ValueChanged<ShellTab>? _tabSelectionHandler;
  static bool Function(String id)? _libraryLinkHandler;

  static void registerTabSelectionHandler({
    required Object owner,
    required ValueChanged<ShellTab> handler,
    bool Function(String id)? libraryLinkHandler,
  }) {
    _tabSelectionOwner = owner;
    _tabSelectionHandler = handler;
    _libraryLinkHandler = libraryLinkHandler;
  }

  static void unregisterTabSelectionHandler(Object owner) {
    if (!identical(_tabSelectionOwner, owner)) return;
    _tabSelectionOwner = null;
    _tabSelectionHandler = null;
    _libraryLinkHandler = null;
    resetHistory();
  }

  static bool requestTab(ShellTab tab) {
    final handler = _tabSelectionHandler;
    if (handler == null) return false;
    handler(tab);
    return true;
  }

  /// Opens a Library sidebar link (`downloads`, `songs`, ...) where the
  /// shell has them, the Mornye desktop sidebar. Returns false elsewhere, so
  /// callers fall back to [requestTab].
  static bool requestLibraryLink(String id) =>
      _libraryLinkHandler?.call(id) ?? false;

  static void syncState({
    required int currentTabIndex,
    required bool showRepoTab,
    bool showSearchTab = false,
  }) {
    if (_currentTabIndex == currentTabIndex &&
        _showRepoTab == showRepoTab &&
        _showSearchTab == showSearchTab) {
      return;
    }
    _currentTab ??= _tabAtCurrentIndex();
    _currentTabIndex = currentTabIndex;
    _showRepoTab = showRepoTab;
    _showSearchTab = showSearchTab;
    // Every destination change reaches the shell here, whether it came from
    // the sidebar, a shortcut or a link, so history records it here too.
    recordTabVisit(_tabAtCurrentIndex());
    _scheduleChromeUpdate();
  }

  static GlobalKey<NavigatorState>? _activeTabNavigatorKey() {
    if (_currentTabIndex == 0) return homeTabNavigatorKey;
    if (_currentTabIndex == 1) return libraryTabNavigatorKey;
    if (_showRepoTab && _currentTabIndex == 2) {
      return repoTabNavigatorKey;
    }
    if (_showSearchTab && _currentTabIndex == (_showRepoTab ? 3 : 2)) {
      return searchTabNavigatorKey;
    }
    return null;
  }

  static Object? _settingsDetailOwner;
  static ValueGetter<NavigatorState?>? _settingsDetailNavigator;

  /// Registers the desktop Settings detail pane, whose pages Escape and Back
  /// close while Settings is the active destination.
  static void registerSettingsDetailNavigator({
    required Object owner,
    required ValueGetter<NavigatorState?> navigator,
  }) {
    _settingsDetailOwner = owner;
    _settingsDetailNavigator = navigator;
  }

  static void unregisterSettingsDetailNavigator(Object owner) {
    if (!identical(_settingsDetailOwner, owner)) return;
    _settingsDetailOwner = null;
    _settingsDetailNavigator = null;
  }

  static NavigatorState? activeTabNavigator() =>
      _activeTabNavigatorKey()?.currentState;

  /// The navigator whose pages Back closes in the active destination.
  /// Settings has no tab navigator; on desktop its detail pane stands in.
  static NavigatorState? activeBackNavigator() {
    final key = _activeTabNavigatorKey();
    if (key != null) return key.currentState;
    return _settingsDetailNavigator?.call();
  }

  static final List<ShellTab> _backHistory = <ShellTab>[];
  static final List<ShellTab> _forwardHistory = <ShellTab>[];
  static ShellTab? _currentTab;
  static bool _isNavigatingHistory = false;

  static ShellTab _tabAtCurrentIndex() {
    if (_currentTabIndex == 0) return ShellTab.home;
    if (_currentTabIndex == 1) return ShellTab.library;
    if (_showRepoTab && _currentTabIndex == 2) return ShellTab.repository;
    if (_showSearchTab && _currentTabIndex == (_showRepoTab ? 3 : 2)) {
      return ShellTab.search;
    }
    return ShellTab.settings;
  }

  /// Records a destination visit into navigation history.
  static void recordTabVisit(ShellTab tab) {
    if (_isNavigatingHistory) return;
    if (_currentTab == null) {
      _currentTab = tab;
      return;
    }
    if (_currentTab == tab) return;
    _backHistory.add(_currentTab!);
    _forwardHistory.clear();
    _currentTab = tab;
  }

  /// Whether destination history has an earlier destination. Pages inside
  /// the active destination are closed by the caller before this applies.
  static bool get canNavigateBack => _backHistory.any(_canRevisit);

  /// Whether destination history has a later destination.
  static bool get canNavigateForward => _forwardHistory.any(_canRevisit);

  /// Returns to the previously visited destination.
  static bool navigateBack() => _travel(_backHistory, _forwardHistory);

  /// Returns to the destination left by [navigateBack].
  static bool navigateForward() => _travel(_forwardHistory, _backHistory);

  /// A destination can disappear after a visit (the Store hidden), and
  /// history must not step onto the destination already shown.
  static bool _canRevisit(ShellTab tab) =>
      tab != _currentTab && (tab != ShellTab.repository || _showRepoTab);

  static bool _travel(List<ShellTab> from, List<ShellTab> to) {
    while (from.isNotEmpty && !_canRevisit(from.last)) {
      from.removeLast();
    }
    if (from.isEmpty) return false;
    final target = from.removeLast();
    final current = _currentTab;
    if (current != null) to.add(current);
    _isNavigatingHistory = true;
    try {
      _currentTab = target;
      // Switch destinations as they were left; requestSearch would also
      // reset Search to its field.
      requestTab(target);
    } finally {
      _isNavigatingHistory = false;
    }
    return true;
  }

  @visibleForTesting
  static void resetHistory({ShellTab? initialTab}) {
    _backHistory.clear();
    _forwardHistory.clear();
    _currentTab = initialTab;
    _isNavigatingHistory = false;
  }

  @visibleForTesting
  static List<ShellTab> get backHistoryForTesting =>
      List.unmodifiable(_backHistory);

  @visibleForTesting
  static List<ShellTab> get forwardHistoryForTesting =>
      List.unmodifiable(_forwardHistory);

  @visibleForTesting
  static ShellTab get currentTabForTesting => _currentTab ?? ShellTab.home;
}

/// Track the top page in each tab. Dialogs keep the underlying page's contrast;
/// a pushed album, another tab, or a back gesture restores its own appearance.
class ShellChromeObserver extends NavigatorObserver {
  ShellChromeObserver(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  final _routes = <Route<dynamic>>[];

  void _update() {
    Route<dynamic>? page;
    for (final route in _routes.reversed) {
      if (route is PageRoute<dynamic>) {
        page = route;
        break;
      }
    }
    ShellNavigationService._visiblePages[navigatorKey] = page;
    ShellNavigationService._scheduleChromeUpdate();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _update();
  }

  void detach() {
    _routes.clear();
    ShellNavigationService._visiblePages.remove(navigatorKey);
    ShellNavigationService._scheduleChromeUpdate();
  }
}
