import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/link_desktop_settings_page.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Grows and shrinks around [child]. With reduced motion the size changes at
/// once: a size animation of no length would finish inside its own layout,
/// which the framework rejects.
Widget _sized(AppMotionSpec grow, AppMotionSpec shrink, Widget child) =>
    grow.duration == Duration.zero
    ? child
    : AnimatedSize(
        alignment: AlignmentDirectional.topStart,
        duration: grow.duration,
        reverseDuration: shrink.duration,
        curve: grow.curve,
        child: child,
      );

/// Share this phone, at the end of the phone's Link page: the switch that
/// makes this phone a Link host for other phones and, while it is on, the
/// rows of the computer's Link page (name, address, security code, pairing
/// and the paired phones with Remove).
class LinkPhoneHostSection extends ConsumerWidget {
  const LinkPhoneHostSection({super.key});

  static const switchKey = ValueKey('link-phone-host');
  static const contentKey = ValueKey('link-phone-host-content');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(linkClientSupportedProvider)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final host = ref.watch(linkDesktopHostProvider);
    final notifier = ref.read(linkDesktopHostProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    // Reduced motion takes this instead of the springs, which are
    // Material's or Mornye's by style.
    final fallback = AppMotionSpec(
      reduced ? Duration.zero : const Duration(milliseconds: 250),
      Curves.easeOut,
    );
    final grow = AppMotion.spatial(context, fallback);
    final shrink = AppMotion.spatialFast(context, fallback);
    final fadeIn = AppMotion.effects(context, fallback);
    final fadeOut = AppMotion.effectsFast(context, fallback);
    final phones = [
      for (final device in host.devices)
        if (!device.isSubsonicApp) device,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: l10n.linkPhoneHostSection),
        SettingsGroup(
          children: [
            SettingsSwitchItem(
              key: switchKey,
              icon: Icons.share_outlined,
              title: l10n.linkPhoneHostTitle,
              titleTrailing: const BetaBadge(),
              subtitle: host.enabled
                  ? linkHostStatus(context, host)
                  : l10n.linkPhoneHostSubtitle,
              value: host.enabled,
              onChanged: host.loaded
                  ? (enabled) => unawaited(notifier.setEnabled(enabled))
                  : null,
              showDivider: false,
            ),
          ],
        ),
        // The page ends here, so growing pushes nothing but the spacer.
        _sized(
          grow,
          shrink,
          AnimatedSwitcher(
            duration: fadeIn.duration,
            reverseDuration: fadeOut.duration,
            switchInCurve: fadeIn.curve,
            switchOutCurve: fadeOut.leaving,
            layoutBuilder: (current, previous) => Stack(
              alignment: AlignmentDirectional.topStart,
              children: [...previous, ?current],
            ),
            child: host.enabled
                ? Column(
                    key: contentKey,
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (host.phase == LinkHostPhase.failed)
                        SettingsInfoCard(
                          tone: SettingsInfoTone.error,
                          icon: Icons.error_outline,
                          message: l10n.linkDesktopStatusFailed(
                            host.error ?? '',
                          ),
                          action: AppActionButton(
                            onPressed: () => unawaited(notifier.retry()),
                            icon: const Icon(Icons.refresh),
                            label: Text(l10n.dialogRetry),
                            tonal: true,
                          ),
                        ),
                      SettingsGroup(
                        children: linkHostInfoRows(
                          context,
                          ref,
                          host,
                          phone: true,
                        ),
                      ),
                      // Paired phones stay listed, and removable, while the
                      // server is off; pairing needs it running.
                      if (host.server != null || phones.isNotEmpty) ...[
                        SettingsSectionHeader(
                          title: l10n.linkDesktopSectionPhones,
                        ),
                        SettingsGroup(
                          // Device rows are their own widgets; mark them.
                          connected: true,
                          children: linkHostPhoneRows(
                            context,
                            ref,
                            host,
                            phone: true,
                          ),
                        ),
                      ],
                    ],
                  )
                : const SizedBox.shrink(key: ValueKey('link-phone-host-off')),
          ),
        ),
      ],
    );
  }
}
