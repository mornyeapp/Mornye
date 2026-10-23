import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';

/// Text input for Material dialogs, sheets and settings. Expressive builds use
/// the M3E text field; Mornye and reduced motion keep the plain field with
/// [decoration], so their existing look is unchanged.
///
/// Inputs that disable autocorrect stay on plain fields because the M3E field
/// cannot honor that option. Credentials also keep their dedicated fields.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.leading,
    this.errorText,
    this.decoration,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.maxLines = 1,
    this.maxLength,
    this.autofocus = false,
    this.outlined = false,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.scrollPadding = const EdgeInsets.all(20),
    this.autocorrect = true,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final Widget? leading;
  final String? errorText;

  /// Plain-field decoration. Defaults to [label], [hint], [leading] and
  /// [errorText] on the theme's input decoration.
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? maxLength;
  final bool autofocus;

  /// Outlined rather than filled container in the expressive style.
  final bool outlined;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Validates inside an enclosing [Form], like [TextFormField].
  final FormFieldValidator<String>? validator;

  /// Keyboard reveal margin of the plain field.
  final EdgeInsets scrollPadding;

  /// False keeps the plain field so keyboard correction stays disabled.
  final bool autocorrect;

  @override
  Widget build(BuildContext context) {
    if (!materialExpressiveEnabled(context) || !autocorrect) {
      return _plainField();
    }
    if (validator != null) return _ExpressiveTextFormField(field: this);
    return _expressiveField();
  }

  Widget _expressiveField({
    TextEditingController? fieldController,
    String? formError,
    ValueChanged<String>? onChanged,
  }) => MaterialExpressiveScope(
    child: M3ETextField(
      // The dependency retains its initial controller for its lifetime.
      key: ObjectKey(fieldController ?? controller),
      controller: fieldController ?? controller,
      label: label,
      placeholder: hint,
      leading: leading,
      errorText: formError ?? errorText,
      variant: outlined
          ? M3ETextFieldVariant.outlined
          : M3ETextFieldVariant.filled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      maxLength: maxLength,
      autofocus: autofocus,
      onChanged: onChanged ?? this.onChanged,
      onSubmitted: onSubmitted,
    ),
  );

  Widget _plainField() {
    final decoration =
        this.decoration ??
        InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: leading,
          errorText: errorText,
        );
    if (validator != null) {
      return TextFormField(
        controller: controller,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        inputFormatters: inputFormatters,
        maxLines: maxLines,
        maxLength: maxLength,
        autofocus: autofocus,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        validator: validator,
        scrollPadding: scrollPadding,
        autocorrect: autocorrect,
      );
    }
    return TextField(
      controller: controller,
      decoration: decoration,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      maxLength: maxLength,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      scrollPadding: scrollPadding,
      autocorrect: autocorrect,
    );
  }
}

class _ExpressiveTextFormField extends FormField<String> {
  _ExpressiveTextFormField({required this.field})
    : super(
        initialValue: field.controller?.text ?? '',
        validator: field.validator,
        builder: (state) => field._expressiveField(
          fieldController: (state as _ExpressiveTextFormFieldState)._controller,
          formError: state.errorText,
          onChanged: (value) {
            state.didChange(value);
            field.onChanged?.call(value);
          },
        ),
      );

  final AppTextField field;

  @override
  FormFieldState<String> createState() => _ExpressiveTextFormFieldState();
}

class _ExpressiveTextFormFieldState extends FormFieldState<String> {
  late TextEditingController _controller;

  @override
  _ExpressiveTextFormField get widget =>
      super.widget as _ExpressiveTextFormField;

  @override
  void initState() {
    super.initState();
    _controller = widget.field.controller ?? TextEditingController(text: value);
  }

  @override
  void didUpdateWidget(_ExpressiveTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.field.controller != widget.field.controller) {
      final previous = _controller;
      _controller =
          widget.field.controller ??
          TextEditingController.fromValue(previous.value);
      if (oldWidget.field.controller == null) previous.dispose();
      setValue(_controller.text);
    }
  }

  @override
  void reset() {
    _controller.text = widget.initialValue ?? '';
    super.reset();
  }

  @override
  void dispose() {
    if (widget.field.controller == null) _controller.dispose();
    super.dispose();
  }
}
