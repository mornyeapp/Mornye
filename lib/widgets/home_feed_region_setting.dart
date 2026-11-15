import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/extension_country_name.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/settings_group.dart';

class HomeFeedRegionSetting extends ConsumerStatefulWidget {
  const HomeFeedRegionSetting({super.key});

  @override
  ConsumerState<HomeFeedRegionSetting> createState() =>
      _HomeFeedRegionSettingState();
}

class _HomeFeedRegionSettingState extends ConsumerState<HomeFeedRegionSetting> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final extension = ref.watch(homeFeedExtensionProvider);
    final setting = extension?.homeFeedRegionSetting;
    if (extension == null || setting == null) return const SizedBox.shrink();
    final saved = ref.watch(extensionSettingsProvider(extension.id));
    final selected = (saved.value?[setting.key] ?? setting.defaultValue)
        ?.toString();
    return SettingsItem(
      icon: Icons.public,
      title: context.l10n.extensionsHomeFeedCountry,
      subtitle: saved.hasError
          ? context.friendlyError(saved.error)
          : '${extensionCountryName(context, selected ?? '')} · ${extension.displayName}',
      showDivider: false,
      onTap: _saving
          ? null
          : () async {
              if (saved.hasError) {
                ref.invalidate(extensionSettingsProvider(extension.id));
                return;
              }
              final region = await showAppScrollableBottomSheet<String>(
                context: context,
                title: context.l10n.extensionsHomeFeedCountry,
                subtitle:
                    setting.description ??
                    context.l10n.extensionsHomeFeedCountryDescription,
                builder: (sheetContext, controller) => SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final code in setting.options!)
                        AppSheetOption.choice(
                          title: Text(extensionCountryName(sheetContext, code)),
                          subtitle: Text(code.toUpperCase()),
                          selected:
                              code.toUpperCase() == selected?.toUpperCase(),
                          onTap: () => Navigator.pop(sheetContext, code),
                        ),
                    ],
                  ),
                ),
              );
              if (!mounted || region == null) return;
              setState(() => _saving = true);
              final success = await ref
                  .read(extensionProvider.notifier)
                  .setHomeFeedRegion(extension.id, region);
              if (!mounted || !context.mounted) return;
              setState(() => _saving = false);
              if (!success) {
                showAppSnackBar(
                  context,
                  content: Text(
                    context.l10n.snackbarError(
                      context.friendlyError(ref.read(extensionProvider).error),
                    ),
                  ),
                );
              }
            },
    );
  }
}
