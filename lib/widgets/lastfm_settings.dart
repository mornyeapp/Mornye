import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/widgets/settings_group.dart';

class LastfmSettings extends StatefulWidget {
  const LastfmSettings({super.key, required this.service});

  final LastfmService service;

  @override
  State<LastfmSettings> createState() => _LastfmSettingsState();
}

class _LastfmSettingsState extends State<LastfmSettings> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.service.initialize());
  }

  @override
  void didUpdateWidget(LastfmSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      unawaited(widget.service.initialize());
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => SettingsGroup(
        children: [
          SettingsItem(
            icon: service.connected ? Icons.check_circle_outline : Icons.link,
            title: service.connected
                ? service.username!
                : service.busy
                ? l10n.lastfmConnecting
                : service.awaitingAuthorization
                ? l10n.lastfmFinishConnection
                : l10n.lastfmConnect,
            subtitle: !service.configured
                ? l10n.lastfmUnavailable
                : service.awaitingAuthorization
                ? l10n.lastfmAuthorizeHelp
                : l10n.lastfmDescription,
            onTap: service.busy || !service.configured || service.connected
                ? null
                : () => unawaited(
                    service.awaitingAuthorization
                        ? service.finishConnection()
                        : service.beginConnection(),
                  ),
            showDivider:
                service.connected ||
                service.awaitingAuthorization ||
                service.problem != null,
          ),
          if (service.awaitingAuthorization)
            SettingsItem(
              icon: Icons.close,
              title: l10n.dialogCancel,
              onTap: service.cancelConnection,
              showDivider: service.problem != null,
            ),
          if (service.connected) ...[
            SettingsSwitchItem(
              icon: Icons.history_rounded,
              title: l10n.lastfmScrobbling,
              subtitle: l10n.lastfmScrobblingDescription,
              value: service.enabled,
              onChanged: (enabled) => unawaited(service.setEnabled(enabled)),
            ),
            SettingsSwitchItem(
              icon: Icons.music_note_outlined,
              title: l10n.lastfmNowPlaying,
              subtitle: l10n.lastfmNowPlayingDescription,
              value: service.nowPlaying,
              enabled: service.enabled,
              onChanged: (enabled) => unawaited(service.setNowPlaying(enabled)),
            ),
          ],
          if (service.pendingCount > 0)
            SettingsItem(
              icon: Icons.sync,
              title: l10n.lastfmPending(service.pendingCount),
              onTap: service.enabled ? () => unawaited(service.flush()) : null,
            ),
          if (service.problem case final problem?)
            SettingsItem(
              icon: Icons.info_outline,
              title: switch (problem) {
                LastfmProblem.connection => l10n.lastfmConnectionError,
                LastfmProblem.storage => l10n.lastfmStorageError,
                LastfmProblem.pending => l10n.lastfmAuthorizationPending,
                LastfmProblem.expired => l10n.lastfmAuthorizationExpired,
                LastfmProblem.reauthenticate => l10n.lastfmReauthenticate,
                LastfmProblem.unavailable => l10n.lastfmUnavailable,
                LastfmProblem.rejected => l10n.lastfmRejected,
              },
              onTap: problem == LastfmProblem.storage
                  ? () => unawaited(service.retry())
                  : null,
              showDivider: service.connected,
            ),
          if (service.connected)
            SettingsItem(
              icon: Icons.link_off,
              title: l10n.lastfmDisconnect,
              onTap: () => unawaited(service.disconnect()),
              showDivider: false,
            ),
        ],
      ),
    );
  }
}
