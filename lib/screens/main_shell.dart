import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/saf_migration_prompt_store.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/playback_notification_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/providers/preview_player_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/screens/repo_tab.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/share_intent_service.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/discord_presence_service.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/services/update_checker.dart';
import 'package:mornye/widgets/app_announcement_dialog.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/download_queue_feedback.dart';
import 'package:mornye/widgets/update_dialog.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/nav_destination_icons.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/lazy_tab_view.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/saf_download_tree.dart';

part 'main_shell_startup_prompts.dart';

final _log = AppLogger('MainShell');

/// The tab at [index] in a style's destination order.
@visibleForTesting
ShellTab shellTabAt(
  int index, {
  required bool mornye,
  required bool showStore,
}) {
  if (index == 0) return ShellTab.home;
  if (index == 1) return ShellTab.library;
  if (showStore && index == 2) return ShellTab.repository;
  if (mornye && index == (showStore ? 3 : 2)) return ShellTab.search;
  return ShellTab.settings;
}

/// Where [tab] sits in a style's destination order, or null when that style
/// has no such destination.
@visibleForTesting
int? shellIndexOfTab(
  ShellTab tab, {
  required bool mornye,
  required bool showStore,
  required bool desktop,
}) => switch (tab) {
  ShellTab.home => 0,
  ShellTab.library => 1,
  ShellTab.repository => showStore ? 2 : null,
  // Material searches from Home.
  ShellTab.search => mornye ? (showStore ? 3 : 2) : 0,
  // Mornye phones open Settings as a page, not a destination.
  ShellTab.settings =>
    !mornye
        ? (showStore ? 3 : 2)
        : desktop
        ? (showStore ? 4 : 3)
        : null,
};

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;
  final _mornyeChrome = MornyeChromeController();
  // Preserves the tab view element (and its kept-alive tabs) when the body
  // structure swaps between rail and bottom-bar layouts on rotation.
  final GlobalKey _pageViewKey = GlobalKey();
  late final PageController _pageController;
  late final AnimationController _tabJumpTransitionController;
  // Transitions update their layers directly; no shell subtree rebuilds per
  // animation frame.
  late final CurvedAnimation _tabJumpOpacity = CurvedAnimation(
    parent: _tabJumpTransitionController,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _tabJumpScale = Tween<double>(
    begin: 0.985,
    end: 1,
  ).animate(_tabJumpOpacity);
  bool _hasCheckedUpdate = false;
  bool _hasCheckedAppAnnouncement = false;
  bool _initialSafRepairComplete = false;
  bool _safRepairDialogVisible = false;
  bool _usbVolumeWarningShown = false;
  StreamSubscription<String>? _shareSubscription;
  DateTime? _lastBackPress;
  final GlobalKey<NavigatorState> _homeTabNavigatorKey =
      ShellNavigationService.homeTabNavigatorKey;
  final GlobalKey<NavigatorState> _libraryTabNavigatorKey =
      ShellNavigationService.libraryTabNavigatorKey;
  final GlobalKey<NavigatorState> _repoTabNavigatorKey =
      ShellNavigationService.repoTabNavigatorKey;
  final GlobalKey<NavigatorState> _searchTabNavigatorKey =
      ShellNavigationService.searchTabNavigatorKey;

  late final _PreviewStopNavigatorObserver _homePreviewStopObserver;
  late final _PreviewStopNavigatorObserver _libraryPreviewStopObserver;
  late final _PreviewStopNavigatorObserver _repoPreviewStopObserver;
  late final _PreviewStopNavigatorObserver _searchPreviewStopObserver;

  /// Desktop: whether Library shows its root page, so the Mornye sidebar
  /// returns to the Library root's link.
  late final _libraryDepthObserver = _PageDepthObserver(
    onRoot: () => desktopSidebarLink.value = null,
  );

  /// The style the current tab index was chosen under.
  bool? _indexStyleMornye;

  /// The two styles order their destinations differently, so switching
  /// styles keeps the same tab rather than the same index (Settings would
  /// otherwise become Mornye's Search).
  void _keepTabAcrossStyles() {
    final mornye = context.isMornye;
    final previous = _indexStyleMornye;
    _indexStyleMornye = mornye;
    if (previous == null || previous == mornye) return;
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final tab = shellTabAt(
      _currentIndex,
      mornye: previous,
      showStore: showStore,
    );
    final index =
        shellIndexOfTab(
          tab,
          mornye: mornye,
          showStore: showStore,
          desktop: isDesktopPlatform,
        ) ??
        0;
    if (index == _currentIndex) return;
    _currentIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keepTabAcrossStyles();
    final l10n = context.l10n;
    NotificationService().updateStrings(l10n);
    final playback = ref.read(musicPlayerRuntimeProvider);
    playback.updateStrings(
      unknownTitle: l10n.unknownTitle,
      unknownArtist: l10n.unknownArtist,
    );
    final settings = ref.read(settingsProvider);
    playback.configure(settings);
    unawaited(
      DiscordPresenceService.instance.setEnabled(
        settings.discordRichPresenceEnabled,
      ),
    );
    listeningRecorder.setEnabled(settings.listeningStatisticsEnabled);
    // Deezer & co. localize artist/genre names by IP unless told the app's
    // language (issue #480).
    unawaited(
      PlatformBridge.setMetadataLanguage(
        Localizations.localeOf(context).toLanguageTag(),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    usbAudioStatus.addListener(_onUsbAudioStatusChanged);
    _homePreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _libraryPreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _repoPreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _searchPreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _pageController = PageController(initialPage: _currentIndex);
    _tabJumpTransitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 1,
    );
    ShellNavigationService.registerTabSelectionHandler(
      owner: this,
      handler: _onShellTabRequested,
      libraryLinkHandler: _requestDesktopLibraryLink,
    );
    ShellNavigationService.syncState(
      currentTabIndex: _currentIndex,
      showRepoTab: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _repairSafAccessIfNeeded(
        knownLost: ref.read(initialSafAccessLostProvider),
      );
      _initialSafRepairComplete = true;
      if (!mounted) return;
      unawaited(ref.read(musicPlayerRuntimeProvider).restoreSession());
      _setupShareListener();
      await _checkSafMigration();
      final updateDialogShown = await _checkForUpdates();
      if (!updateDialogShown) {
        await _checkAppAnnouncement();
      }
    });
  }

  void _onUsbAudioStatusChanged() {
    if (usbAudioStatus.value.reason == 'active') {
      _usbVolumeWarningShown = false;
    }
    if (usbAudioStatus.value.reason != 'volume_unavailable' ||
        _usbVolumeWarningShown) {
      return;
    }
    _usbVolumeWarningShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || usbAudioStatus.value.reason != 'volume_unavailable') {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.usbVolumeUnavailable),
          duration: const Duration(seconds: 8),
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _initialSafRepairComplete) {
      unawaited(_repairSafAccessIfNeeded());
    } else if (state == AppLifecycleState.paused) {
      unawaited(
        ref.read(musicPlayerRuntimeProvider).handler?.persistCurrentSession(),
      );
    }
  }

  void _setupShareListener() {
    final pendingUrl = ShareIntentService().consumePendingUrl();
    if (pendingUrl != null) {
      _handleSharedUrl(pendingUrl);
    }

    _shareSubscription = ShareIntentService().sharedUrlStream.listen(
      (url) {
        _handleSharedUrl(url);
      },
      onError: (Object error) {
        _log.e('Share stream error: $error');
      },
      cancelOnError: false,
    );
  }

  Future<void> _handleSharedUrl(String url) async {
    if (!mounted) return;

    Navigator.of(context).popUntil((route) => route.isFirst);
    _onShellTabRequested(ShellTab.search);
    final searchNavigator = context.isMornye
        ? _searchTabNavigatorKey
        : _homeTabNavigatorKey;
    searchNavigator.currentState?.popUntil((route) => route.isFirst);
    // Mount the lazy Search page before the metadata listener handles the link.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    ref.read(settingsProvider.notifier).setHasSearchedBefore();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.loadingSharedLink)));
    }
    await ref.read(trackProvider.notifier).fetchFromUrl(url);
    final trackState = ref.read(trackProvider);
    if (trackState.error != null && mounted) {
      final l10n = context.l10n;
      final errorMsg = trackState.error!;
      final isRateLimit =
          errorMsg.contains('429') ||
          errorMsg.toLowerCase().contains('rate limit') ||
          errorMsg.toLowerCase().contains('too many requests');
      final displayMessage = errorMsg == 'url_not_recognized'
          ? l10n.errorUrlNotRecognizedMessage
          : isRateLimit
          ? l10n.errorRateLimitedMessage
          : l10n.errorUrlFetchFailed;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(displayMessage),
          // Retrying an unrecognized URL is deterministic; skip the action.
          action: errorMsg == 'url_not_recognized'
              ? null
              : SnackBarAction(
                  label: l10n.dialogRetry,
                  onPressed: () => _handleSharedUrl(url),
                ),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    usbAudioStatus.removeListener(_onUsbAudioStatusChanged);
    ShellNavigationService.unregisterTabSelectionHandler(this);
    _shareSubscription?.cancel();
    _pageController.dispose();
    _tabJumpOpacity.dispose();
    _tabJumpTransitionController.dispose();
    _mornyeChrome.dispose();
    _libraryDepthObserver.dispose();
    super.dispose();
  }

  void _resetHomeToMain() {
    ref.read(previewPlayerProvider.notifier).stop();
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final homeNavigator = _navigatorForTab(0, showStore);
    homeNavigator?.popUntil((route) => route.isFirst);
    // Unfocus BEFORE clear so _onTrackStateChanged can properly
    // clear _urlController (it checks !_searchFocusNode.hasFocus)
    FocusManager.instance.primaryFocus?.unfocus();
    if (!context.isMornye) ref.read(trackProvider.notifier).clear();
  }

  /// Mornye desktop windows show Settings as a destination after Search, in
  /// the content pane. Phones and tablets open it as a page instead.
  bool get _mornyeSettingsTab => context.isMornye && isDesktopPlatform;

  int _settingsIndex(bool showStore) =>
      context.isMornye ? (showStore ? 4 : 3) : (showStore ? 3 : 2);

  void _onShellTabRequested(ShellTab tab) {
    // Picking a destination returns from Now Playing to the content pane.
    if (isDesktopPlatform) desktopNowPlayingOpen.value = false;
    if (tab == ShellTab.settings && context.isMornye && !_mornyeSettingsTab) {
      unawaited(_openProfileSettings());
      return;
    }
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final index = switch (tab) {
      ShellTab.home => 0,
      ShellTab.search => context.isMornye ? (showStore ? 3 : 2) : 0,
      ShellTab.library => 1,
      ShellTab.repository => showStore ? 2 : null,
      ShellTab.settings => _settingsIndex(showStore),
    };
    if (index != null) _onNavTap(index, resetHome: tab != ShellTab.search);
  }

  bool _settingsPageOpen = false;

  Future<void> _openProfileSettings() async {
    if (_settingsPageOpen) return;
    _settingsPageOpen = true;
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(previewPlayerProvider.notifier).stop();
    try {
      await Navigator.of(context).push(
        slidePageRoute<void>(
          page: const Scaffold(body: SettingsTab(asPage: true)),
        ),
      );
    } finally {
      _settingsPageOpen = false;
    }
  }

  void _onNavTap(int index, {bool resetHome = true}) {
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    _mornyeChrome.expand();
    if (index == 0 && resetHome && (context.isMornye || _currentIndex == 0)) {
      _resetHomeToMain();
    }
    if (index == 0 && _currentIndex == 0) {
      return;
    }

    if (_currentIndex != index) {
      final previousIndex = _currentIndex;
      final isNonAdjacentJump = (previousIndex - index).abs() > 1;
      HapticFeedback.selectionClick();
      // Stop any preview snippet when leaving the current tab. (_onPageChanged
      // cannot do this because _currentIndex is already updated below.)
      ref.read(previewPlayerProvider.notifier).stop();
      setState(() => _currentIndex = index);
      ShellNavigationService.syncState(
        currentTabIndex: _currentIndex,
        showRepoTab: showStore,
        showSearchTab: context.isMornye,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      // Jump directly when skipping intermediate tabs to avoid
      // sliding through them. For those jumps, keep a short fade-in
      // so the transition still feels intentional.
      if (context.isMornye) {
        // The glass pill owns the tab transition. Sliding/fading the whole
        // page at the same time continuously invalidates its live backdrop.
        _tabJumpTransitionController.value = 1;
      } else if (isNonAdjacentJump) {
        _pageController.jumpToPage(index);
        _tabJumpTransitionController.forward(from: 0);
      } else {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  void _onPageChanged(int index) {
    _mornyeChrome.expand();
    if (_currentIndex != index) {
      ref.read(previewPlayerProvider.notifier).stop();
      setState(() => _currentIndex = index);
      final showStore = ref.read(
        settingsProvider.select((s) => s.showExtensionStore),
      );
      ShellNavigationService.syncState(
        currentTabIndex: _currentIndex,
        showRepoTab: showStore,
        showSearchTab: context.isMornye,
      );
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  Future<void> _handleBackPress() async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final handledByRootNavigator = await rootNavigator.maybePop();
    if (handledByRootNavigator) {
      _lastBackPress = null;
      return;
    }

    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final currentNavigator = _navigatorForTab(_currentIndex, showStore);
    final handledByCurrentNavigator =
        await currentNavigator?.maybePop() ?? false;
    if (handledByCurrentNavigator) {
      _lastBackPress = null;
      return;
    }

    if (!mounted) return;

    final trackState = ref.read(trackProvider);
    final isSearchTab =
        _currentIndex == (context.isMornye ? (showStore ? 3 : 2) : 0);

    final isKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

    if (isSearchTab &&
        trackState.isShowingRecentAccess &&
        !trackState.isLoading &&
        (trackState.hasSearchText || trackState.hasContent)) {
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(previewPlayerProvider.notifier).stop();
      ref.read(trackProvider.notifier).clear();
      _lastBackPress = null;
      return;
    }

    if (isSearchTab && trackState.isShowingRecentAccess) {
      ref.read(trackProvider.notifier).setShowingRecentAccess(false);
      FocusManager.instance.primaryFocus?.unfocus();
      _lastBackPress = null;
      return;
    }

    if (isSearchTab &&
        !trackState.isLoading &&
        (trackState.hasSearchText || trackState.hasContent)) {
      // Unfocus BEFORE clear so _onTrackStateChanged can properly
      // clear _urlController (it checks !_searchFocusNode.hasFocus)
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(previewPlayerProvider.notifier).stop();
      ref.read(trackProvider.notifier).clear();
      _lastBackPress = null;
      return;
    }

    if (isSearchTab && isKeyboardVisible) {
      FocusManager.instance.primaryFocus?.unfocus();
      _lastBackPress = null;
      return;
    }

    if (_currentIndex != 0) {
      _onNavTap(0);
      _lastBackPress = null;
      return;
    }

    if (isSearchTab && trackState.isLoading) {
      return;
    }

    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      unawaited(PlatformBridge.exitApp());
    } else {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.pressBackAgainToExit),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  ShellTab _tabForIndex(int index, bool showStore) {
    if (index == 0) return ShellTab.home;
    if (index == 1) return ShellTab.library;
    if (showStore && index == 2) return ShellTab.repository;
    if (_mornyeSettingsTab && index == _settingsIndex(showStore)) {
      return ShellTab.settings;
    }
    return context.isMornye ? ShellTab.search : ShellTab.settings;
  }

  List<DesktopDestination> _desktopDestinations({
    required bool showStore,
    required int queueCount,
    required int repoUpdatesCount,
  }) {
    final l10n = context.l10n;
    final mornye = context.isMornye;
    return [
      for (final tab in desktopDestinationTabs(
        mornye: mornye,
        showStore: showStore,
      ))
        switch (tab) {
          ShellTab.home => DesktopDestination(
            tab: tab,
            icon: mornye ? CupertinoIcons.house : Icons.home_outlined,
            selectedIcon: mornye ? CupertinoIcons.house_fill : Icons.home,
            label: l10n.navHome,
          ),
          ShellTab.library => DesktopDestination(
            tab: tab,
            icon: mornye
                ? CupertinoIcons.square_stack
                : Icons.library_music_outlined,
            selectedIcon: mornye
                ? CupertinoIcons.square_stack_fill
                : Icons.library_music,
            label: l10n.navLibrary,
            badgeCount: queueCount,
          ),
          ShellTab.repository => DesktopDestination(
            tab: tab,
            icon: mornye
                ? CupertinoIcons.square_grid_2x2
                : Icons.extension_outlined,
            selectedIcon: mornye
                ? CupertinoIcons.square_grid_2x2_fill
                : Icons.extension,
            label: l10n.navStore,
            badgeCount: repoUpdatesCount,
          ),
          ShellTab.search => DesktopDestination(
            tab: tab,
            icon: CupertinoIcons.search,
            selectedIcon: CupertinoIcons.search,
            label: l10n.mornyeSearch,
          ),
          ShellTab.settings => DesktopDestination(
            tab: tab,
            icon: mornye ? CupertinoIcons.gear_alt : Icons.settings_outlined,
            selectedIcon: mornye
                ? CupertinoIcons.gear_alt_fill
                : Icons.settings,
            label: l10n.navSettings,
          ),
        },
    ];
  }

  /// The Library pages under the Mornye desktop sidebar's Library heading,
  /// as in Music. Recently Added is the Library root.
  List<DesktopSidebarLink> _desktopLibraryLinks({required int queueCount}) {
    final l10n = context.l10n;
    return [
      DesktopSidebarLink(
        id: 'recent',
        icon: CupertinoIcons.clock,
        label: l10n.libraryRecentlyAdded,
      ),
      DesktopSidebarLink(
        id: 'artists',
        icon: CupertinoIcons.music_mic,
        label: l10n.searchArtists,
      ),
      DesktopSidebarLink(
        id: 'albums',
        icon: CupertinoIcons.square_stack,
        label: l10n.searchAlbums,
      ),
      DesktopSidebarLink(
        id: 'songs',
        icon: CupertinoIcons.music_note,
        label: l10n.searchSongs,
      ),
      DesktopSidebarLink(
        id: 'downloads',
        icon: CupertinoIcons.arrow_down_circle,
        label: l10n.libraryDownloads,
        badgeCount: queueCount,
      ),
    ];
  }

  /// The page a Mornye desktop sidebar link opens in the Library tab, or
  /// null for the Library root.
  Widget? _desktopLibraryPage(String id) {
    const playlistPrefix = 'playlist:';
    if (id.startsWith(playlistPrefix)) {
      return LibraryTracksFolderScreen(
        mode: LibraryTracksFolderMode.playlist,
        playlistId: id.substring(playlistPrefix.length),
      );
    }
    // Only the Library root links to sections from its own page.
    return switch (id) {
      'artists' => Scaffold(
        body: MornyeLibraryScreen(
          page: MornyeLibraryPage.artists,
          onOpenSection: (_) {},
        ),
      ),
      'albums' => Scaffold(
        body: MornyeLibraryScreen(
          page: MornyeLibraryPage.albums,
          onOpenSection: (_) {},
        ),
      ),
      'songs' => const Scaffold(body: QueueTab(librarySection: 'all')),
      'downloads' => const Scaffold(
        body: QueueTab(librarySection: 'downloads'),
      ),
      DesktopSidebarLink.allPlaylistsId => const Scaffold(
        body: QueueTab(librarySection: 'playlists'),
      ),
      _ => null,
    };
  }

  /// Shows a Library page or playlist picked in the Mornye desktop sidebar
  /// in the Library tab, in place of the page it showed.
  void _openDesktopLibraryLink(String id) {
    _onShellTabRequested(ShellTab.library);
    final page = _desktopLibraryPage(id);
    // The Library navigator mounts with the tab on its first visit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = _libraryTabNavigatorKey.currentState;
      if (!mounted || navigator == null) return;
      navigator.popUntil((route) => route.isFirst);
      if (page != null) {
        unawaited(
          navigator.push(MaterialPageRoute<void>(builder: (_) => page)),
        );
      }
      desktopSidebarLink.value = page == null ? null : id;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Only the Mornye desktop sidebar has Library links; Material keeps a
  /// plain Library tab request.
  bool _requestDesktopLibraryLink(String id) {
    if (!mounted || !isDesktopPlatform || !context.isMornye) return false;
    _openDesktopLibraryLink(id);
    return true;
  }

  /// Opens the profile from the Mornye desktop sidebar's account row: in
  /// the Settings detail pane, or as a page when Settings shows only its
  /// list.
  void _openDesktopProfile() {
    final profile = ref.read(userProfileProvider).value;
    _onShellTabRequested(ShellTab.settings);
    if (profile == null) return;
    // Settings registers its detail pane once it has built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator =
          ShellNavigationService.activeBackNavigator() ?? Navigator.of(context);
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => MornyeSettingsTheme(
              child: ProfileSettingsPage(profile: profile),
            ),
          ),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  NavigatorState? _navigatorForTab(int index, bool showStore) {
    if (index == 0) return _homeTabNavigatorKey.currentState;
    if (index == 1) return _libraryTabNavigatorKey.currentState;
    if (showStore && index == 2) return _repoTabNavigatorKey.currentState;
    if (context.isMornye && index == (showStore ? 3 : 2)) {
      return _searchTabNavigatorKey.currentState;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      playbackNotificationProvider((
        favorite: context.l10n.trackOptionAddToLoved,
        unfavorite: context.l10n.trackOptionRemoveFromLoved,
        shuffleOn: context.l10n.nowPlayingShuffleOn,
        shuffleOff: context.l10n.nowPlayingPlayInOrder,
      )),
    );
    ref.listen(settingsProvider, (_, settings) {
      ref.read(musicPlayerRuntimeProvider).configure(settings);
    });
    ref.listen(settingsProvider.select((s) => s.discordRichPresenceEnabled), (
      _,
      enabled,
    ) {
      unawaited(DiscordPresenceService.instance.setEnabled(enabled));
    });
    ref.listen(
      settingsProvider.select((s) => s.listeningStatisticsEnabled),
      (_, enabled) => listeningRecorder.setEnabled(enabled),
    );
    final queueState = ref.watch(
      downloadQueueProvider.select((s) => s.queuedCount),
    );
    final showStore = ref.watch(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final heroAnimationsEnabled = ref.watch(
      settingsProvider.select((s) => s.heroAnimationsEnabled),
    );
    ShellNavigationService.syncState(
      currentTabIndex: _currentIndex,
      showRepoTab: showStore,
      showSearchTab: context.isMornye,
    );
    final repoUpdatesCount = ref.watch(
      repoProvider.select((s) => s.updatesAvailableCount),
    );

    final tabs = <Widget>[
      _TabNavigator(
        key: const ValueKey('tab-home'),
        navigatorKey: _homeTabNavigatorKey,
        observers: [_homePreviewStopObserver],
        heroAnimationsEnabled: heroAnimationsEnabled,
        child: Builder(
          builder: (context) => HomeTab(
            mode: context.isMornye ? HomeTabMode.browse : HomeTabMode.combined,
          ),
        ),
      ),
      _TabNavigator(
        key: const ValueKey('tab-library'),
        navigatorKey: _libraryTabNavigatorKey,
        observers: [
          _libraryPreviewStopObserver,
          if (isDesktopPlatform) _libraryDepthObserver,
        ],
        heroAnimationsEnabled: heroAnimationsEnabled,
        child: _LibraryTabRoot(isTabActive: _currentIndex == 1),
      ),
      if (showStore)
        _TabNavigator(
          key: const ValueKey('tab-repo'),
          navigatorKey: _repoTabNavigatorKey,
          observers: [_repoPreviewStopObserver],
          heroAnimationsEnabled: heroAnimationsEnabled,
          child: const RepoTab(),
        ),
      if (!context.isMornye) const SettingsTab(),
      if (context.isMornye)
        _TabNavigator(
          key: const ValueKey('tab-search'),
          navigatorKey: _searchTabNavigatorKey,
          observers: [_searchPreviewStopObserver],
          heroAnimationsEnabled: heroAnimationsEnabled,
          child: const HomeTab(mode: HomeTabMode.search),
        ),
      if (_mornyeSettingsTab) const SettingsTab(key: ValueKey('tab-settings')),
    ];

    final l10n = context.l10n;
    final destinations = <NavigationDestination>[
      NavigationDestination(
        icon: AppIcon(
          context.isMornye ? CupertinoIcons.house_fill : Icons.home_outlined,
        ),
        selectedIcon: BouncingIcon(child: const AppIcon(Icons.home)),
        label: l10n.navHome,
      ),
      NavigationDestination(
        icon: context.isMornye
            ? MornyeNavigationIcon(
                icon: CupertinoIcons.square_stack_fill,
                badgeCount: queueState,
              )
            : AnimatedBadge(
                count: queueState,
                child: Badge(
                  isLabelVisible: queueState > 0,
                  label: Text('$queueState'),
                  child: const AppIcon(Icons.library_music_outlined),
                ),
              ),
        selectedIcon: SlidingIcon(
          child: AnimatedBadge(
            count: queueState,
            child: Badge(
              isLabelVisible: queueState > 0,
              label: Text('$queueState'),
              child: const AppIcon(Icons.library_music),
            ),
          ),
        ),
        label: l10n.navLibrary,
      ),
      if (showStore)
        NavigationDestination(
          icon: context.isMornye
              ? MornyeNavigationIcon(
                  icon: CupertinoIcons.square_grid_2x2,
                  badgeCount: repoUpdatesCount,
                )
              : AnimatedBadge(
                  count: repoUpdatesCount,
                  child: Badge(
                    isLabelVisible: repoUpdatesCount > 0,
                    label: Text('$repoUpdatesCount'),
                    child: const AppIcon(Icons.extension_outlined),
                  ),
                ),
          selectedIcon: BouncingIcon(
            child: AnimatedBadge(
              count: repoUpdatesCount,
              child: Badge(
                isLabelVisible: repoUpdatesCount > 0,
                label: Text('$repoUpdatesCount'),
                child: const AppIcon(Icons.extension),
              ),
            ),
          ),
          label: l10n.navStore,
        ),
      if (!context.isMornye)
        NavigationDestination(
          icon: const AppIcon(Icons.settings_outlined),
          selectedIcon: SpinIcon(child: const AppIcon(Icons.settings)),
          label: l10n.navSettings,
        ),
      if (context.isMornye)
        NavigationDestination(
          icon: const Icon(CupertinoIcons.search),
          label: l10n.mornyeSearch,
        ),
    ];

    final maxIndex = tabs.length - 1;
    final selectedDestination = _currentIndex.clamp(0, maxIndex);
    if (_currentIndex > maxIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _currentIndex = maxIndex);
          if (_pageController.hasClients) {
            _pageController.jumpToPage(maxIndex);
          }
        }
      });
    }

    final screenSize = MediaQuery.sizeOf(context);
    final isTablet = screenSize.shortestSide >= 600;
    // Material follows its expanded window class: landscape tablets get the
    // rail, portrait tablets keep the bottom bar. Mornye keeps a bottom tab
    // bar on tablets, compact and centered once the window is expanded, and
    // reserves the rail for desktop-width windows.
    final useNavigationRail = context.isMornye
        ? useNavigationRailForWidth(screenSize.width)
        : useMaterialNavigationRailForWidth(screenSize.width);
    final compactMornyeChrome =
        context.isMornye && screenSize.width >= expandedLayoutBreakpoint;
    final canMinimizeChrome =
        !isDesktopPlatform &&
        context.isMornye &&
        !useNavigationRail &&
        MediaQuery.viewInsetsOf(context).bottom == 0 &&
        MediaQuery.textScalerOf(context).scale(15) <= 20;

    Widget observeScroll(Widget child, int index) =>
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (canMinimizeChrome && index == _currentIndex) {
              return _mornyeChrome.handleScroll(notification);
            }
            return false;
          },
          child: child,
        );

    final pageView = KeyedSubtree(
      key: _pageViewKey,
      child: context.isMornye
          ? LazyTabView(
              index: selectedDestination,
              preloadKeys: {const ValueKey('tab-search')},
              children: [
                for (var index = 0; index < tabs.length; index++)
                  KeyedSubtree(
                    key: tabs[index].key,
                    child: observeScroll(tabs[index], index),
                  ),
              ],
            )
          : FadeTransition(
              opacity: _tabJumpOpacity,
              child: ScaleTransition(
                scale: _tabJumpScale,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: tabs.length,
                  onPageChanged: _onPageChanged,
                  physics: const NeverScrollableScrollPhysics(),
                  // TickerMode mutes animations and lets visibility-aware widgets
                  // (e.g. MotionHeaderBanner) pause when their tab is hidden —
                  // kept-alive pages otherwise keep running offscreen.
                  itemBuilder: (context, index) => _KeepAliveTabPage(
                    key: ValueKey('page-$index'),
                    child: TickerMode(
                      enabled: index == _currentIndex,
                      child: observeScroll(tabs[index], index),
                    ),
                  ),
                ),
              ),
            ),
    );

    if (isDesktopPlatform) {
      // Desktop windows: a rail (Material) or source-list sidebar (Mornye)
      // with a persistent player; no bottom tabs or touch gestures.
      final mornye = context.isMornye;
      final selectedTab = _tabForIndex(selectedDestination, showStore);
      final destinations = _desktopDestinations(
        showStore: showStore,
        // Mornye shows the queue on its Downloads link instead.
        queueCount: mornye ? 0 : queueState,
        repoUpdatesCount: repoUpdatesCount,
      );
      return DownloadQueueFeedback(
        child: Scaffold(
          body: DesktopShellLayout(
            destinations: destinations,
            selected: selectedTab,
            onSelected: _onShellTabRequested,
            libraryLinks: mornye
                ? _desktopLibraryLinks(queueCount: queueState)
                : const [],
            onOpenLibraryLink: mornye ? _openDesktopLibraryLink : null,
            onOpenProfile: mornye ? _openDesktopProfile : null,
            // The selection bar floats over the pages, not the sidebar.
            body: SelectionOverlayHost(child: pageView),
          ),
        ),
      );
    }

    final shell = SelectionOverlayHost(
      child: BackButtonListener(
        onBackButtonPressed: () async {
          await _handleBackPress();
          return true;
        },
        child: Scaffold(
          extendBody: true,
          // The tab view keeps one element across the rail<->bar structure
          // swap via _pageViewKey so rotation doesn't remount tab navigators.
          body: useNavigationRail
              ? Row(
                  children: [
                    SafeArea(
                      right: false,
                      bottom: false,
                      child: ExpressiveNavigationRail(
                        selectedIndex: selectedDestination,
                        onDestinationSelected: _onNavTap,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainer,
                        destinations: destinations,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    // Width-based layout (centered columns, grids) measures
                    // the space beside the rail rather than the whole screen.
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final mediaQuery = MediaQuery.of(context);
                          return MediaQuery(
                            data: mediaQuery
                                .copyWith(
                                  size: Size(
                                    constraints.maxWidth,
                                    mediaQuery.size.height,
                                  ),
                                )
                                .removePadding(removeLeft: true),
                            child: pageView,
                          );
                        },
                      ),
                    ),
                  ],
                )
              : pageView,
          bottomNavigationBar: Builder(
            builder: (context) {
              if (context.isMornye) {
                return ListenableBuilder(
                  listenable: Listenable.merge([
                    ShellNavigationService.chromeBrightness,
                    ShellNavigationService.chromeSurface,
                  ]),
                  builder: (context, child) => Theme(
                    data: ShellNavigationService.chromeBrightness.value == null
                        ? Theme.of(context)
                        : MornyeTheme.fromContext(
                            context,
                            brightness:
                                ShellNavigationService.chromeBrightness.value!,
                            chromeSurface:
                                ShellNavigationService.chromeSurface.value,
                          ),
                    child: child!,
                  ),
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    // iPadOS-style chrome: one compact, centered pill rather
                    // than a bar spread across a landscape tablet.
                    child: Center(
                      heightFactor: 1,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: compactMornyeChrome ? 600 : double.infinity,
                        ),
                        child: useNavigationRail
                            ? const MiniPlayer()
                            : ValueListenableBuilder<bool>(
                                valueListenable: _mornyeChrome,
                                builder: (context, collapsed, _) =>
                                    MornyeBottomBar(
                                      collapsed: canMinimizeChrome && collapsed,
                                      destinations: destinations,
                                      selectedIndex: selectedDestination,
                                      onSelected: _onNavTap,
                                      onHome: () => _onNavTap(0),
                                      onSearch:
                                          ShellNavigationService.requestSearch,
                                      blurEnabled: ref.watch(
                                        mornyeBlurEnabledProvider,
                                      ),
                                    ),
                              ),
                      ),
                    ),
                  ),
                );
              }
              final blurEnabled = ref.watch(backdropBlurEnabledProvider);
              // The mini player and the bar read as one surface, so the bar
              // takes the playing track's artwork scheme too; with nothing
              // playing both keep the app scheme. Only this scope listens
              // to the track, so a cover change does not rebuild the shell.
              return Consumer(
                builder: (context, ref, child) => PlayerArtworkTheme(
                  artUri: ref.watch(
                    currentMediaItemProvider.select(
                      (item) => item.value?.artUri?.toString(),
                    ),
                  ),
                  child: child!,
                ),
                child: Builder(
                  builder: (context) {
                    final bottomBar = Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const MiniPlayer(),
                        // The bar's container fill separates it; no divider,
                        // so the mini player and the bar read as one surface.
                        if (!useNavigationRail)
                          ExpressiveNavigationBar(
                            selectedIndex: _currentIndex.clamp(0, maxIndex),
                            onDestinationSelected: _onNavTap,
                            isTablet: isTablet,
                            backgroundColor: settingsGroupColor(
                              context,
                            ).withValues(alpha: 0.72),
                            destinations: destinations,
                          ),
                      ],
                    );
                    // The backdrop blur re-filters everything scrolling
                    // underneath on every frame; low-end devices get an
                    // opaque base instead unless the user forces blur on in
                    // appearance settings.
                    if (!blurEnabled) {
                      return ColoredBox(
                        color: settingsGroupColor(context),
                        child: bottomBar,
                      );
                    }
                    return ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        blendMode: BlendMode.src,
                        child: bottomBar,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    return DownloadQueueFeedback(child: shell);
  }
}

class _TabNavigator extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final List<NavigatorObserver> observers;
  final bool heroAnimationsEnabled;

  const _TabNavigator({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.observers = const [],
    required this.heroAnimationsEnabled,
  });

  @override
  State<_TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<_TabNavigator> {
  late final ShellChromeObserver _chromeObserver = ShellChromeObserver(
    widget.navigatorKey,
  );
  // Nested navigators get no HeroController from MaterialApp; without one,
  // Hero widgets on routes pushed inside a tab never fly.
  final HeroController _heroController =
      MaterialApp.createMaterialHeroController();
  final _nowPlayingCloser = DesktopNowPlayingCloser();

  @override
  void dispose() {
    _chromeObserver.detach();
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: widget.navigatorKey,
      observers: [
        _chromeObserver,
        if (widget.heroAnimationsEnabled) _heroController,
        if (isDesktopPlatform) _nowPlayingCloser,
        ...widget.observers,
      ],
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(builder: (_) => widget.child),
      ],
    );
  }
}

