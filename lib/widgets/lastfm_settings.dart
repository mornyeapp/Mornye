import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/widgets/scrobble_settings.dart';
import 'package:mornye/widgets/settings_group.dart';

/// A Last.fm-compatible service, signed in through its approval page.
class LastfmSettings extends StatefulWidget {
  const LastfmSettings({super.key, required this.service, this.serviceName});

  final LastfmService service;

  /// The name of a compatible service such as Libre.fm; null for Last.fm.
  final String? serviceName;

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
    final labels = switch (widget.serviceName) {
      final name? => ScrobbleSettingsLabels.named(l10n, name),
      null => ScrobbleSettingsLabels.lastfm(l10n),
    };
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final rows = scrobbleAccountRows(context, service, labels);
        return SettingsGroup(
          children: [
            SettingsItem(
              icon: service.connected ? Icons.check_circle_outline : Icons.link,
              title: service.connected
                  ? service.username!
                  : service.busy
                  ? labels.connecting
                  : service.awaitingAuthorization
                  ? l10n.lastfmFinishConnection
                  : labels.connect,
              subtitle: !service.configured
                  ? labels.unavailable
                  : service.awaitingAuthorization
                  ? l10n.lastfmAuthorizeHelp
                  : labels.description,
              onTap: service.busy || !service.configured || service.connected
                  ? null
                  : () => unawaited(
                      service.awaitingAuthorization
                          ? service.finishConnection()
                          : service.beginConnection(),
                    ),
              showDivider: service.awaitingAuthorization || rows.isNotEmpty,
            ),
            if (service.awaitingAuthorization)
              SettingsItem(
                icon: Icons.close,
                title: l10n.dialogCancel,
                onTap: service.cancelConnection,
                showDivider: rows.isNotEmpty,
              ),
            ...rows,
          ],
        );
      },
    );
  }
}
