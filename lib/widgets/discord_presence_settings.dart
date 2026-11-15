import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/discord_presence_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/settings_group.dart';

class DiscordPresenceSettings extends ConsumerWidget {
  const DiscordPresenceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      settingsProvider.select((s) => s.discordRichPresenceEnabled),
    );
    final service = DiscordPresenceService.instance;
    final l10n = context.l10n;
    return ValueListenableBuilder<DiscordPresenceStatus>(
      valueListenable: service.status,
      builder: (context, status, _) => SettingsGroup(
        children: [
          SettingsSwitchItem(
            icon: Icons.headphones_outlined,
            title: 'Discord Rich Presence',
            subtitle: l10n.discordPresenceDescription,
            value: enabled,
            onChanged: ref
                .read(settingsProvider.notifier)
                .setDiscordRichPresenceEnabled,
            showDivider: enabled,
          ),
          if (enabled)
            SettingsItem(
              icon: status == DiscordPresenceStatus.active
                  ? Icons.check_circle_outline
                  : Icons.info_outline,
              title: switch (status) {
                DiscordPresenceStatus.disabled => l10n.discordPresenceDisabled,
                DiscordPresenceStatus.linkRequired => l10n.discordPresenceLink,
                DiscordPresenceStatus.connecting =>
                  l10n.discordPresenceConnecting,
                DiscordPresenceStatus.ready => l10n.discordPresenceReady,
                DiscordPresenceStatus.active => l10n.discordPresenceActive,
                DiscordPresenceStatus.unavailable =>
                  l10n.discordPresenceUnavailable,
                DiscordPresenceStatus.sdkUnavailable =>
                  l10n.discordPresenceBuildUnavailable,
              },
              subtitle: isDesktopPlatform
                  ? l10n.discordPresenceDesktopHelp
                  : Platform.isAndroid
                  ? l10n.discordPresenceAndroidHelp
                  : l10n.discordPresenceIosHelp,
              onTap: status == DiscordPresenceStatus.linkRequired
                  ? () => unawaited(service.link())
                  : null,
              showDivider: Platform.isIOS,
            ),
          if (enabled && Platform.isIOS)
            SettingsItem(
              icon: Icons.link_off,
              title: l10n.discordPresenceDisconnect,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setDiscordRichPresenceEnabled(false);
                unawaited(service.forgetAccount());
              },
              showDivider: false,
            ),
        ],
      ),
    );
  }
}
