import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_api.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_service.dart';
import 'package:mornye/services/scrobbling/scrobbler.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:url_launcher/url_launcher.dart';

/// The words a scrobbling service's settings use. Last.fm keeps its own
/// translated strings; other services share strings that name them.
class ScrobbleSettingsLabels {
  const ScrobbleSettingsLabels({
    required this.connect,
    required this.connecting,
    required this.description,
    required this.scrobblingDescription,
    required this.nowPlayingDescription,
    required this.disconnect,
    required this.connectionError,
    required this.storageError,
    required this.reauthenticate,
    required this.unavailable,
    required this.rejected,
  });

  factory ScrobbleSettingsLabels.lastfm(AppLocalizations l10n) =>
      ScrobbleSettingsLabels(
        connect: l10n.lastfmConnect,
        connecting: l10n.lastfmConnecting,
        description: l10n.lastfmDescription,
        scrobblingDescription: l10n.lastfmScrobblingDescription,
        nowPlayingDescription: l10n.lastfmNowPlayingDescription,
        disconnect: l10n.lastfmDisconnect,
        connectionError: l10n.lastfmConnectionError,
        storageError: l10n.lastfmStorageError,
        reauthenticate: l10n.lastfmReauthenticate,
        unavailable: l10n.lastfmUnavailable,
        rejected: l10n.lastfmRejected,
      );

  factory ScrobbleSettingsLabels.named(AppLocalizations l10n, String name) =>
      ScrobbleSettingsLabels(
        connect: l10n.scrobbleServiceConnect(name),
        connecting: l10n.scrobbleServiceConnecting(name),
        description: l10n.scrobbleServiceDescription(name),
        scrobblingDescription: l10n.scrobbleServiceScrobblingDescription(name),
        nowPlayingDescription: l10n.scrobbleServiceNowPlayingDescription(name),
        disconnect: l10n.scrobbleServiceDisconnect(name),
        connectionError: l10n.scrobbleServiceConnectionError(name),
        storageError: l10n.scrobbleServiceStorageError(name),
        reauthenticate: l10n.scrobbleServiceReauthenticate(name),
        unavailable: l10n.scrobbleServiceUnavailable(name),
        rejected: l10n.scrobbleServiceRejected(name),
      );

  final String connect;
  final String connecting;
  final String description;
  final String scrobblingDescription;
  final String nowPlayingDescription;
  final String disconnect;
  final String connectionError;
  final String storageError;
  final String reauthenticate;
  final String unavailable;
  final String rejected;
}

/// The rows below a service's account row: its switches, waiting listens,
/// the latest problem and sign-out. The last row has no divider.
List<Widget> scrobbleAccountRows(
  BuildContext context,
  Scrobbler service,
  ScrobbleSettingsLabels labels,
) {
  final l10n = context.l10n;
  return [
    if (service.connected) ...[
      SettingsSwitchItem(
        icon: Icons.history_rounded,
        title: l10n.lastfmScrobbling,
        subtitle: labels.scrobblingDescription,
        value: service.enabled,
        onChanged: (enabled) => unawaited(service.setEnabled(enabled)),
      ),
      SettingsSwitchItem(
        icon: Icons.music_note_outlined,
        title: l10n.lastfmNowPlaying,
        subtitle: labels.nowPlayingDescription,
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
        showDivider: service.problem != null || service.connected,
      ),
    if (service.problem case final problem?)
      SettingsItem(
        icon: Icons.info_outline,
        title: switch (problem) {
          ScrobbleProblem.connection => labels.connectionError,
          ScrobbleProblem.storage => labels.storageError,
          ScrobbleProblem.pending => l10n.lastfmAuthorizationPending,
          ScrobbleProblem.expired => l10n.lastfmAuthorizationExpired,
          ScrobbleProblem.reauthenticate => labels.reauthenticate,
          ScrobbleProblem.unavailable => labels.unavailable,
          ScrobbleProblem.rejected => labels.rejected,
          ScrobbleProblem.invalidToken => l10n.listenBrainzInvalidToken,
          ScrobbleProblem.insecureServer => l10n.listenBrainzServerInsecure,
        },
        onTap: problem == ScrobbleProblem.storage
            ? () => unawaited(service.retry())
            : null,
        showDivider: service.connected,
      ),
    if (service.connected)
      SettingsItem(
        icon: Icons.link_off,
        title: labels.disconnect,
        onTap: () => unawaited(service.disconnect()),
        showDivider: false,
      ),
  ];
}

const _listenBrainzName = 'ListenBrainz';

/// ListenBrainz signs in with the user token pasted from its settings page,
/// optionally on a compatible self-hosted server.
class ListenBrainzSettings extends StatefulWidget {
  const ListenBrainzSettings({
    super.key,
    required this.service,
    this.openBrowser,
  });

  final ListenBrainzService service;
  final Future<bool> Function(Uri url)? openBrowser;

  @override
  State<ListenBrainzSettings> createState() => _ListenBrainzSettingsState();
}

class _ListenBrainzSettingsState extends State<ListenBrainzSettings> {
  String _server = '';

  @override
  void initState() {
    super.initState();
    unawaited(widget.service.initialize());
  }

  @override
  void didUpdateWidget(ListenBrainzSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      unawaited(widget.service.initialize());
    }
  }

  Future<void> _connect() async {
    final entry = await showAppScrollableBottomSheet<(String, String)>(
      context: context,
      title: context.l10n.scrobbleServiceConnect(_listenBrainzName),
      subtitle: context.l10n.listenBrainzConnectHelp,
      dialogSize: AppDialogSize.compact,
      builder: (sheetContext, scrollController) => _ListenBrainzConnectSheet(
        scrollController: scrollController,
        server: _server,
        openBrowser:
            widget.openBrowser ??
            (url) => launchUrl(url, mode: LaunchMode.externalApplication),
      ),
    );
    if (entry == null || !mounted) return;
    final (token, server) = entry;
    _server = server;
    await widget.service.connect(token, server: server);
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final l10n = context.l10n;
    final labels = ScrobbleSettingsLabels.named(l10n, _listenBrainzName);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final rows = scrobbleAccountRows(context, service, labels);
        final server = service.server;
        return SettingsGroup(
          children: [
            SettingsItem(
              icon: service.connected ? Icons.check_circle_outline : Icons.link,
              title: service.connected
                  ? service.username!
                  : service.busy
                  ? labels.connecting
                  : labels.connect,
              subtitle: server != null && server != listenBrainzDefaultServer
                  ? l10n.listenBrainzServerSubtitle(server)
                  : labels.description,
              onTap: service.busy || service.connected
                  ? null
                  : () => unawaited(_connect()),
              showDivider: rows.isNotEmpty,
            ),
            ...rows,
          ],
        );
      },
    );
  }
}

