import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/metadata_text_field.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Grouped option list used by the metadata editor pickers.
class MetadataEditorOptions extends StatelessWidget {
  final List<Widget> children;

  const MetadataEditorOptions({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) return SettingsGroup(children: children);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: MornyeTheme.controlFill(context),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class MetadataEditorQuickSelectButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final ColorScheme cs;
  final bool fetching;

  const MetadataEditorQuickSelectButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.cs,
    required this.fetching,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        onPressed: fetching ? null : onTap,
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.primary),
        ),
      );
    }
    // The shared outlined button keeps the 48dp touch target.
    return ExpressiveButton(
      outlined: true,
      onPressed: fetching ? null : onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(label),
    );
  }
}

class MetadataEditorSwitchField extends StatelessWidget {
  final ColorScheme colorScheme;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const MetadataEditorSwitchField({
    super.key,
    required this.colorScheme,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          Material(
            color: metadataEditorFieldFill(context, cs),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: AppSwitchListTile(
              adaptive: true,
              value: value,
              onChanged: onChanged,
              contentPadding: EdgeInsets.symmetric(
                horizontal: context.isMornye ? 4 : 16,
              ),
              title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
              subtitle: Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
          if (context.isMornye) const Divider(height: 0.5),
        ],
      ),
    );
  }
}

class MetadataEditorSelectionField extends StatelessWidget {
  final ColorScheme colorScheme;
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool enabled;

  const MetadataEditorSelectionField({
    super.key,
    required this.colorScheme,
    required this.label,
    required this.value,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    if (context.isMornye) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            CupertinoButton(
              color: metadataEditorFieldFill(context, cs),
              disabledColor: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
              onPressed: enabled ? onTap : null,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: enabled ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    CupertinoIcons.chevron_up_chevron_down,
                    size: 16,
                    color: cs.primary,
                  ),
                ],
              ),
            ),
            const Divider(height: 0.5),
          ],
        ),
      );
    }
    final radius = BorderRadius.circular(14);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: enabled ? cs.onSurfaceVariant : cs.outline,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Material(
            color: metadataEditorFieldFill(context, cs),
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 12, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: enabled ? cs.onSurface : cs.outline,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.expand_more_rounded,
                      color: enabled ? cs.onSurfaceVariant : cs.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Titled section card. When [onHeaderTap] is set the header is a full-width
/// tappable row (ripple clipped to the card) with an auto chevron.
class MetadataEditorSectionCard extends StatelessWidget {
  final ColorScheme colorScheme;
  final IconData icon;
  final String title;
  final List<Widget> children;
  final VoidCallback? onHeaderTap;
  final bool expanded;

  const MetadataEditorSectionCard({
    super.key,
    required this.colorScheme,
    required this.icon,
    required this.title,
    required this.children,
    this.onHeaderTap,
    this.expanded = true,
  });

  RoundedRectangleBorder _sectionCardShape(ColorScheme cs) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final collapsible = onHeaderTap != null;
    const inset = 16.0;
    // The chevron turns on the fast spatial spring. The card's height moves
    // the sections below it, so it unfolds on springs that stop at its size
    // (an expressive overshoot would be several fields tall); reduced motion
    // changes both at once.
    const still = AppMotionSpec(Duration.zero, Curves.linear);
    final turn = AppMotion.spatialFast(
      context,
      still,
      mornye: MornyeMotion.fast,
    );
    final unfold = AppMotion.surface(context);

    final headerRow = Row(
      children: [
        Icon(context.adaptiveIcon(icon), size: 20, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ),
        if (collapsible)
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: turn.duration,
            curve: turn.curve,
            child: Icon(
              context.isMornye
                  ? CupertinoIcons.chevron_down
                  : Icons.expand_more,
              size: 22,
              color: cs.onSurfaceVariant,
            ),
          ),
      ],
    );

    final Widget header = collapsible
        ? InkWell(
            onTap: onHeaderTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 16),
              child: headerRow,
            ),
          )
        : Padding(
            padding: EdgeInsets.fromLTRB(inset, 16, inset, 8),
            child: headerRow,
          );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        if (children.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
      ],
    );
    // A zero-length AnimatedSize re-dirties itself during layout.
    final content = unfold.duration == Duration.zero
        ? column
        : AnimatedSize(
            duration: unfold.duration,
            curve: unfold.curve,
            alignment: Alignment.topCenter,
            child: column,
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: context.isMornye
          ? Material(
              color: MornyeTheme.controlFill(context),
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: DividerTheme(
                data: DividerTheme.of(
                  context,
                ).copyWith(color: MornyeTheme.metadataDividerColor(context)),
                child: content,
              ),
            )
          : AppContentCard(
              elevation: 0,
              margin: EdgeInsets.zero,
              color: settingsGroupColor(context),
              shape: _sectionCardShape(cs),
              clipBehavior: Clip.antiAlias,
              child: content,
            ),
    );
  }
}
