import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Square extension icon with a tinted fallback.
class ExtensionAvatar extends StatelessWidget {
  const ExtensionAvatar({
    super.key,
    required this.fallbackIcon,
    this.filePath,
    this.imageUrl,
    this.background,
    this.foreground,
  });

  /// Shown when no image is available or the image fails to load.
  final IconData fallbackIcon;

  /// Local icon shipped inside an installed extension.
  final String? filePath;

  /// Remote icon from the store registry.
  final String? imageUrl;

  final Color? background;
  final Color? foreground;

  static const double size = 44;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final borderRadius = tokens.borderRadiusCover;
    final fallback = AppIcon(
      fallbackIcon,
      color: foreground ?? colorScheme.onPrimaryContainer,
    );

    Widget? image;
    if (filePath != null && filePath!.isNotEmpty) {
      image = Image.file(
        File(filePath!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        cacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => fallback,
      );
    } else if (imageUrl != null && imageUrl!.isNotEmpty) {
      image = Image.network(
        imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        cacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: AppLoadingIndicator(size: 20, strokeWidth: 2),
          );
        },
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? colorScheme.primaryContainer,
        borderRadius: borderRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: image ?? fallback,
    );
  }
}

/// Row shell shared by the extension store and the installed-extensions list:
/// optional avatar, title/subtitle column, trailing control, and group divider.
class ExtensionRow extends StatelessWidget {
  const ExtensionRow({
    super.key,
    this.avatar,
    required this.title,
    required this.subtitle,
    required this.showDivider,
    this.trailing,
    this.onTap,
    this.trailingWidth,
  });

  /// Narrowest title, in logical pixels at the default text size, that a
  /// [trailing] beside the text may leave.
  static const double minTitleWidth = 140;

  final Widget? avatar;

  /// A widget rather than a string: the store row appends a version pill.
  final Widget title;

  final Widget subtitle;
  final bool showDivider;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// The widest [trailing] of the list, such as its longest button label in
  /// the current language and text size. When set, [trailing] moves under
  /// the subtitle on a row where a control this wide would leave the title
  /// narrower than [minTitleWidth]. Rows of a list share the width, so they
  /// lay out alike whatever their own button says.
  final double? trailingWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final trailing = this.trailing;
    final trailingWidth = this.trailingWidth;

    Widget text({Widget? below}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DefaultTextStyle.merge(
          style: Theme.of(
            context,
          ).textTheme.bodyLarge!.copyWith(fontWeight: FontWeight.w500),
          child: title,
        ),
        SizedBox(height: tokens.gapXs / 2),
        subtitle,
        if (below != null) ...[SizedBox(height: tokens.gapSm), below],
      ],
    );

    Widget content(bool trailingBelow) => Row(
      crossAxisAlignment: trailingBelow
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (avatar != null) ...[avatar!, SizedBox(width: tokens.gapLg)],
        Expanded(child: text(below: trailingBelow ? trailing : null)),
        if (!trailingBelow && trailing != null) ...[
          // A button carries no gap of its own, since it may sit below.
          if (trailingWidth != null) SizedBox(width: tokens.gapMd),
          trailing,
        ],
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.gapLg,
              vertical: tokens.gapMd,
            ),
            child: trailing == null || trailingWidth == null
                ? content(false)
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final titleWidth =
                          constraints.maxWidth -
                          (avatar == null
                              ? 0
                              : ExtensionAvatar.size + tokens.gapLg) -
                          trailingWidth -
                          tokens.gapMd;
                      final minWidth = MediaQuery.textScalerOf(
                        context,
                      ).scale(minTitleWidth);
                      return content(titleWidth < minWidth);
                    },
                  ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            thickness: 1,
            indent: avatar == null
                ? tokens.gapLg
                : ExtensionAvatar.size + tokens.gapLg * 2,
            endIndent: tokens.gapLg,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }
}
