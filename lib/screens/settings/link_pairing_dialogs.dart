import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_text_field.dart';

/// The message for a pairing failure.
String linkPairingErrorMessage(AppLocalizations l10n, LinkPairingError error) =>
    switch (error) {
      LinkPairingError.badPin => l10n.linkErrorBadPin,
      LinkPairingError.pairingClosed => l10n.linkErrorPairingClosed,
      LinkPairingError.tooManyAttempts => l10n.linkErrorTooManyAttempts,
      LinkPairingError.certificateMismatch => l10n.linkErrorCertificate,
      LinkPairingError.incompatible => l10n.linkErrorIncompatible,
      LinkPairingError.invalidAddress => l10n.linkErrorInvalidAddress,
      LinkPairingError.localNetworkPermission =>
        l10n.networkErrorLocalPermission,
      LinkPairingError.unreachable => l10n.linkErrorUnreachable,
      LinkPairingError.timeout => l10n.linkErrorTimeout,
      LinkPairingError.failed => l10n.linkErrorFailed,
    };

/// Host and port from what someone typed: `192.168.1.20`, `host:47710`,
/// `https://[fe80::2]:47710/` and the like. [portInput] is used when the
/// address carries no port. Null when either part is unusable.
({String host, int port})? linkParseManualAddress(
  String hostInput,
  String portInput,
) {
  var text = hostInput.trim().replaceFirst(
    RegExp(r'^[a-z]+://', caseSensitive: false),
    '',
  );
  final slash = text.indexOf('/');
  if (slash >= 0) text = text.substring(0, slash);
  String host;
  String? port;
  final bracketed = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(text);
  if (bracketed != null) {
    host = bracketed[1]!;
    port = bracketed[2];
  } else if (RegExp(r'^[^:]+:\d+$').hasMatch(text)) {
    final colon = text.lastIndexOf(':');
    host = text.substring(0, colon);
    port = text.substring(colon + 1);
  } else {
    host = text;
  }
  host = host.trim();
  final parsedPort = int.tryParse((port ?? portInput).trim());
  if (host.isEmpty ||
      parsedPort == null ||
      parsedPort < 1 ||
      parsedPort > 65535 ||
      host.contains(RegExp(r'[\s@/?#]')) ||
      (host.contains(':') && InternetAddress.tryParse(host) == null)) {
    return null;
  }
  return (host: host, port: parsedPort);
}

/// Asks for the desktop's PIN and pairs. [onSubmit] answers null on success,
/// which pops `true`, or the error to show while the dialog stays open.
class LinkPinDialog extends StatefulWidget {
  const LinkPinDialog({
    super.key,
    required this.serverName,
    required this.shortFingerprint,
    required this.pairingOpen,
    required this.onSubmit,
  });

  static const fieldKey = ValueKey('link-pin-field');

  final String serverName;

  /// The fingerprint's first 8 hex characters, shown on the desktop too.
  final String shortFingerprint;

  /// Whether the desktop reported an open pairing window.
  final bool pairingOpen;
  final Future<LinkPairingError?> Function(String pin) onSubmit;

  @override
  State<LinkPinDialog> createState() => _LinkPinDialogState();
}

class _LinkPinDialogState extends State<LinkPinDialog> {
  final _pin = TextEditingController();
  var _busy = false;
  LinkPairingError? _error;

