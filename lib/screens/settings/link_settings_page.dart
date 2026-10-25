import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/link_pairing_dialogs.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/client/link_client_session.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Mornye on your computer: paired computers with their connection, what
/// this phone shares with them, the computers found on the network, and
/// pairing.
class LinkSettingsPage extends ConsumerStatefulWidget {
  const LinkSettingsPage({super.key});

  @override
  ConsumerState<LinkSettingsPage> createState() => _LinkSettingsPageState();
}

class _LinkSettingsPageState extends ConsumerState<LinkSettingsPage> {
  late final VoidCallback _releaseDiscovery;
  var _busy = false;

  LinkClientController get _controller =>
      ref.read(linkClientControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _releaseDiscovery = _controller.acquireDiscovery();
  }

  @override
  void dispose() {
    _releaseDiscovery();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showCertificateWarning() => showAppDialog<void>(
    context: context,
    builder: (context) => AppAlertDialog(
      icon: const Icon(Icons.gpp_maybe_outlined),
      title: Text(context.l10n.linkErrorCertificateTitle),
      content: Text(context.l10n.linkErrorCertificate),
      actions: [
        AppDialogAction(
          filled: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    ),
  );

  /// Reads the computer's `info`, then asks for the PIN and pairs.
  Future<void> _pair(
    String host,
    int port, {
    String? expectedFingerprint,
    String? name,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    final LinkPairingTarget target;
    try {
      target = await _controller.probe(
        host,
        port,
        expectedFingerprint: expectedFingerprint,
      );
    } on LinkPairingException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (error.error == LinkPairingError.certificateMismatch) {
        await _showCertificateWarning();
      } else {
        _showMessage(linkPairingErrorMessage(context.l10n, error.error));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final serverName = target.info.name.isNotEmpty
        ? target.info.name
        : name ?? host;
    final paired = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LinkPinDialog(
        serverName: serverName,
        shortFingerprint: target.shortFingerprint,
        pairingOpen: target.info.pairing,
        onSubmit: (pin) async {
          try {
            await _controller.pair(target, pin);
            return null;
          } on LinkPairingException catch (error) {
            return error.error;
          }
        },
      ),
    );
    if (paired == true && mounted) {
      _showMessage(context.l10n.linkPaired(serverName));
    }
  }

  Future<void> _pairDiscovered(LinkDiscoveredServer server) => _pair(
    server.host,
    server.port,
    expectedFingerprint: server.fingerprint,
    name: server.name,
  );

  /// Pairs a known computer again, at its advertised address when the
  /// network shows it, else at the saved one.
  Future<void> _pairAgain(LinkServerRecord record) {
    final found = ref
        .read(linkClientControllerProvider)
        .discoveredServer(record.serverId);
    if (found != null) return _pairDiscovered(found);
    final address = Uri.parse(record.address);
    return _pair(address.host, address.port, name: record.name);
  }

  Future<void> _addManually() async {
    final address = await showAppDialog<({String host, int port})>(
      context: context,
      builder: (_) => const LinkManualAddDialog(),
    );
    if (address == null || !mounted) return;
    await _pair(address.host, address.port);
  }

  Future<void> _forget(LinkServerRecord record) async {
    final removeLibrary = await showAppDialog<bool>(
      context: context,
      builder: (_) => LinkForgetDialog(name: record.name),
    );
    if (removeLibrary == null || !mounted) return;
    await _controller.forget(record.serverId, removeLibrary: removeLibrary);
  }

  Future<void> _allowLocalNetwork() async {
    try {
      await _controller.requestLocalNetworkAccess();
    } on LocalNetworkPermissionException {
      if (mounted) _showMessage(context.l10n.networkErrorLocalPermission);
    }
  }

  String _status(LinkClientState state, LinkServerRecord record) {
    final l10n = context.l10n;
    if (record.serverId != state.activeServerId) return l10n.linkStateInactive;
    return switch (state.connection) {
      LinkConnectionState.connected => l10n.linkStateConnected,
      LinkConnectionState.connecting => l10n.linkStateConnecting,
      LinkConnectionState.disconnected => l10n.linkStateDisconnected,
    };
  }

  List<Widget> _notices(LinkClientState state) {
    final l10n = context.l10n;
    final active = state.activeServer;
    final permissionDenied =
        state.discovery == LinkDiscoveryStatus.permissionDenied ||
        state.issue == LinkSessionIssue.localNetworkPermission;
    return [
      if (permissionDenied)
        SettingsInfoCard(
          tone: SettingsInfoTone.warning,
          icon: Icons.wifi_off_rounded,
          title: l10n.linkLocalNetworkTitle,
          message: l10n.linkLocalNetworkMessage,
          action: AppActionButton(
            onPressed: _allowLocalNetwork,
            icon: const Icon(Icons.lock_open_outlined),
            label: Text(l10n.linkLocalNetworkAllow),
            tonal: true,
          ),
        )
      else if (!state.localNetworkAvailable)
        SettingsInfoCard(
          tone: SettingsInfoTone.warning,
          icon: Icons.wifi_off_rounded,
          title: l10n.linkWifiOffTitle,
          message: l10n.linkWifiOffMessage,
        ),
      if (active != null &&
          state.connection != LinkConnectionState.connected &&
          (state.issue == LinkSessionIssue.certificate ||
              state.certificateChanged(active)))
        SettingsInfoCard(
          tone: SettingsInfoTone.error,
          icon: Icons.gpp_maybe_outlined,
          title: l10n.linkErrorCertificateTitle,
          message: l10n.linkIssueCertificate(active.name),
          action: AppActionButton(
            onPressed: _busy ? null : () => _pairAgain(active),
            icon: const Icon(Icons.link),
            label: Text(l10n.linkPairAgain),
            tonal: true,
          ),
        )
      else if (active != null &&
          state.connection != LinkConnectionState.connected &&
          state.issue == LinkSessionIssue.unauthorized)
        SettingsInfoCard(
          tone: SettingsInfoTone.error,
          icon: Icons.link_off,
          message: l10n.linkIssueUnauthorized(active.name),
          action: AppActionButton(
            onPressed: _busy ? null : () => _pairAgain(active),
            icon: const Icon(Icons.link),
            label: Text(l10n.linkPairAgain),
            tonal: true,
          ),
        )
      else if (active != null &&
          state.connection != LinkConnectionState.connected &&
          state.issue == LinkSessionIssue.incompatible)
        SettingsInfoCard(
          tone: SettingsInfoTone.warning,
          icon: Icons.system_update_outlined,
          message: l10n.linkIssueIncompatible(active.name),
        ),
    ];
  }

  Widget _pairedRow(LinkClientState state, LinkServerRecord record) {
    final l10n = context.l10n;
    final active = record.serverId == state.activeServerId;
    final scheme = Theme.of(context).colorScheme;
    return SettingsItem(
      icon: Icons.computer,
      showIconInMornye: true,
      iconColor: active && state.connection == LinkConnectionState.connected
          ? scheme.primary
          : null,
      title: record.name,
      titleTrailing: active && state.servers.length > 1
          ? Text(
              l10n.linkActive,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.primary),
            )
          : null,
      subtitle: '${_status(state, record)} · ${Uri.parse(record.address).host}',
      onTap: _busy
          ? null
          : active
          ? (state.connection == LinkConnectionState.disconnected
                ? _controller.retry
                : null)
          : () => _controller.setActive(record.serverId),
      trailing: _LinkIconAction(
        tooltip: l10n.linkForget,
        icon: Icons.link_off,
        cupertinoIcon: CupertinoIcons.minus_circle,
        onPressed: _busy ? null : () => _forget(record),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(linkClientControllerProvider);
    final options = ref.watch(linkPhoneOptionsProvider);
    final optionsNotifier = ref.read(linkPhoneOptionsProvider.notifier);
    final unpaired = state.unpaired;
    final searching = state.discovery == LinkDiscoveryStatus.searching;
    final theme = Theme.of(context);
    final note = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.linkPageTitle),
          SliverToBoxAdapter(
            child: _LinkInset(
              child: Text(l10n.linkPageDescription, style: note),
            ),
          ),
          if (_busy)
            const SliverToBoxAdapter(
              child: _LinkInset(child: AppProgressIndicator.linear()),
            ),
          SliverList.list(children: _notices(state)),
          if (state.servers.isNotEmpty)
            ...settingsSectionSlivers(
              title: l10n.linkPairedSection,
              children: [
                for (final record in state.servers) _pairedRow(state, record),
              ],
            ),
          if (state.servers.isNotEmpty)
            ...settingsSectionSlivers(
              title: l10n.linkPhoneSection,
              children: [
                SettingsSwitchItem(
                  icon: Icons.library_music_outlined,
                  title: l10n.linkShareSongsTitle,
                  subtitle: l10n.linkShareSongsSubtitle,
                  value: options.shareSongs,
                  onChanged: options.loaded
                      ? optionsNotifier.setShareSongs
                      : null,
                ),
                SettingsSwitchItem(
                  icon: Icons.devices_outlined,
                  title: l10n.linkFollowDesktopTitle,
                  subtitle: l10n.linkFollowDesktopSubtitle,
                  value: options.followDesktop,
                  onChanged: options.loaded
                      ? optionsNotifier.setFollowDesktop
                      : null,
                  showDivider: false,
                ),
              ],
            ),
          ...settingsSectionSlivers(
            title: l10n.linkNearbySection,
            children: [
              for (final server in unpaired)
                SettingsItem(
                  icon: Icons.computer,
                  showIconInMornye: true,
                  title: server.name,
                  subtitle: server.host,
                  onTap: _busy ? null : () => _pairDiscovered(server),
                ),
              if (unpaired.isEmpty)
                SettingsItem(
                  icon: Icons.wifi,
                  showIconInMornye: true,
                  title: searching
                      ? l10n.linkSearching
                      : l10n.linkNoneFoundTitle,
                  subtitle: l10n.linkNoneFound,
                  trailing: searching
                      ? SizedBox.square(
                          dimension: 24,
                          child: context.isMornye
                              ? const CupertinoActivityIndicator()
                              : const AppProgressIndicator.circular(),
                        )
                      : null,
                ),
            ],
          ),
          SliverToBoxAdapter(
            child: _LinkInset(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: AppActionButton(
                  onPressed: _busy ? null : _addManually,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.linkAddManually),
                  tonal: true,
                ),
              ),
            ),
          ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

/// Lines free content up with the settings groups at any width.
class _LinkInset extends StatelessWidget {
  const _LinkInset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = settingsHorizontalInset(context, constraints.maxWidth);
      return Padding(
        padding: EdgeInsets.fromLTRB(inset + 8, 8, inset + 8, 8),
        child: child,
      );
    },
  );
}

class _LinkIconAction extends StatelessWidget {
  const _LinkIconAction({
    required this.tooltip,
    required this.icon,
    required this.cupertinoIcon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final IconData cupertinoIcon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => context.isMornye
      ? Tooltip(
          message: tooltip,
          child: CupertinoButton(
            onPressed: onPressed,
            padding: const EdgeInsets.all(12),
            child: Icon(
              cupertinoIcon,
              size: 24,
              semanticLabel: tooltip,
              color: onPressed == null
                  ? Theme.of(context).disabledColor
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        )
      : ExpressiveIconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
        );
}
