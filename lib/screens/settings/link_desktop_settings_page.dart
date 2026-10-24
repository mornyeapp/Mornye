import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/desktop/link_text_input_dialog.dart';
import 'package:mornye/widgets/settings_group.dart';

/// The username third-party Subsonic apps enter; the server accepts any.
const linkSubsonicUsername = 'mornye';

/// The security code grouped for reading: `1a2b 3c4d`.
String _groupedCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

/// Desktop settings for Mornye Link: share the Library with the phone app,
/// pair phones, remove them and mint keys for other Subsonic apps.
class LinkDesktopSettingsPage extends ConsumerWidget {
  const LinkDesktopSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final host = ref.watch(linkDesktopHostProvider);
    final notifier = ref.read(linkDesktopHostProvider.notifier);
    final server = host.server;
    final phones = [
      for (final device in host.devices)
        if (!device.isSubsonicApp) device,
    ];
    final apps = [
      for (final device in host.devices)
        if (device.isSubsonicApp) device,
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.linkDesktopSettingsTitle),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  key: const ValueKey('link-enable'),
                  icon: Icons.phone_android,
                  title: l10n.linkDesktopEnableTitle,
                  titleTrailing: const BetaBadge(),
                  subtitle: _status(context, host),
                  value: host.enabled,
                  onChanged: (enabled) =>
                      unawaited(notifier.setEnabled(enabled)),
                  showDivider: false,
                ),
              ],
            ),
          ),
          if (host.phase == LinkHostPhase.failed)
            SliverToBoxAdapter(
              child: SettingsInfoCard(
                tone: SettingsInfoTone.error,
                icon: Icons.error_outline,
                message: l10n.linkDesktopStatusFailed(host.error ?? ''),
                action: TextButton(
                  onPressed: () => unawaited(notifier.retry()),
                  child: Text(l10n.dialogRetry),
                ),
              ),
            )
          else if (host.enabled)
            SliverToBoxAdapter(
              child: SettingsInfoCard(
                key: const ValueKey('link-firewall-hint'),
                icon: Icons.security_outlined,
                message: l10n.linkDesktopFirewallHint,
              ),
            ),
          ...settingsSectionSlivers(
            title: l10n.linkDesktopSectionComputer,
            children: [
              SettingsItem(
                key: const ValueKey('link-name'),
                icon: Icons.computer,
                title: l10n.linkDesktopDeviceName,
                subtitle: host.name,
                onTap: () => unawaited(_rename(context, ref)),
                showDivider: server != null,
              ),
              if (server != null) ...[
                SettingsItem(
                  icon: Icons.lan_outlined,
                  title: l10n.linkDesktopAddress,
                  subtitle: server.urls.join('\n'),
                  trailing: server.urls.isEmpty
                      ? null
                      : _CopyButton(
                          label: l10n.linkDesktopAddress,
                          value: server.urls.first,
                        ),
                ),
                SettingsItem(
                  key: const ValueKey('link-security-code'),
                  icon: Icons.security_outlined,
                  title: l10n.linkDesktopSecurityCode,
                  subtitle: l10n.linkDesktopSecurityCodeHint,
                  trailing: Text(
                    _groupedCode(server.shortFingerprint),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  showDivider: host.catalogSongs != null,
                ),
                if (host.catalogSongs != null)
                  SettingsItem(
                    icon: Icons.library_music_outlined,
                    title: l10n.linkDesktopCatalogSongs(host.catalogSongs!),
                    showDivider: false,
                  ),
              ],
            ],
          ),
          // Paired devices stay listed, and removable, while the server is
          // off; pairing and new keys need it running.
          if (server != null || phones.isNotEmpty)
            ...settingsSectionSlivers(
              title: l10n.linkDesktopSectionPhones,
              children: [
                if (server != null)
                  SettingsItem(
                    key: const ValueKey('link-pair'),
                    icon: Icons.add,
                    title: l10n.linkDesktopPairPhone,
                    subtitle: l10n.linkDesktopPairPhoneSubtitle,
                    onTap: () => unawaited(_pair(context, ref)),
                  ),
                if (phones.isEmpty)
                  SettingsItem(
                    title: l10n.linkDesktopNoDevices,
                    showDivider: false,
                  )
                else
                  for (final device in phones)
                    _DeviceRow(
                      device: device,
                      showDivider: device != phones.last,
                    ),
              ],
            ),
          if (server != null || apps.isNotEmpty)
            ...settingsSectionSlivers(
              title: l10n.linkDesktopSectionOtherApps,
              children: [
                if (server != null)
                  SettingsItem(
                    key: const ValueKey('link-add-app'),
                    icon: Icons.vpn_key_outlined,
                    title: l10n.linkDesktopAddSubsonicApp,
                    subtitle: l10n.linkDesktopAddSubsonicAppSubtitle,
                    onTap: () => unawaited(_addApp(context, ref)),
                    showDivider: apps.isNotEmpty,
                  ),
                for (final device in apps)
                  _DeviceRow(device: device, showDivider: device != apps.last),
              ],
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }

  String _status(BuildContext context, LinkDesktopHostState host) {
    final l10n = context.l10n;
    if (!host.enabled) return l10n.linkDesktopEnableSubtitle;
    return switch (host.phase) {
      LinkHostPhase.running => l10n.linkDesktopStatusRunning(
        host.clients.length,
      ),
      LinkHostPhase.failed => l10n.linkDesktopStatusFailed(host.error ?? ''),
      LinkHostPhase.starting ||
      LinkHostPhase.stopped => l10n.linkDesktopStatusStarting,
    };
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final name = await showLinkTextInputDialog(
      context,
      title: l10n.linkDesktopDeviceName,
      label: l10n.linkDesktopDeviceName,
      hint: l10n.linkDesktopDeviceNameHint,
      confirmLabel: l10n.dialogSave,
      initialValue: ref.read(linkDesktopHostProvider).name,
      maxLength: 63,
    );
    if (name == null) return;
    await ref.read(linkDesktopHostProvider.notifier).setName(name);
  }

  Future<void> _pair(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final notifier = ref.read(linkDesktopHostProvider.notifier);
    final LinkPairingWindow window;
    try {
      window = await notifier.beginPairing();
    } on Object {
      if (context.mounted) _toast(context, l10n.linkDesktopPairFailed);
      return;
    }
    if (!context.mounted) return;
    final outcome = await showAppDialog<LinkPairingEvent>(
      context: context,
      barrierDismissible: false,
      builder: (context) => LinkDesktopPairingDialog(
        window: window,
        events: notifier.pairingEvents,
      ),
    );
    if (outcome == null) {
      await notifier.endPairing();
      return;
    }
    final message = switch (outcome) {
      LinkPairedEvent(:final name) => l10n.linkDesktopPaired(name),
      LinkPairingEndedEvent(reason: LinkPairingEndReason.expired) =>
        l10n.linkDesktopPairExpired,
      LinkPairingEndedEvent(reason: LinkPairingEndReason.attempts) =>
        l10n.linkDesktopPairAttempts,
      LinkPairingEndedEvent() => null,
    };
    if (message != null && context.mounted) _toast(context, message);
  }

  Future<void> _addApp(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final name = await showLinkTextInputDialog(
      context,
      title: l10n.linkDesktopAddSubsonicApp,
      label: l10n.linkDesktopAppName,
      confirmLabel: l10n.linkDesktopCreateKey,
      maxLength: 63,
    );
    if (name == null || !context.mounted) return;
    final LinkAppKey key;
    try {
      key = await ref.read(linkDesktopHostProvider.notifier).createAppKey(name);
    } on Object catch (error) {
      if (context.mounted) _toastError(context, error);
      return;
    }
    if (!context.mounted) return;
    final urls = ref.read(linkDesktopHostProvider).server?.urls ?? const [];
    await showAppDialog<void>(
      context: context,
      builder: (context) =>
          _AppKeyDialog(name: name, urls: urls, apiKey: key.apiKey),
    );
  }
}

