import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/settings_group.dart';

String desktopWindowModeLabel(BuildContext context, DesktopWindowMode mode) =>
    switch (mode) {
      DesktopWindowMode.windowed => context.l10n.desktopWindowed,
      DesktopWindowMode.fullscreen => context.l10n.desktopWindowFullscreen,
      DesktopWindowMode.borderless => context.l10n.desktopWindowBorderless,
    };

Future<void> _chooseMode(BuildContext context) async {
  final selected = await showAppBottomSheet<DesktopWindowMode>(
    context: context,
    builder: (context) => AppBottomSheet(
      title: context.l10n.desktopWindowMode,
      child: SettingsGroup(
        children: [
          for (final mode in DesktopWindowMode.values)
            SettingsItem(
              title: desktopWindowModeLabel(context, mode),
              selected: desktopWindowMode.value == mode,
              showDivider: mode != DesktopWindowMode.values.last,
              onTap: () => Navigator.pop(context, mode),
            ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final changed = await setDesktopWindowMode(selected);
  if (!changed && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.l10n.desktopWindowModeUnavailable)),
    );
  }
}

class DesktopWindowModeSetting extends StatelessWidget {
  const DesktopWindowModeSetting({super.key});

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<DesktopWindowMode>(
        valueListenable: desktopWindowMode,
        builder: (context, mode, _) => SettingsItem(
          icon: Icons.desktop_windows_outlined,
          title: context.l10n.desktopWindowMode,
          subtitle: desktopWindowModeLabel(context, mode),
          showDivider: false,
          onTap: () => unawaited(_chooseMode(context)),
        ),
      );
}

/// Borderless window controls stay above pages and dialogs. Fullscreen keeps
/// the entire surface for content; the mini player supplies its own controls.
class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({
    super.key,
    required this.child,
    this.showControls = true,
    this.navigatorKey,
  });

  final Widget child;
  final bool showControls;
  final GlobalKey<NavigatorState>? navigatorKey;

  void _chooseWindowMode() {
    final context = (navigatorKey ?? AppNavigationService.rootNavigatorKey)
        .currentState
        ?.overlay
        ?.context;
    if (context != null) unawaited(_chooseMode(context));
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return child;
    return DesktopWindowModeScope(
      child: ValueListenableBuilder<DesktopWindowMode>(
        valueListenable: desktopWindowMode,
        child: child,
        builder: (context, mode, child) {
          final left = Directionality.of(context) == TextDirection.rtl;
          // The replacement title bar sits above the root navigator. Give
          // its tooltips an overlay while keeping the navigator mounted.
          return Overlay.wrap(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    if (showControls && mode == DesktopWindowMode.borderless)
                      _BorderlessWindowControls(onChooseMode: _chooseWindowMode)
                    else
                      const SizedBox.shrink(),
                    Expanded(child: child!),
                  ],
                ),
                if (showControls && mode == DesktopWindowMode.borderless)
                  PositionedDirectional(
                    bottom: 0,
                    end: 0,
                    child: MouseRegion(
                      cursor: left
                          ? SystemMouseCursors.resizeDownLeft
                          : SystemMouseCursors.resizeDownRight,
                      child: GestureDetector(
                        key: const ValueKey('desktop-window-resize'),
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) =>
                            unawaited(resizeDesktopWindow(fromLeft: left)),
                        child: Padding(
                          padding: EdgeInsets.all(context.tokens.gapXs),
                          child: AppIcon(
                            left ? Icons.south_west : Icons.south_east,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BorderlessWindowControls extends StatelessWidget {
  const _BorderlessWindowControls({required this.onChooseMode});

  final VoidCallback onChooseMode;

  @override
  Widget build(BuildContext context) {
    final title = SizedBox(
      height: context.tokens.minTouchTarget,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          desktopWindowModeLabel(context, DesktopWindowMode.borderless),
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: context.tokens.gapMd),
        child: Row(
          children: [
            Expanded(
              child: DesktopWindowDragArea(
                frameless: true,
                zoomOnDoubleClick: true,
                child: title,
              ),
            ),
            AppIconButton(
              tooltip: context.l10n.desktopWindowMode,
              icon: const AppIcon(Icons.desktop_windows_outlined),
              onPressed: onChooseMode,
            ),
            AppIconButton(
              tooltip: desktopTooltip(
                context,
                context.l10n.desktopWindowed,
                DesktopCommand.borderless,
              ),
              icon: const AppIcon(Icons.filter_none),
              onPressed: () => unawaited(leaveDesktopWindowMode()),
            ),
            AppIconButton(
              tooltip: context.l10n.desktopMinimizeWindow,
              icon: const AppIcon(Icons.minimize),
              onPressed: minimizeDesktopWindow,
            ),
            AppIconButton(
              tooltip: context.l10n.desktopZoomWindow,
              icon: const AppIcon(Icons.crop_square),
              onPressed: zoomDesktopWindow,
            ),
            AppIconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: const AppIcon(Icons.close),
              onPressed: closeDesktopWindow,
            ),
          ],
        ),
      ),
    );
  }
}
