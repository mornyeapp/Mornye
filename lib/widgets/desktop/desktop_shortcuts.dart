import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/music_playback_deck.dart'
    show usbHardwareVolume;
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/desktop/desktop_window_controls.dart';
import 'package:url_launcher/url_launcher.dart';

/// Keyboard shortcuts for desktop builds, plus the macOS menu bar that
/// mirrors them. Wraps the app content above the root navigator, so the
/// shortcuts also work over Now Playing, dialogs and pushed pages.
///
/// Escape first leaves a focused text field, then closes the top dialog or
/// page, like the Android back button. Open menus handle Escape themselves
/// before it reaches these shortcuts.
class DesktopShortcuts extends ConsumerStatefulWidget {
  const DesktopShortcuts({super.key, required this.child, this.navigatorKey});

  final Widget child;

  /// The root navigator; defaults to [AppNavigationService.rootNavigatorKey].
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  ConsumerState<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends ConsumerState<DesktopShortcuts> {
  static const _volumeStep = 0.05;

  // Holds focus while no control or page has it, so shortcuts still reach
  // the actions below before a route claims focus.
  final _idleFocus = FocusNode(debugLabel: 'DesktopShortcuts');

  late final Map<Type, Action<Intent>> _actions = {
    DesktopCommandIntent: _DesktopCommandAction(this),
    DesktopDestinationIntent: CallbackAction<DesktopDestinationIntent>(
      onInvoke: (intent) => _selectDestination(intent.position),
    ),
  };

  NavigatorState? get _rootNavigator =>
      (widget.navigatorKey ?? AppNavigationService.rootNavigatorKey)
          .currentState;

  @override
  void dispose() {
    _idleFocus.dispose();
    super.dispose();
  }

  bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  /// Space toggles playback only when no control has focus; a focused button
  /// keeps Space for activation.
  bool get _nothingFocused {
    final focus = FocusManager.instance.primaryFocus;
    return focus == null || focus is FocusScopeNode || focus == _idleFocus;
  }

  bool _playerCommand(DesktopCommand command) => switch (command) {
    DesktopCommand.playPause ||
    DesktopCommand.next ||
    DesktopCommand.previous ||
    DesktopCommand.volumeUp ||
    DesktopCommand.volumeDown ||
    DesktopCommand.lyrics ||
    DesktopCommand.upNext ||
    DesktopCommand.miniPlayer => true,
    _ => false,
  };

  bool _canRun(DesktopCommand command) {
    if (_playerCommand(command) && !ref.read(playerUiEnabledProvider)) {
      return false;
    }
    return switch (command) {
      DesktopCommand.playPause => !_editingText && _nothingFocused,
      // Text fields use these keys for caret movement.
      DesktopCommand.next ||
      DesktopCommand.previous ||
      DesktopCommand.volumeUp ||
      DesktopCommand.volumeDown => !_editingText,
      DesktopCommand.back => _canCloseTopLayer,
      DesktopCommand.dismiss =>
        _editingText ||
            _canCloseTopLayer ||
            desktopWindowMode.value != DesktopWindowMode.windowed,
      _ => true,
    };
  }

  void _run(DesktopCommand command) {
    if (_playerCommand(command) && !ref.read(playerUiEnabledProvider)) return;
    final controller = ref.read(musicPlayerControllerProvider);
    switch (command) {
      case DesktopCommand.playPause:
        unawaited(
          controller.togglePlayPause(ref.read(playbackPlayingProvider)),
        );
      case DesktopCommand.next:
        unawaited(controller.next());
      case DesktopCommand.previous:
        unawaited(controller.previous());
      case DesktopCommand.volumeUp:
        _nudgeVolume(_volumeStep);
      case DesktopCommand.volumeDown:
        _nudgeVolume(-_volumeStep);
      case DesktopCommand.search:
        _closePages();
        ShellNavigationService.requestSearch();
      case DesktopCommand.settings:
        _closePages();
        ShellNavigationService.requestTab(ShellTab.settings);
      case DesktopCommand.back:
        _closeTopLayer();
      case DesktopCommand.dismiss:
        if (_editingText) {
          FocusManager.instance.primaryFocus?.unfocus();
        } else if (_canCloseTopLayer) {
          _closeTopLayer();
        } else {
          unawaited(leaveDesktopWindowMode());
        }
      case DesktopCommand.lyrics:
        toggleDesktopInspector(DesktopInspectorPanel.lyrics);
      case DesktopCommand.upNext:
        toggleDesktopInspector(DesktopInspectorPanel.upNext);
      case DesktopCommand.toggleSidebar:
        toggleDesktopSidebar();
      case DesktopCommand.refresh:
        AppRefreshIndicator.refreshVisible();
      case DesktopCommand.miniPlayer:
        unawaited(toggleDesktopMiniPlayer());
      case DesktopCommand.fullScreen:
        unawaited(_changeWindowMode(toggleDesktopFullScreen));
      case DesktopCommand.borderless:
        unawaited(_changeWindowMode(toggleDesktopBorderless));
    }
  }

  Future<void> _changeWindowMode(Future<bool> Function() change) async {
    if (desktopMiniPlayerOpen.value) {
      await setDesktopMiniPlayer(open: false);
      if (desktopMiniPlayerOpen.value) return;
    }
    await change();
  }

  void _selectDestination(int position) {
    final context = _rootNavigator?.context ?? this.context;
    final tabs = desktopDestinationTabs(
      mornye: context.isMornye,
      showStore: ref.read(settingsProvider).showExtensionStore,
    );
    if (position < 1 || position > tabs.length) return;
    final tab = tabs[position - 1];
    _closePages();
    if (tab == ShellTab.search) {
      ShellNavigationService.requestSearch();
    } else {
      ShellNavigationService.requestTab(tab);
    }
  }

  /// Closes pages above the shell (Now Playing, Settings) before switching
  /// destinations, stopping at a dialog or sheet.
  void _closePages() {
    _rootNavigator?.popUntil(
      (route) => route.isFirst || route is! PageRoute<dynamic>,
    );
  }

  /// Reads the window width without depending on it: commands run outside
  /// build, and a dependency would rebuild this layer on every resize.
  double get _windowWidth =>
      context.getInheritedWidgetOfExactType<MediaQuery>()!.data.size.width;

  bool get _canCloseTopLayer =>
      _rootNavigator?.canPop() == true ||
      canDismissDesktopPlayerLayer(_windowWidth) ||
      ShellNavigationService.activeBackNavigator()?.canPop() == true;

  /// Closes what Escape or Back closes: a dialog or page over the shell
  /// first, then the floating inspector or Now Playing, then the active
  /// destination's own pages.
  void _closeTopLayer() {
    final root = _rootNavigator;
    if (root != null && root.canPop()) {
      unawaited(root.maybePop());
      return;
    }
    if (dismissDesktopPlayerLayer(_windowWidth)) return;
    final tab = ShellNavigationService.activeBackNavigator();
    if (tab != null && tab.canPop()) unawaited(tab.maybePop());
  }

  void _nudgeVolume(double delta) {
    final usb = usbHardwareVolume.value;
    final current = usb == null
        ? ref.read(systemVolumeProvider).value
        : usb.available
        ? usb.fraction
        : null;
    if (current == null) return;
    unawaited(
      ref.read(systemVolumeWriterProvider)((current + delta).clamp(0.0, 1.0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerUiEnabledProvider, (_, enabled) {
      if (enabled) return;
      desktopNowPlayingOpen.value = false;
      desktopInspectorPanel.value = null;
      if (desktopMiniPlayerOpen.value) {
        unawaited(setDesktopMiniPlayer(open: false));
      }
    });
    // Keeps the playback and volume streams alive so the shortcuts read
    // current values even while no player surface is visible.
    ref.listen(playbackPlayingProvider, (_, _) {});
    ref.listen(systemVolumeProvider, (_, _) {});
    Widget child = Shortcuts(
      shortcuts: desktopShortcutBindings(),
      child: Actions(
        actions: _actions,
        child: Focus(
          focusNode: _idleFocus,
          autofocus: true,
          child: ValueListenableBuilder<bool>(
            valueListenable: desktopMiniPlayerOpen,
            builder: (context, mini, _) => DesktopWindowFrame(
              showControls: !mini,
              navigatorKey: widget.navigatorKey,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      child = ValueListenableBuilder<DesktopWindowMode>(
        valueListenable: desktopWindowMode,
        child: child,
        builder: (context, _, child) =>
            _DesktopMenuBar(state: this, child: child!),
      );
    }
    return child;
  }
}

class _DesktopCommandAction extends Action<DesktopCommandIntent> {
  _DesktopCommandAction(this._state);

  final _DesktopShortcutsState _state;

  @override
  bool isEnabled(DesktopCommandIntent intent) => _state._canRun(intent.command);

  @override
  Object? invoke(DesktopCommandIntent intent) {
    _state._run(intent.command);
    return null;
  }
}

/// The macOS menu bar. Items show the same shortcuts as the key bindings;
/// Play/Pause stays unregistered so typing a space never reaches the menu.
class _DesktopMenuBar extends ConsumerStatefulWidget {
  const _DesktopMenuBar({required this.state, required this.child});

  final _DesktopShortcutsState state;
  final Widget child;

  @override
  ConsumerState<_DesktopMenuBar> createState() => _DesktopMenuBarState();
}

class _DesktopMenuBarState extends ConsumerState<_DesktopMenuBar> {
  // PlatformMenuItem has no ==, so a new list makes PlatformMenuBar send
  // the whole menu to the platform again. The items are rebuilt only when
  // something they show changes.
  Object? _shown;
  List<PlatformMenuItem> _menus = const [];

  PlatformMenuItem _command(String label, DesktopCommand command) {
    final state = widget.state;
    return PlatformMenuItem(
      label: label,
      shortcut: command == DesktopCommand.playPause
          ? null
          : desktopCommandShortcut(command),
      onSelected: () => state._run(command),
    );
  }

  PlatformMenuItem _textCommand(
    String label,
    SingleActivator shortcut,
    Intent intent,
  ) => PlatformMenuItem(
    label: label,
    shortcut: shortcut,
    onSelected: () {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null) Actions.maybeInvoke(focused, intent);
    },
  );

  Iterable<PlatformMenuItem> _provided(
    List<PlatformProvidedMenuItemType> types,
  ) => [
    for (final type in types)
      if (PlatformProvidedMenuItem.hasMenu(type))
        PlatformProvidedMenuItem(type: type),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final mornye = context.isMornye;
    final showPlayer = ref.watch(playerUiEnabledProvider);
    final showStore = ref.watch(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final fullScreen = desktopWindowFullScreen.value;
    final mode = desktopWindowMode.value;
    final shown = (
      widget.state,
      l10n,
      material,
      mornye,
      showPlayer,
      showStore,
      fullScreen,
      mode,
      desktopMiniPlayerSupported,
    );
    if (shown != _shown) {
      _shown = shown;
      _menus = _buildMenus(
        l10n: l10n,
        material: material,
        tabs: desktopDestinationTabs(mornye: mornye, showStore: showStore),
        showPlayer: showPlayer,
        fullScreen: fullScreen,
        mode: mode,
      );
    }
    return PlatformMenuBar(menus: _menus, child: widget.child);
  }

  List<PlatformMenuItem> _buildMenus({
    required AppLocalizations l10n,
    required MaterialLocalizations material,
    required List<ShellTab> tabs,
    required bool showPlayer,
    required bool fullScreen,
    required DesktopWindowMode mode,
  }) {
    final state = widget.state;
    String tabLabel(ShellTab tab) => switch (tab) {
      ShellTab.home => l10n.navHome,
      ShellTab.library => l10n.navLibrary,
      ShellTab.repository => l10n.navStore,
      ShellTab.search => l10n.mornyeSearch,
      ShellTab.settings => l10n.navSettings,
    };
    return [
      PlatformMenu(
        label: AppInfo.appName,
        menus: [
          PlatformMenuItemGroup(
            members: [
              ..._provided([PlatformProvidedMenuItemType.about]),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              _command(l10n.desktopMenuSettings, DesktopCommand.settings),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              ..._provided([PlatformProvidedMenuItemType.servicesSubmenu]),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              ..._provided([
                PlatformProvidedMenuItemType.hide,
                PlatformProvidedMenuItemType.hideOtherApplications,
                PlatformProvidedMenuItemType.showAllApplications,
              ]),
            ],
          ),
          ..._provided([PlatformProvidedMenuItemType.quit]),
        ],
      ),
      PlatformMenu(
        label: l10n.desktopMenuFile,
        menus: [_command(l10n.mornyeSearch, DesktopCommand.search)],
      ),
      PlatformMenu(
        label: l10n.desktopMenuEdit,
        menus: [
          _textCommand(
            material.cutButtonLabel,
            const SingleActivator(LogicalKeyboardKey.keyX, meta: true),
            CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          _textCommand(
            material.copyButtonLabel,
            const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
            CopySelectionTextIntent.copy,
          ),
          _textCommand(
            material.pasteButtonLabel,
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true),
            const PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          _textCommand(
            material.selectAllButtonLabel,
            const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
        ],
      ),
      PlatformMenu(
        label: l10n.desktopMenuView,
        menus: [
          PlatformMenuItemGroup(
            members: [
              for (var i = 0; i < tabs.length; i++)
                PlatformMenuItem(
                  label: tabLabel(tabs[i]),
                  shortcut: i < 5 ? desktopDestinationShortcut(i + 1) : null,
                  onSelected: () => state._selectDestination(i + 1),
                ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              _command(material.backButtonTooltip, DesktopCommand.back),
              _command(l10n.desktopMenuRefresh, DesktopCommand.refresh),
              if (showPlayer)
                _command(l10n.nowPlayingTabLyrics, DesktopCommand.lyrics),
              if (showPlayer)
                _command(l10n.nowPlayingUpNext, DesktopCommand.upNext),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              _command(
                fullScreen
                    ? l10n.desktopExitFullscreen
                    : l10n.desktopWindowFullscreen,
                DesktopCommand.fullScreen,
              ),
              _command(
                mode == DesktopWindowMode.borderless
                    ? l10n.desktopWindowed
                    : l10n.desktopWindowBorderless,
                DesktopCommand.borderless,
              ),
            ],
          ),
        ],
      ),
      if (showPlayer)
        PlatformMenu(
          label: l10n.desktopMenuControls,
          menus: [
            PlatformMenuItemGroup(
              members: [
                _command(l10n.desktopMenuPlayPause, DesktopCommand.playPause),
                _command(l10n.nowPlayingNextTrack, DesktopCommand.next),
                _command(l10n.nowPlayingPreviousTrack, DesktopCommand.previous),
              ],
            ),
            PlatformMenuItemGroup(
              members: [
                _command(l10n.desktopVolumeUp, DesktopCommand.volumeUp),
                _command(l10n.desktopVolumeDown, DesktopCommand.volumeDown),
              ],
            ),
          ],
        ),
      PlatformMenu(
        label: l10n.desktopMenuWindow,
        menus: [
          ..._provided([
            PlatformProvidedMenuItemType.minimizeWindow,
            PlatformProvidedMenuItemType.zoomWindow,
          ]),
          if (showPlayer && desktopMiniPlayerSupported)
            PlatformMenuItemGroup(
              members: [
                _command(l10n.desktopMenuMiniPlayer, DesktopCommand.miniPlayer),
              ],
            ),
          PlatformMenuItemGroup(
            members: [
              ..._provided([
                PlatformProvidedMenuItemType.arrangeWindowsInFront,
              ]),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: l10n.desktopMenuHelp,
        menus: [
          PlatformMenuItem(
            label: l10n.desktopMenuProjectPage,
            onSelected: () => unawaited(
              launchUrl(
                Uri.parse(AppInfo.githubUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ),
        ],
      ),
    ];
  }
}