  bool get _complete => RegExp(r'^\d{6}$').hasMatch(_pin.text);

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_complete || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onSubmit(_pin.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
      if (error == LinkPairingError.badPin) _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final formatters = [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(6),
    ];
    final pinStyle = theme.textTheme.headlineSmall?.copyWith(
      letterSpacing: 8,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final field = context.isMornye
        ? CupertinoTextField(
            key: LinkPinDialog.fieldKey,
            controller: _pin,
            enabled: !_busy,
            autofocus: true,
            placeholder: l10n.linkPinField,
            keyboardType: TextInputType.number,
            inputFormatters: formatters,
            autofillHints: const [AutofillHints.oneTimeCode],
            textAlign: TextAlign.center,
            style: pinStyle,
            padding: const EdgeInsets.all(12),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          )
        : Semantics(
            label: l10n.linkPinField,
            child: TextField(
              key: LinkPinDialog.fieldKey,
              controller: _pin,
              enabled: !_busy,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: formatters,
              autofillHints: const [AutofillHints.oneTimeCode],
              textAlign: TextAlign.center,
              style: pinStyle,
              decoration: InputDecoration(
                labelText: l10n.linkPinField,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          );
    final note = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AppAlertDialog(
      title: Text(l10n.linkPinTitle(widget.serverName)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.linkPinMessage),
          const SizedBox(height: 16),
          field,
          const SizedBox(height: 12),
          Text(l10n.linkPinCode(widget.shortFingerprint), style: note),
          if (!widget.pairingOpen) ...[
            const SizedBox(height: 8),
            Text(l10n.linkPinNotOpen, style: note),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Text(
              linkPairingErrorMessage(l10n, error),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            const AppProgressIndicator.linear(),
          ],
        ],
      ),
      actions: [
        AppDialogAction(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          onPressed: _busy || !_complete ? null : _submit,
          child: Text(l10n.linkPair),
        ),
      ],
    );
  }
}

/// Asks for a desktop's address and port, for networks without mDNS and
/// emulators. Pops the parsed address, or null when cancelled.
class LinkManualAddDialog extends StatefulWidget {
  const LinkManualAddDialog({super.key});

  static const hostKey = ValueKey('link-manual-host');
  static const portKey = ValueKey('link-manual-port');

  @override
  State<LinkManualAddDialog> createState() => _LinkManualAddDialogState();
}

class _LinkManualAddDialogState extends State<LinkManualAddDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '$linkPortFirst');
  var _invalid = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    final address = linkParseManualAddress(_host.text, _port.text);
    if (address == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(address);
  }

  Widget _field(
    Key key,
    TextEditingController controller,
    String label, {
    required TextInputType keyboardType,
    String? hint,
    bool last = false,
  }) {
    if (context.isMornye) {
      return CupertinoTextField(
        key: key,
        controller: controller,
        placeholder: hint ?? label,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        padding: const EdgeInsets.all(12),
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onSubmitted: last ? (_) => _submit() : null,
      );
    }
    return AppTextField(
      key: key,
      controller: controller,
      label: label,
      hint: hint,
      keyboardType: keyboardType,
      autocorrect: false,
      outlined: true,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onSubmitted: last ? (_) => _submit() : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AppAlertDialog(
      title: Text(l10n.linkAddManually),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.linkManualMessage),
          const SizedBox(height: 16),
          _field(
            LinkManualAddDialog.hostKey,
            _host,
            l10n.linkManualHost,
            hint: '192.168.1.20',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          _field(
            LinkManualAddDialog.portKey,
            _port,
            l10n.linkManualPort,
            keyboardType: TextInputType.number,
            last: true,
          ),
          if (_invalid) ...[
            const SizedBox(height: 12),
            Text(
              l10n.linkErrorInvalidAddress,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        AppDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          onPressed: _submit,
          child: Text(l10n.linkContinue),
        ),
      ],
    );
  }
}

/// Confirms forgetting [name]. Pops whether its music should leave Library
/// too, or null when cancelled.
class LinkForgetDialog extends StatefulWidget {
  const LinkForgetDialog({super.key, required this.name});

  final String name;

  @override
  State<LinkForgetDialog> createState() => _LinkForgetDialogState();
}

class _LinkForgetDialogState extends State<LinkForgetDialog> {
  var _removeLibrary = true;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = Theme.of(context).colorScheme.error;
    return AppAlertDialog(
      title: Text(l10n.linkForgetTitle(widget.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.linkForgetMessage),
          const SizedBox(height: 12),
          MergeSemantics(
            child: Row(
              children: [
                Expanded(child: Text(l10n.linkForgetRemoveLibrary)),
                const SizedBox(width: 12),
                AppSwitch(
                  value: _removeLibrary,
                  semanticLabel: l10n.linkForgetRemoveLibrary,
                  onChanged: (value) => setState(() => _removeLibrary = value),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        AppDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        AppDialogAction(
          isDestructive: true,
          style: TextButton.styleFrom(foregroundColor: error),
          onPressed: () => Navigator.of(context).pop(_removeLibrary),
          child: Text(l10n.linkForget),
        ),
      ],
    );
  }
}
