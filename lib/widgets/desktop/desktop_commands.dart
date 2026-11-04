import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';

export 'package:mornye/widgets/desktop/desktop_inspector.dart'
    show DesktopInspectorPanel, toggleDesktopInspector;

/// App-wide desktop commands. Each one has one keyboard shortcut, mirrored in
/// the macOS menu bar and named in the tooltip of the control that runs it.
enum DesktopCommand {
  openAudioFiles,
  openAudioFolder,
  playPause,
  next,
  previous,
  volumeUp,
  volumeDown,
  search,
  settings,
  back,
  forward,
  lyrics,
  upNext,
  toggleSidebar,

  /// Refreshes the page on screen when it can refresh
  /// ([AppRefreshIndicator.refreshVisible]).
  refresh,

  /// Turns the window into the floating mini player, or back.
  miniPlayer,

  fullScreen,
  borderless,

  /// Escape: leaves a focused text field, otherwise closes the top dialog
  /// or page.
  dismiss,
}

/// Runs a [DesktopCommand] through the desktop [Actions].
class DesktopCommandIntent extends Intent {
  const DesktopCommandIntent(this.command);

  final DesktopCommand command;
}

/// Selects the [position]th (1-based) desktop destination.
class DesktopDestinationIntent extends Intent {
  const DesktopDestinationIntent(this.position);

  final int position;
}

/// Command on macOS, Control elsewhere.
bool _usesCommandKey(TargetPlatform platform) =>
    platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;

SingleActivator _primary(
  LogicalKeyboardKey key,
  TargetPlatform platform, {
  bool shift = false,
  bool alt = false,
}) {
  final command = _usesCommandKey(platform);
  return SingleActivator(
    key,
    meta: command,
    control: !command,
    shift: shift,
    alt: alt,
  );
}

/// The shortcut for [command], or null when it has none on [platform].
SingleActivator? desktopCommandShortcut(
  DesktopCommand command, [
  TargetPlatform? platform,
]) {
  final target = platform ?? defaultTargetPlatform;
  return switch (command) {
    DesktopCommand.openAudioFiles => _primary(LogicalKeyboardKey.keyO, target),
    DesktopCommand.openAudioFolder => _primary(
      LogicalKeyboardKey.keyO,
      target,
      shift: true,
    ),
    DesktopCommand.playPause => const SingleActivator(LogicalKeyboardKey.space),
    DesktopCommand.next => _primary(LogicalKeyboardKey.arrowRight, target),
    DesktopCommand.previous => _primary(LogicalKeyboardKey.arrowLeft, target),
    DesktopCommand.volumeUp => _primary(LogicalKeyboardKey.arrowUp, target),
    DesktopCommand.volumeDown => _primary(LogicalKeyboardKey.arrowDown, target),
    DesktopCommand.search => _primary(LogicalKeyboardKey.keyF, target),
    DesktopCommand.settings => _primary(LogicalKeyboardKey.comma, target),
    DesktopCommand.back => _primary(LogicalKeyboardKey.bracketLeft, target),
    DesktopCommand.forward => _primary(LogicalKeyboardKey.bracketRight, target),
    DesktopCommand.lyrics => _primary(
      LogicalKeyboardKey.keyL,
      target,
      shift: true,
    ),
    DesktopCommand.upNext => _primary(
      LogicalKeyboardKey.keyU,
      target,
      shift: true,
    ),
    // The standard macOS "Show Sidebar" shortcut.
    DesktopCommand.toggleSidebar =>
      _usesCommandKey(target)
          ? const SingleActivator(
              LogicalKeyboardKey.keyS,
              meta: true,
              control: true,
            )
          : null,
    DesktopCommand.refresh => _primary(LogicalKeyboardKey.keyR, target),
    // Use Cmd+Option+M on macOS. Ctrl+Alt elsewhere is AltGr
    // on many keyboard layouts, so Windows and Linux add Shift instead.
    DesktopCommand.miniPlayer => _primary(
      LogicalKeyboardKey.keyM,
      target,
      alt: _usesCommandKey(target),
      shift: !_usesCommandKey(target),
    ),
    DesktopCommand.dismiss => const SingleActivator(LogicalKeyboardKey.escape),
    DesktopCommand.fullScreen =>
      _usesCommandKey(target)
          ? const SingleActivator(
              LogicalKeyboardKey.keyF,
              control: true,
              meta: true,
            )
          : const SingleActivator(LogicalKeyboardKey.f11),
    DesktopCommand.borderless => _primary(
      LogicalKeyboardKey.keyB,
      target,
      shift: true,
    ),
  };
}

const _destinationKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
];

