import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/desktop/windows_audio_quick_settings.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/no_scrollbars.dart';

/// Window width at which the Material rail shows labels beside its icons.
const double desktopExpandedRailBreakpoint = 1200;

/// Expanded Material rail width.
const double desktopSidebarWidth = 220;

/// Collapsed Material rail width.
const double desktopCollapsedRailWidth = 96;

/// Space between the expanded Material rail's destinations, so adjacent
/// 56dp indicators and hover layers never touch.
const double desktopRailItemGap = 8;

/// A Library page or playlist in the Mornye sidebar.
class DesktopSidebarLink {
  const DesktopSidebarLink({
    required this.id,
    required this.icon,
    required this.label,
    this.badgeCount = 0,
  });

  /// Identifies the link to [DesktopShellLayout.onOpenLibraryLink] and
  /// [desktopSidebarLink]. Playlists use [playlistId].
  final String id;
  final IconData icon;
  final String label;
  final int badgeCount;

  /// The link id of the user playlist [id].
  static String playlistId(String id) => 'playlist:$id';

  /// The link that opens the list of every playlist.
  static const allPlaylistsId = 'playlists';

  /// The Library root, which the Material rail's Library destination opens
  /// while a link is open.
  static const libraryRootId = 'library';
}

/// The Library link open in the Mornye sidebar, or null for the Library
/// root, which the first Library link stands for.
final desktopSidebarLink = ValueNotifier<String?>(null);

/// The user's playlists listed in the Mornye sidebar.
final desktopSidebarPlaylistsProvider = Provider<List<UserPlaylistCollection>>(
  (ref) => ref.watch(libraryCollectionsProvider.select((s) => s.playlists)),
);

/// The profile in the Mornye sidebar's account row, once it has loaded.
final desktopSidebarProfileProvider = Provider<UserProfile?>(
  (ref) => ref.watch(userProfileProvider).value,
);

/// A top-level desktop destination.
class DesktopDestination {
  const DesktopDestination({
    required this.tab,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
  });

  final ShellTab tab;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;
}

/// The desktop shell: navigation on the leading edge, the content pane and
/// the trailing inspector.
///
/// Material uses [DesktopNavigationRail] and the player bar docked across the bottom. Mornye follows Music: the
/// [DesktopSidebar] runs the full window height, and the player floats as a
/// glass capsule at the bottom of the content pane, which pads its pages so
/// their last rows scroll clear of it.
///
/// On macOS the window content reaches under a transparent title bar
/// ([desktopTitleBarInContent]): the traffic lights sit over the top of the
/// navigation, and the top [desktopTitleBarHeight] of the content pane drags
/// the window.
///
/// Now Playing covers the whole window while [desktopNowPlayingOpen] is
/// set. Lyrics and Up Next ([desktopInspectorPanel]) sit beside the content
/// from [desktopInspectorBesideBreakpoint] and float over it below that.
class DesktopShellLayout extends ConsumerWidget {
  const DesktopShellLayout({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
    required this.body,
    this.libraryLinks = const [],
    this.onOpenLibraryLink,
    this.onOpenProfile,
    this.playerBar = const DesktopPlayerBar(),
    this.nowPlaying = const DesktopNowPlaying(),
  });

  /// Destinations in [desktopDestinationTabs] order; Cmd/Ctrl+1..5 follow it.
  final List<DesktopDestination> destinations;
  final ShellTab? selected;
  final ValueChanged<ShellTab> onSelected;
  final Widget body;

  /// Mornye: the Library pages listed under the sidebar's Library heading.
  /// The first stands for the Library destination itself.
  final List<DesktopSidebarLink> libraryLinks;

  /// Opens a Library link or a playlist from the Mornye sidebar, or a
  /// playlist from the expanded Material rail.
  final ValueChanged<String>? onOpenLibraryLink;

  /// Mornye: opens the profile from the sidebar's account row.
  final VoidCallback? onOpenProfile;
  final Widget playerBar;
  final Widget nowPlaying;

  /// The mini player ([desktopMiniPlayerOpen]) replaces the whole window.
  /// The shell stays mounted behind it, in the same place in the tree and at
  /// the last full window size, so its pages keep their layout and state
  /// while the window is small.
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _window(ref.watch(playerUiEnabledProvider));