/// A paired phone or Subsonic app with its status and a remove button.
class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.device, required this.showDivider});

  final LinkPairedDevice device;
  final bool showDivider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final status = device.connected
        ? l10n.linkDesktopDeviceConnected
        : device.lastSeenMs > 0
        ? l10n.linkDesktopDeviceLastSeen(
            DateFormat.yMMMd(locale).add_jm().format(
              DateTime.fromMillisecondsSinceEpoch(device.lastSeenMs),
            ),
          )
        : l10n.linkDesktopDeviceNeverSeen;
    final name = device.name.isEmpty ? device.deviceId : device.name;
    return SettingsItem(
      key: ValueKey('link-device-${device.deviceId}'),
      icon: device.isSubsonicApp ? Icons.vpn_key_outlined : Icons.phone_android,
      title: name,
      subtitle: device.isSubsonicApp
          ? '${l10n.linkDesktopSubsonicApp} · $status'
          : status,
      showDivider: showDivider,
      trailing: AppIconButton(
        key: ValueKey('link-revoke-${device.deviceId}'),
        tooltip: l10n.linkDesktopRevoke,
        icon: AppIcon.adaptive(Icons.delete_outline, size: 22),
        onPressed: () => unawaited(_revoke(context, ref, name)),
      ),
    );
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref, String name) async {
    final l10n = context.l10n;
    final confirmed = await showAppConfirmDialog(
      context,
      title: l10n.linkDesktopRevokeTitle(name),
      message: l10n.linkDesktopRevokeMessage,
      confirmLabel: l10n.linkDesktopRevoke,
      destructive: true,
      errorConfirm: true,
    );
    if (!confirmed) return;
    try {
      await ref.read(linkDesktopHostProvider.notifier).revoke(device.deviceId);
      // The row leaves the list on the next frame; it is still mounted here.
      if (context.mounted) _toast(context, l10n.linkDesktopRevoked(name));
    } on Object catch (error) {
      if (context.mounted) _toastError(context, error);
    }
  }
}

void _toast(BuildContext context, String message) =>
    showAppSnackBar(context, content: Text(message));

void _toastError(BuildContext context, Object error) =>
    _toast(context, context.l10n.snackbarError(context.friendlyError(error)));