/// Includes the native menu shortcut and any additional keyboard bindings.
List<SingleActivator> desktopCommandShortcuts(
  DesktopCommand command, [
  TargetPlatform? platform,
]) {
  final target = platform ?? defaultTargetPlatform;
  return [
    ?desktopCommandShortcut(command, target),
    if (command == DesktopCommand.fullScreen && _usesCommandKey(target))
      const SingleActivator(LogicalKeyboardKey.f11),
    // The Back and Forward keys of Windows and Linux keyboards. Mouse side
    // buttons arrive as pointer buttons instead (DesktopShortcuts).
    if (command == DesktopCommand.back && !_usesCommandKey(target))
      const SingleActivator(LogicalKeyboardKey.browserBack),
    if (command == DesktopCommand.forward && !_usesCommandKey(target))
      const SingleActivator(LogicalKeyboardKey.browserForward),
  ];
}

/// The shortcut that selects the [position]th (1-based) destination.
SingleActivator desktopDestinationShortcut(
  int position, [
  TargetPlatform? platform,
]) =>
    _primary(_destinationKeys[position - 1], platform ?? defaultTargetPlatform);

final _shortcutBindings = <TargetPlatform, Map<ShortcutActivator, Intent>>{};

/// Every desktop key binding. Each platform gets one unmodifiable map, so
/// [Shortcuts] keeps its index when the shortcut layer rebuilds.
Map<ShortcutActivator, Intent> desktopShortcutBindings([
  TargetPlatform? platform,
]) {
  final target = platform ?? defaultTargetPlatform;
  return _shortcutBindings[target] ??= Map.unmodifiable({
    for (final command in DesktopCommand.values)
      for (final shortcut in desktopCommandShortcuts(command, target))
        shortcut: DesktopCommandIntent(command),
    for (var position = 1; position <= _destinationKeys.length; position++)
      desktopDestinationShortcut(position, target): DesktopDestinationIntent(
        position,
      ),
  });
}

/// Human-readable form of [activator]: "⌘→" on macOS, "Ctrl+Right" elsewhere.
String desktopShortcutLabel(
  SingleActivator activator, [
  TargetPlatform? platform,
]) {
  final mac = _usesCommandKey(platform ?? defaultTargetPlatform);
  final trigger = activator.trigger;
  final key = switch (trigger) {
    LogicalKeyboardKey.arrowLeft => mac ? '←' : 'Left',
    LogicalKeyboardKey.arrowRight => mac ? '→' : 'Right',
    LogicalKeyboardKey.arrowUp => mac ? '↑' : 'Up',
    LogicalKeyboardKey.arrowDown => mac ? '↓' : 'Down',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.escape => mac ? '⎋' : 'Esc',
    _ => trigger.keyLabel.toUpperCase(),
  };
  final parts = [
    if (activator.control) mac ? '⌃' : 'Ctrl',
    if (activator.alt) mac ? '⌥' : 'Alt',
    if (activator.shift) mac ? '⇧' : 'Shift',
    if (activator.meta) mac ? '⌘' : 'Win',
    key,
  ];
  return mac ? parts.join() : parts.join('+');
}

/// [label] followed by the shortcut of [command] on desktop; [label] alone on
/// phones and tablets, which have no keyboard shortcuts.
String desktopTooltip(
  BuildContext context,
  String label,
  DesktopCommand command,
) {
  if (!isDesktopPlatform) return label;
  final activator = desktopCommandShortcut(command);
  if (activator == null) return label;
  return context.l10n.desktopShortcutTooltip(
    label,
    desktopShortcutLabel(activator),
  );
}

/// The same as [desktopTooltip] for a destination at [position] (1-based).
String desktopDestinationTooltip(
  BuildContext context,
  String label,
  int position,
) {
  if (!isDesktopPlatform || position > _destinationKeys.length) return label;
  return context.l10n.desktopShortcutTooltip(
    label,
    desktopShortcutLabel(desktopDestinationShortcut(position)),
  );
}

/// Desktop destinations in rail or sidebar order. Cmd/Ctrl+1..5 select them
/// by position. Mornye reaches Search from the sidebar search field.
List<ShellTab> desktopDestinationTabs({
  required bool mornye,
  required bool showStore,
}) => [
  ShellTab.home,
  ShellTab.library,
  if (showStore) ShellTab.repository,
  if (mornye) ShellTab.search,
  ShellTab.settings,
];

const _sidebarCollapsedKey = 'desktop_sidebar_collapsed';

/// Whether the Material desktop rail is collapsed. Wide windows start with
/// it expanded; the sidebar shortcut toggles it and the choice is kept.
final desktopSidebarCollapsed = ValueNotifier<bool>(false);

/// Restores the rail state [toggleDesktopSidebar] last saved.
void restoreDesktopSidebar(SharedPreferences prefs) =>
    desktopSidebarCollapsed.value =
        prefs.getBool(_sidebarCollapsedKey) ?? false;

/// Collapses or expands the Material rail and remembers the choice.
void toggleDesktopSidebar() {
  final collapsed = desktopSidebarCollapsed.value =
      !desktopSidebarCollapsed.value;
  unawaited(
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_sidebarCollapsedKey, collapsed),
    ),
  );
}

/// Opens Now Playing in the content pane. Lyrics and Up Next live in the
/// trailing inspector, toggled with [toggleDesktopInspector].
void openDesktopNowPlaying() => desktopNowPlayingOpen.value = true;
