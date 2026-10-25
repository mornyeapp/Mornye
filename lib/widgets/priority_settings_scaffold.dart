import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';

class PrioritySettingsScaffold extends StatelessWidget {
  final bool hasChanges;
  final String title;
  final String description;
  final String? infoText;
  final EdgeInsetsGeometry descriptionPadding;
  final List<Widget> slivers;
  final Future<void> Function() onSave;
  final Future<bool> Function(BuildContext context) onConfirmDiscard;

  const PrioritySettingsScaffold({
    super.key,
    required this.hasChanges,
    required this.title,
    required this.description,
    this.infoText,
    required this.slivers,
    required this.onSave,
    required this.onConfirmDiscard,
    this.descriptionPadding = const EdgeInsets.fromLTRB(16, 4, 16, 8),
  });

  Future<void> _handleBack(BuildContext context) async {
    if (!hasChanges) {
      Navigator.pop(context);
      return;
    }
    final shouldPop = await onConfirmDiscard(context);
    if (shouldPop && context.mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final wideInset = wideListInset(context);

    return PopScope(
      canPop: !hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await onConfirmDiscard(context);
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(
              title: title,
              leading: AppIconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _handleBack(context),
              ),
              actions: [
                if (hasChanges)
                  ExpressiveButton(
                    text: true,
                    onPressed: onSave,
                    child: Text(context.l10n.dialogSave),
                  ),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: descriptionPadding.add(
                  EdgeInsets.symmetric(horizontal: wideInset),
                ),
                child: Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            ...slivers,
            if (infoText case final infoText?)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16 + wideInset,
                    16,
                    16 + wideInset,
                    16,
                  ),
                  child: SettingsInfoCard(
                    icon: Icons.info_outline,
                    message: infoText,
                    margin: EdgeInsets.zero,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}
