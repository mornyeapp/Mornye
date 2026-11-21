import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class DownloadFallbackExtensionsPage extends ConsumerStatefulWidget {
  const DownloadFallbackExtensionsPage({super.key});

  @override
  ConsumerState<DownloadFallbackExtensionsPage> createState() =>
      _DownloadFallbackExtensionsPageState();
}

class _DownloadFallbackExtensionsPageState
    extends ConsumerState<DownloadFallbackExtensionsPage> {
  late List<Extension> _extensions;
  late Set<String> _selectedExtensionIds;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _loadExtensions();
  }

  void _loadExtensions() {
    final extState = ref.read(extensionProvider);
    final settings = ref.read(settingsProvider);

    _extensions = extState.extensions
        .where(
          (extension) => extension.enabled && extension.hasDownloadProvider,
        )
        .toList();

    final savedIds = settings.downloadFallbackExtensionIds;
    if (savedIds == null) {
      _selectedExtensionIds = _extensions
          .map((extension) => extension.id)
          .toSet();
    } else {
      final allowedIds = _extensions.map((extension) => extension.id).toSet();
      _selectedExtensionIds = savedIds
          .where((extensionId) => allowedIds.contains(extensionId))
          .toSet();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final wideInset = wideListInset(context);

    return MornyeSettingsTheme(
      child: PopScope(
        canPop: !_hasChanges,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          final shouldPop = await showDiscardChangesDialog(context);
          if (shouldPop && context.mounted) {
            Navigator.pop(context);
          }
        },
        child: Scaffold(
          body: CustomScrollView(
            slivers: [
              AppSliverHeader.page(
                title: context.l10n.extensionsFallbackTitle,
                leading: AppIconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const AppIcon.adaptive(Icons.arrow_back),
                  onPressed: () async {
                    if (_hasChanges) {
                      final shouldPop = await showDiscardChangesDialog(context);
                      if (shouldPop && context.mounted) {
                        Navigator.pop(context);
                      }
                    } else {
                      Navigator.pop(context);
                    }
                  },
                ),
                actions: [
                  if (_hasChanges)
                    ExpressiveButton(
                      text: true,
                      onPressed: _saveChanges,
                      child: Text(context.l10n.dialogSave),
                    ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16 + wideInset,
                    16,
                    16 + wideInset,
                    16,
                  ),
                  child: Text(
                    context.l10n.providerPriorityFallbackExtensionsDescription,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (_extensions.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16 + wideInset),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: settingsGroupColor(context),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        context.l10n.extensionsNoDownloadProvider,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_extensions.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: 16 + wideInset),
                  sliver: SliverToBoxAdapter(
                    child: SettingsGroup(
                      margin: EdgeInsets.zero,
                      children: List.generate(_extensions.length, (index) {
                        final extension = _extensions[index];
                        final isSelected = _selectedExtensionIds.contains(
                          extension.id,
                        );
                        return SettingsSwitchItem(
                          icon: Icons.extension_rounded,
                          title: extension.displayName,
                          subtitle: extension.id,
                          value: isSelected,
                          showDivider: index != _extensions.length - 1,
                          onChanged: (value) {
                            setState(() {
                              if (value) {
                                _selectedExtensionIds.add(extension.id);
                              } else {
                                _selectedExtensionIds.remove(extension.id);
                              }
                              _hasChanges = true;
                            });
                          },
                        );
                      }),
                    ),
                  ),
                ),
              if (_extensions.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16 + wideInset,
                      8,
                      16 + wideInset,
                      0,
                    ),
                    child: Text(
                      context.l10n.providerPriorityFallbackExtensionsHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              const NavBarSliverSpacer(),
            ],
          ),
        ),
      ),
    );
  }

  void _saveChanges() {
    final allExtensionIds = _extensions
        .map((extension) => extension.id)
        .toList();
    final selectedExtensionIds = allExtensionIds
        .where(_selectedExtensionIds.contains)
        .toList();
    final fallbackExtensionIds =
        selectedExtensionIds.length == allExtensionIds.length
        ? null
        : selectedExtensionIds;

    ref
        .read(settingsProvider.notifier)
        .setDownloadFallbackExtensionIds(fallbackExtensionIds);
    setState(() {
      _hasChanges = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.snackbarProviderPrioritySaved)),
    );
  }
}
