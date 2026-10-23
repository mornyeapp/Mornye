import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoButton, CupertinoDynamicColor, kCupertinoModalBarrierColor;
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/theme/mornye_icons.dart';

/// The drag handle shown at the top of every modal sheet.
///
/// Sheets using Material's `showDragHandle` should not add this handle.
class AppSheetHandle extends StatelessWidget {
  const AppSheetHandle({super.key, this.margin});

  /// Overrides the default spacing around the handle. Sheets whose first row
  /// already carries top padding pass [EdgeInsets.zero].
  final EdgeInsetsGeometry? margin;

  static const double _width = 40;
  static const double _height = 4;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // Desktop shows sheets as dialogs, which nothing drags.
    if (isDesktopPlatform) return SizedBox(height: tokens.gapMd);
    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: _width,
          height: _height,
          margin:
              margin ??
              EdgeInsets.only(top: tokens.gapMd, bottom: tokens.gapSm),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(_height / 2),
          ),
        ),
      ),
    );
  }
}

/// Standard chrome for modal sheet content: drag handle, optional title block,
/// height cap, keyboard inset and bottom safe area, so each sheet only supplies
/// its own body.
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    required this.child,
    this.showHandle = true,
    this.title,
    this.titleTrailing,
    this.subtitle,
    this.maxHeightFactor,
  });

  final Widget child;
  final bool showHandle;

  /// Leading title row. Rendered with the app's single sheet-title style
  /// instead of the three variants that had accumulated across sheets.
  final String? title;

  /// Optional action beside [title], outside the scrolling body.
  final Widget? titleTrailing;

  /// Secondary line under [title], e.g. the track a sheet is acting on.
  final String? subtitle;

  /// Caps the sheet at this fraction of the screen height.
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    // Material desktop dialogs end their header with a close button for the
    // pointer; Esc and a click outside close them too.
    final closes =
        titleTrailing == null && isDesktopPlatform && !context.isMornye;
    final trailing = closes ? const _SheetDialogCloseButton() : titleTrailing;

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHandle) const AppSheetHandle(),
        if (title != null)
          Padding(
            // The close button's touch target is taller than the title, so
            // its row starts higher to keep the title where it sat before.
            padding: EdgeInsetsDirectional.fromSTEB(
              tokens.gapXl,
              closes ? tokens.gapXs : tokens.gapLg,
              closes ? tokens.gapMd : tokens.gapXl,
              subtitle == null ? tokens.gapSm : tokens.gapXs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title!,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  SizedBox(width: tokens.gapSm),
                  trailing,
                ],
              ],
            ),
          ),
        if (subtitle != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.gapXl,
              0,
              tokens.gapXl,
              tokens.gapMd,
            ),
            child: Text(
              subtitle!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Flexible(child: child),
      ],
    );

    if (maxHeightFactor != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor!,
        ),
        child: content,
      );
    }

    // Sheets containing text fields must lift above the keyboard; doing it here
    // means no call site has to remember `viewInsets`.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(top: false, child: content),
    );
  }
}

class _SheetDialogCloseButton extends StatelessWidget {
  const _SheetDialogCloseButton();

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: const AppIcon(Icons.close_rounded),
    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
    onPressed: () => Navigator.of(context).maybePop(),
  );
}

/// Opens a modal bottom sheet wrapped in [AppBottomSheet].
///
/// The shape comes from `ThemeData.bottomSheetTheme`, which is derived from
/// [AppTokens.radiusSheet]; call sites no longer pass a `shape` and therefore
/// cannot drift from the scale. [dialogSize] picks the width of the dialog
/// that replaces the sheet on desktop.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  double? maxHeightFactor,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  bool showHandle = true,
  Color? backgroundColor,
  AppDialogSize dialogSize = AppDialogSize.medium,
}) {
  return showAppModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    backgroundColor: backgroundColor,
    dialogSize: dialogSize,
    builder: (sheetContext) => AppBottomSheet(
      showHandle: showHandle,
      title: title,
      subtitle: subtitle,
      maxHeightFactor: maxHeightFactor,
      child: builder(sheetContext),
    ),
  );
}