class _PreviewStopNavigatorObserver extends NavigatorObserver {
  _PreviewStopNavigatorObserver(this._onNavigate);

  final VoidCallback _onNavigate;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) {
      _onNavigate();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _onNavigate();
  }
}

/// Counts the pages in a tab navigator for the desktop shell. Navigators
/// push their first page while building, so [depth] and [onRoot] follow
/// after the frame rather than marking the shell dirty mid-build.
class _PageDepthObserver extends NavigatorObserver {
  _PageDepthObserver({this.onRoot});

  final VoidCallback? onRoot;
  final depth = ValueNotifier<int>(0);
  int _pages = 0;
  bool _scheduled = false;
  bool _disposed = false;

  void _change(int delta) {
    _pages += delta;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      depth.value = _pages;
      if (_pages <= 1) onRoot?.call();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static int _pageCount(Route<dynamic>? route) =>
      route is PageRoute<dynamic> ? 1 : 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(_pageCount(route));

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(-_pageCount(route));

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(-_pageCount(route));

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _change(_pageCount(newRoute) - _pageCount(oldRoute));

  void dispose() {
    _disposed = true;
    depth.dispose();
  }
}

class _LibraryTabRoot extends ConsumerWidget {
  final bool isTabActive;

  const _LibraryTabRoot({required this.isTabActive});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return QueueTab(isTabActive: isTabActive);
  }
}

class _KeepAliveTabPage extends StatefulWidget {
  final Widget child;

  const _KeepAliveTabPage({super.key, required this.child});

  @override
  State<_KeepAliveTabPage> createState() => _KeepAliveTabPageState();
}

class _KeepAliveTabPageState extends State<_KeepAliveTabPage>
    with AutomaticKeepAliveClientMixin<_KeepAliveTabPage> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
