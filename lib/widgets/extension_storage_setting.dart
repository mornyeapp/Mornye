import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/settings_group.dart';

final unsecuredExtensionStorageProvider = FutureProvider.autoDispose<bool>(
  (ref) => ExtensionStorageService.isUnsecuredStorageEnabled(),
);

final extensionStorageRecoveryNoticeProvider = FutureProvider.autoDispose<bool>(
  (ref) => ExtensionStorageService.hasRecoveryNotice(),
);

/// Says once that extension settings and sign-ins were set aside with their
/// lost key. Leaving the page counts as having read it.
class ExtensionStorageRecoveryNotice extends ConsumerStatefulWidget {
  const ExtensionStorageRecoveryNotice({super.key});

  @override
  ConsumerState<ExtensionStorageRecoveryNotice> createState() =>
      _ExtensionStorageRecoveryNoticeState();
}

class _ExtensionStorageRecoveryNoticeState
    extends ConsumerState<ExtensionStorageRecoveryNotice> {
  bool _shown = false;

  @override
  void dispose() {
    if (_shown) unawaited(ExtensionStorageService.dismissRecoveryNotice());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Startup may still be setting the data aside.
    ref.listen(extensionProvider.select((state) => state.isInitialized), (
      _,
      _,
    ) {
      ref.invalidate(extensionStorageRecoveryNoticeProvider);
    });
    if (ref.watch(extensionStorageRecoveryNoticeProvider).value != true) {
      return const SizedBox.shrink();
    }
    _shown = true;
    return SettingsGroup(
      children: [
        SettingsItem(
          icon: Icons.info_outline,
          title: context.l10n.extensionsStorageRecoveredTitle,
          subtitle: context.l10n.extensionsStorageRecoveredMessage,
          showDivider: false,
        ),
      ],
    );
  }
}

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
      try {
        await ExtensionStorageService.setUnsecuredStorage(enabled);
      } on ExtensionStorageModeException catch (error) {
        if (error.reason != ExtensionStorageModeFailure.keyringRequired ||
            !mounted) {
          rethrow;
        }
        // Without this choice a computer that has lost its keyring could
        // never use extensions again.
        final l10n = context.l10n;
        final startOver = await showAppConfirmDialog(
          context,
          title: l10n.extensionsStorageStartOverTitle,
          message:
              '${l10n.extensionsStorageKeyringRequired}\n\n'
              '${l10n.extensionsStorageStartOverMessage}',
          confirmLabel: l10n.extensionsStorageStartOver,
          destructive: true,
          cancelIsDefault: true,
        );
        if (!startOver) return;
        await ExtensionStorageService.setUnsecuredStorage(
          enabled,
          startOver: true,
        );
      }
      if (!mounted) return;
      ref.invalidate(extensionStorageRecoveryNoticeProvider);
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
