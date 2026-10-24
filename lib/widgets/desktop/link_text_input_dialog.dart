import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_text_field.dart';

/// Asks for one line of text (a name, a link) in the app's dialog style.
/// Returns the trimmed text, or null when cancelled. The confirm action
/// stays disabled while the field is empty.
Future<String?> showLinkTextInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  String initialValue = '',
  String? hint,
  int? maxLength,
  TextInputType? keyboardType,
}) => showAppDialog<String>(
  context: context,
  builder: (context) => _LinkTextInputDialog(
    title: title,
    label: label,
    confirmLabel: confirmLabel,
    initialValue: initialValue,
    hint: hint,
    maxLength: maxLength,
    keyboardType: keyboardType,
  ),
);

class _LinkTextInputDialog extends StatefulWidget {
  const _LinkTextInputDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.initialValue,
    this.hint,
    this.maxLength,
    this.keyboardType,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String initialValue;
  final String? hint;
  final int? maxLength;
  final TextInputType? keyboardType;

  @override
  State<_LinkTextInputDialog> createState() => _LinkTextInputDialogState();
}

class _LinkTextInputDialogState extends State<_LinkTextInputDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: Text(widget.title),
    content: AppTextField(
      controller: _controller,
      label: widget.label,
      hint: widget.hint,
      maxLength: widget.maxLength,
      keyboardType: widget.keyboardType,
      autofocus: true,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      AppDialogAction(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        onPressed: _controller.text.trim().isEmpty ? null : _submit,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
