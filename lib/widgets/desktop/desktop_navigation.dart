import 'dart:ui' show lerpDouble;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
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
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_row_ink.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
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
/// Material uses [DesktopNavigationRail] and the player bar docked across
/// the bottom. With Mornye, [DesktopSidebar] runs the full window height, and
/// the player floats as a glass capsule at the bottom of the content pane,
/// which pads its pages so
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
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(playerUiEnabledProvider);
    final hasTrack = ref.watch(
      currentMediaItemProvider.select((state) => state.value != null),
    );
    return ValueListenableBuilder<bool>(
      valueListenable: desktopPlayerDismissed,
      builder: (context, dismissed, _) =>
          _window(enabled && (!dismissed || hasTrack)),
    );
  }

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

  /// Now Playing covers the whole window. The destinations keep their state
  /// underneath, but stop painting and ticking once it has opened.
  Widget _nowPlayingOrShell(BuildContext context, bool showPlayer) =>
      ValueListenableBuilder<bool>(
        valueListenable: desktopNowPlayingOpen,
        builder: (context, nowPlayingOpen, shell) => _NowPlayingTransition(
          open: nowPlayingOpen && showPlayer,
          shell: shell!,
          nowPlaying: nowPlaying,
        ),
        child: _WindowBreakpoints(
          builder: (context, breakpoints) =>
              _shell(context, showPlayer, breakpoints),
        ),
      );

  Widget _shell(
    BuildContext context,
    bool showPlayer,
    _ShellBreakpoints breakpoints,
  ) {
    if (context.isMornye) {
      // The sidebar always shows, full height against the window's edges.
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
                inspectorFitsBeside: breakpoints.besideFits,
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
                      SizedBox(
                        height: desktopTitleBarHeightFor(context),
                        width: desktopWindowControlsWidthFor(context),
                        child: const DesktopWindowDragArea(
                          zoomOnDoubleClick: true,
                        ),
                      ),
                    // Expanded by default and always collapsed below
                    // [desktopExpandedRailBreakpoint]; the rail's menu
                    // button and the sidebar shortcut toggle it in wider
                    // windows.
                    Expanded(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: desktopSidebarCollapsed,
                        builder: (context, collapsed, _) {
                          final wide = breakpoints.wide;
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
                  inspectorFitsBeside: breakpoints.besideFits,
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

/// Opens and closes the full-window Now Playing over [shell]. Material fades
/// it in on the effects spring while it rises 24dp on the slow spatial
/// spring, which is critically damped; Mornye dissolves it. Both exit with a
/// shorter eased fade. The shell keeps painting until the entrance ends and
/// Now Playing stays mounted until the exit ends, so either can reverse
/// midway (Esc during the entrance). Reduced motion swaps at once.
class _NowPlayingTransition extends StatefulWidget {
  const _NowPlayingTransition({
    required this.open,
    required this.shell,
    required this.nowPlaying,
  });

  final bool open;
  final Widget shell;
  final Widget nowPlaying;

  @override
  State<_NowPlayingTransition> createState() => _NowPlayingTransitionState();
}

class _NowPlayingTransitionState extends State<_NowPlayingTransition>
    with SingleTickerProviderStateMixin {
  static const double _rise = 24;

  /// The resting value of [_fade] and [_move] before the first entrance.
  /// The entrances themselves are the style's springs; reduced motion
  /// opens and closes at once.
  static const _initialEntrance = AppMotionSpec(
    Duration(milliseconds: 220),
    Curves.easeOutCubic,
  );

  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.open ? 1 : 0,
  );

  // The entrance in use: the fade covers the first [_fadeEnd] of it.
  AppMotionSpec _fade = _initialEntrance;
  AppMotionSpec _move = _initialEntrance;
  double _fadeEnd = 1;
  double _distance = 0;

  // Where the exit started, so Esc during the entrance fades out from
  // there instead of jumping to the exit's start.
  double _exitFrom = 1;
  double _exitOpacity = 1;
  double _exitOffset = 0;
  Curve _exitCurve = Easing.standardAccelerate;

  @override
  void didUpdateWidget(_NowPlayingTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.open ? 1 : 0;
      return;
    }
    if (widget.open) {
      _fade = AppMotion.effects(context, _initialEntrance);
      _move = AppMotion.spatialSlow(context, _initialEntrance);
      _distance = materialExpressiveEnabled(context) ? _rise : 0;
      // Mornye only fades, so its entrance ends with the fade.
      final entrance = _distance == 0 || _fade.duration > _move.duration
          ? _fade.duration
          : _move.duration;
      _fadeEnd = _fade.duration.inMicroseconds / entrance.inMicroseconds;
      _controller.duration = entrance;
      _controller.forward();
    } else {
      _exitFrom = _controller.value;
      _exitOpacity = _entranceOpacity(_exitFrom);
      _exitOffset = _entranceOffset(_exitFrom);
      _exitCurve = context.isMornye
          ? MornyeMotion.effectsFast.curve
          : Easing.standardAccelerate;
      _controller.reverseDuration = MotionPace.duration(
        context.isMornye
            ? const Duration(milliseconds: 160)
            : const Duration(milliseconds: 200),
      );
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _entranceOpacity(double t) =>
      _fade.curve.transform((t / _fadeEnd).clamp(0.0, 1.0));

  double _entranceOffset(double t) =>
      _distance * (1 - _move.curve.transform(t));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final t = _controller.value;
      final exiting = !widget.open;
      final opacity = exiting
          ? _exitFrom <= 0
                ? 0.0
                : _exitOpacity * (1 - _exitCurve.transform(1 - t / _exitFrom))
          : _entranceOpacity(t);
      final offset = exiting ? _exitOffset : _entranceOffset(t);
      final covered = widget.open && _controller.isCompleted;
      return Stack(
        fit: StackFit.expand,
        children: [
          Visibility(
            visible: !covered,
            maintainState: true,
            // Focus leaves the shell as soon as Now Playing opens, and leaves
            // Now Playing as soon as it closes, as without the transition, so
            // a field left focused underneath cannot take Space meanwhile.
            child: IgnorePointer(
              ignoring: widget.open,
              child: ExcludeFocus(excluding: widget.open, child: widget.shell),
            ),
          ),
          if (widget.open || !_controller.isDismissed)
            IgnorePointer(
              ignoring: exiting,
              child: ExcludeFocus(
                excluding: exiting,
                child: Transform.translate(
                  offset: Offset(0, offset),
                  child: Opacity(
                    key: const ValueKey('desktop-now-playing-fade'),
                    opacity: opacity.clamp(0.0, 1.0),
                    child: KeyedSubtree(
                      key: const ValueKey('desktop-now-playing'),
                      child: widget.nowPlaying,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

typedef _ShellBreakpoints = ({bool wide, bool besideFits});

/// Builds the shell again only when the window crosses a breakpoint, so a
/// resize frame does not build the sidebar, rail and inspectors again.
class _WindowBreakpoints extends StatefulWidget {
  const _WindowBreakpoints({required this.builder});

  final Widget Function(BuildContext context, _ShellBreakpoints breakpoints)
  builder;

  @override
  State<_WindowBreakpoints> createState() => _WindowBreakpointsState();
}

class _WindowBreakpointsState extends State<_WindowBreakpoints> {
  _ShellBreakpoints? _breakpoints;
  Widget? _shell;

  @override
  void didUpdateWidget(_WindowBreakpoints oldWidget) {
    super.didUpdateWidget(oldWidget);
    _shell = null;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final breakpoints = (
      wide: width >= desktopExpandedRailBreakpoint,
      besideFits: width >= desktopInspectorBesideBreakpoint,
    );
    if (breakpoints != _breakpoints) {
      _breakpoints = breakpoints;
      _shell = null;
    }
    // A Builder of its own, so the shell's other dependencies rebuild it.
    return _shell ??= Builder(
      builder: (context) => widget.builder(context, breakpoints),
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
      final rtl = Directionality.of(context) == TextDirection.rtl;
      var data = mediaQuery
          .copyWith(size: Size(constraints.maxWidth, constraints.maxHeight))
          .removePadding(
            removeLeft: !rtl,
            removeRight: rtl,
            removeBottom: true,
          );
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

/// The narrowest pane that fits the Mornye capsule beside the glass inspector.
const double _capsuleBesideInspectorWidth = mornyeGlassInspectorWidth + 520;

/// The content pane, the trailing inspector and, in Mornye, the floating
/// player. Pages bring their own search fields (Home, Library), so there is
/// no shell search bar above them.
class _DesktopContentArea extends StatelessWidget {
  const _DesktopContentArea({
    required this.inspectorFitsBeside,
    required this.body,
    this.floatingPlayer,
    this.showPlayer = true,
    this.titleBarDrag = false,
  });

  /// Whether the window is wide enough for the inspector beside the pane.
  final bool inspectorFitsBeside;
  final Widget body;

  /// The Mornye player capsule, floating over the bottom of the pane.
  final Widget? floatingPlayer;
  final bool showPlayer;

  /// Whether the top of the pane is the window's title bar row, where a
  /// drag moves the window.
  final bool titleBarDrag;

  static final Listenable _chromeListenable = Listenable.merge([
    desktopInspectorPanel,
    desktopWindowFullScreen,
  ]);

  @override
  Widget build(BuildContext context) {
    final player = floatingPlayer;
    final playerInset = player == null ? 0.0 : DesktopPlayerBar.floatingInset;
    final mornye = context.isMornye;
    final pages = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A semantics container keeps the tab navigators'
        // modal barriers from hiding the sidebar.
        Expanded(
          key: const ValueKey('desktop-pages'),
          child: Semantics(
            container: true,
            child: _PaneMediaQuery(bottomInset: playerInset, child: body),
          ),
        ),
      ],
    );
    return ListenableBuilder(
      listenable: _chromeListenable,
      builder: (context, _) {
        final panel = showPlayer ? desktopInspectorPanel.value : null;
        final overlayInspector = desktopInspectorOverlaysWhen(
          besideFits: inspectorFitsBeside,
          mornye: mornye,
        );
        Widget buildContent(bool beside) {
          final motion = desktopInspectorMotion(context);
          final stack = Stack(
            fit: StackFit.expand,
            children: [
              pages,
              if (player != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: DesktopPlayerBar.floatingMargin,
                  child: AnimatedPadding(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : motion.duration,
                    curve: motion.curve,
                    padding: EdgeInsetsDirectional.only(
                      end: beside && panel != null
                          ? mornyeGlassInspectorWidth
                          : 0,
                    ),
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
                ),
              // A narrow window's inspector floats above the player.
              PositionedDirectional(
                top: 0,
                bottom: beside ? 0 : playerInset,
                end: 0,
                width: mornye
                    ? mornyeGlassInspectorWidth
                    : desktopInspectorWidth,
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
          return stack;
        }

        // Mornye's glass runs the window's height and the capsule moves
        // beside it, while the pane has room for the two.
        Widget? besideContent;
        Widget? stackedContent;
        final content = LayoutBuilder(
          builder: (context, pane) =>
              mornye &&
                  overlayInspector &&
                  pane.maxWidth >= _capsuleBesideInspectorWidth
              ? (besideContent ??= buildContent(true))
              : (stackedContent ??= buildContent(false)),
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
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: desktopTitleBarHeightFor(context),
              child: const DesktopWindowDragArea(),
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
      // Reduced motion keeps Flutter's rail; Settings stays last. Its extend
      // controller follows the platform's reduced-motion flag, which cuts
      // the 200 ms to a single frame, and the rail stays the same element so
      // a focused destination keeps keyboard focus.
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
              selectedIcon: Badge(
                isLabelVisible: destination.badgeCount > 0,
                label: Text('${destination.badgeCount}'),
                child: AppIcon(destination.selectedIcon),
              ),
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
    // Only reached with expressive motion on; reduced motion takes the
    // static rail above, so the fallback never animates.
    final motion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    final openLink = onOpenLibraryLink;
    // Centered over the collapsed rail, where it stays, in line with the
    // destination icons. Made once, outside the expansion spring.
    final menu = onToggleExtended == null
        ? null
        : SizedBox(
            width: desktopCollapsedRailWidth,
            height: 56,
            child: Center(child: _menuButton(context)),
          );
    return ValueListenableBuilder<String?>(
      valueListenable: desktopSidebarLink,
      builder: (context, openId, _) {
        // An open playlist takes the selection from Library, as a link
        // does in the Mornye sidebar.
        final linkId = openLink != null && selected == ShellTab.library
            ? openId
            : null;
        // One expansion value drives the width, every pill and every label,
        // so the rail morphs continuously instead of swapping layouts at the
        // end. The playlist rows are built once here and only fade.
        return TweenAnimationBuilder<double>(
          tween: Tween(end: extended ? 1 : 0),
          duration: motion.duration,
          curve: motion.curve,
          child: openLink == null
              ? null
              : _RailPlaylists(openId: linkId, onOpen: openLink),
          builder: (context, expansion, playlists) {
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
                // The width stops at its ends while the pills and labels keep
                // the spring: a rail growing past its width would narrow the
                // content below its final size and flip its breakpoints twice.
                width: lerpDouble(
                  desktopCollapsedRailWidth,
                  desktopSidebarWidth,
                  expansion.clamp(0.0, 1.0),
                ),
                child: ClipRect(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ?menu,
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
                              if (playlists != null && playlistsShown > 0)
                                Opacity(
                                  opacity: playlistsShown,
                                  child: playlists,
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
        );
      },
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

/// The Material rail's selection fill: a `secondaryContainer` stadium behind
/// [child]. On selection it grows from its centre, half to full width, on
/// the fast spatial spring while its fill fades in on the fast effects
/// spring; on deselection the fill fades out on the effects spring alone at
/// the width it had, shorter than the entrance. It paints nothing and runs
/// no animation while unselected and faded out.
class _RailIndicator extends StatefulWidget {
  const _RailIndicator({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  State<_RailIndicator> createState() => _RailIndicatorState();
}

class _RailIndicatorState extends State<_RailIndicator>
    with TickerProviderStateMixin {
  // Linear progress; [_growSpec] and [_fadeSpec] shape it when read, so a
  // stopped grow keeps the width it reached.
  AnimationController? _grow;
  AnimationController? _fade;
  Listenable? _listenable;

  // Made on first use, so rows never selected hold no controllers or tickers.
  void _ensureControllers({required double initialValue}) {
    if (_grow != null) return;
    final grow = AnimationController(vsync: this, value: initialValue);
    final fade = AnimationController(vsync: this, value: initialValue);
    _grow = grow;
    _fade = fade;
    _listenable = Listenable.merge([grow, fade]);
  }

  @override
  void initState() {
    super.initState();
    if (widget.selected) {
      _ensureControllers(initialValue: 1);
    }
  }

  AppMotionSpec get _growSpec => AppMotion.spatialFast(
    context,
    const AppMotionSpec(Duration(milliseconds: 200), Curves.easeOutCubic),
  );

  AppMotionSpec get _fadeSpec => AppMotion.effectsFast(
    context,
    const AppMotionSpec(Duration(milliseconds: 150), Curves.easeOut),
  );

  @override
  void didUpdateWidget(_RailIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected == oldWidget.selected) return;
    _ensureControllers(initialValue: oldWidget.selected ? 1 : 0);
    final grow = _grow!;
    final fadeController = _fade!;
    final fade = _fadeSpec;
    fadeController.duration = fade.duration;
    if (widget.selected) {
      // A pill that had faded out grows again from half width; one still
      // fading out grows on from where it is.
      if (fadeController.value == 0) grow.value = 0;
      grow.duration = _growSpec.duration;
      grow.forward();
      fadeController.forward();
    } else {
      // The outgoing pill keeps its width and only fades.
      grow.stop();
      fadeController.reverse();
    }
  }

  @override
  void dispose() {
    _grow?.dispose();
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The same structure before the controllers exist, so a first selection
    // never remounts the row and its focus.
    final growController = _grow;
    final fadeController = _fade;
    final color = Theme.of(context).colorScheme.secondaryContainer;
    final grow = _growSpec.curve;
    final fade = _fadeSpec.curve;
    return AnimatedBuilder(
      animation: _listenable ?? kAlwaysDismissedAnimation,
      child: widget.child,
      builder: (context, child) {
        final fill = fadeController == null
            ? 0.0
            : fade.transform(fadeController.value).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.passthrough,
          children: [
            if (fill > 0 && growController != null)
              Positioned.fill(
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.5 + grow.transform(growController.value) / 2,
                    child: DecoratedBox(
                      key: const ValueKey('desktop-rail-indicator'),
                      decoration: ShapeDecoration(
                        color: color.withValues(alpha: color.a * fill),
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ),
              ),
            child!,
          ],
        );
      },
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
    final press = desktopRowInk(context, content: foreground);
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
          child: _RailIndicator(
            selected: selected,
            child: Material(
              type: MaterialType.transparency,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                hoverColor: foreground.withValues(alpha: 0.08),
                splashFactory: press.splashFactory,
                highlightColor: press.highlightColor,
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
/// Playlists rows' fill, hover and press, and in between they cross-fade
/// around a fixed icon while the row narrows with the rail, as the owner
/// preferred to a morphing pill. Only the row, or the whole 56dp square
/// while collapsed, takes clicks and hover.
class _RailDestination extends StatefulWidget {
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
  State<_RailDestination> createState() => _RailDestinationState();
}

class _RailDestinationState extends State<_RailDestination> {
  static const double _height = 56;

  /// The layers that do not move with the expansion, made once per
  /// selection and theme instead of on every frame of the rail's spring.
  Widget? _icon;
  final _collapsedLayers = <bool, Widget>{};
  final _expandedLayers = <bool, Widget>{};

  void _onTap() => widget.onTap();

  void _forgetLayers() {
    _icon = null;
    _collapsedLayers.clear();
    _expandedLayers.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _forgetLayers();
  }

  @override
  void didUpdateWidget(_RailDestination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected ||
        widget.destination != oldWidget.destination) {
      _forgetLayers();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _forgetLayers();
  }

  Color _foreground(ColorScheme colorScheme) => widget.selected
      ? colorScheme.onSecondaryContainer
      : colorScheme.onSurfaceVariant;

  // A stadium with the selected fill and the hover and press layers of
  // the Playlists rows.
  Widget _surface({required bool active, Widget? child}) {
    final foreground = _foreground(Theme.of(context).colorScheme);
    final press = desktopRowInk(context, content: foreground);
    return _RailIndicator(
      selected: widget.selected,
      child: Material(
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: active ? _onTap : null,
          canRequestFocus: active,
          hoverColor: foreground.withValues(alpha: 0.08),
          splashFactory: press.splashFactory,
          highlightColor: press.highlightColor,
          child: child ?? const SizedBox.expand(),
        ),
      ),
    );
  }

  // Names the icon while the label is hidden; the whole square around the
  // indicator takes the click.
  Widget _collapsedLayer(bool active) => Tooltip(
    message: widget.destination.label,
    excludeFromSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _surface(active: active),
      ),
    ),
  );

  Widget _expandedLayer(bool active) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge!.copyWith(
      fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
      color: _foreground(theme.colorScheme),
    );
    return _surface(
      active: active,
      child: Row(
        children: [
          // The icon is drawn once, above both states.
          const SizedBox(width: 16 + 24 + 8),
          Expanded(
            child: Text(
              widget.destination.label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: style,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget _iconLayer() {
    final destination = widget.destination;
    return PositionedDirectional(
      start: _RailDestination._inset + 16,
      top: (_height - 24) / 2,
      child: IgnorePointer(
        child: IconTheme.merge(
          data: IconThemeData(
            color: _foreground(Theme.of(context).colorScheme),
            size: 24,
          ),
          child: Badge(
            isLabelVisible: destination.badgeCount > 0,
            label: Text('${destination.badgeCount}'),
            child: AppIcon(
              widget.selected ? destination.selectedIcon : destination.icon,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.expansion.clamp(0.0, 1.0);
    const inset = _RailDestination._inset;
    // The expanded pill spans the rail like the Playlists rows below, so
    // every fill and hover lines up at both edges.
    const expandedPillWidth = desktopSidebarWidth - inset * 2;

    // Like the Playlists rows, the expanded row narrows with the rail and
    // fades, and the collapsed indicator fades in where it ends. Neither
    // changes shape, so no long flat pill or edge crosses the label.
    final expanded = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
    final collapsed = ((0.6 - t) / 0.6).clamp(0.0, 1.0);
    final rowWidth = lerpDouble(56, expandedPillWidth, t)!;
    final collapsedActive = t < 0.5;

    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      label: widget.destination.label,
      onTap: widget.onTap,
      child: SizedBox(
        height: _height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (collapsed > 0)
              PositionedDirectional(
                start: inset,
                top: 0,
                width: 56,
                height: _height,
                child: IgnorePointer(
                  ignoring: !collapsedActive,
                  child: ExcludeSemantics(
                    child: Opacity(
                      opacity: collapsed,
                      child: _collapsedLayers[collapsedActive] ??=
                          _collapsedLayer(collapsedActive),
                    ),
                  ),
                ),
              ),
            if (expanded > 0)
              PositionedDirectional(
                start: inset,
                top: 0,
                width: rowWidth,
                height: _height,
                child: IgnorePointer(
                  ignoring: collapsedActive,
                  child: ExcludeSemantics(
                    child: Opacity(
                      opacity: expanded,
                      child: _expandedLayers[!collapsedActive] ??=
                          _expandedLayer(!collapsedActive),
                    ),
                  ),
                ),
              ),
            _icon ??= _iconLayer(),
          ],
        ),
      ),
    );
  }
}

/// The Mornye source-list sidebar: a rounded panel
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
  static const double width = 226;

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

    // Search leads the list.
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
        // The source list scrolls without a scrollbar.
        return NoScrollbars(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
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
      // The tint follows the backdrop's crossfade instead of landing in one
      // frame.
      builder: (context, tint, child) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: panelColor(context, tint)),
        duration: _SidebarBackdrop.crossFade(context).duration,
        curve: _SidebarBackdrop.crossFade(context).curve,
        child: child,
        builder: (context, color, child) => DecoratedBox(
          // One piece with the window: only a hairline parts it
          // from the content, and the window's own corners are its corners.
          decoration: BoxDecoration(
            color: color,
            border: BorderDirectional(
              end: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.1),
                width: 0.5,
              ),
            ),
          ),
          child: child,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _SidebarBackdrop(),
          Material(
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
        ],
      ),
    );
    return SizedBox(width: width, child: panel);
  }
}

/// Extends the page's hero beneath the sidebar's backdrop blur.
///
/// The sidebar and the page are separate panes, so this paints the artwork
/// again rather than sampling the page: a tiny decode, enlarged and mirrored
/// at the seam. The enlargement is the blur, with no filter to rerun on each
/// scroll frame, and the mirror meets the hero's edge with the same colors.
class _SidebarBackdrop extends StatelessWidget {
  const _SidebarBackdrop();

  /// Decoded width; the fewer pixels, the softer the enlarged image.
  static const int _decodeWidth = 48;

  /// The artwork's crossfade, which the panel's tint follows: Mornye's
  /// effects spring, or a cut with reduced motion.
  static AppMotionSpec crossFade(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? const AppMotionSpec(Duration.zero, Curves.linear)
      : MornyeMotion.effects;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: ShellNavigationService.chromeBackdrop,
    builder: (context, source, _) {
      final image = source == null
          ? null
          : coverImageProvider(source, cacheWidth: _decodeWidth);
      final fade = crossFade(context);
      return AnimatedSwitcher(
        duration: fade.duration,
        switchInCurve: fade.curve,
        switchOutCurve: fade.leaving,
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.expand, children: [...previous, ?current]),
        child: image == null
            ? const SizedBox.expand()
            : ClipRect(
                key: ValueKey(source),
                child: _SidebarArtwork(image: image),
              ),
      );
    },
  );
}

class _SidebarArtwork extends StatelessWidget {
  const _SidebarArtwork({required this.image});

  final ImageProvider image;

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final hero = Size(
      window.width - DesktopSidebar.width,
      // MornyeArtistHeader's hero height on the desktop.
      (window.height * 0.82).clamp(420.0, 820.0),
    );
    return ValueListenableBuilder<Color?>(
      valueListenable: ShellNavigationService.chromeSurface,
      builder: (context, tint, _) {
        final fill = DesktopSidebar.panelColor(context, tint);
        return AnimatedBuilder(
          animation: ShellNavigationService.chromeBackdropOffset,
          builder: (context, child) => Transform.translate(
            offset: Offset(
              0,
              -ShellNavigationService.chromeBackdropOffset.value,
            ),
            child: child,
          ),
          child: RepaintBoundary(
            child: SizedBox(
              width: DesktopSidebar.width,
              height: hero.height,
              child: ClipRect(
                child: OverflowBox(
                  alignment: AlignmentDirectional.topEnd,
                  minWidth: hero.width,
                  maxWidth: hero.width,
                  minHeight: hero.height,
                  maxHeight: hero.height,
                  child: Stack(
                    key: const ValueKey('desktop-sidebar-backdrop'),
                    fit: StackFit.expand,
                    children: [
                      Transform.flip(
                        flipX: true,
                        child: Image(
                          image: image,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          filterQuality: FilterQuality.high,
                          gaplessPlayback: true,
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                      // The sidebar glass fades out where the hero ends.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0, 0.6, 1],
                            colors: [
                              fill.withValues(alpha: 0.42),
                              fill.withValues(alpha: 0.62),
                              fill,
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The account row pinned under the sidebar's list: the
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
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
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
    height: desktopTitleBarInContentFor(context)
        ? desktopTitleBarHeightFor(context)
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

/// One source-list row: a 32pt row inset 6pt from the
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
