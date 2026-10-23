import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/utils/adaptive_layout.dart';

/// The neutral grouped fill used in Settings, including AMOLED themes.
Color settingsGroupColor(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;
  if (context.isMornye) return colorScheme.surfaceContainer;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark
      ? Color.alphaBlend(
          Colors.white.withValues(alpha: 0.08),
          colorScheme.surface,
        )
      : Color.alphaBlend(
          Colors.black.withValues(alpha: 0.04),
          colorScheme.surface,
        );
}

/// Carries a Settings search result into its destination page.
///
/// Descendant [SettingsSearchTarget] widgets compete to claim the matching
/// label. The first match scrolls into view and briefly highlights itself.
class SettingsSearchHighlightScope extends StatefulWidget {
  const SettingsSearchHighlightScope({
    super.key,
    required this.targetLabel,
    required this.child,
  });

  final String targetLabel;
  final Widget child;

  @override
  State<SettingsSearchHighlightScope> createState() =>
      _SettingsSearchHighlightScopeState();
}

class _SettingsSearchHighlightScopeState
    extends State<SettingsSearchHighlightScope> {
  late _SettingsSearchHighlightController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _SettingsSearchHighlightController(widget.targetLabel);
  }

  @override
  void didUpdateWidget(SettingsSearchHighlightScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetLabel != widget.targetLabel) {
      _controller = _SettingsSearchHighlightController(widget.targetLabel);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsSearchHighlightInherited(
      controller: _controller,
      child: widget.child,
    );
  }
}

class _SettingsSearchHighlightController {
  _SettingsSearchHighlightController(this.targetLabel);

  final String targetLabel;
  bool _claimed = false;

  bool matches(String label) => label == targetLabel;

  bool claim(String label) {
    if (_claimed || !matches(label)) return false;
    _claimed = true;
    return true;
  }
}

class _SettingsSearchHighlightInherited extends InheritedWidget {
  const _SettingsSearchHighlightInherited({
    required this.controller,
    required super.child,
  });

  final _SettingsSearchHighlightController controller;

  static _SettingsSearchHighlightInherited? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<
          _SettingsSearchHighlightInherited
        >();
  }

  @override
  bool updateShouldNotify(_SettingsSearchHighlightInherited oldWidget) {
    return controller != oldWidget.controller;
  }
}