  Widget _window(bool show) => ValueListenableBuilder<bool>(
    valueListenable: desktopMiniPlayerOpen,
    builder: (context, mini, window) {
      mini = mini && show;
      final mediaQuery = MediaQuery.of(context);
      if (!mini) _fullWindowSize = mediaQuery.size;
      final full = mini ? _fullWindowSize : null;
      // Follow native resize frames instead of running a second animation
      // clock that could finish before AppKit or a slow Flutter frame.
      final span = full == null
          ? 0.0
          : full.width - desktopMiniPlayerSize.width;
      final progress = !mini
          ? 0.0
          : span <= 0
          ? 1.0
          : ((full!.width - mediaQuery.size.width) / span).clamp(0.0, 1.0);
      final fade = Curves.easeInOut.transform(progress);
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Visibility(
              visible: progress < 1,
              maintainState: true,
              child: IgnorePointer(
                ignoring: mini,
                child: ExcludeSemantics(
                  excluding: mini,
                  child: Opacity(
                    key: const ValueKey('desktop-mini-player-shell-fade'),
                    opacity: 1 - fade,
                    child: RepaintBoundary(
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: full?.width,
                        maxWidth: full?.width,
                        minHeight: full?.height,
                        maxHeight: full?.height,
                        child: MediaQuery(
                          data: full == null
                              ? mediaQuery
                              : mediaQuery.copyWith(size: full),
                          child: window!,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (mini)
              IgnorePointer(
                ignoring: progress < 1,
                child: Opacity(
                  key: const ValueKey('desktop-mini-player-fade'),
                  opacity: fade,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(
                      width: desktopMiniPlayerSize.width,
                      child: const KeyedSubtree(
                        key: ValueKey('desktop-mini-player'),
                        child: DesktopMiniPlayer(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
    child: Builder(builder: (context) => _nowPlayingOrShell(context, show)),
  );

  /// The window's size before the mini player shrank it.
  static Size? _fullWindowSize;

  /// Now Playing covers the whole window, as Music's player does. The
  /// destinations keep their state underneath, but stop painting and
  /// ticking.
  Widget _nowPlayingOrShell(BuildContext context, bool showPlayer) =>
      ValueListenableBuilder<bool>(
        valueListenable: desktopNowPlayingOpen,
        builder: (context, nowPlayingOpen, shell) {
          nowPlayingOpen = nowPlayingOpen && showPlayer;
          return Stack(
            fit: StackFit.expand,
            children: [
              Visibility(
                visible: !nowPlayingOpen,
                maintainState: true,
                child: shell!,
              ),
              if (nowPlayingOpen)
                KeyedSubtree(
                  key: const ValueKey('desktop-now-playing'),
                  child: nowPlaying,
                ),
              if (isDesktopPlatform &&
                  defaultTargetPlatform == TargetPlatform.windows &&
                  !nowPlayingOpen)
                const DesktopAudioControlCenterOverlay(),
            ],
          );
        },
        child: Builder(builder: (context) => _shell(context, showPlayer)),
      );

  Widget _shell(BuildContext context, bool showPlayer) {
    final width = MediaQuery.sizeOf(context).width;
    if (context.isMornye) {
      // The sidebar always shows; the page background shows around the
      // inset panel.
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopSidebar(
              destinations: destinations,
              selected: selected,
              onSelected: onSelected,
              libraryLinks: libraryLinks,
              onOpenLibraryLink: onOpenLibraryLink,
              onOpenProfile: onOpenProfile,
            ),
            Expanded(
              key: const ValueKey('desktop-content'),
              child: _DesktopContentArea(
                overlayInspector: desktopInspectorOverlays(width),
                body: body,
                floatingPlayer: showPlayer ? playerBar : null,
                showPlayer: showPlayer,
                titleBarDrag: true,
              ),
            ),
          ],
        ),
      );
    }
    final railBackground = Theme.of(context).colorScheme.surfaceContainer;
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: railBackground,
                child: Column(
                  children: [
                    // The traffic lights sit above the rail.
                    if (desktopTitleBarInContentFor(context))
                      const SizedBox(
                        height: desktopTitleBarHeight,
                        width: desktopWindowControlsWidth,
                        child: DesktopWindowDragArea(zoomOnDoubleClick: true),
                      ),
                    // Expanded by default and always collapsed below
                    // [desktopExpandedRailBreakpoint]; the rail's menu
                    // button and the sidebar shortcut toggle it in wider
                    // windows.
                    Expanded(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: desktopSidebarCollapsed,
                        builder: (context, collapsed, _) {
                          final wide = width >= desktopExpandedRailBreakpoint;
                          return DesktopNavigationRail(
                            destinations: destinations,
                            selected: selected,
                            onSelected: onSelected,
                            extended: !collapsed && wide,
                            onToggleExtended: wide
                                ? toggleDesktopSidebar
                                : null,
                            onOpenLibraryLink: onOpenLibraryLink,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _DesktopContentArea(
                  overlayInspector: desktopInspectorOverlays(width),
                  body: body,
                  showPlayer: showPlayer,
                  titleBarDrag: true,
                ),
              ),
            ],
          ),
        ),
        if (showPlayer) playerBar,
      ],
    );
  }
}

/// Gives [child] the size of the space it lays out in, so width-based layout
/// (centered columns, grids) measures the pane rather than the whole window.
/// [bottomInset] becomes the bottom padding, which pages add after their
/// last row ([NavBarInset]) so it scrolls clear of the floating player.
class _PaneMediaQuery extends StatelessWidget {
  const _PaneMediaQuery({required this.child, this.bottomInset = 0});

  final Widget child;
  final double bottomInset;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mediaQuery = MediaQuery.of(context);
      var data = mediaQuery
          .copyWith(size: Size(constraints.maxWidth, constraints.maxHeight))
          .removePadding(removeLeft: true, removeBottom: true);
      if (bottomInset > 0) {
        data = data.copyWith(
          padding: data.padding.copyWith(bottom: bottomInset),
          viewPadding: data.viewPadding.copyWith(bottom: bottomInset),
        );
      }
      return MediaQuery(data: data, child: child);
    },
  );
}

/// The content pane, the trailing inspector and, in Mornye, the floating
/// player. Pages bring their own search fields (Home, Library), so there is
/// no shell search bar above them.
class _DesktopContentArea extends StatelessWidget {
  const _DesktopContentArea({
    required this.overlayInspector,
    required this.body,
    this.floatingPlayer,
    this.showPlayer = true,
    this.titleBarDrag = false,
  });

  final bool overlayInspector;
  final Widget body;

  /// The Mornye player capsule, floating over the bottom of the pane.
  final Widget? floatingPlayer;
  final bool showPlayer;

  /// Whether the top of the pane is the window's title bar row, where a
  /// drag moves the window.
  final bool titleBarDrag;

  @override
  Widget build(BuildContext context) {
    final player = floatingPlayer;
    final playerInset = player == null ? 0.0 : DesktopPlayerBar.floatingInset;
    return ValueListenableBuilder<DesktopInspectorPanel?>(
      valueListenable: desktopInspectorPanel,
      builder: (context, panel, _) {
        if (!showPlayer) panel = null;
        final content = Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A semantics container keeps the tab navigators'
                // modal barriers from hiding the sidebar.
                Expanded(
                  key: const ValueKey('desktop-pages'),
                  child: Semantics(
                    container: true,
                    child: _PaneMediaQuery(
                      bottomInset: playerInset,
                      child: body,
                    ),
                  ),
                ),
              ],
            ),
            if (player != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: DesktopPlayerBar.floatingMargin,
                child: LayoutBuilder(
                  builder: (context, constraints) => Center(
                    child: SizedBox(
                      width: DesktopPlayerBar.floatingWidth(
                        constraints.maxWidth,
                      ),
                      child: player,
                    ),
                  ),
                ),
              ),
            // A narrow window's inspector floats above the player.
            PositionedDirectional(
              top: 0,
              bottom: playerInset,
              end: 0,
              width: desktopInspectorWidth,
              child: DesktopInspectorTransition(
                key: const ValueKey('desktop-inspector-overlay'),
                panel: overlayInspector ? panel : null,
                overlay: true,
                builder: (context, panel) =>
                    DesktopInspector(panel: panel, overlay: true),
              ),
            ),
          ],
        );
        // One structure for every state, so opening the inspector never
        // remounts the destinations.
        final pane = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: content),
            DesktopInspectorTransition(
              key: const ValueKey('desktop-inspector-beside'),
              panel: overlayInspector ? null : panel,
              builder: (context, panel) => DesktopInspector(panel: panel),
            ),
          ],
        );
        if (!titleBarDrag || !desktopTitleBarInContentFor(context)) return pane;
        // Pages keep their clicks in the title bar row; a drag that
        // starts on it moves the window.
        return Stack(
          fit: StackFit.expand,
          children: [
            pane,
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: desktopTitleBarHeight,
              child: DesktopWindowDragArea(),
            ),
          ],
        );
      },
    );
  }
}