/// Shows the pairing PIN, the security code and a countdown until a phone
/// pairs or the window closes. Pops the [LinkPairingEvent] that ended it,
/// or null when the owner cancels.
class LinkDesktopPairingDialog extends StatefulWidget {
  const LinkDesktopPairingDialog({
    super.key,
    required this.window,
    required this.events,
    this.nowMs,
  });

  final LinkPairingWindow window;
  final Stream<LinkPairingEvent> events;

  /// Overrides the clock in tests.
  final int Function()? nowMs;

  @override
  State<LinkDesktopPairingDialog> createState() =>
      _LinkDesktopPairingDialogState();
}

class _LinkDesktopPairingDialogState extends State<LinkDesktopPairingDialog> {
  late final StreamSubscription<LinkPairingEvent> _events;
  Timer? _ticker;
  Timer? _pairedFallback;
  bool _closed = false;
  late int _remainingMs = _remaining();

  int _now() => widget.nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  int _remaining() => (widget.window.expiresMs - _now()).clamp(0, 1 << 31);

  @override
  void initState() {
    super.initState();
    _events = widget.events.listen(_onEvent);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remainingMs = _remaining());
      if (_remainingMs == 0) {
        _close(const LinkPairingEndedEvent(LinkPairingEndReason.expired));
      }
    });
  }

  void _onEvent(LinkPairingEvent event) {
    // `linkPaired` carries the phone's name; the window's own end event
    // for a pairing may arrive first, so give the name a moment.
    if (event is LinkPairingEndedEvent &&
        event.reason == LinkPairingEndReason.paired) {
      _pairedFallback ??= Timer(
        const Duration(seconds: 2),
        () => _close(event),
      );
      return;
    }
    _close(event);
  }

  void _close(LinkPairingEvent? event) {
    // The dialog stays mounted while it animates out, and ending the window
    // makes the server report it ended; a second pop would close the page.
    if (_closed) return;
    _closed = true;
    _ticker?.cancel();
    _pairedFallback?.cancel();
    if (mounted) Navigator.of(context).pop(event);
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    _ticker?.cancel();
    _pairedFallback?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pin = widget.window.pin;
    final spaced = pin.length == 6
        ? '${pin.substring(0, 3)} ${pin.substring(3)}'
        : pin;
    final seconds = (_remainingMs / 1000).ceil();
    final countdown =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return AppAlertDialog(
      title: Text(l10n.linkDesktopPairPhone),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.linkDesktopPairInstructions),
          SizedBox(height: context.tokens.gapLg),
          Semantics(
            label: pin.split('').join(' '),
            excludeSemantics: true,
            child: Text(
              spaced,
              key: const ValueKey('link-pairing-pin'),
              textAlign: TextAlign.center,
              style: theme.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(height: context.tokens.gapLg),
          Text(
            l10n.linkDesktopPairCheckCode(
              _groupedCode(linkShortFingerprint(widget.window.fingerprint)),
            ),
          ),
          SizedBox(height: context.tokens.gapSm),
          Text(
            l10n.linkDesktopPairExpires(countdown),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      actions: [
        AppDialogAction(
          onPressed: () => _close(null),
          child: Text(l10n.dialogCancel),
        ),
      ],
    );
  }
}

/// Shows what a third-party Subsonic app needs: the server address, the
/// username and the new key, each with a copy button.
class _AppKeyDialog extends StatelessWidget {
  const _AppKeyDialog({
    required this.name,
    required this.urls,
    required this.apiKey,
  });

  final String name;
  final List<String> urls;
  final String apiKey;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppAlertDialog(
      title: Text(l10n.linkDesktopAppKeyTitle(name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.linkDesktopAppKeyMessage),
          SizedBox(height: context.tokens.gapLg),
          if (urls.isNotEmpty)
            _CopyField(
              label: l10n.linkDesktopServerAddress,
              value: urls.join('\n'),
              copyValue: urls.first,
            ),
          _CopyField(
            label: l10n.linkDesktopUsername,
            value: linkSubsonicUsername,
          ),
          _CopyField(
            key: const ValueKey('link-app-key'),
            label: l10n.linkDesktopApiKey,
            value: apiKey,
          ),
        ],
      ),
      actions: [
        AppDialogAction(
          isDefault: true,
          filled: true,
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// A labelled, selectable value with a copy button.
class _CopyField extends StatelessWidget {
  const _CopyField({
    super.key,
    required this.label,
    required this.value,
    this.copyValue,
  });

  final String label;
  final String value;
  final String? copyValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: context.tokens.gapXs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                SelectableText(value, style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
          _CopyButton(label: label, value: copyValue ?? value),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A fixed box: dialogs measure their content, which the button cannot
    // report.
    return SizedBox.square(
      dimension: 48,
      child: Center(
        child: AppIconButton(
          tooltip: l10n.linkDesktopCopy(label),
          icon: AppIcon.adaptive(Icons.copy, size: 20),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) _toast(context, l10n.trackCopiedToClipboard);
          },
        ),
      ),
    );
  }
}