/// Marks one settings control as a possible deep-link target from search.
class SettingsSearchTarget extends StatefulWidget {
  const SettingsSearchTarget({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  State<SettingsSearchTarget> createState() => _SettingsSearchTargetState();
}

class _SettingsSearchTargetState extends State<SettingsSearchTarget> {
  Timer? _highlightTimer;
  bool _handled = false;
  bool _highlighted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_handled) return;

    final scope = _SettingsSearchHighlightInherited.maybeOf(context);
    if (scope?.controller.claim(widget.label) != true) return;
    _handled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  Future<void> _reveal() async {
    if (!mounted) return;
    setState(() => _highlighted = true);

    await Scrollable.ensureVisible(
      context,
      alignment: 0.32,
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;

    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlighted = false);
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Normal settings rendering stays allocation-light: only the one claimed
    // search target creates an animated decoration and semantics node.
    if (!_handled) return widget.child;

    final colorScheme = Theme.of(context).colorScheme;
    final motion = AppMotion.effects(
      context,
      AppMotionSpec(context.tokens.motionMedium, Curves.easeOutCubic),
    );
    return Semantics(
      selected: _highlighted,
      child: AnimatedContainer(
        key: ValueKey('settings-highlight:${widget.label}'),
        duration: motion.duration,
        curve: motion.curve,
        color: _highlighted
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

/// Whether rows sit in an expressive connected [SettingsGroup], where the gaps
/// between row surfaces replace dividers. Custom rows check this to hide
/// their own dividers.
bool settingsRowsConnected(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_ConnectedRowsScope>() != null;

/// Horizontal margin of settings content on a surface [maxWidth] wide: the
/// 16dp edge plus the wide-layout centering inset. Groups, section headers,
/// info cards and page-level buttons share it so their edges line up.
double settingsHorizontalInset(double maxWidth) =>
    16 + (maxWidth.isFinite ? wideInsetForWidth(maxWidth) : 0);

/// Corners of one row in an expressive connected list: the card radius at the
/// [first] and [last] ends of the run, tight corners between rows.
BorderRadius connectedRowRadius(
  BuildContext context, {
  required bool first,
  required bool last,
}) {
  final outer = Radius.circular(context.tokens.radiusCard);
  const inner = Radius.circular(4);
  return BorderRadius.vertical(
    top: first ? outer : inner,
    bottom: last ? outer : inner,
  );
}

class _ConnectedRowsScope extends InheritedWidget {
  const _ConnectedRowsScope({required super.child});

  @override
  bool updateShouldNotify(_ConnectedRowsScope oldWidget) => false;
}

class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final bool glass;

  /// Connects custom [children] that are each one complete row, such as
  /// extension rows. Groups of [SettingsItem], [SettingsSwitchItem] and [ListTile]
  /// connect without it.
  final bool connected;

  const SettingsGroup({
    super.key,
    required this.children,
    this.margin,
    this.glass = false,
    this.connected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor = settingsGroupColor(context);
    final colorScheme = Theme.of(context).colorScheme;

    final decoration = BoxDecoration(
      color: cardColor,
      borderRadius: BorderRadius.circular(
        context.isMornye ? 28 : context.tokens.radiusCard,
      ),
      border: context.isMornye
          ? null
          : Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
    );
    final child = Material(
      color: Colors.transparent,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
    // Explicit caller margin wins as-is. Otherwise center on wide surfaces
    // using the incoming constraint (not screen width) so groups nested in an
    // already clamped box, e.g. a bottom sheet, are not over-inset.
    Widget inset(Widget child) => margin != null
        ? Padding(padding: margin!, child: child)
        : LayoutBuilder(
            builder: (context, constraints) => Padding(
              padding: EdgeInsets.symmetric(
                horizontal: settingsHorizontalInset(constraints.maxWidth),
                vertical: 4,
              ),
              child: child,
            ),
          );

    if (glass && context.isMornye) {
      // Groups scroll over the opaque page color, where a backdrop pass
      // filters a flat color; keep the glass tint and rim without it.
      return inset(MornyeGlassPanel(samplesBackdrop: false, child: child));
    }

    final expressive = materialExpressiveEnabled(context);
    // Only groups of standard rows split into connected tiles. Forms and
    // custom content keep one card, so spacers never become empty tiles.
    final standardRows =
        children.isNotEmpty &&
        (connected ||
            children.every(
              (child) =>
                  child is SettingsItem ||
                  child is SettingsSwitchItem ||
                  child is ListTile,
            ));
    // Connected surfaces are static layout, so reduced motion keeps the gaps.
    if (!context.isMornye && standardRows) {
      // Expressive connected list: every row is its own surface separated by
      // a 2dp gap. The group's ends keep the card radius, inner corners stay
      // tight, and the gaps replace row dividers.
      final last = children.length - 1;
      return inset(
        _ConnectedRowsScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, row) in children.indexed) ...[
                if (index > 0) const SizedBox(height: 2),
                Material(
                  color: cardColor,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: connectedRowRadius(
                      context,
                      first: index == 0,
                      last: index == last,
                    ),
                  ),
                  child: row,
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (expressive) {
      return inset(
        MaterialExpressiveScope(
          child: M3ECard(
            variant: M3ECardVariant.filled,
            color: cardColor,
            padding: EdgeInsets.zero,
            borderRadius: context.tokens.borderRadiusCard,
            child: child,
          ),
        ),
      );
    }

    return inset(
      Container(
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

/// A [SettingsSectionHeader] sliver followed by its [SettingsGroup] sliver.
List<Widget> settingsSectionSlivers({
  required String title,
  required List<Widget> children,
  bool connected = false,
  bool glass = false,
}) => [
  SliverToBoxAdapter(child: SettingsSectionHeader(title: title)),
  SliverToBoxAdapter(
    child: SettingsGroup(
      connected: connected,
      glass: glass,
      children: children,
    ),
  ),
];

/// The grouped list appearance with rows built only near the viewport.
class SliverSettingsGroup extends StatelessWidget {
  const SliverSettingsGroup({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.margin,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: margin,
    sliver: SliverList.builder(
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final first = index == 0;
        final last = index == itemCount - 1;
        final mornye = context.isMornye;
        final radius = mornye
            ? BorderRadius.vertical(
                top: first ? const Radius.circular(28) : Radius.zero,
                bottom: last ? const Radius.circular(28) : Radius.zero,
              )
            : connectedRowRadius(context, first: first, last: last);
        final row = Material(
          color: settingsGroupColor(context),
          clipBehavior: Clip.antiAlias,
          borderRadius: radius,
          child: itemBuilder(context, index),
        );
        return mornye
            ? row
            : Padding(
                padding: EdgeInsets.only(top: first ? 0 : 2),
                child: _ConnectedRowsScope(child: row),
              );
      },
    ),
  );
}

class SettingsItem extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;

  /// Show category icons in Mornye's top-level settings and search results.
  final bool showIconInMornye;
  final String title;
  final Widget? titleTrailing;
  final String? subtitle;
  final Widget? footer;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  /// Announces a checkmark choice's state to screen readers; null for rows
  /// that are not choices.
  final bool? selected;

  const SettingsItem({
    super.key,
    this.icon,
    this.iconColor,
    this.showIconInMornye = false,
    required this.title,
    this.titleTrailing,
    this.subtitle,
    this.footer,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final showIcon = icon != null && (!context.isMornye || showIconInMornye);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          selected: selected,
          inMutuallyExclusiveGroup: selected != null,
          child: InkWell(
            onTap: onTap,
            splashColor: colorScheme.primary.withValues(alpha: 0.12),
            highlightColor: Colors.transparent,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.tokens.rowPaddingH,
                vertical: context.tokens.rowPaddingV,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: context.tokens.rowMinHeight,
                ),
                child: Row(
                  children: [
                    if (showIcon) ...[
                      AppIcon.adaptive(
                        icon!,
                        color: iconColor ?? colorScheme.onSurfaceVariant,
                        size: 24,
                      ),
                      SizedBox(width: context.tokens.rowIconGap),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                              if (titleTrailing != null) ...[
                                const SizedBox(width: 8),
                                titleTrailing!,
                              ],
                            ],
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style:
                                  (context.isMornye
                                          ? Theme.of(
                                              context,
                                            ).textTheme.bodySmall
                                          : Theme.of(
                                              context,
                                            ).textTheme.bodyMedium)
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                            ),
                          ],
                          if (footer != null) ...[
                            const SizedBox(height: 8),
                            footer!,
                          ],
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ] else if (onTap != null) ...[
                      const SizedBox(width: 8),
                      AppIcon(
                        context.isMornye
                            ? CupertinoIcons.forward
                            : Icons.chevron_right,
                        size: context.tokens.rowChevronSize,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            indent: showIcon
                ? context.tokens.rowIconDividerIndent
                : context.tokens.rowPaddingH,
            endIndent: context.tokens.rowPaddingH,
            color: context.isMornye
                ? colorScheme.outlineVariant
                : colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}

class SettingsSwitchItem extends StatelessWidget {
  final IconData? icon;
  final String title;
  final Widget? titleTrailing;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool showDivider;
  final bool enabled;

  const SettingsSwitchItem({
    super.key,
    this.icon,
    required this.title,
    this.titleTrailing,
    this.subtitle,
    required this.value,
    this.onChanged,
    this.showDivider = true,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDisabled = !enabled || onChanged == null;
    final showIcon = icon != null && !context.isMornye;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // One focus stop that reads the title, subtitle and on/off state.
        MergeSemantics(
          child: Opacity(
            opacity: isDisabled ? 0.5 : 1.0,
            child: InkWell(
              onTap: isDisabled ? null : () => onChanged!(!value),
              splashColor: colorScheme.primary.withValues(alpha: 0.12),
              highlightColor: Colors.transparent,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.tokens.rowPaddingH,
                  vertical: context.tokens.rowPaddingVCompact,
                ),
                child: Row(
                  children: [
                    if (showIcon) ...[
                      AppIcon(
                        icon,
                        color: isDisabled
                            ? colorScheme.outline
                            : colorScheme.onSurfaceVariant,
                        size: 24,
                      ),
                      SizedBox(width: context.tokens.rowIconGap),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: isDisabled
                                            ? colorScheme.outline
                                            : null,
                                      ),
                                ),
                              ),
                              if (titleTrailing != null) ...[
                                const SizedBox(width: 8),
                                titleTrailing!,
                              ],
                            ],
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: isDisabled
                                        ? colorScheme.outline
                                        : colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppSwitch(
                      value: value,
                      onChanged: isDisabled ? null : onChanged,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            indent: showIcon
                ? context.tokens.rowIconDividerIndent
                : context.tokens.rowPaddingH,
            endIndent: context.tokens.rowPaddingH,
            color: context.isMornye
                ? colorScheme.outlineVariant
                : colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}

class SettingsSectionHeader extends StatelessWidget {
  final String title;

  const SettingsSectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final label = Text(
      title,
      style:
          (context.isMornye
                  ? Theme.of(context).textTheme.bodyLarge
                  : Theme.of(context).textTheme.titleSmall)
              ?.copyWith(
                color: context.isMornye
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
    );
    // Aligned with the row content of the groups below at any width.
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final inset = settingsHorizontalInset(constraints.maxWidth) + 16;
        return Padding(
          padding: EdgeInsets.fromLTRB(inset, 24, inset, 8),
          child: Semantics(header: true, child: label),
        );
      },
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}

/// How a [SettingsChoiceChip] stacks its icon and label.
enum SettingsChipLayout {
  /// Icon beside the label. Fits wide chips in a grid.
  row,

  /// Icon above the label. Fits equal-width chips in a row.
  column,
}

/// Single-select chip used across the settings pages.
class SettingsChoiceChip extends StatelessWidget {
  const SettingsChoiceChip({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.icon,
    this.layout = SettingsChipLayout.row,
    this.expand = false,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final IconData? icon;
  final SettingsChipLayout layout;

  /// Wraps the chip in [Expanded] so a row of chips divides the width evenly.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final borderRadius = BorderRadius.circular(tokens.radiusCover);

    // One solid tier above a settings group in light, dark and AMOLED.
    final unselectedColor = context.isMornye
        ? Colors.transparent
        : colorScheme.surfaceContainerHigh;
    final foreground = context.isMornye && isSelected
        ? colorScheme.primary
        : isSelected
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    final labelText = Text(
      label,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        // Like an iOS segment, the filled chip marks the choice; accent text
        // on Mornye's grey fill falls below readable contrast.
        color: context.isMornye && isSelected
            ? colorScheme.onSurface
            : foreground,
      ),
    );

    final Widget content;
    if (icon == null) {
      content = Center(child: labelText);
    } else if (layout == SettingsChipLayout.column) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon.adaptive(icon!, color: foreground),
          SizedBox(height: tokens.gapXs + 2),
          labelText,
        ],
      );
    } else {
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon.adaptive(icon!, size: 18, color: foreground),
          SizedBox(width: tokens.gapSm),
          Flexible(child: labelText),
        ],
      );
    }

    final chip = Material(
      color: isSelected
          ? (context.isMornye
                ? colorScheme.surfaceContainerHighest
                : colorScheme.primaryContainer)
          : unselectedColor,
      borderRadius: borderRadius,
      child: Semantics(
        button: true,
        selected: isSelected,
        inMutuallyExclusiveGroup: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: ConstrainedBox(
            // Keeps every chip a comfortable tap target regardless of layout.
            constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: tokens.gapMd,
                horizontal: tokens.gapMd,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );

    return expand ? Expanded(child: chip) : chip;
  }
}

/// One option of a [SettingsSegmentedChoice].
class SettingsSegmentOption<T> {
  const SettingsSegmentOption({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

/// Single-select row of two to four related options that fits on one line.
///
/// Material 3 Expressive replaces the segmented button with a connected
/// button group spanning the row; reduced motion keeps the static
/// [SegmentedButton]. Mornye keeps its equal-width chips. Option sets that
/// wrap belong in a [SettingsChoiceGrid] instead.
class SettingsSegmentedChoice<T> extends StatelessWidget {
  const SettingsSegmentedChoice({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<SettingsSegmentOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (materialExpressiveEnabled(context)) {
      final index = options.indexWhere((option) => option.value == selected);
      return MaterialExpressiveScope(
        skipAutofocus: true,
        child: M3EButtonGroup(
          type: M3EButtonGroupType.connected,
          style: M3EButtonStyle.filled,
          // Connected segments get no inflated target; keep 48 dp.
          size: M3EButtonSize.sm.copyWith(height: 48),
          selectedIndex: index < 0 ? null : index,
          selectionRequired: true,
          onSelectedIndexChanged: (index) {
            if (index != null) onChanged(options[index].value);
          },
          semanticLabel: semanticLabel,
          actions: [
            for (final option in options)
              M3EButtonGroupAction(
                icon: option.icon == null
                    ? null
                    : AppIcon.adaptive(option.icon!, size: 18, fill: 0),
                selectedIcon: option.icon == null
                    ? null
                    : AppIcon.adaptive(option.icon!, size: 18, fill: 1),
                label: Text(option.label),
              ),
          ],
        ),
      );
    }
    if (!context.isMornye) {
      return SegmentedButton<T>(
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        segments: [
          for (final option in options)
            ButtonSegment(
              value: option.value,
              label: Text(option.label),
              icon: option.icon == null ? null : AppIcon(option.icon!),
            ),
        ],
        selected: {selected},
        onSelectionChanged: (value) => onChanged(value.first),
      );
    }
    return Row(
      children: [
        for (final (index, option) in options.indexed) ...[
          if (index > 0) SizedBox(width: context.tokens.gapSm),
          SettingsChoiceChip(
            expand: true,
            layout: SettingsChipLayout.column,
            icon: option.icon,
            label: option.label,
            isSelected: option.value == selected,
            onTap: () => onChanged(option.value),
          ),
        ],
      ],
    );
  }
}

/// Lays out [SettingsChoiceChip]s in an even grid that reflows by width.
class SettingsChoiceGrid extends StatelessWidget {
  const SettingsChoiceGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final spacing = context.tokens.gapSm;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 320).floor().clamp(2, 4);
        final chipWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: chipWidth, child: child),
          ],
        );
      },
    );
  }
}

/// Tone of a [SettingsInfoCard].
enum SettingsInfoTone { neutral, warning, error }

/// Inline explanatory or warning callout inside a settings page.
class SettingsInfoCard extends StatelessWidget {
  const SettingsInfoCard({
    super.key,
    required this.message,
    this.icon,
    this.title,
    this.tone = SettingsInfoTone.neutral,
    this.action,
    this.margin,
    this.glass = false,
  });

  final String message;
  final IconData? icon;
  final String? title;
  final SettingsInfoTone tone;

  /// Optional trailing action, e.g. a retry or "grant permission" button.
  final Widget? action;

  final EdgeInsetsGeometry? margin;

  /// Uses the shared glass surface in Mornye without changing Material cards.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Material uses the solid container with its paired on-color, so the
    // text keeps its contrast; Mornye keeps its softer fills.
    final mornye = context.isMornye;
    final (background, foreground) = switch (tone) {
      SettingsInfoTone.neutral => (
        mornye
            ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
            : colorScheme.surfaceContainerHigh,
        colorScheme.onSurfaceVariant,
      ),
      SettingsInfoTone.warning => (
        mornye
            ? colorScheme.tertiaryContainer.withValues(alpha: 0.5)
            : colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
      SettingsInfoTone.error => (
        mornye
            ? colorScheme.errorContainer.withValues(alpha: 0.6)
            : colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
    };

    final useGlass = glass && mornye;
    final textColor = useGlass ? colorScheme.onSurface : foreground;
    final content = Padding(
      padding: EdgeInsets.all(tokens.gapLg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            AppIcon(
              useGlass ? mornyeIconFor(icon!) : icon,
              size: 20,
              color: useGlass ? colorScheme.primary : foreground,
            ),
            SizedBox(width: tokens.gapMd),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: tokens.gapXs),
                ],
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(color: textColor),
                ),
                if (action != null) ...[
                  SizedBox(height: tokens.gapSm),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: action!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final card = useGlass
        ? MornyeGlassPanel.overlay(child: content)
        : DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: tokens.borderRadiusCard,
            ),
            child: content,
          );
    final resolved =
        (margin ??
                EdgeInsets.symmetric(
                  horizontal: tokens.gapLg,
                  vertical: tokens.gapXs,
                ))
            .resolve(Directionality.of(context));
    // Wide layouts center groups; the card keeps the same edges.
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = settingsHorizontalInset(constraints.maxWidth) - 16;
        return Padding(
          padding: resolved.copyWith(
            left: resolved.left + wide,
            right: resolved.right + wide,
          ),
          child: card,
        );
      },
    );
  }
}