/// Fits short content and coordinates scrolling/dragging for longer sheets.
class AppScrollableSheet extends StatefulWidget {
  const AppScrollableSheet({super.key, required this.builder});

  final ScrollableWidgetBuilder builder;

  @override
  State<AppScrollableSheet> createState() => _AppScrollableSheetState();
}

class _AppScrollableSheetState extends State<AppScrollableSheet> {
  final _contentKey = GlobalKey();
  final _sheetController = DraggableScrollableController();
  ScrollController? _scrollController;
  double _availableHeight = 0;
  double _initialSize = 0.85;
  double _maxSize = 0.95;
  bool _fitScheduled = false;

  void _scheduleFit() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted || _availableHeight <= 0) return;
      final box = _contentKey.currentContext?.findRenderObject();
      final scroll = _scrollController;
      if (box is! RenderBox || !box.hasSize || scroll == null) return;
      final overflow = scroll.hasClients && scroll.position.hasContentDimensions
          ? (scroll.position.maxScrollExtent - scroll.position.minScrollExtent)
                .clamp(0.0, double.infinity)
          : 0.0;
      // Align lets the header/body shrink below the allocated sheet height.
      // Adding the scroll overflow recovers the full content height without
      // an intrinsic-layout pass or a second hidden copy of the form.
      final contentFraction = (box.size.height + overflow) / _availableHeight;
      final initial = contentFraction.clamp(0.01, 0.85);
      final maximum = contentFraction.clamp(initial, 0.95);
      if ((initial - _initialSize).abs() * _availableHeight < 1 &&
          (maximum - _maxSize).abs() * _availableHeight < 1) {
        return;
      }
      final resize = (initial - _initialSize).abs() * _availableHeight >= 1;
      setState(() {
        _initialSize = initial;
        _maxSize = maximum;
      });
      // A field or search result can change after the user has dragged. The
      // framework otherwise preserves that old extent when content grows.
      if (resize) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _sheetController.isAttached) {
            _sheetController.jumpTo(_initialSize);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _availableHeight = constraints.maxHeight;
      _scheduleFit();
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) _scheduleFit();
          return false;
        },
        child: NotificationListener<SizeChangedLayoutNotification>(
          onNotification: (_) {
            _scheduleFit();
            return false;
          },
          child: DraggableScrollableSheet(
            controller: _sheetController,
            expand: false,
            initialChildSize: _initialSize,
            minChildSize: (_initialSize * 0.6).clamp(0.0, 0.5),
            maxChildSize: _maxSize,
            snap: true,
            snapSizes: [_initialSize],
            builder: (context, controller) {
              _scrollController = controller;
              return Align(
                alignment: Alignment.bottomCenter,
                child: SizeChangedLayoutNotifier(
                  key: _contentKey,
                  child: widget.builder(context, controller),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

/// A fixed handle/header above a body that scrolls and drags the same sheet.
Future<T?> showAppScrollableBottomSheet<T>({
  required BuildContext context,
  required ScrollableWidgetBuilder builder,
  required String title,
  String? subtitle,
  AppDialogSize dialogSize = AppDialogSize.medium,
}) => showAppModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  dialogSize: dialogSize,
  builder: (context) => AppScrollableSheet(
    builder: (context, controller) => AppBottomSheet(
      title: title,
      subtitle: subtitle,
      child: builder(context, controller),
    ),
  ),
);

/// One row of [showAppChoiceSheet].
class AppChoice<T> {
  const AppChoice(this.value, this.icon, this.title, {this.subtitle});

  final T value;
  final IconData icon;
  final String title;
  final String? subtitle;
}

/// A single-choice sheet: tapping a row reports its value through
/// [onSelected], then closes the sheet. [bottomSpacing] of 0 adds no gap.
Future<void> showAppChoiceSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required T selected,
  required List<AppChoice<T>> choices,
  required ValueChanged<T> onSelected,
  double bottomSpacing = 16,
}) => showAppScrollableBottomSheet<void>(
  context: context,
  title: title,
  subtitle: subtitle,
  builder: (sheetContext, controller) => SingleChildScrollView(
    controller: controller,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final choice in choices)
          AppSheetOption.choice(
            leading: AppIcon(choice.icon),
            title: Text(choice.title),
            subtitle: choice.subtitle == null ? null : Text(choice.subtitle!),
            selected: choice.value == selected,
            onTap: () {
              onSelected(choice.value);
              Navigator.pop(sheetContext);
            },
          ),
        if (bottomSpacing > 0) SizedBox(height: bottomSpacing),
      ],
    ),
  ),
);

