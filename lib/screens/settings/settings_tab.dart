import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
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
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/no_scrollbars.dart';

/// One entry on the Settings tab.
class _Destination {
  const _Destination({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
    this.keywords = const [],
    this.searchEntries = const [],
    this.showDonationProgress = false,
  });

  final IconData icon;
  final MaterialColor iconColor;
  final String title;
  final String subtitle;
  final Widget Function() pageBuilder;
  final bool showDonationProgress;

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
  /// for the previous category close.
  int _selected = 0;
  String? _selectedTarget;
  var _detailNavigatorKey = GlobalKey<NavigatorState>();
  static const int _profileSelection = -1;

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
    if (identical(_cachedLocalizations, l10n) && _cachedGroups != null) {
      return _cachedGroups!;
    }

    final searchCatalog = SettingsSearchCatalog(
      l10n,
      androidAudio: Platform.isAndroid,
    );
    final groups = [
      _Group(
        destinations: [
          _Destination(
            icon: Icons.extension_outlined,
            iconColor: Colors.teal,
            title: l10n.settingsExtensions,
            subtitle: l10n.settingsExtensionsSubtitle,
            keywords: const ['plugin', 'provider', 'priority', 'store'],
            searchEntries: searchCatalog.extensions,
            pageBuilder: () => const ExtensionsPage(),
          ),
          _Destination(
            icon: Icons.favorite_outline,
            iconColor: Colors.pink,
            title: l10n.settingsDonate,
            subtitle: l10n.settingsDonateSubtitle,
            keywords: const ['support', 'ko-fi', 'sponsor'],
            pageBuilder: () =>
                DonatePage(remoteConfigService: _remoteConfigService),
            showDonationProgress: true,
          ),
          _Destination(
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
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.library_music_outlined,
            iconColor: Colors.blue,
            title: l10n.settingsLocalLibrary,
            subtitle: l10n.settingsLocalLibrarySubtitle,
            keywords: const ['scan', 'local', 'duplicate'],
            searchEntries: searchCatalog.library,
            pageBuilder: () => const LibrarySettingsPage(),
          ),
          _Destination(
            icon: Icons.dns_outlined,
            iconColor: Colors.blueGrey,
            title: l10n.networkStorage,
            subtitle: 'SMB · WebDAV · HTTP(S) · Subsonic',
            keywords: const [
              'nas',
              'server',
              'network',
              'smb',
              'webdav',
              'http',
            ],
            pageBuilder: () => const NetworkStorageScreen(),
          ),
          if (Platform.isAndroid || Platform.isIOS)
            _Destination(
              icon: Icons.computer,
              iconColor: Colors.deepPurple,
              title: l10n.linkSettingsTitle,
              subtitle: l10n.linkSettingsSubtitle,
              keywords: const [
                'computer',
                'desktop',
                'pc',
                'mac',
                'pair',
                'link',
                'komputer',
              ],
              pageBuilder: () => const LinkSettingsPage(),
            ),
          if (isDesktopPlatform)
            _Destination(
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
            ),
          _Destination(
            icon: Icons.sell_outlined,
            iconColor: Colors.amber,
            title: l10n.settingsMetadata,
            subtitle: l10n.settingsMetadataSubtitle,
            keywords: const ['tag', 'cover', 'artwork', 'isrc', 'provider'],
            searchEntries: searchCatalog.metadata,
            pageBuilder: () => const MetadataSettingsPage(),
          ),
          _Destination(
            icon: Icons.lyrics_outlined,
            iconColor: Colors.cyan,
            title: l10n.settingsLyrics,
            subtitle: l10n.settingsLyricsSubtitle,
            keywords: const ['lrc', 'synced', 'provider'],
            searchEntries: searchCatalog.lyrics,
            pageBuilder: () => const LyricsSettingsPage(),
          ),
          _Destination(
            icon: Icons.play_circle_outline,
            iconColor: Colors.indigo,
            title: l10n.libraryPlayback,
            subtitle: l10n.settingsPlaybackSubtitle,
            keywords: const ['player', 'audio', 'playback', 'pemutaran'],
            searchEntries: searchCatalog.playback,
            pageBuilder: () => const PlaybackSettingsPage(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
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
          ),
          _Destination(
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
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.tune_outlined,
            iconColor: Colors.blueGrey,
            title: l10n.settingsApp,
            subtitle: l10n.settingsAppSubtitle,
            keywords: const ['update', 'channel', 'debug', 'logging'],
            searchEntries: searchCatalog.app,
            pageBuilder: () => const AppSettingsPage(),
          ),
          if (isDesktopPlatform)
            _Destination(
              icon: Icons.keyboard_outlined,
              iconColor: Colors.blueGrey,
              title: l10n.settingsKeyboardShortcuts,
              subtitle: l10n.settingsKeyboardShortcutsSubtitle,
              keywords: const ['hotkey', 'keys', 'keybinding', 'pintasan'],
              pageBuilder: () => const KeyboardShortcutsPage(),
            ),
          _Destination(
            icon: Icons.storage_outlined,
            iconColor: Colors.indigo,
            title: l10n.settingsCache,
            subtitle: l10n.settingsCacheSubtitle,
            keywords: const ['clear', 'space', 'image', 'temp'],
            searchEntries: searchCatalog.cache,
            pageBuilder: () => const CacheManagementPage(),
          ),
          _Destination(
            icon: Icons.settings_backup_restore,
            iconColor: Colors.teal,
            title: l10n.settingsBackup,
            subtitle: l10n.settingsBackupSubtitle,
            keywords: const ['export', 'import', 'restore', 'json'],
            searchEntries: searchCatalog.backup,
            pageBuilder: () => const BackupRestorePage(),
          ),
        ],
      ),
      _Group(
        destinations: [
          _Destination(
            icon: Icons.article_outlined,
            iconColor: Colors.brown,
            title: l10n.logTitle,
            subtitle: l10n.settingsLogsSubtitle,
            keywords: const ['debug', 'error', 'report'],
            searchEntries: searchCatalog.logs,
            pageBuilder: () => const LogScreen(),
          ),
          _Destination(
            icon: Icons.info_outline,
            iconColor: Colors.grey,
            title: l10n.settingsAbout,
            subtitle: '${l10n.aboutVersion} ${AppInfo.displayVersion}',
            keywords: const ['version', 'license', 'contributor'],
            searchEntries: searchCatalog.about,
            pageBuilder: () => const AboutPage(),
          ),
        ],
      ),
    ];
    _cachedLocalizations = l10n;
    _cachedGroups = groups;
    return groups;
  }

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
    final goal = _monthlyGoal;
    return SettingsItem(
      icon: destination.icon,
      iconColor: _iconColorFor(destination),
      showIconInMornye: true,
      title: destination.title,
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
      onTap: () => _navigateTo(
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
    // Settings reads as chrome; its pages scroll without a bar.
    if (!_supportsListDetail) return NoScrollbars(child: _buildList(context));
    return NoScrollbars(
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= listDetailMinWidth
            ? _buildListDetail(context)
            : _buildList(context),
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
                  child: LayoutBuilder(
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
                        child: Semantics(
                          container: true,
                          child: HeroControllerScope.none(
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
          return _CategoryRow(
            key: const ValueKey('settings-category:profile'),
            leading: ProfileAvatar(
              name: profile?.name ?? '',
              photoPath: profile?.photoPath,
              size: mornye ? 36 : 40,
            ),
            title: named ? profile!.name : context.l10n.profileSetUp,
            subtitle: context.l10n.profileEdit,
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
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() => _query = ''),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final profile = ref.watch(userProfileProvider).value;
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
                      subtitle:
                          profile?.name.isNotEmpty == true ||
                              profile?.photoPath?.isNotEmpty == true
                          ? null
                          : Text(context.l10n.profileEdit),
                      trailing: const AppIcon(Icons.chevron_right),
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
