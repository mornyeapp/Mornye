import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

/// Account input goes straight to the action, never into extension settings.
Future<Map<String, dynamic>?> runExtensionActionWithForms(
  BuildContext context,
  String extensionId,
  String action,
) async {
  Map<String, dynamic>? input;
  for (var step = 0; step < 8; step++) {
    Map<String, dynamic> result;
    try {
      result = await PlatformBridge.invokeExtensionAction(
        extensionId,
        action,
        input: input,
      );
    } finally {
      input?.updateAll((_, value) => value is String ? '' : null);
      input = null;
    }
    if (!context.mounted) return null;
    final nested = result['result'];
    final payload = nested is Map ? nested : result;
    // Accept the supplied protocol while exposing a provider-neutral form API.
    final raw = payload['action_form'] ?? payload['byoa_form'];
    if (payload['success'] != true || raw == null) return result;
    final form = _AccountForm.parse(raw);
    if (form == null) {
      return {
        'success': false,
        'error': context.l10n.extensionAccountInvalidForm,
      };
    }
    input = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AccountFormDialog(form: form),
    );
    if (input == null) {
      if (form.cancelAction != null) {
        await PlatformBridge.invokeExtensionAction(
          extensionId,
          form.cancelAction!,
        );
      }
      return null;
    }
    action = form.submitAction;
  }
  input?.updateAll((_, value) => value is String ? '' : null);
  if (!context.mounted) return null;
  return {'success': false, 'error': context.l10n.extensionAccountRestartLogin};
}

class _AccountForm {
  const _AccountForm(
    this.submitAction,
    this.cancelAction,
    this.title,
    this.description,
    this.fields,
  );
  final String submitAction;
  final String? cancelAction;
  final String? title;
  final String? description;
  final List<Map<String, dynamic>> fields;
  static final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');
  static bool _action(dynamic value) =>
      value is String && _identifier.hasMatch(value);
  static bool _text(dynamic value, int max) =>
      value == null || (value is String && value.length <= max);

  static _AccountForm? parse(dynamic raw) {
    final cancelAction = raw is Map ? raw['cancel_action'] : null;
    if (raw is! Map ||
        raw['version'] != 1 ||
        !_action(raw['submit_action']) ||
        (cancelAction != null &&
            cancelAction != '' &&
            !_action(cancelAction)) ||
        !_text(raw['title'], 256) ||
        !_text(raw['description'], 4096)) {
      return null;
    }
    final fields = raw['fields'];
    if (fields is! List || fields.isEmpty || fields.length > 12) return null;
    final validated = <Map<String, dynamic>>[];
    final keys = <String>{};
    for (final item in fields) {
      if (item is! Map || item.keys.any((key) => key is! String)) return null;
      final key = item['key'];
      if (!_action(key) ||
          !keys.add(key as String) ||
          !_text(item['label'], 256) ||
          !const {
            'string',
            'password',
            'otp',
            'number',
            'select',
          }.contains(item['type'])) {
        return null;
      }
      if (item['type'] == 'select') {
        final options = item['options'];
        if (options is! List ||
            options.isEmpty ||
            options.length > 30 ||
            options.any(
              (option) =>
                  option is! String || option.isEmpty || option.length > 256,
            ) ||
            options.toSet().length != options.length ||
            (item['default'] != null && !options.contains(item['default']))) {
          return null;
        }
      }
      validated.add(Map<String, dynamic>.from(item));
    }
    return _AccountForm(
      raw['submit_action'] as String,
      cancelAction == '' ? null : cancelAction as String?,
      raw['title'] as String?,
      raw['description'] as String?,
      validated,
    );
  }
}

class _AccountFormDialog extends StatefulWidget {
  const _AccountFormDialog({required this.form});
  final _AccountForm form;
  @override
  State<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends State<_AccountFormDialog> {
  final _controllers = <String, TextEditingController>{};
  final _choices = <String, String>{};
  final _formKey = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    for (final field in widget.form.fields) {
      final key = field['key'] as String;
      if (field['type'] == 'select') {
        _choices[key] =
            field['default'] as String? ??
            (field['options'] as List).first as String;
      } else {
        _controllers[key] = TextEditingController();
      }
    }
  }

