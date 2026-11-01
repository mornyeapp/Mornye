import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/settings_group.dart';

final unsecuredExtensionStorageProvider = FutureProvider.autoDispose<bool>(
  (ref) => ExtensionStorageService.isUnsecuredStorageEnabled(),
);

/// Shared by Linux setup and extension settings, including failed startup.
class ExtensionStorageSetting extends ConsumerStatefulWidget {
  const ExtensionStorageSetting({super.key});

  @override
  ConsumerState<ExtensionStorageSetting> createState() =>
      _ExtensionStorageSettingState();
}

class _ExtensionStorageSettingState
    extends ConsumerState<ExtensionStorageSetting> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    if (!ExtensionStorageService.supportsUnsecuredStorage) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(unsecuredExtensionStorageProvider);
    return SettingsGroup(
      children: [
        if (enabled.hasError)
          SettingsItem(
            icon: Icons.lock_outline,
            title: context.l10n.extensionsUnsecuredStorage,
            subtitle: context.friendlyError(enabled.error),
            onTap: () => ref.invalidate(unsecuredExtensionStorageProvider),
            showDivider: false,
          )
        else
          SettingsSwitchItem(
            icon: Icons.lock_open_outlined,
            title: context.l10n.extensionsUnsecuredStorage,
            subtitle: context.l10n.extensionsUnsecuredStorageDescription,
            value: enabled.value ?? false,
            enabled: enabled.hasValue && !_saving,
            onChanged: _changeMode,
            showDivider: false,
          ),
      ],
    );
  }

  Future<void> _changeMode(bool enabled) async {
    setState(() => _saving = true);
    try {
      await ExtensionStorageService.setUnsecuredStorage(enabled);
      if (!mounted) return;
      ref.invalidate(unsecuredExtensionStorageProvider);
      // A failed startup can now recover. An active runtime keeps the same key.
      try {
        await ref.read(extensionProvider.notifier).ensureInitialized();
      } catch (_) {
        // Extension settings already display initialization errors and retry.
      }
    } catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        ExtensionStorageModeException(
          reason: ExtensionStorageModeFailure.keyringRequired,
        ) =>
          context.l10n.extensionsStorageKeyringRequired,
        ExtensionStorageModeException(
          reason: ExtensionStorageModeFailure.conflictingKeys,
        ) =>
          context.l10n.extensionsStorageKeyConflict,
        PlatformException() => context.l10n.extensionsStorageKeyringUnavailable,
        _ => context.friendlyError(error),
      };
      showAppSnackBar(context, content: Text(message));
    } finally {
      if (mounted) {
        ref.invalidate(unsecuredExtensionStorageProvider);
        setState(() => _saving = false);
      }
    }
  }
}