/// Adaptive surface for sheets which already supply their own header/layout.
///
/// Desktop windows present the sheet as a centered dialog instead
/// ([showAppSheetDialog]) of [dialogSize]; there is no edge to slide from or
/// drag to. Mornye draws the sheet on overlay glass unless [mornyeGlass] is
/// false for content that brings its own.
Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  bool useSafeArea = false,
  bool? showDragHandle,
  bool mornyeGlass = true,
  BoxConstraints? constraints,
  Color? backgroundColor,
  AppDialogSize dialogSize = AppDialogSize.medium,
}) {
  if (isDesktopPlatform) {
    return showAppSheetDialog<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      topInset: showDragHandle == true,
      mornyeGlass: mornyeGlass,
      backgroundColor: backgroundColor,
      dialogSize: dialogSize,
    );
  }
  final mornye = context.isMornye;
  return showModalBottomSheet<T>(
    context: context,
    sheetAnimationStyle: AppMotion.surfaceEntrance(context),
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    constraints: constraints,
    backgroundColor: mornye ? Colors.transparent : backgroundColor,
    barrierColor: mornye
        ? CupertinoDynamicColor.resolve(kCupertinoModalBarrierColor, context)
        : null,
    elevation: mornye ? 0 : null,
    builder: (context) => mornye && mornyeGlass
        ? MornyeGlassPanel.overlay(child: Builder(builder: builder))
        : builder(context),
  );
}

/// Width of a [AppDialogSize.medium] sheet dialog, the default class.
const double appSheetDialogMaxWidth = 560;

/// Width classes of a sheet presented as a desktop dialog. Each is the
/// widest the dialog grows; a narrower window shrinks it.
enum AppDialogSize {
  /// A confirmation or a single field.
  compact(440),

  /// A list or a picker.
  medium(appSheetDialogMaxWidth),

  /// An editor or a reference page.
  wide(720);

  const AppDialogSize(this.width);

  final double width;
}

/// Presents sheet content as a centered modal dialog, as desktop windows do
/// with every sheet that is not an action menu. The dialog takes the width
/// of [dialogSize] and a height cap (85% of the window for scroll-controlled
/// sheets, 60% otherwise), so content built for a sheet, including a
/// [DraggableScrollableSheet], lays out unchanged: its header stays put and
/// its body scrolls.
///
/// Mornye draws the dialog on overlay glass unless [mornyeGlass] is false
/// for content that brings its own; Material uses `surfaceContainerHigh`.
/// [topInset] replaces the space of a drag handle the sheet would show.
Future<T?> showAppSheetDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool topInset = false,
  bool mornyeGlass = true,
  Color? backgroundColor,
  AppDialogSize dialogSize = AppDialogSize.medium,
}) {
  final mornye = context.isMornye;
  return showDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    barrierColor: mornye
        ? CupertinoDynamicColor.resolve(kCupertinoModalBarrierColor, context)
        : null,
    builder: (dialogContext) => AppSheetDialog(
      isScrollControlled: isScrollControlled,
      topInset: topInset,
      mornyeGlass: mornyeGlass,
      backgroundColor: backgroundColor,
      dialogSize: dialogSize,
      child: Builder(builder: builder),
    ),
  );
}

/// The dialog surface of [showAppSheetDialog].
class AppSheetDialog extends StatelessWidget {
  const AppSheetDialog({
    super.key,
    required this.child,
    this.isScrollControlled = false,
    this.topInset = false,
    this.mornyeGlass = true,
    this.backgroundColor,
    this.dialogSize = AppDialogSize.medium,
  });

  final Widget child;
  final bool isScrollControlled;
  final bool topInset;
  final bool mornyeGlass;
  final Color? backgroundColor;
  final AppDialogSize dialogSize;