  void _clear() {
    for (final controller in _controllers.values) {
      controller.clear();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    final values = <String, dynamic>{..._choices};
    for (final field in widget.form.fields) {
      final key = field['key'] as String;
      final controller = _controllers[key];
      if (controller != null) {
        values[key] = field['type'] == 'number' && controller.text.isNotEmpty
            ? num.parse(controller.text)
            : controller.text;
      }
    }
    _clear();
    Navigator.pop(context, values);
  }

  String? _validate(Map<String, dynamic> field, String? value) {
    if (field['required'] == true && (value == null || value.isEmpty)) {
      return context.l10n.extensionAccountRequiredValue;
    }
    if (field['type'] == 'number' &&
        value != null &&
        value.isNotEmpty &&
        num.tryParse(value)?.isFinite != true) {
      return context.l10n.extensionAccountInvalidNumber;
    }
    return null;
  }

  Future<void> _chooseOption(Map<String, dynamic> field) async {
    FocusScope.of(context).unfocus();
    final key = field['key'] as String;
    final value = await showAppBottomSheet<String>(
      context: context,
      title: field['label'] as String? ?? key,
      maxHeightFactor: 0.7,
      builder: (sheetContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in (field['options'] as List).cast<String>())
              AppSheetOption.choice(
                title: Text(option),
                selected: option == _choices[key],
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        ),
      ),
    );
    if (mounted && value != null) setState(() => _choices[key] = value);
  }

  Widget _field(Map<String, dynamic> field, int index) {
    final key = field['key'] as String;
    final label = field['label'] as String? ?? key;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mornye = context.isMornye;
    final last = index == widget.form.fields.length - 1;
    final secret = field['type'] == 'password' || field['secret'] == true;
    final keyboard = field['type'] == 'number'
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : TextInputType.text;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    );
    final themedBorder = theme.inputDecorationTheme.enabledBorder;
    final materialRadius = themedBorder is OutlineInputBorder
        ? themedBorder.borderRadius
        : border.borderRadius;
    final decoration = InputDecoration(
      labelText: label,
      filled: true,
      fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.5),
      border: border,
      counterText: '',
    );
    Widget input;
    if (field['type'] == 'select') {
      input = mornye
          ? CupertinoButton(
              onPressed: () => _chooseOption(field),
              color: MornyeTheme.controlFill(context),
              borderRadius: BorderRadius.circular(12),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _choices[key]!,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_up_chevron_down,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            )
          : Material(
              color: Colors.transparent,
              child: Ink(
                decoration: BoxDecoration(
                  color: decoration.fillColor,
                  borderRadius: materialRadius,
                ),
                child: InkWell(
                  borderRadius: materialRadius,
                  onTap: () => _chooseOption(field),
                  child: InputDecorator(
                    decoration: decoration.copyWith(
                      fillColor: Colors.transparent,
                      suffixIcon: Icon(
                        Icons.expand_more,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    child: Text(
                      _choices[key]!,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ),
              ),
            );
    } else if (mornye) {
      input = FormField<String>(
        validator: (value) => _validate(field, value),
        builder: (state) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CupertinoTextField(
              controller: _controllers[key],
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MornyeTheme.controlFill(context),
                borderRadius: BorderRadius.circular(12),
              ),
              style: theme.textTheme.bodyLarge,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              maxLength: 4096,
              keyboardType: keyboard,
              textInputAction: last
                  ? TextInputAction.done
                  : TextInputAction.next,
              onChanged: state.didChange,
              onSubmitted: (_) =>
                  last ? _submit() : FocusScope.of(context).nextFocus(),
            ),
            if (state.errorText != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 4, top: 6),
                child: Text(
                  state.errorText!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ),
          ],
        ),
      );
    } else {
      input = TextFormField(
        controller: _controllers[key],
        obscureText: secret,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        maxLength: 4096,
        keyboardType: keyboard,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onFieldSubmitted: (_) =>
            last ? _submit() : FocusScope.of(context).nextFocus(),
        decoration: decoration,
        validator: (value) => _validate(field, value),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mornye) ...[
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
          Semantics(
            label: label,
            button: field['type'] == 'select' ? true : null,
            child: input,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: Text(widget.form.title ?? context.l10n.extensionAccountTitle),
    content: SingleChildScrollView(
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.form.description?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.form.description!),
              ),
            for (var i = 0; i < widget.form.fields.length; i++)
              _field(widget.form.fields[i], i),
          ],
        ),
      ),
    ),
    actions: [
      AppDialogAction(
        onPressed: () {
          _clear();
          Navigator.pop(context);
        },
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        isDefault: true,
        onPressed: _submit,
        child: Text(context.l10n.upgradeIntroContinue),
      ),
    ],
  );
}
