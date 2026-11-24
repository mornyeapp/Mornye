import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:mornye/controllers/open_audio_controller.dart';
import 'package:mornye/services/audio_file_open_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/saf_migration_prompt_store.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_auto_update_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/network_upload_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/playback_notification_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/providers/preview_player_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/library_directory_screen.dart';
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
import 'package:mornye/widgets/player_underlay.dart';
import 'package:mornye/widgets/tv_shell.dart';
import 'package:mornye/widgets/lazy_tab_view.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/page_transitions.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/search_moved_hint.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_link_transfer_actions.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/saf_download_tree.dart';

part 'main_shell_startup_prompts.dart';

final _log = AppLogger('MainShell');
final _materialBottomBarBlur = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

/// The badge counts on Library (queued downloads) and Store (extension
/// updates). Only the navigation chrome watches them, so a finished
/// download or an update check does not rebuild every tab.
int _watchQueuedCount(WidgetRef ref) =>
    ref.watch(downloadQueueProvider.select((s) => s.queuedCount));

int _watchRepoUpdatesCount(WidgetRef ref) =>
    ref.watch(repoProvider.select((s) => s.updatesAvailableCount));

/// The tab at [index]: Home, Library, the Store when shown, Search, then
/// Settings where the style has it as a destination.
@visibleForTesting
ShellTab shellTabAt(int index, {required bool showStore}) {
  if (index == 0) return ShellTab.home;
  if (index == 1) return ShellTab.library;
  if (showStore && index == 2) return ShellTab.repository;
  if (index == (showStore ? 3 : 2)) return ShellTab.search;
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
  ShellTab.search => showStore ? 3 : 2,
  // Mornye phones open Settings as a page, not a destination.
  ShellTab.settings => !mornye || desktop ? (showStore ? 4 : 3) : null,
};

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;
  final _mornyeChrome = MornyeChromeController();
  // Preserves the tab view element (and its kept-alive tabs) when the body
  // structure swaps between rail and bottom-bar layouts on rotation.
  final GlobalKey _pageViewKey = GlobalKey();
  late final PageController _pageController;
  late final AnimationController _tabJumpTransitionController;
  // Material fade through between destinations: [_fadeThroughToCurrentTab]
  // fades the page shown out on [_tabExitController], then
  // [_playTabFadeThrough] fades the new one in and sets the curves.
  // Transitions update their layers directly; no shell subtree rebuilds per
  // animation frame.
  late final AnimationController _tabExitController;
  bool _tabLeaving = false;
  static const _tabExitDuration = Duration(milliseconds: 90);
  late final CurvedAnimation _tabJumpOpacity = CurvedAnimation(
    parent: _tabJumpTransitionController,
    curve: Easing.standardDecelerate,
  );
  late final CurvedAnimation _tabJumpScaleCurve = CurvedAnimation(
    parent: _tabJumpTransitionController,
    curve: Easing.standardDecelerate,
  );
  // One opacity layer for both halves: the lower of the two.
  late final Animation<double> _tabOpacity = AnimationMin<double>(
    _tabJumpOpacity,
    _tabExitController,
  );
  late final Animation<double> _tabJumpScale = Tween<double>(
    begin: 0.92,
    end: 1,
  ).animate(_tabJumpScaleCurve);
  bool _hasCheckedUpdate = false;
  bool _hasCheckedAppAnnouncement = false;
  bool _initialSafRepairComplete = false;
  bool _safRepairDialogVisible = false;
  bool _usbVolumeWarningShown = false;
  StreamSubscription<String>? _shareSubscription;
  StreamSubscription<List<OpenAudioFile>>? _audioOpenSubscription;
  DateTime? _lastBackPress;
  late final PageBackSwipe _backSwipe = PageBackSwipe(_backNavigators);
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
  /// returns to the Library root's link and the Material rail to Library.
  late final _libraryDepthObserver = _PageDepthObserver(
    onRoot: () => desktopSidebarLink.value = null,
  );
  late final Listenable _chromeSurfaceListenable = Listenable.merge([
    ShellNavigationService.chromeBrightness,
    ShellNavigationService.chromeSurface,
  ]);

  /// The style the current tab index was chosen under.
  bool? _indexStyleMornye;

  /// Mornye phones have no Settings destination, so switching styles keeps
  /// the same tab rather than an index the new style lacks.
  void _keepTabAcrossStyles() {
    final mornye = context.isMornye;
    final previous = _indexStyleMornye;
    _indexStyleMornye = mornye;
    if (previous == null || previous == mornye) return;
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final tab = shellTabAt(_currentIndex, showStore: showStore);
    final index =
        shellIndexOfTab(
          tab,
          mornye: mornye,
          showStore: showStore,
          desktop: isDesktopPlatform || isAndroidTv,
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

  /// What the services below were last configured with. Theme and media
  /// query changes also reach [didChangeDependencies]; the services only
  /// need a new language.
  AppLocalizations? _servicesL10n;
  String? _servicesLanguageTag;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keepTabAcrossStyles();
    final l10n = context.l10n;
    final languageTag = Localizations.localeOf(context).toLanguageTag();
    if (identical(l10n, _servicesL10n) && languageTag == _servicesLanguageTag) {
      return;
    }
    _servicesL10n = l10n;
    _servicesLanguageTag = languageTag;
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
    unawaited(PlatformBridge.setMetadataLanguage(languageTag));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addObserver(_backSwipe);
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
    _tabExitController = AnimationController(
      vsync: this,
      duration: _tabExitDuration,
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
      // Null when the startup check gave no answer: it is then asked again.
      final safLost = await ref.read(initialSafValidationProvider);
      if (!mounted) return;
      await _repairSafAccessIfNeeded(
        knownLost: safLost ?? false,
        alreadyChecked: safLost != null,
      );
      _initialSafRepairComplete = true;
      if (!mounted) return;
      unawaited(_pointAtMovedSearch());
      unawaited(_restorePlayback());
      // Off the startup path: waits for extensions, then fills the Store
      // badge and installs updates without the Store tab being opened.
      unawaited(
        ref.read(extensionAutoUpdateProvider.notifier).checkAfterStartup(),
      );
      // Library menus are built synchronously and offer an upload only once
      // the writable connections are known.
      ref.read(networkUploadConnectionsProvider);
      _setupShareListener();
      await _checkSafMigration();
      if (!mounted) return;
      final updateDialogShown = await _checkForUpdates();
      if (!updateDialogShown) {
        await _checkAppAnnouncement();
      }
    });
  }

  /// Shows the pointer to the Search tab over Home when it is owed. The
  /// migration that notes it runs with the settings load.
  Future<void> _pointAtMovedSearch() async {
    try {
      await ref.read(settingsProvider.notifier).ensureLoaded();
      if (mounted && _currentIndex == 0) await SearchMovedHint.showIfOwed();
    } on Object catch (error) {
      _log.w('Could not show the Search hint: $error');
    }
  }

  /// Restores the last session, then its song's cover from the file once
  /// extensions are ready; the desktop backend reads files only then.
  Future<void> _restorePlayback() async {
    final runtime = ref.read(musicPlayerRuntimeProvider);
    try {
      await runtime.restoreSession();
      await ref.read(extensionProvider.notifier).ensureInitialized();
      if (!mounted) return;
      await runtime.recoverRestoredArtwork();
    } on Object catch (error) {
      _log.w('Could not restore the playing song\'s cover: $error');
    }
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
      unawaited(ref.read(extensionAutoUpdateProvider.notifier).checkOnResume());
    } else if (state == AppLifecycleState.paused) {
      unawaited(
        ref.read(musicPlayerRuntimeProvider).handler?.persistCurrentSession(),
      );
    }
  }

  void _setupShareListener() {
    final audio = AudioFileOpenService.instance;
    _audioOpenSubscription = audio.requests.listen(_openAudioFiles);
    for (final files in audio.takePending()) {
      unawaited(_openAudioFiles(files));
    }
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

  Future<void> _openAudioFiles(List<OpenAudioFile> files) async {
    try {
      await ref.read(openAudioControllerProvider.notifier).open(files);
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  Future<void> _handleSharedUrl(String url) async {
    if (!mounted) return;

    Navigator.of(context).popUntil((route) => route.isFirst);
    _onShellTabRequested(ShellTab.search);
    _searchTabNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    // Mount the lazy Search page before the metadata listener handles the link.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    ref.read(settingsProvider.notifier).setHasSearchedBefore();
    if (mounted) {
      final linkClient = ref.read(linkPhoneClientProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.loadingSharedLink),
          // A paired desktop can take the link instead.
          action: linkClient == null || !linkTakesSharedUrls(linkClient)
              ? null
              : SnackBarAction(
                  label: context.l10n.linkSendToDesktop(
                    linkDesktopName(linkClient),
                  ),
                  onPressed: () => showLinkSharedUrlSheet(context, ref, url),
                ),
        ),
      );
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
    WidgetsBinding.instance.removeObserver(_backSwipe);
    usbAudioStatus.removeListener(_onUsbAudioStatusChanged);
    ShellNavigationService.unregisterTabSelectionHandler(this);
    _shareSubscription?.cancel();
    _audioOpenSubscription?.cancel();
    _pageController.dispose();
    _tabJumpOpacity.dispose();
    _tabJumpScaleCurve.dispose();
    _tabJumpTransitionController.dispose();
    _tabExitController.dispose();
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
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Tapping Search again returns to its opening page: the field is emptied
  /// and the feed shows instead of results or recent searches.
  void _resetSearchToMain() {
    ref.read(previewPlayerProvider.notifier).stop();
    _searchTabNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    // Unfocus BEFORE clear so _onTrackStateChanged can properly
    // clear _urlController (it checks !_searchFocusNode.hasFocus)
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(trackProvider.notifier).clear();
  }

  int _searchIndex(bool showStore) => showStore ? 3 : 2;

  /// The Mornye bar's search button opens Search on its feed; pressed there,
  /// or with no feed to open on, it goes to the field.
  void _openSearchFromBar() {
    final index = _searchIndex(
      ref.read(settingsProvider.select((s) => s.showExtensionStore)),
    );
    if (_currentIndex == index || ref.read(homeFeedExtensionProvider) == null) {
      ShellNavigationService.requestSearch();
    } else {
      _onNavTap(index);
    }
  }

  /// Desktop and TV show Settings after Search in the content pane.
  /// Phones and tablets open it as a page instead.
  bool get _mornyeSettingsTab =>
      context.isMornye && (isDesktopPlatform || isAndroidTv);

  int _settingsIndex(bool showStore) => showStore ? 4 : 3;

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
      ShellTab.search => _searchIndex(showStore),
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
    // A request to search (a shortcut, a shared link) keeps what is typed.
    if (resetHome &&
        index == _currentIndex &&
        index == _searchIndex(showStore)) {
      _resetSearchToMain();
      return;
    }

    if (_currentIndex != index) {
      HapticFeedback.selectionClick();
      // Stop any preview snippet when leaving the current tab. (_onPageChanged
      // cannot do this because _currentIndex is already updated below.)
      ref.read(previewPlayerProvider.notifier).stop();
      setState(() => _currentIndex = index);
      ShellNavigationService.syncState(
        currentTabIndex: _currentIndex,
        showRepoTab: showStore,
      );
      if (!isAndroidTv) FocusManager.instance.primaryFocus?.unfocus();
      if (context.isMornye || isAndroidTv) {
        // The glass pill owns the tab transition. Sliding/fading the whole
        // page at the same time continuously invalidates its live backdrop.
        _tabJumpTransitionController.value = 1;
      } else {
        // Top-level destinations have no spatial order, so Material fades
        // through to the page (M3 fade through) instead of sliding through
        // its neighbours.
        _fadeThroughToCurrentTab();
      }
    }
  }

  /// Material fade through to the page of [_currentIndex]: the page shown
  /// fades out, then the new one fades in ([_playTabFadeThrough]). A change
  /// made while a page is still fading in starts from the opacity it has,
  /// and one made during the fade out only renames where it ends, so quick
  /// taps never flash a page in from nothing. Reduced motion jumps.
  void _fadeThroughToCurrentTab() {
    if (!materialExpressiveEnabled(context)) {
      _showCurrentTabPage();
      return;
    }
    if (_tabLeaving) return;
    final shown = _tabOpacity.value;
    _tabJumpTransitionController.stop();
    if (shown <= 0.01) {
      _showCurrentTabPage();
      return;
    }
    _tabLeaving = true;
    _tabExitController.value = shown;
    _tabExitController
        .animateTo(
          0,
          duration: MotionPace.duration(_tabExitDuration) * shown,
          curve: Easing.standardAccelerate,
        )
        .whenCompleteOrCancel(() {
          if (mounted && _tabLeaving) _showCurrentTabPage();
        });
  }

  /// Jumps to the page of [_currentIndex] and fades it in.
  void _showCurrentTabPage() {
    _tabLeaving = false;
    if (_pageController.hasClients) _pageController.jumpToPage(_currentIndex);
    _playTabFadeThrough();
    _tabExitController.value = 1;
  }

  /// Fades the Material tab view in after a destination change: opacity on
  /// the effects spring, a scale up from 92 percent on the standard spatial
  /// spring, whose overshoot stays far below a pixel, so the page never
  /// spills over the rail. Reduced motion shows the page at once.
  void _playTabFadeThrough() {
    if (!materialExpressiveEnabled(context)) {
      _tabJumpTransitionController.value = 1;
      return;
    }
    const fallback = AppMotionSpec(
      Duration(milliseconds: 180),
      Easing.standardDecelerate,
    );
    final opacity = AppMotion.effects(context, fallback);
    final scale = AppMotion.materialPage;
    final total = opacity.duration > scale.duration
        ? opacity.duration
        : scale.duration;
    final micros = total.inMicroseconds;
    _tabJumpOpacity.curve = Interval(
      0,
      opacity.duration.inMicroseconds / micros,
      curve: opacity.curve,
    );
    _tabJumpScaleCurve.curve = Interval(
      0,
      scale.duration.inMicroseconds / micros,
      curve: scale.curve,
    );
    _tabJumpTransitionController
      ..duration = total
      ..forward(from: 0);
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
      );
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  /// Reads the keyboard inset without depending on it, so keyboard frames
  /// do not rebuild the shell.
  bool get _keyboardVisible {
    final media = context.getInheritedWidgetOfExactType<MediaQuery>()!;
    return media.data.viewInsets.bottom > 0;
  }

  /// Whether scrolling may collapse the Mornye tab bar at [width].
  bool _canMinimizeChromeAt(double width, TextScaler textScaler) =>
      !isDesktopPlatform &&
      context.isMornye &&
      !useNavigationRailForWidth(width) &&
      textScaler.scale(15) <= 20;

  /// [_canMinimizeChromeAt] for the window now, read without depending on
  /// its size, so the tab pages' scroll listeners do not rebuild the shell.
  bool get _canMinimizeChrome {
    final media = context.getInheritedWidgetOfExactType<MediaQuery>()!.data;
    return _canMinimizeChromeAt(media.size.width, media.textScaler);
  }

  /// The navigators a back press pops from, in [_handleBackPress]'s order.
  Iterable<NavigatorState?> _backNavigators() {
    if (!mounted) return const [];
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    return [
      Navigator.of(context, rootNavigator: true),
      _navigatorForTab(_currentIndex, showStore),
    ];
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
    final isSearchTab = _currentIndex == _searchIndex(showStore);

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

    if (isSearchTab && _keyboardVisible) {
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

    if (isAndroidTv) {
      await SystemNavigator.pop();
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
    if (index == _searchIndex(showStore)) return ShellTab.search;
    return ShellTab.settings;
  }

  List<DesktopDestination> _desktopDestinations({
    required bool showStore,
    required int queueCount,
    required int repoUpdatesCount,
  }) {
    final l10n = context.l10n;
    final mornye = context.isMornye;
    return [
      for (final tab in desktopDestinationTabs(showStore: showStore))
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
            icon: mornye ? CupertinoIcons.search : Icons.search,
            selectedIcon: mornye ? CupertinoIcons.search : Icons.search,
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

  /// The pages under the Mornye desktop sidebar's Library heading.
  /// Recently Added is the Library root.
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
        id: 'genres',
        icon: CupertinoIcons.guitars,
        label: l10n.libraryGenres,
      ),
      DesktopSidebarLink(
        id: 'folders',
        icon: CupertinoIcons.folder,
        label: l10n.libraryFolders,
      ),
      DesktopSidebarLink(
        id: 'downloads',
        icon: CupertinoIcons.arrow_down_circle,
        label: l10n.libraryDownloads,
        badgeCount: queueCount,
      ),
    ];
  }

  /// The page a desktop sidebar or rail link opens in the Library tab, or
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
      'genres' => Scaffold(
        body: MornyeLibraryScreen(
          page: MornyeLibraryPage.genres,
          onOpenSection: (_) {},
        ),
      ),
      'folders' => const LibraryDirectoryScreen(),
      'downloads' => const Scaffold(
        body: QueueTab(librarySection: 'downloads'),
      ),
      DesktopSidebarLink.allPlaylistsId => const Scaffold(
        body: QueueTab(librarySection: 'playlists'),
      ),
      _ => null,
    };
  }

  /// Shows a Library page or playlist picked in the Mornye desktop sidebar,
  /// or a playlist picked in the Material rail, in the Library tab, in place
  /// of the page it showed.
  void _openDesktopLibraryLink(String id) {
    final page = _desktopLibraryPage(id);
    // A link replaces the Library page at once, as in a source list, so the
    // Library root never shows on the way from another tab. Material fades
    // the new page in like a destination change; Mornye cuts.
    void show(NavigatorState navigator) {
      navigator.popUntil((route) => route.isFirst);
      if (page != null) {
        unawaited(
          navigator.push(
            PageRouteBuilder<void>(
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (_, _, _) => page,
            ),
          ),
        );
      }
      desktopSidebarLink.value = page == null ? null : id;
      if (!context.isMornye) _playTabFadeThrough();
    }

    final navigator = _libraryTabNavigatorKey.currentState;
    if (navigator != null) show(navigator);
    _onShellTabRequested(ShellTab.library);
    if (navigator != null) return;
    // The Library navigator mounts with the tab on its first visit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = _libraryTabNavigatorKey.currentState;
      if (mounted && navigator != null) show(navigator);
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
          SteadyPageRoute<void>(
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
    if (index == _searchIndex(showStore)) {
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
    ref.listen(activeRemotePlaybackProvider, (_, remote) {
      unawaited(ref.read(musicPlayerRuntimeProvider).showRemote(remote));
    });
    ref.listen(soundsBesideRemoteProvider, (_, beside) {
      ref.read(musicPlayerRuntimeProvider).soundsBesideRemote = beside;
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
    ref.listen(extensionAutoUpdateProvider, (_, notice) {
      if (notice == null) return;
      showAppSnackBar(
        context,
        content: Text(context.l10n.extensionsAutoUpdatedCount(notice.count)),
      );
    });
    final showStore = ref.watch(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final heroAnimationsEnabled = ref.watch(
      settingsProvider.select((s) => s.heroAnimationsEnabled),
    );
    ShellNavigationService.syncState(
      currentTabIndex: _currentIndex,
      showRepoTab: showStore,
    );

    final tabs = <Widget>[
      _TabNavigator(
        key: const ValueKey('tab-home'),
        navigatorKey: _homeTabNavigatorKey,
        observers: [_homePreviewStopObserver],
        heroAnimationsEnabled: heroAnimationsEnabled,
        child: const _HomeTabRoot(),
      ),
      _TabShown(
        key: const ValueKey('tab-library'),
        shown: _currentIndex == 1,
        child: _TabNavigator(
          navigatorKey: _libraryTabNavigatorKey,
          observers: [
            _libraryPreviewStopObserver,
            if (isDesktopPlatform) _libraryDepthObserver,
          ],
          heroAnimationsEnabled: heroAnimationsEnabled,
          child: const _LibraryTabRoot(),
        ),
      ),
      if (showStore)
        _TabNavigator(
          key: const ValueKey('tab-repo'),
          navigatorKey: _repoTabNavigatorKey,
          observers: [_repoPreviewStopObserver],
          heroAnimationsEnabled: heroAnimationsEnabled,
          child: const RepoTab(),
        ),
      _TabNavigator(
        key: const ValueKey('tab-search'),
        navigatorKey: _searchTabNavigatorKey,
        observers: [_searchPreviewStopObserver],
        heroAnimationsEnabled: heroAnimationsEnabled,
        child: const HomeTab(mode: HomeTabMode.search),
      ),
      // Mornye phones open Settings as a page instead.
      if (!context.isMornye || _mornyeSettingsTab)
        const SettingsTab(key: ValueKey('tab-settings')),
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

    Widget observeScroll(Widget child, int index) =>
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // The chrome stays expanded while the keyboard is up.
            if (_canMinimizeChrome &&
                index == _currentIndex &&
                !_keyboardVisible) {
              return _mornyeChrome.handleScroll(notification);
            }
            return false;
          },
          child: child,
        );

    final pageView = KeyedSubtree(
      key: _pageViewKey,
      child: context.isMornye || isAndroidTv
          ? LazyTabView(
              index: selectedDestination,
              preloadKeys: isAndroidTv
                  ? const {}
                  : {const ValueKey('tab-search')},
              children: [
                for (var index = 0; index < tabs.length; index++)
                  KeyedSubtree(
                    key: tabs[index].key,
                    child: observeScroll(tabs[index], index),
                  ),
              ],
            )
          : FadeTransition(
              opacity: _tabOpacity,
              child: PictureScaleTransition(
                scale: _tabJumpScale,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: tabs.length,
                  onPageChanged: _onPageChanged,
                  physics: const NeverScrollableScrollPhysics(),
                  // TickerMode mutes animations and lets visibility-aware widgets
                  // (e.g. MotionHeaderBanner) pause when their tab is hidden;
                  // kept-alive pages otherwise keep running offscreen.
                  itemBuilder: (context, index) => _KeepAliveTabPage(
                    key: ValueKey('page-$index'),
                    child: TickerMode(
                      enabled: index == _currentIndex,
                      // Kept-alive hidden pages keep their last size, so
                      // resizes and rail motion rebuild only the page shown.
                      child: HiddenTabMediaQuery(
                        hidden: index != _currentIndex,
                        child: observeScroll(tabs[index], index),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );

    // From here only the navigation chrome follows the window size and the
    // badge counts. It gets the same tab view each time, so none of them
    // rebuilds the shell or the routes of its tabs; pages read them
    // themselves.
    if (isAndroidTv) {
      return DownloadQueueFeedback(
        child: BackButtonListener(
          onBackButtonPressed: () async {
            await _handleBackPress();
            return true;
          },
          child: Scaffold(
            body: Consumer(
              child: SelectionOverlayHost(child: pageView),
              builder: (context, ref, body) => TvShell(
                destinations: _navigationDestinations(
                  queuedCount: _watchQueuedCount(ref),
                  repoUpdatesCount: _watchRepoUpdatesCount(ref),
                  showStore: showStore,
                ),
                selectedIndex: selectedDestination,
                onSelected: _onNavTap,
                child: body!,
              ),
            ),
          ),
        ),
      );
    }

    if (isDesktopPlatform) {
      // Desktop windows: a rail (Material) or source-list sidebar (Mornye)
      // with a persistent player; no bottom tabs or touch gestures.
      final mornye = context.isMornye;
      final selectedTab = _tabForIndex(selectedDestination, showStore);
      return DownloadQueueFeedback(
        child: DesktopLinkTransferNotices(
          child: Scaffold(
            body: Consumer(
              // The selection bar floats over the pages, not the sidebar.
              child: SelectionOverlayHost(child: pageView),
              builder: (context, ref, body) {
                final queuedCount = _watchQueuedCount(ref);
                return DesktopShellLayout(
                  destinations: _desktopDestinations(
                    showStore: showStore,
                    // Mornye shows the queue on its Downloads link instead.
                    queueCount: mornye ? 0 : queuedCount,
                    repoUpdatesCount: _watchRepoUpdatesCount(ref),
                  ),
                  selected: selectedTab,
                  onSelected: _onShellTabRequested,
                  libraryLinks: mornye
                      ? _desktopLibraryLinks(queueCount: queuedCount)
                      : const [],
                  // The Material rail opens playlists alone.
                  onOpenLibraryLink: _openDesktopLibraryLink,
                  onOpenProfile: mornye ? _openDesktopProfile : null,
                  body: body!,
                );
              },
            ),
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
        child: Consumer(
          child: pageView,
          builder: (context, ref, pageView) => _mobileScaffold(
            context,
            ref,
            pageView: pageView!,
            destinations: _navigationDestinations(
              queuedCount: _watchQueuedCount(ref),
              repoUpdatesCount: _watchRepoUpdatesCount(ref),
              showStore: showStore,
            ),
            selectedDestination: selectedDestination,
            maxIndex: maxIndex,
          ),
        ),
      ),
    );
    return DownloadQueueFeedback(
      // Mornye's glass bar is the costly part of a page under a moving
      // player. Material flies its cover as a Hero out of the live page.
      child: PlayerUnderlay(enabled: context.isMornye, child: shell),
    );
  }

  /// Phone, tablet and TV destinations, with the download count on Library.
  List<NavigationDestination> _navigationDestinations({
    required int queuedCount,
    required int repoUpdatesCount,
    required bool showStore,
  }) {
    final l10n = context.l10n;
    return <NavigationDestination>[
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
                badgeCount: queuedCount,
              )
            : AnimatedBadge(
                count: queuedCount,
                child: Badge(
                  isLabelVisible: queuedCount > 0,
                  label: Text('$queuedCount'),
                  child: const AppIcon(Icons.library_music_outlined),
                ),
              ),
        selectedIcon: SlidingIcon(
          child: AnimatedBadge(
            count: queuedCount,
            child: Badge(
              isLabelVisible: queuedCount > 0,
              label: Text('$queuedCount'),
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
      if (context.isMornye)
        NavigationDestination(
          icon: const Icon(CupertinoIcons.search),
          label: l10n.mornyeSearch,
        )
      else ...[
        NavigationDestination(
          // Home's search field moved here; people who had it are shown once.
          icon: const SearchMovedHintAnchor(child: AppIcon(Icons.search)),
          selectedIcon: BouncingIcon(child: const AppIcon(Icons.search)),
          label: l10n.mornyeSearch,
        ),
        NavigationDestination(
          icon: const AppIcon(Icons.settings_outlined),
          selectedIcon: SpinIcon(child: const AppIcon(Icons.settings)),
          label: l10n.navSettings,
        ),
      ],
      if (context.isMornye && isAndroidTv)
        NavigationDestination(
          icon: const Icon(CupertinoIcons.gear_alt),
          label: l10n.navSettings,
        ),
    ];
  }

  /// The phone and tablet chrome around [pageView]: the bottom bar, or the
  /// rail in wide windows, and the mini player.
  Widget _mobileScaffold(
    BuildContext context,
    WidgetRef ref, {
    required Widget pageView,
    required List<NavigationDestination> destinations,
    required int selectedDestination,
    required int maxIndex,
  }) {
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
    final canMinimizeChrome = _canMinimizeChromeAt(
      screenSize.width,
      MediaQuery.textScalerOf(context),
    );

    return Scaffold(
      extendBody: true,
      // The tab view keeps one element across the rail<->bar structure
      // swap via _pageViewKey so rotation doesn't remount tab navigators.
      body: useNavigationRail
          ? Row(
              children: [
                Builder(
                  builder: (context) {
                    final rtl = Directionality.of(context) == TextDirection.rtl;
                    return SafeArea(
                      left: !rtl,
                      right: rtl,
                      bottom: false,
                      child: ExpressiveNavigationRail(
                        selectedIndex: selectedDestination,
                        onDestinationSelected: _onNavTap,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainer,
                        destinations: destinations,
                      ),
                    );
                  },
                ),
                const VerticalDivider(width: 1),
                // Width-based layout (centered columns, grids) measures
                // the space beside the rail rather than the whole screen.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final mediaQuery = MediaQuery.of(context);
                      final rtl =
                          Directionality.of(context) == TextDirection.rtl;
                      return MediaQuery(
                        data: mediaQuery
                            .copyWith(
                              size: Size(
                                constraints.maxWidth,
                                mediaQuery.size.height,
                              ),
                            )
                            .removePadding(removeLeft: !rtl, removeRight: rtl),
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
            final mornyeBlurEnabled = ref.watch(mornyeBlurEnabledProvider);
            return ListenableBuilder(
              listenable: _chromeSurfaceListenable,
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
                        : _KeyboardOpenProvider(
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _mornyeChrome,
                              builder: (context, collapsed, _) =>
                                  MornyeBottomBar(
                                    collapsed:
                                        canMinimizeChrome &&
                                        collapsed &&
                                        !_KeyboardOpenScope.of(context),
                                    destinations: destinations,
                                    selectedIndex: selectedDestination,
                                    onSelected: _onNavTap,
                                    onHome: () => _onNavTap(0),
                                    onSearch: _openSearchFromBar,
                                    blurEnabled: mornyeBlurEnabled,
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
          // Only the fills fade; a whole-scheme move rebuilt the bar on
          // every frame of a song change.
          return Consumer(
            builder: (context, ref, child) => PlayerArtworkTheme(
              artUri: ref.watch(
                currentMediaItemProvider.select(
                  (item) => item.value?.artUri?.toString(),
                ),
              ),
              fadesSurfaceOnly: true,
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
                      PlayerArtworkSurface(
                        surface: Theme.of(context).colorScheme.surface,
                        overlay: settingsGroupOverlay(context),
                        opacity: 0.72,
                        child: ExpressiveNavigationBar(
                          selectedIndex: _currentIndex.clamp(0, maxIndex),
                          onDestinationSelected: _onNavTap,
                          isTablet: isTablet,
                          backgroundColor: Colors.transparent,
                          destinations: destinations,
                        ),
                      ),
                  ],
                );
                // The backdrop blur re-filters everything scrolling
                // underneath on every frame; low-end devices get an
                // opaque base instead unless the user forces blur on in
                // appearance settings.
                if (!blurEnabled) {
                  return PlayerArtworkSurface(
                    surface: Theme.of(context).colorScheme.surface,
                    overlay: settingsGroupOverlay(context),
                    child: bottomBar,
                  );
                }
                return ClipRect(
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: _materialBottomBarBlur,
                          blendMode: BlendMode.src,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      RepaintBoundary(child: bottomBar),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Tells the Mornye bottom bar only whether the keyboard is open, so the
/// frames of the keyboard's own animation do not rebuild the bar.
class _KeyboardOpenProvider extends StatelessWidget {
  const _KeyboardOpenProvider({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _KeyboardOpenScope(
    open: MediaQuery.viewInsetsOf(context).bottom > 0,
    child: child,
  );
}

class _KeyboardOpenScope extends InheritedWidget {
  const _KeyboardOpenScope({required this.open, required super.child});

  final bool open;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_KeyboardOpenScope>()!.open;

  @override
  bool updateShouldNotify(_KeyboardOpenScope oldWidget) =>
      open != oldWidget.open;
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

  /// The navigator as last built. A [Navigator] that is built again builds
  /// the page of every route on it again, so every tab's pages would follow
  /// each switch of tab; the same one is handed back until what it is made
  /// from changes.
  Navigator? _navigator;

  @override
  void didUpdateWidget(_TabNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.child, oldWidget.child) ||
        widget.navigatorKey != oldWidget.navigatorKey ||
        widget.heroAnimationsEnabled != oldWidget.heroAnimationsEnabled ||
        !listEquals(widget.observers, oldWidget.observers)) {
      _navigator = null;
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _navigator = null;
  }

  @override
  void dispose() {
    _chromeObserver.detach();
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _navigator ??= Navigator(
      key: widget.navigatorKey,
      routeDirectionalTraversalEdgeBehavior: isAndroidTv
          ? TraversalEdgeBehavior.parentScope
          : TraversalEdgeBehavior.stop,
      observers: [
        _chromeObserver,
        if (widget.heroAnimationsEnabled) _heroController,
        if (isDesktopPlatform) _nowPlayingCloser,
        ...widget.observers,
      ],
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(
          requestFocus: !isAndroidTv,
          builder: (_) => widget.child,
        ),
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

/// Whether a tab is the one on screen, for the tab's root page. It reaches
/// the page from above the tab's navigator: handed down as a parameter it
/// would build the navigator again, and every page on it.
class _TabShown extends InheritedWidget {
  const _TabShown({super.key, required this.shown, required super.child});

  final bool shown;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TabShown>()?.shown ?? true;

  @override
  bool updateShouldNotify(_TabShown oldWidget) => shown != oldWidget.shown;
}

class _HomeTabRoot extends StatelessWidget {
  const _HomeTabRoot();

  @override
  Widget build(BuildContext context) => const HomeTab();
}

/// Library's root page: one [QueueTab] for the life of the tab. A switch of
/// tab changes what it listens to and builds nothing of the Library again.
class _LibraryTabRoot extends StatefulWidget {
  const _LibraryTabRoot();

  @override
  State<_LibraryTabRoot> createState() => _LibraryTabRootState();
}

class _LibraryTabRootState extends State<_LibraryTabRoot> {
  final _shown = ValueNotifier(false);
  late final _tab = QueueTab(tabActive: _shown);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shown.value = _TabShown.of(context);
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _tab;
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
