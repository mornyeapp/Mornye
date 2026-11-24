import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/profile_overview_provider.dart'
    show profileTraitsProvider;
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/screens/settings/profile_share_screen.dart'
    show profileTraitLine;
import 'package:mornye/screens/settings/about_page.dart';
import 'package:mornye/screens/settings/app_settings_page.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/screens/settings/backup_restore_page.dart';
import 'package:mornye/screens/settings/cache_management_page.dart';
import 'package:mornye/screens/settings/donate_page.dart';
import 'package:mornye/screens/settings/download_settings_page.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/files_settings_page.dart';
import 'package:mornye/screens/settings/keyboard_shortcuts_page.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/screens/settings/link_desktop_settings_page.dart';
import 'package:mornye/screens/settings/link_settings_page.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/screens/settings/log_screen.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/screens/settings/metadata_settings_page.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/no_scrollbars.dart';

/// Whether Link is set up on this device: a device is paired, or this one
/// is shared. With an external player the Link page is listed only then.
final settingsLinkInUseProvider = Provider.autoDispose<bool>((ref) {
  final phone = ref.watch(linkClientSupportedProvider);
  if (!phone && !isDesktopPlatform) return false;
  if (ref.watch(linkDesktopHostProvider.select((host) => host.enabled))) {
    return true;
  }
  return phone &&
      ref.watch(
        linkClientControllerProvider.select((s) => s.servers.isNotEmpty),
      );
});

/// Names a Settings page, so the open one stays open when the list changes.
enum _Page {
  donate,
  appearance,
  playback,
  lyrics,
  library,
  networkStorage,
  link,
  linkDesktop,
  download,
  extensions,
  files,
  metadata,
  app,
  keyboard,
  cache,
  backup,
  logs,
  about,
}

class _Destination {
  const _Destination({
    required this.id,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
    this.keywords = const [],
    this.searchEntries = const [],
    this.showDonationProgress = false,
    this.beta = false,
  });

  final _Page id;
  final IconData icon;
  final MaterialColor iconColor;
  final String title;
  final String subtitle;
  final Widget Function() pageBuilder;
  final bool showDonationProgress;

  /// Marks the entry with a Beta tag in the phone list. The desktop category
  /// column is too narrow for it, so those pages show the tag themselves.
  final bool beta;

  /// Extra search terms for things the title does not spell out (e.g. "SAF"
  /// for the Files page), so a user can find a page by what it does.
  final List<String> keywords;
  final List<SettingsSearchEntry> searchEntries;

  bool matches(SettingsSearchQuery query) {
    return query.matches([title, subtitle, ...keywords]);
  }
}

class _SearchResult {
  const _SearchResult(this.destination, [this.entry]);

  final _Destination destination;
  final SettingsSearchEntry? entry;
}

/// Destinations that stay visually connected inside one settings card.
class _Group {
  const _Group({required this.destinations});