  /// Mornye's sheet token is the 32pt iOS sheet corner; its dialogs keep
  /// the corner they have always had.
  static const double _mornyeRadius = 28;
  static const double _margin = 24;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final radius = mornye ? _mornyeRadius : context.tokens.radiusSheet;
    final window = MediaQuery.sizeOf(context);
    final width = (window.width - _margin * 2).clamp(0.0, dialogSize.width);
    final maxHeight =
        (window.height - _margin * 2) * (isScrollControlled ? 0.85 : 0.6);
    Widget content = MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      child: Padding(
        padding: EdgeInsets.only(top: topInset ? context.tokens.gapLg : 0),
        child: child,
      ),
    );
    if (mornye && mornyeGlass) {
      content = MornyeGlassPanel.overlay(radius: radius, child: content);
    } else if (!mornye) {
      // Desktop scrollbars normally fade out when idle. In a dialog the
      // body's bar stays visible, so a cut-off list reads as scrollable.
      content = ScrollbarTheme(
        data: ScrollbarTheme.of(
          context,
        ).copyWith(thumbVisibility: const WidgetStatePropertyAll(true)),
        child: content,
      );
    }
    return Dialog(
      key: const ValueKey('app-sheet-dialog'),
      insetPadding: const EdgeInsets.all(_margin),
      backgroundColor: mornye
          ? Colors.transparent
          : backgroundColor ??
                Theme.of(context).colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: mornye ? 0 : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: content,
        ),
      ),
    );
  }
}

/// Flat rows sit directly on a sheet's glass; Material keeps its ListTile.
class AppSheetOption extends StatelessWidget {
  const AppSheetOption({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.contentPadding,
    this.enabled = true,
    this.selected,
  }) : _isChoice = false;

  /// A choice with the sheet's adaptive checkmark and selection semantics.
  const AppSheetOption.choice({
    super.key,
    required this.title,
    required bool this.selected,
    required VoidCallback this.onTap,
    this.subtitle,
    this.leading,
  }) : trailing = null,
       contentPadding = null,
       enabled = true,
       _isChoice = true;

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final bool enabled;
  final bool _isChoice;

  /// Announces a checkmark choice's state to screen readers; null for
  /// options that are actions rather than choices.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trailing = _isChoice
        ? selected == true
              ? AppIcon(Icons.check, color: scheme.primary)
              : null
        : this.trailing;
    if (!context.isMornye) {
      return ListTile(
        title: this.title,
        subtitle: subtitle,
        leading: leading == null ? null : symbolIconWidget(leading!),
        trailing: trailing == null ? null : symbolIconWidget(trailing),
        onTap: onTap,
        contentPadding: contentPadding,
        enabled: enabled,
        // The checkmark already shows the choice; selection only feeds
        // screen readers, so the row keeps its ordinary text color.
        selected: selected ?? false,
        selectedColor: scheme.onSurface,
      );
    }
    // Annotated on the title so it merges into the option's button node.
    final title = selected == null
        ? this.title
        : Semantics(
            selected: selected,
            inMutuallyExclusiveGroup: true,
            child: this.title,
          );
    Widget adaptedIcon(Widget widget, double size) {
      final (icon, color) = switch (widget) {
        Icon(:final icon?, :final color) => (icon, color),
        AppIcon(:final icon?, :final color) => (icon, color),
        _ => (null, null),
      };
      if (icon != null) {
        return Icon(
          mornyeIconFor(icon),
          size: size,
          color: enabled ? color ?? scheme.primary : theme.disabledColor,
        );
      }
      return widget;
    }

    return CupertinoButton(
      onPressed: enabled ? onTap : null,
      padding:
          contentPadding ??
          const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          if (leading != null) ...[
            adaptedIcon(leading!, 24),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DefaultTextStyle(
                  style: theme.textTheme.bodyLarge!.copyWith(
                    color: enabled ? scheme.onSurface : theme.disabledColor,
                    fontWeight: FontWeight.w500,
                  ),
                  child: title,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  DefaultTextStyle(
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: enabled
                          ? scheme.onSurfaceVariant
                          : theme.disabledColor,
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            adaptedIcon(trailing, 20),
          ],
        ],
      ),
    );
  }
}