class _ListenBrainzConnectSheet extends StatefulWidget {
  const _ListenBrainzConnectSheet({
    required this.scrollController,
    required this.server,
    required this.openBrowser,
  });

  final ScrollController scrollController;
  final String server;
  final Future<bool> Function(Uri url) openBrowser;

  @override
  State<_ListenBrainzConnectSheet> createState() =>
      _ListenBrainzConnectSheetState();
}

class _ListenBrainzConnectSheetState extends State<_ListenBrainzConnectSheet> {
  final _token = TextEditingController();
  late final _server = TextEditingController(text: widget.server);
  String? _serverError;

  @override
  void dispose() {
    _token.dispose();
    _server.dispose();
    super.dispose();
  }

  void _submit() {
    final token = _token.text.trim();
    final server = _server.text.trim();
    if (token.isEmpty) return;
    final address = normalizeListenBrainzServer(server);
    final error = address == null
        ? context.l10n.listenBrainzServerInvalid
        : !listenBrainzServerSecure(address)
        ? context.l10n.listenBrainzServerInsecure
        : null;
    if (error != null) {
      setState(() => _serverError = error);
      return;
    }
    Navigator.pop(context, (token, server));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _token.text = text;
    _token.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final mornye = context.isMornye;
    final paste = IconButton(
      tooltip: l10n.actionPaste,
      icon: const AppIcon(Icons.content_paste_outlined),
      onPressed: _paste,
    );
    final fieldDecoration = BoxDecoration(
      color: mornye ? MornyeTheme.controlFill(context) : null,
      borderRadius: BorderRadius.circular(12),
    );
    // The token keeps a dedicated secret field, as other credentials do.
    final token = mornye
        ? CupertinoTextField(
            controller: _token,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            placeholder: l10n.listenBrainzToken,
            padding: const EdgeInsets.all(12),
            decoration: fieldDecoration,
            style: theme.textTheme.bodyLarge,
            suffix: paste,
            textInputAction: TextInputAction.next,
          )
        : TextField(
            controller: _token,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              labelText: l10n.listenBrainzToken,
              suffixIcon: paste,
            ),
            textInputAction: TextInputAction.next,
          );
    final server = mornye
        ? CupertinoTextField(
            controller: _server,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            placeholder: l10n.listenBrainzServer,
            padding: const EdgeInsets.all(12),
            decoration: fieldDecoration,
            style: theme.textTheme.bodyLarge,
            onSubmitted: (_) => _submit(),
          )
        : AppTextField(
            controller: _server,
            label: l10n.listenBrainzServer,
            hint: listenBrainzDefaultServer,
            errorText: _serverError,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            onSubmitted: (_) => _submit(),
          );
    final note = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          token,
          const SizedBox(height: 12),
          server,
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, top: 6),
            child: Text(
              // Material fields show the error themselves.
              _serverError != null && mornye
                  ? _serverError!
                  : l10n.listenBrainzServerHelp,
              style: _serverError != null && mornye
                  ? note?.copyWith(color: theme.colorScheme.error)
                  : note,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              AppDialogAction(
                onPressed: () => unawaited(
                  widget.openBrowser(
                    Uri.https('listenbrainz.org', '/settings/'),
                  ),
                ),
                child: Text(l10n.listenBrainzOpenSettings),
              ),
              AppDialogAction(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.dialogCancel),
              ),
              ListenableBuilder(
                listenable: _token,
                builder: (context, _) => AppDialogAction(
                  filled: true,
                  onPressed: _token.text.trim().isEmpty ? null : _submit,
                  child: Text(l10n.scrobbleServiceConnect(_listenBrainzName)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