  final List<_Destination> destinations;
}

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key, this.asPage = false, this.remoteConfigService});

  final bool asPage;
  final AppRemoteConfigService? remoteConfigService;

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  AppLocalizations? _cachedLocalizations;
  bool? _cachedBuiltInPlayer;
  bool? _cachedLinkListed;
  List<_Group>? _cachedGroups;
  String _query = '';
  bool _hasRequestedDonationGoal = false;
  MonthlyDonationGoal? _monthlyGoal;
  String? _activeDonationJson;
  late final AppRemoteConfigService _remoteConfigService =
      widget.remoteConfigService ?? AppRemoteConfigService();

  /// Desktop list-detail: the selected category ([_profileSelection] for the
  /// profile), the setting a search result points at, and the detail pane's
  /// navigator. Each selection gets a fresh navigator, so the pages pushed
  /// for the previous category close. Opens on the first page after the
  /// donation card: Appearance, or Download with an external player.
  int _selected = 1;
  String? _selectedTarget;
  var _detailNavigatorKey = GlobalKey<NavigatorState>();
  static const int _profileSelection = -1;

  /// Whether the detail pane fades in: after a category change, not when
  /// Settings first opens.
  bool _fadeDetail = false;

  bool get _supportsListDetail => isDesktopPlatform && !widget.asPage;

  @override
  void initState() {
    super.initState();
    if (_supportsListDetail) {
      ShellNavigationService.registerSettingsDetailNavigator(
        owner: this,
        navigator: () => _detailNavigatorKey.currentState,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasRequestedDonationGoal) return;
    _hasRequestedDonationGoal = true;
    unawaited(_loadDonationGoal());
  }

  Future<void> _loadDonationGoal({bool refresh = true}) async {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final cached = await _remoteConfigService.readCachedConfig();
    if (!mounted) return;
    if (cached != null) _applyDonationGoal(cached);
    if (!refresh) return;
    final refreshed = await _remoteConfigService.fetchConfigSnapshot(
      locale: locale,
    );
    if (!mounted || refreshed == null) return;
    _applyDonationGoal(refreshed);
  }

  void _applyDonationGoal(RemoteConfigSnapshot snapshot) {
    if (_activeDonationJson == snapshot.rawJson) return;
    setState(() {
      _activeDonationJson = snapshot.rawJson;
      _monthlyGoal = snapshot.config.donate.monthlyGoal;
    });
  }

  @override
  void dispose() {
    ShellNavigationService.unregisterSettingsDetailNavigator(this);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Related destinations share one card; whitespace separates each group
  /// without adding section labels that compete with the page title.
  List<_Group> _groups(BuildContext context) {
    final l10n = context.l10n;
    final builtInPlayer = ref.read(settingsProvider).usesBuiltInPlayer;
    // A download-focused app lists Link only once it is set up.
    final linkListed = builtInPlayer || ref.read(settingsLinkInUseProvider);
    if (identical(_cachedLocalizations, l10n) &&
        _cachedBuiltInPlayer == builtInPlayer &&
        _cachedLinkListed == linkListed &&
        _cachedGroups != null) {
      return _cachedGroups!;
    }

    final searchCatalog = SettingsSearchCatalog(
      l10n,
      androidAudio: Platform.isAndroid,
      builtInPlayer: builtInPlayer,
    );
    final donate = _Destination(
      id: _Page.donate,
      icon: Icons.favorite_outline,
      iconColor: Colors.pink,
      title: l10n.settingsDonate,
      subtitle: l10n.settingsDonateSubtitle,
      keywords: const ['support', 'ko-fi', 'sponsor'],
      pageBuilder: () => DonatePage(remoteConfigService: _remoteConfigService),
      showDonationProgress: true,
    );
    final appearance = _Destination(
      id: _Page.appearance,
      icon: Icons.palette_outlined,
      iconColor: Colors.purple,
      title: l10n.settingsAppearance,
      subtitle: l10n.settingsAppearanceSubtitle,
      keywords: const [
        'theme',
        'dark',
        'light',
        'amoled',
        'color',
        'language',
        'locale',
        'layout',
        'grid',
      ],
      searchEntries: searchCatalog.appearance,
      pageBuilder: () => const AppearanceSettingsPage(),
    );
    final playback = _Destination(
      id: _Page.playback,
      icon: Icons.play_circle_outline,
      iconColor: Colors.indigo,
      title: l10n.libraryPlayback,
      subtitle: builtInPlayer
          ? l10n.settingsPlaybackSubtitle
          : l10n.settingsPlaybackExternalSubtitle,
      keywords: const ['player', 'audio', 'playback', 'pemutaran'],
      searchEntries: searchCatalog.playback,
      pageBuilder: () => const PlaybackSettingsPage(),
    );
    final lyrics = _Destination(
      id: _Page.lyrics,
      icon: Icons.lyrics_outlined,
      iconColor: Colors.cyan,
      title: l10n.settingsLyrics,
      subtitle: l10n.settingsLyricsSubtitle,
      keywords: const ['lrc', 'synced', 'provider'],
      searchEntries: searchCatalog.lyrics,
      pageBuilder: () => const LyricsSettingsPage(),
    );
    final library = _Destination(
      id: _Page.library,
      icon: Icons.library_music_outlined,
      iconColor: Colors.blue,
      title: l10n.settingsLocalLibrary,
      subtitle: l10n.settingsLocalLibrarySubtitle,
      keywords: const ['scan', 'local', 'duplicate'],
      searchEntries: searchCatalog.library,
      pageBuilder: () => const LibrarySettingsPage(),
    );
    final networkStorage = _Destination(
      id: _Page.networkStorage,
      icon: Icons.dns_outlined,
      iconColor: Colors.blueGrey,
      title: l10n.networkStorage,
      subtitle: 'SMB · WebDAV · HTTP(S) · Subsonic',
      keywords: const ['nas', 'server', 'network', 'smb', 'webdav', 'http'],
      pageBuilder: () => const NetworkStorageScreen(),
    );
    final link = linkListed && (Platform.isAndroid || Platform.isIOS)
        ? _Destination(
            id: _Page.link,
            icon: Icons.devices,
            iconColor: Colors.deepPurple,
            title: l10n.linkSettingsTitle,
            subtitle: l10n.linkSettingsSubtitle,
            keywords: const [
              'computer',
              'desktop',
              'pc',
              'mac',
              'phone',
              'device',
              'pair',
              'link',
              'komputer',
              'ponsel',
              'perangkat',
            ],
            pageBuilder: () => const LinkSettingsPage(),
            beta: true,
          )
        : null;
    final linkDesktop = linkListed && isDesktopPlatform
        ? _Destination(
            id: _Page.linkDesktop,
            icon: Icons.phone_android,
            iconColor: Colors.lightBlue,
            title: l10n.linkDesktopSettingsTitle,
            subtitle: l10n.linkDesktopSettingsSubtitle,
            keywords: const [
              'phone',
              'mobile',
              'pair',
              'remote',
              'handoff',
              'subsonic',
              'ponsel',
            ],
            pageBuilder: () => const LinkDesktopSettingsPage(),
          )
        : null;
    final download = _Destination(
      id: _Page.download,
      icon: Icons.download_outlined,
      iconColor: Colors.green,
      title: l10n.settingsDownload,
      subtitle: l10n.settingsDownloadSubtitle,
      keywords: const [
        'quality',
        'flac',
        'concurrent',
        'network',
        'wifi',
        'service',
        'region',
      ],
      searchEntries: searchCatalog.download,
      pageBuilder: () => const DownloadSettingsPage(),
    );
    final extensions = _Destination(
      id: _Page.extensions,
      icon: Icons.extension_outlined,
      iconColor: Colors.teal,
      title: l10n.settingsExtensions,
      subtitle: l10n.settingsExtensionsSubtitle,
      keywords: const ['plugin', 'provider', 'priority', 'store'],
      searchEntries: searchCatalog.extensions,
      pageBuilder: () => const ExtensionsPage(),
    );
    final files = _Destination(
      id: _Page.files,
      icon: Icons.folder_outlined,
      iconColor: Colors.orange,
      title: l10n.settingsFiles,
      subtitle: l10n.settingsFilesSubtitle,
      keywords: const [
        'saf',
        'storage',
        'folder',
        'filename',
        'path',
        'permission',
      ],
      searchEntries: searchCatalog.files,
      pageBuilder: () => const FilesSettingsPage(),
    );
    final metadata = _Destination(
      id: _Page.metadata,
      icon: Icons.sell_outlined,
      iconColor: Colors.amber,
      title: l10n.settingsMetadata,
      subtitle: l10n.settingsMetadataSubtitle,
      keywords: const ['tag', 'cover', 'artwork', 'isrc', 'provider'],
      searchEntries: searchCatalog.metadata,
      pageBuilder: () => const MetadataSettingsPage(),
    );
    final app = _Destination(
      id: _Page.app,
      icon: Icons.tune_outlined,
      iconColor: Colors.blueGrey,
      title: l10n.settingsApp,
      subtitle: l10n.settingsAppSubtitle,
      keywords: const ['update', 'channel', 'debug', 'logging'],
      searchEntries: searchCatalog.app,
      pageBuilder: () => const AppSettingsPage(),
    );
    final keyboard = isDesktopPlatform
        ? _Destination(
            id: _Page.keyboard,
            icon: Icons.keyboard_outlined,
            iconColor: Colors.blueGrey,
            title: l10n.settingsKeyboardShortcuts,
            subtitle: l10n.settingsKeyboardShortcutsSubtitle,
            keywords: const ['hotkey', 'keys', 'keybinding', 'pintasan'],
            pageBuilder: () => const KeyboardShortcutsPage(),
          )
        : null;
    final cache = _Destination(
      id: _Page.cache,
      icon: Icons.storage_outlined,
      iconColor: Colors.indigo,
      title: l10n.settingsCache,
      subtitle: l10n.settingsCacheSubtitle,
      keywords: const ['clear', 'space', 'image', 'temp'],
      searchEntries: searchCatalog.cache,
      pageBuilder: () => const CacheManagementPage(),
    );
    final backup = _Destination(
      id: _Page.backup,
      icon: Icons.settings_backup_restore,
      iconColor: Colors.teal,
      title: l10n.settingsBackup,
      subtitle: l10n.settingsBackupSubtitle,
      keywords: const ['export', 'import', 'restore', 'json'],
      searchEntries: searchCatalog.backup,
      pageBuilder: () => const BackupRestorePage(),
    );
    final logs = _Destination(
      id: _Page.logs,
      icon: Icons.article_outlined,
      iconColor: Colors.brown,
      title: l10n.logTitle,
      subtitle: l10n.settingsLogsSubtitle,
      keywords: const ['debug', 'error', 'report'],
      searchEntries: searchCatalog.logs,
      pageBuilder: () => const LogScreen(),
    );
    final about = _Destination(
      id: _Page.about,
      icon: Icons.info_outline,
      iconColor: Colors.grey,
      title: l10n.settingsAbout,
      subtitle: '${l10n.aboutVersion} ${AppInfo.displayVersion}',
      keywords: const ['version', 'license', 'contributor'],
      searchEntries: searchCatalog.about,
      pageBuilder: () => const AboutPage(),
    );
    final sources = _Group(
      destinations: [library, networkStorage, ?link, ?linkDesktop],
    );
    final groups = [
      // On its own at the top, so its progress reads as the app's status.
      _Group(destinations: [donate]),
      if (builtInPlayer) ...[
        _Group(destinations: [appearance, playback, lyrics]),
        sources,
        _Group(destinations: [download, extensions, files, metadata]),
      ] else ...[
        // Download focus: what shapes a download leads the list.
        _Group(destinations: [download, files, metadata, lyrics, extensions]),
        sources,
        _Group(destinations: [appearance, playback]),
      ],
      _Group(destinations: [app, ?keyboard, cache, backup]),
      _Group(destinations: [logs, about]),
    ];
    // The list changes with the player choice; the open category stays open.
    final previous = _cachedGroups;
    if (previous != null && _selected >= 0) {
      final open = [
        for (final group in previous) ...group.destinations,
      ].elementAtOrNull(_selected)?.id;
      final index = [
        for (final group in groups) ...group.destinations,
      ].indexWhere((destination) => destination.id == open);
      if (index >= 0) _selected = index;
    }
    _cachedLocalizations = l10n;
    _cachedBuiltInPlayer = builtInPlayer;
    _cachedLinkListed = linkListed;
    _cachedGroups = groups;
    return groups;
  }

  /// With an external player the Playback page holds only this choice, so
  /// the phone list offers it as a row.
  void _choosePlayer() {
    final l10n = context.l10n;
    showAppChoiceSheet<String>(
      context: context,
      title: l10n.sectionPlayer,
      subtitle: l10n.playbackExternalHidden,
      selected: ref.read(settingsProvider).playerMode,
      choices: [
        AppChoice(
          'external',
          Icons.open_in_new,
          l10n.libraryExternalPlayer,
          subtitle: l10n.libraryExternalPlayerSubtitle,
        ),
        AppChoice(
          'internal',
          Icons.play_circle_outline,
          l10n.libraryBuiltInPreviewPlayer,
          subtitle: l10n.libraryBuiltInPreviewPlayerSubtitle,
        ),
      ],
      onSelected: (mode) =>
          ref.read(settingsProvider.notifier).setPlayerMode(mode),
    );
  }

  bool _isPlayerChoice(_Destination destination) =>
      destination.id == _Page.playback &&
      !ref.read(settingsProvider).usesBuiltInPlayer;

  Future<void> _navigateTo(
    BuildContext context,
    Widget page, {
    String? targetLabel,
  }) async {
    _searchFocusNode.unfocus();
    _searchFocusNode.canRequestFocus = false;
    FocusManager.instance.primaryFocus?.unfocus();
    final destination = targetLabel == null
        ? page
        : SettingsSearchHighlightScope(targetLabel: targetLabel, child: page);
    await Navigator.of(
      context,
    ).push(slidePageRoute<void>(page: MornyeSettingsTheme(child: destination)));
    if (!mounted) return;

    if (page is DonatePage) {
      unawaited(_loadDonationGoal(refresh: false));
    }

    // A route's focus scope remembers its previously focused child. Keep the
    // search field out of that restoration cycle while the child page is open,
    // then re-enable it without requesting focus when Settings becomes active.
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.canRequestFocus = true;
      _searchFocusNode.unfocus();
    });
  }

  Color _iconColorFor(_Destination destination) => context.isMornye
      ? destination.iconColor[Theme.of(context).brightness == Brightness.dark
            ? 300
            : 800]!
      : Theme.of(context).colorScheme.onSurfaceVariant;

  Widget _itemFor(_Destination destination, {required bool showDivider}) {
    if (_isPlayerChoice(destination)) {
      return SettingsItem(
        key: const ValueKey('settings-player-choice'),
        icon: destination.icon,
        iconColor: _iconColorFor(destination),
        showIconInMornye: true,
        title: context.l10n.sectionPlayer,
        subtitle: context.l10n.libraryExternalPlayer,
        showDivider: showDivider,
        onTap: _choosePlayer,
      );
    }
    final goal = _monthlyGoal;
    return SettingsItem(
      icon: destination.icon,
      iconColor: _iconColorFor(destination),
      showIconInMornye: true,
      title: destination.title,
      titleTrailing: destination.beta ? const BetaBadge() : null,
      subtitle: context.isMornye ? null : destination.subtitle,
      footer: destination.showDonationProgress && goal?.isVisible == true
          ? _DonationGoalProgress(goal: goal!)
          : null,
      showDivider: showDivider,
      onTap: () => _navigateTo(context, destination.pageBuilder()),
    );
  }

  Widget _searchItemFor(_SearchResult result, {required bool showDivider}) {
    final entry = result.entry;
    if (entry == null) {
      return _itemFor(result.destination, showDivider: showDivider);
    }

    return SettingsItem(
      key: ValueKey(
        'settings-search:${result.destination.title}:${entry.title}',
      ),
      icon: entry.icon,
      iconColor: _iconColorFor(result.destination),
      showIconInMornye: true,
      title: entry.title,
      subtitle: result.destination.title,
      showDivider: showDivider,
      onTap: _isPlayerChoice(result.destination)
          ? _choosePlayer
          : () => _navigateTo(
              context,
              result.destination.pageBuilder(),
              targetLabel: entry.targetLabel,
            ),
    );
  }

  /// Content pane width from which desktop Settings shows its categories
  /// beside the selected page.
  static const double listDetailMinWidth = 720;

  @override
  Widget build(BuildContext context) {
    // The list and its search leave out built-in player settings while
    // another app plays the music.
    final builtInPlayer = ref.watch(
      settingsProvider.select((s) => s.usesBuiltInPlayer),
    );
    if (!builtInPlayer) ref.watch(settingsLinkInUseProvider);
    // Settings reads as chrome; its pages scroll without a bar.
    if (!_supportsListDetail) return NoScrollbars(child: _buildList(context));
    Widget? wide;
    bool? wideMornye;
    return NoScrollbars(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= listDetailMinWidth) {
            final mornye = context.isMornye;
            if (wide == null || wideMornye != mornye) {
              wideMornye = mornye;
              wide = _buildListDetail(context);
            }
            return wide!;
          }
          // Not cached: the list reads strings and insets from this context.
          return _buildList(context);
        },
      ),
    );
  }

  /// Selects the category at [index] (or [_profileSelection]) for the
  /// detail pane. Selecting the open category again returns its pane to the
  /// top page.
  void _select(int index, {String? target}) {
    _searchFocusNode.unfocus();
    if (index == _selected && target == null && _selectedTarget == null) {
      _detailNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() {
      _selected = index;
      _selectedTarget = target;
      _detailNavigatorKey = GlobalKey<NavigatorState>();
      _fadeDetail = true;
    });
  }

  Widget _detailPage() {
    final Widget page;
    if (_selected == _profileSelection) {
      final profile = ref.read(userProfileProvider).value;
      page = profile == null
          ? const SizedBox.shrink()
          : ProfileSettingsPage(profile: profile);
    } else {
      final destinations = [
        for (final group in _groups(context)) ...group.destinations,
      ];
      page = destinations[_selected.clamp(0, destinations.length - 1)]
          .pageBuilder();
    }
    final target = _selectedTarget;
    return MornyeSettingsTheme(
      child: target == null
          ? page
          : SettingsSearchHighlightScope(targetLabel: target, child: page),
    );
  }

  /// Material fades a new category's page in on the fast effects spring.
  /// Keyed by the navigator key, so each category mounts one fresh navigator
  /// and the previous one leaves at once; the two never share the pane.
  /// Mornye keeps the source-list cut, and reduced motion cuts too.
  Widget _detailFade(BuildContext context, Widget navigator) {
    final fade = AppMotion.effectsFast(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    return TweenAnimationBuilder<double>(
      key: ObjectKey(_detailNavigatorKey),
      tween: Tween<double>(
        begin: _fadeDetail && fade.duration > Duration.zero ? 0 : 1,
        end: 1,
      ),
      duration: fade.duration,
      curve: fade.curve,
      builder: (context, opacity, child) => Opacity(
        key: const ValueKey('settings-detail-fade'),
        opacity: opacity,
        child: child,
      ),
      child: navigator,
    );
  }

  /// Desktop Settings: categories on the leading side and the selected page
  /// beside them, whose own links open inside the detail pane. Material
  /// follows the M3 list-detail layout; Mornye follows the System Settings
  /// sidebar.
  Widget _buildListDetail(BuildContext context) {
    final mornye = context.isMornye;
    return MornyeSettingsTheme(
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const ValueKey('settings-category-list'),
                width: mornye ? 260 : 320,
                child: Material(
                  color: mornye
                      ? theme.scaffoldBackgroundColor
                      : theme.colorScheme.surfaceContainerLow,
                  child: _buildCategoryList(context),
                ),
              ),
              if (mornye)
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: MornyeTheme.metadataDividerColor(context),
                ),
              Expanded(
                child: ClipRect(
                  child: Builder(
                    builder: (context) {
                      final detailChild = Semantics(
                        container: true,
                        child: _detailFade(
                          context,
                          HeroControllerScope.none(
                            child: Navigator(
                              key: _detailNavigatorKey,
                              onGenerateInitialRoutes: (_, _) => [
                                PageRouteBuilder<void>(
                                  transitionDuration: Duration.zero,
                                  reverseTransitionDuration: Duration.zero,
                                  pageBuilder: (_, _, _) => _detailPage(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final mediaQuery = MediaQuery.of(context);
                          // Pages measure the detail pane, not the window.
                          return MediaQuery(
                            data: mediaQuery.copyWith(
                              size: Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                            ),
                            // A semantics container keeps the detail routes'
                            // modal barriers from hiding the category list.
                            child: detailChild,
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCategoryList(BuildContext context) {
    final mornye = context.isMornye;
    final theme = Theme.of(context);
    final query = SettingsSearchQuery(_query);
    final groups = _groups(context);
    final destinations = [for (final group in groups) ...group.destinations];
    final goal = _monthlyGoal;

    Widget categoryRow(
      _Destination destination, {
      bool first = true,
      bool last = true,
    }) {
      final index = destinations.indexOf(destination);
      return _CategoryRow(
        key: ValueKey('settings-category:${destination.title}'),
        first: first,
        last: last,
        leading: _CategoryIcon(
          icon: destination.icon,
          color: destination.iconColor,
          selected: index == _selected,
        ),
        title: destination.title,
        footer: destination.showDonationProgress && goal?.isVisible == true
            ? _DonationGoalProgress(goal: goal!)
            : null,
        selected: index == _selected,
        onTap: () => _select(index),
      );
    }

    final children = <Widget>[
      if (!mornye)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
          child: Semantics(
            header: true,
            child: Text(
              context.l10n.settingsTitle,
              style: theme.textTheme.headlineSmall,
            ),
          ),
        ),
      Padding(
        padding: EdgeInsets.only(top: mornye ? 12 : 0, bottom: 12),
        child: AppSearchField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          hintText: context.l10n.settingsSearchHint,
          clearTooltip: context.l10n.dialogClear,
          samplesBackdrop: false,
          onChanged: (value) => setState(() => _query = value),
          onClear: () => setState(() => _query = ''),
        ),
      ),
      Consumer(
        builder: (context, ref, _) {
          final profile = ref.watch(userProfileProvider).value;
          final named = profile?.name.isNotEmpty == true;
          final traits = profileTraitLine(
            context,
            ref.watch(profileTraitsProvider).value ?? const [],
          );
          return _CategoryRow(
            key: const ValueKey('settings-category:profile'),
            leading: ProfileAvatar(
              name: profile?.name ?? '',
              photoPath: profile?.photoPath,
              size: mornye ? 36 : 40,
            ),
            title: named ? profile!.name : context.l10n.profileSetUp,
            subtitle: traits ?? context.l10n.profileEdit,
            selected: _selected == _profileSelection,
            onTap: profile == null ? null : () => _select(_profileSelection),
          );
        },
      ),
    ];

    if (query.isEmpty) {
      for (final group in groups) {
        children.add(SizedBox(height: mornye ? 16 : 12));
        final last = group.destinations.length - 1;
        for (final (index, destination) in group.destinations.indexed) {
          children.add(
            categoryRow(destination, first: index == 0, last: index == last),
          );
        }
      }
    } else {
      final matches = <_SearchResult>[
        for (final destination in destinations) ...[
          if (destination.matches(query)) _SearchResult(destination),
          for (final entry in destination.searchEntries)
            if (entry.matches(query)) _SearchResult(destination, entry),
        ],
      ];
      children.add(const SizedBox(height: 12));
      if (matches.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              context.l10n.settingsSearchNoResults(_query.trim()),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      for (final (position, result) in matches.indexed) {
        final first = position == 0;
        final last = position == matches.length - 1;
        final entry = result.entry;
        if (entry == null) {
          children.add(
            categoryRow(result.destination, first: first, last: last),
          );
          continue;
        }
        final index = destinations.indexOf(result.destination);
        children.add(
          _CategoryRow(
            key: ValueKey(
              'settings-search:${result.destination.title}:${entry.title}',
            ),
            first: first,
            last: last,
            leading: _CategoryIcon(
              icon: entry.icon,
              color: result.destination.iconColor,
              selected: false,
            ),
            title: entry.title,
            subtitle: result.destination.title,
            selected: false,
            onTap: () => _select(index, target: entry.targetLabel),
          ),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: children,
    );
  }

  Widget _buildList(BuildContext context) {
    final tokens = context.tokens;
    final wideInset = wideListInset(context);
    final query = SettingsSearchQuery(_query);
    final groups = _groups(context);

    final margin = EdgeInsets.fromLTRB(
      tokens.gapLg + wideInset,
      context.isMornye ? 12 : tokens.gapSm,
      tokens.gapLg + wideInset,
      context.isMornye ? 12 : tokens.gapSm,
    );

    final List<Widget> body;
    if (query.isEmpty) {
      body = [
        for (final group in groups)
          SliverToBoxAdapter(
            child: SettingsGroup(
              margin: margin,
              children: [
                for (var i = 0; i < group.destinations.length; i++)
                  _itemFor(
                    group.destinations[i],
                    showDivider: i != group.destinations.length - 1,
                  ),
              ],
            ),
          ),
      ];
    } else {
      final matches = <_SearchResult>[
        for (final group in groups)
          for (final destination in group.destinations) ...[
            if (destination.matches(query)) _SearchResult(destination),
            for (final entry in destination.searchEntries)
              if (entry.matches(query)) _SearchResult(destination, entry),
          ],
      ];
      body = matches.isEmpty
          ? [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(tokens.gapXl),
                  child: Text(
                    context.l10n.settingsSearchNoResults(_query.trim()),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ]
          : [
              SliverSettingsGroup(
                margin: margin,
                itemCount: matches.length,
                itemBuilder: (context, index) => _searchItemFor(
                  matches[index],
                  showDivider: index != matches.length - 1,
                ),
              ),
            ];
    }

    return MornyeSettingsTheme(
      child: CustomScrollView(
        slivers: [
          if (widget.asPage)
            AppSliverHeader.page(title: context.l10n.settingsTitle)
          else
            AppSliverHeader.tabRoot(
              title: context.l10n.settingsTitle,
              alignToContent: true,
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapLg + wideInset,
                tokens.gapSm,
                tokens.gapLg + wideInset,
                tokens.gapSm,
              ),
              child: AppSearchField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: context.l10n.settingsSearchHint,
                clearTooltip: context.l10n.dialogClear,
                samplesBackdrop: false,
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() => _query = ''),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final profile = ref.watch(userProfileProvider).value;
                final traits = profileTraitLine(
                  context,
                  ref.watch(profileTraitsProvider).value ?? const [],
                );
                return SettingsGroup(
                  margin: margin,
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      leading: ProfileAvatar(
                        name: profile?.name ?? '',
                        photoPath: profile?.photoPath,
                        size: 64,
                      ),
                      title: Text(
                        profile?.name.isNotEmpty == true
                            ? profile!.name
                            : context.l10n.profileSetUp,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      subtitle: traits != null
                          ? Text(
                              traits,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : profile?.name.isNotEmpty == true ||
                                profile?.photoPath?.isNotEmpty == true
                          ? null
                          : Text(context.l10n.profileEdit),
                      trailing: const AppIcon.adaptive(Icons.chevron_right),
                      onTap: profile == null
                          ? null
                          : () => _navigateTo(
                              context,
                              ProfileSettingsPage(profile: profile),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          ...body,
          const NavBarSliverSpacer(),
          const SliverFillRemaining(hasScrollBody: false, child: SizedBox()),
        ],
      ),
    );
  }
}

class _DonationGoalProgress extends StatelessWidget {
  const _DonationGoalProgress({required this.goal});

  final MonthlyDonationGoal goal;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final percentage =
        '${NumberFormat('0.#', locale).format(goal.progressPercent)}%';
    return Row(
      children: [
        Expanded(
          child: AppProgressIndicator.linear(
            wavy: false,
            value: goal.progressRatio,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            semanticsLabel: goal.title,
            semanticsValue: goal.showPercentage ? percentage : null,
          ),
        ),
        if (goal.showPercentage) ...[
          const SizedBox(width: 8),
          // The progress bar already reads the percentage as its value.
          ExcludeSemantics(
            child: Text(
              percentage,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A category in the desktop settings list. Material lays each group out as
/// an expressive connected list, like the settings pages beside it, and
/// marks the selected row with a fully rounded `secondaryContainer` tile;
/// Mornye fills it with a quiet gray like the System Settings sidebar.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    super.key,
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.footer,
    this.first = true,
    this.last = true,
  });

  final Widget leading;
  final String title;
  final String? subtitle;

  /// Shown under the title, as the donation goal's progress is on phones.
  final Widget? footer;
  final bool selected;
  final VoidCallback? onTap;

  /// The row's place in its Material connected group.
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final radius = mornye
        ? BorderRadius.circular(8)
        : selected
        ? BorderRadius.circular(context.tokens.radiusCard)
        : connectedRowRadius(context, first: first, last: last);
    // Mornye selects with the app sidebar's quiet gray fill, so the colored
    // category tiles keep their own color.
    final dark = colorScheme.brightness == Brightness.dark;
    final mornyeFill = colorScheme.onSurface.withValues(
      alpha: dark ? 0.12 : 0.08,
    );
    final foreground = selected && !mornye
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurface;
    final secondary = selected
        ? foreground.withValues(alpha: 0.8)
        : colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: mornye || !last ? 2 : 0),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected
              ? (mornye ? mornyeFill : colorScheme.secondaryContainer)
              : (mornye ? Colors.transparent : settingsGroupColor(context)),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            hoverColor: mornye
                ? colorScheme.onSurface.withValues(alpha: 0.05)
                : null,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: mornye ? 36 : 56),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: mornye ? 8 : 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    IconTheme.merge(
                      data: IconThemeData(color: foreground),
                      child: leading,
                    ),
                    SizedBox(width: mornye ? 10 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style:
                                (mornye
                                        ? textTheme.bodyMedium
                                        : textTheme.labelLarge)
                                    ?.copyWith(
                                      color: foreground,
                                      fontWeight: selected
                                          ? (mornye
                                                ? FontWeight.w600
                                                : FontWeight.w700)
                                          : null,
                                    ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              style: textTheme.bodySmall?.copyWith(
                                color: secondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (footer != null) ...[
                            const SizedBox(height: 6),
                            footer!,
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A category glyph: Material's plain icon, or Mornye's white symbol on a
/// tile in the category's color, as in System Settings.
class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({
    required this.icon,
    required this.color,
    required this.selected,
  });

  final IconData icon;
  final MaterialColor color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!context.isMornye) {
      return AppIcon.adaptive(
        icon,
        size: 24,
        color: selected
            ? colorScheme.onSecondaryContainer
            : colorScheme.onSurfaceVariant,
      );
    }
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color[600],
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: AppIcon.adaptive(icon, size: 15, color: Colors.white),
    );
  }
}