int _positionOf(List<DesktopDestination> destinations, ShellTab tab) =>
    destinations.indexWhere((destination) => destination.tab == tab) + 1;

/// Material 3 Expressive navigation rail for desktop windows: collapsed, or
/// expanded to [desktopSidebarWidth] when [extended], with Settings anchored
/// at the bottom. A menu button on top toggles it when [onToggleExtended] is
/// set. Expanded, the user's playlists follow the destinations when
/// [onOpenLibraryLink] opens them.
class DesktopNavigationRail extends StatelessWidget {
  const DesktopNavigationRail({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
    required this.extended,
    this.onToggleExtended,
    this.onOpenLibraryLink,
  });

  final List<DesktopDestination> destinations;
  final ShellTab? selected;
  final ValueChanged<ShellTab> onSelected;
  final bool extended;

  /// Collapses or expands the rail; null hides the menu button, as in
  /// windows too narrow for the expanded rail.
  final VoidCallback? onToggleExtended;

  /// Opens a playlist ([DesktopSidebarLink.playlistId]) or the list of them
  /// ([DesktopSidebarLink.allPlaylistsId]) in the Library tab.
  final ValueChanged<String>? onOpenLibraryLink;

  Widget _menuButton(BuildContext context) {
    final toggle = onToggleExtended!;
    return AppIconButton(
      key: const ValueKey('desktop-rail-menu'),
      tooltip: desktopTooltip(
        context,
        context.l10n.desktopShortcutToggleSidebar,
        DesktopCommand.toggleSidebar,
      ),
      icon: AppIcon(extended ? Icons.menu_open : Icons.menu),
      onPressed: toggle,
    );
  }

  /// Library leaves an open playlist for the Library root, as the root link
  /// does in the Mornye sidebar; switching tabs alone would show the
  /// playlist again.
  void _select(ShellTab tab) {
    final openLink = onOpenLibraryLink;
    if (tab == ShellTab.library &&
        openLink != null &&
        desktopSidebarLink.value != null) {
      openLink(DesktopSidebarLink.libraryRootId);
    } else {
      onSelected(tab);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = colorScheme.surfaceContainer;
    if (!materialExpressiveEnabled(context)) {
      // Reduced motion keeps Flutter's rail; Settings stays last.
      final index = destinations.indexWhere((d) => d.tab == selected);
      return NavigationRail(
        extended: extended,
        minExtendedWidth: desktopSidebarWidth,
        // Collapsed, the rail shows icons alone.
        labelType: NavigationRailLabelType.none,
        backgroundColor: background,
        leading: onToggleExtended == null ? null : _menuButton(context),
        selectedIndex: index < 0 ? null : index,
        onDestinationSelected: (index) => _select(destinations[index].tab),
        destinations: [
          for (final destination in destinations)
            NavigationRailDestination(
              icon: Badge(
                isLabelVisible: destination.badgeCount > 0,
                label: Text('${destination.badgeCount}'),
                child: AppIcon(destination.icon),
              ),
              selectedIcon: AppIcon(destination.selectedIcon),
              label: Text(destination.label),
            ),
        ],
      );
    }
    final primary = [
      for (final destination in destinations)
        if (destination.tab != ShellTab.settings) destination,
    ];
    final settings = destinations
        .where((destination) => destination.tab == ShellTab.settings)
        .firstOrNull;
    final motion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration(milliseconds: 300), Curves.easeInOutCubic),
    );
    final openLink = onOpenLibraryLink;
    // One expansion value drives the width, every pill and every label, so
    // the rail morphs continuously instead of swapping layouts at the end.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: extended ? 1 : 0),
      duration: motion.duration,
      curve: motion.curve,
      builder: (context, expansion, _) => ValueListenableBuilder<String?>(
        valueListenable: desktopSidebarLink,
        builder: (context, openId, _) {
          // An open playlist takes the selection from Library, as a link
          // does in the Mornye sidebar.
          final linkId = openLink != null && selected == ShellTab.library
              ? openId
              : null;
          Widget item(DesktopDestination destination) => _RailDestination(
            key: ValueKey('desktop-rail:${destination.tab.name}'),
            destination: destination,
            selected: destination.tab == selected && linkId == null,
            expansion: expansion,
            onTap: () => _select(destination.tab),
          );
          final gap = lerpDouble(4, desktopRailItemGap, expansion)!;
          final playlistsShown = (expansion * 2 - 1).clamp(0.0, 1.0);
          return ColoredBox(
            color: background,
            child: SizedBox(
              width: lerpDouble(
                desktopCollapsedRailWidth,
                desktopSidebarWidth,
                expansion,
              ),
              child: ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (onToggleExtended != null)
                      // Centered over the collapsed rail, where it stays,
                      // in line with the destination icons.
                      SizedBox(
                        width: desktopCollapsedRailWidth,
                        height: 56,
                        child: Center(child: _menuButton(context)),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final (index, destination)
                                in primary.indexed) ...[
                              if (index > 0) SizedBox(height: gap),
                              item(destination),
                            ],
                            if (openLink != null && playlistsShown > 0)
                              Opacity(
                                opacity: playlistsShown,
                                child: _RailPlaylists(
                                  openId: linkId,
                                  onOpen: openLink,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (settings != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: item(settings),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The expanded Material rail's Playlists section: a heading, All Playlists
/// and the user's playlists as full-width 44dp rows, the desktop list
/// density, so the rail lists what it can open instead of leaving the space
/// under the destinations empty.
class _RailPlaylists extends ConsumerWidget {
  const _RailPlaylists({required this.openId, required this.onOpen});

  /// The open link, which shows as selected.
  final String? openId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final playlists = ref.watch(desktopSidebarPlaylistsProvider);
    Widget row(String id, IconData icon, String label) => _RailLinkRow(
      key: ValueKey('desktop-rail-link:$id'),
      icon: icon,
      label: label,
      selected: id == openId,
      onTap: () => onOpen(id),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // The heading starts at the destination icons.
          padding: const EdgeInsetsDirectional.fromSTEB(
            _RailDestination._inset + 16,
            24,
            _RailDestination._inset,
            8,
          ),
          child: Semantics(
            header: true,
            child: Text(
              l10n.searchPlaylists,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        row(
          DesktopSidebarLink.allPlaylistsId,
          Icons.queue_music,
          l10n.desktopAllPlaylists,
        ),
        for (final playlist in playlists)
          row(
            DesktopSidebarLink.playlistId(playlist.id),
            Icons.playlist_play,
            playlist.name,
          ),
      ],
    );
  }
}

/// A row in the expanded Material rail's Playlists section: the icon in line
/// with the destination icons, a stadium hover layer and the selected
/// destination's fill.
class _RailLinkRow extends StatelessWidget {
  const _RailLinkRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final foreground = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _RailDestination._inset),
      // Long playlist names are cut, so the tooltip shows them whole.
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 800),
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: selected ? colorScheme.secondaryContainer : null,
            type: selected ? MaterialType.canvas : MaterialType.transparency,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              hoverColor: foreground.withValues(alpha: 0.08),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    AppIcon(icon, size: 24, color: foreground),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: foreground,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
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

/// One Material rail destination at [expansion] (0 collapsed, 1 expanded).
///
/// Collapsed, a 56x32 indicator holds the icon alone, named by a tooltip;
/// a desktop rail of three or four destinations reads better without
/// labels under the icons. Expanded, a 56dp row spans the rail with the
/// label beside the icon, as wide as the Playlists rows below (the owner's
/// call over M3 Expressive's pill that hugs its label). Both take the
/// Playlists rows' fill, hover and ripple, and in between they cross-fade
/// around a fixed icon while the row narrows with the rail, as the owner
/// preferred to a morphing pill. Only the row, or the whole 56dp square
/// while collapsed, takes clicks and hover.
class _RailDestination extends StatelessWidget {
  const _RailDestination({
    super.key,
    required this.destination,
    required this.selected,
    required this.expansion,
    required this.onTap,
  });

  final DesktopDestination destination;
  final bool selected;
  final double expansion;
  final VoidCallback onTap;

  /// Distance from the rail's leading edge to the indicator, centering the
  /// 56dp collapsed indicator in the 96dp collapsed rail.
  static const double _inset = (desktopCollapsedRailWidth - 56) / 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final t = expansion.clamp(0.0, 1.0);
    const inset = _RailDestination._inset;

    final expandedStyle = textTheme.labelLarge!.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    );
    // The expanded pill spans the rail like the Playlists rows below, so
    // every fill and hover lines up at both edges.
    const expandedPillWidth = desktopSidebarWidth - inset * 2;

    const height = 56.0;
    // Like the Playlists rows, the expanded row narrows with the rail and
    // fades, and the collapsed indicator fades in where it ends. Neither
    // changes shape, so no long flat pill or edge crosses the label.
    final expanded = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
    final collapsed = ((0.6 - t) / 0.6).clamp(0.0, 1.0);
    final rowWidth = lerpDouble(56, expandedPillWidth, t)!;

    final foreground = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;

    // A stadium with the selected fill, the hover layer and the ink ripple
    // of the Playlists rows.
    Widget surface({required bool active, Widget? child}) => Material(
      color: selected ? colorScheme.secondaryContainer : null,
      type: selected ? MaterialType.canvas : MaterialType.transparency,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: active ? onTap : null,
        canRequestFocus: active,
        hoverColor: foreground.withValues(alpha: 0.08),
        child: child ?? const SizedBox.expand(),
      ),
    );

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: destination.label,
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (collapsed > 0)
              PositionedDirectional(
                start: inset,
                top: 0,
                width: 56,
                height: height,
                child: IgnorePointer(
                  ignoring: t >= 0.5,
                  child: ExcludeSemantics(
                    // Names the icon while the label is hidden; the whole
                    // square around the indicator takes the click.
                    child: Tooltip(
                      message: destination.label,
                      excludeFromSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onTap,
                        child: Opacity(
                          opacity: collapsed,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: surface(active: t < 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (expanded > 0)
              PositionedDirectional(
                start: inset,
                top: 0,
                width: rowWidth,
                height: height,
                child: IgnorePointer(
                  ignoring: t < 0.5,
                  child: ExcludeSemantics(
                    child: Opacity(
                      opacity: expanded,
                      child: surface(
                        active: t >= 0.5,
                        child: Row(
                          children: [
                            // The icon is drawn once, above both states.
                            const SizedBox(width: 16 + 24 + 8),
                            Expanded(
                              child: Text(
                                destination.label,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: expandedStyle.copyWith(
                                  color: foreground,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            PositionedDirectional(
              start: inset + 16,
              top: (height - 24) / 2,
              child: IgnorePointer(
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 24),
                  child: Badge(
                    isLabelVisible: destination.badgeCount > 0,
                    label: Text('${destination.badgeCount}'),
                    child: AppIcon(
                      selected ? destination.selectedIcon : destination.icon,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Mornye source-list sidebar, laid out like Music's: a rounded panel
/// inset from the window edges, with the window controls and the sidebar
/// button on top, then Search and the top-level destinations, the Library
/// pages and the user's playlists under section headings, and the account
/// row pinned at the bottom with Settings beside it. The panel takes a tint
/// from the page's artwork color when the page sets one. The sidebar
/// button, View > Hide Sidebar and Control-Command-S hide it completely.
///
/// Without [onOpenLibraryLink] it lists the destinations alone, Library
/// included.
class DesktopSidebar extends ConsumerWidget {
  const DesktopSidebar({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
    this.libraryLinks = const [],
    this.onOpenLibraryLink,
    this.onOpenProfile,
  });

  /// Width of the panel.
  static const double width = 210;

  /// Space between the panel and the window edges and content pane.
  static const double margin = 8;

  /// Width the sidebar takes from the window.
  static const double footprint = width + 2 * margin;

  /// Corner radius of the panel.
  static const double radius = 12;

  final List<DesktopDestination> destinations;
  final ShellTab? selected;
  final ValueChanged<ShellTab> onSelected;

  /// The Library pages under the Library heading. The first stands for the
  /// Library destination and takes its place and shortcut.
  final List<DesktopSidebarLink> libraryLinks;

  /// Opens a Library link, All Playlists or a playlist by its link id.
  final ValueChanged<String>? onOpenLibraryLink;

  /// Opens the profile from the account row. Without it the row opens
  /// Settings.
  final VoidCallback? onOpenProfile;

  /// The panel fill: a step off the page background, tinted by the page's
  /// artwork color ([ShellNavigationService.chromeSurface]) when it has one.
  static Color panelColor(BuildContext context, Color? tint) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = dark ? const Color(0xff1e1e20) : const Color(0xffefeff3);
    if (tint == null) return base;
    return Color.lerp(base, tint, dark ? 0.32 : 0.18)!;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final openLink = onOpenLibraryLink;
    final links = openLink == null
        ? const <DesktopSidebarLink>[]
        : libraryLinks;
    final playlists = openLink == null
        ? const <UserPlaylistCollection>[]
        : ref.watch(desktopSidebarPlaylistsProvider);
    Widget destinationRow(DesktopDestination destination) {
      final search = destination.tab == ShellTab.search;
      return _SidebarRow(
        // Search focuses its field, as Command-F does.
        key: search ? const ValueKey('desktop-sidebar-search') : null,
        icon: destination.icon,
        label: destination.label,
        badgeCount: destination.badgeCount,
        selected: destination.tab == selected,
        tooltip: search
            ? desktopTooltip(context, destination.label, DesktopCommand.search)
            : desktopDestinationTooltip(
                context,
                destination.label,
                _positionOf(destinations, destination.tab),
              ),
        onTap: search
            ? ShellNavigationService.requestSearch
            : () => onSelected(destination.tab),
      );
    }

    // Search leads the list, as in Music.
    final topLevel = [
      for (final tab in [ShellTab.search, ShellTab.home, ShellTab.repository])
        ...destinations.where((destination) => destination.tab == tab),
      if (links.isEmpty)
        ...destinations.where(
          (destination) => destination.tab == ShellTab.library,
        ),
    ];
    final libraryPosition = _positionOf(destinations, ShellTab.library);
    final settings = destinations
        .where((destination) => destination.tab == ShellTab.settings)
        .firstOrNull;
    final list = ValueListenableBuilder<String?>(
      valueListenable: desktopSidebarLink,
      builder: (context, openId, _) {
        final current = selected == ShellTab.library
            ? openId ?? links.firstOrNull?.id
            : null;
        Widget linkRow(DesktopSidebarLink link, {String? tooltip}) =>
            _SidebarRow(
              icon: link.icon,
              label: link.label,
              badgeCount: link.badgeCount,
              selected: link.id == current,
              tooltip: tooltip ?? link.label,
              onTap: () => openLink!(link.id),
            );
        // A source list scrolls without a bar, as in Music's sidebar.
        return NoScrollbars(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            children: [
              for (final destination in topLevel) destinationRow(destination),
              if (links.isNotEmpty) ...[
                _SidebarSectionHeader(l10n.navLibrary),
                for (final (index, link) in links.indexed)
                  linkRow(
                    link,
                    tooltip: index == 0 && libraryPosition > 0
                        ? desktopDestinationTooltip(
                            context,
                            link.label,
                            libraryPosition,
                          )
                        : null,
                  ),
              ],
              if (openLink != null) ...[
                _SidebarSectionHeader(l10n.searchPlaylists),
                linkRow(
                  DesktopSidebarLink(
                    id: DesktopSidebarLink.allPlaylistsId,
                    icon: CupertinoIcons.square_grid_2x2,
                    label: l10n.desktopAllPlaylists,
                  ),
                ),
                for (final playlist in playlists)
                  linkRow(
                    DesktopSidebarLink(
                      id: DesktopSidebarLink.playlistId(playlist.id),
                      icon: CupertinoIcons.music_note_list,
                      label: playlist.name,
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
    final panel = ValueListenableBuilder<Color?>(
      valueListenable: ShellNavigationService.chromeSurface,
      builder: (context, tint, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: panelColor(context, tint),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.08),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SidebarHeader(),
              Expanded(child: list),
              if (settings != null)
                _SidebarAccountRow(
                  settings: settings,
                  settingsSelected: selected == ShellTab.settings,
                  settingsTooltip: desktopDestinationTooltip(
                    context,
                    settings.label,
                    _positionOf(destinations, ShellTab.settings),
                  ),
                  onOpenSettings: () => onSelected(ShellTab.settings),
                  onOpenProfile:
                      onOpenProfile ?? () => onSelected(ShellTab.settings),
                ),
            ],
          ),
        ),
      ),
    );
    return SizedBox(
      width: footprint,
      child: Padding(padding: const EdgeInsets.all(margin), child: panel),
    );
  }
}

/// The account row pinned under the sidebar's list, as in Music: the
/// profile picture and name, which open the profile, then Settings.
class _SidebarAccountRow extends ConsumerWidget {
  const _SidebarAccountRow({
    required this.settings,
    required this.settingsSelected,
    required this.settingsTooltip,
    required this.onOpenSettings,
    required this.onOpenProfile,
  });

  final DesktopDestination settings;
  final bool settingsSelected;
  final String settingsTooltip;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final profile = ref.watch(desktopSidebarProfileProvider);
    final name = profile?.name.trim() ?? '';
    // The sidebar is too narrow for the full invitation in long languages,
    // where it ellipsized mid-word; screen readers still hear all of it.
    final label = name.isEmpty ? context.l10n.profileTitle : name;
    final semanticLabel = name.isEmpty ? context.l10n.profileSetUp : name;
    final radius = BorderRadius.circular(_SidebarRow.radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: MornyeTheme.metadataDividerColor(context),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: semanticLabel,
                excludeSemantics: true,
                child: InkWell(
                  key: const ValueKey('desktop-sidebar-account'),
                  borderRadius: radius,
                  hoverColor: _SidebarRow.hoverFill(context),
                  onTap: onOpenProfile,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 40),
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        SizedBox.square(
                          dimension: 28,
                          child: ProfileAvatar(
                            name: name,
                            photoPath: profile?.photoPath,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              selected: settingsSelected,
              child: AppIconButton(
                key: const ValueKey('desktop-sidebar-settings'),
                tooltip: settingsTooltip,
                isSelected: settingsSelected,
                iconSize: 18,
                color: settingsSelected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                // A fill marks Settings as open by more than its color.
                style: settingsSelected
                    ? IconButton.styleFrom(
                        backgroundColor: _SidebarRow.selectionFill(context),
                      )
                    : null,
                icon: AppIcon(
                  settingsSelected ? settings.selectedIcon : settings.icon,
                ),
                onPressed: onOpenSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The top of the sidebar panel: on macOS the rest of the title bar row,
/// where the traffic lights sit and a drag moves the window.
class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader();

  /// Height without a title bar in the content (Windows, Linux).
  static const double height = 44;

  @override
  Widget build(BuildContext context) => SizedBox(
    // The panel starts [DesktopSidebar.margin] below the window top.
    height: desktopTitleBarInContentFor(context)
        ? desktopTitleBarHeight - DesktopSidebar.margin
        : height,
    child: const DesktopWindowDragArea(
      zoomOnDoubleClick: true,
      child: SizedBox.expand(),
    ),
  );
}

/// A sidebar section heading, in the small bold secondary style of macOS
/// source lists.
class _SidebarSectionHeader extends StatelessWidget {
  const _SidebarSectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(14, 16, 10, 4),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// One source-list row, measured from Music: a 32pt row inset 6pt from the
/// panel, an 18pt accent icon and a 13pt label, and an optional count. The
/// selected row gets a rounded translucent fill and a semibold label.
class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    this.badgeCount = 0,
  });

  /// Row height at the default text size; larger text grows the row.
  static const double height = 32;

  /// Corner radius of the selection fill.
  static const double radius = 8;

  /// The selected row's fill.
  static Color selectionFill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return scheme.onSurface.withValues(
      alpha: scheme.brightness == Brightness.dark ? 0.12 : 0.08,
    );
  }

  /// A hovered row's fill, lighter than the selection.
  static Color hoverFill(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05);

  final IconData icon;
  final String label;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final borderRadius = BorderRadius.circular(radius);
    final badge = badgeCount > 0 ? '$badgeCount' : null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 800),
      child: Semantics(
        button: true,
        selected: selected,
        label: badge == null ? label : '$label, $badge',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: borderRadius,
          hoverColor: hoverFill(context),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? selectionFill(context) : null,
              borderRadius: borderRadius,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: height),
              child: Row(
                children: [
                  // Icon at 20pt and label at 56pt from the panel edge.
                  const SizedBox(width: 14),
                  AppIcon(icon, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(
                      label,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badge != null)
                    Text(
                      badge,
                      style: textTheme.labelSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  const SizedBox(width: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
