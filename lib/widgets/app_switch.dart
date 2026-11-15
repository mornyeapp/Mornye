import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoColors;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';

/// One switch style for settings, extension controls and editing sheets.
/// Mornye keeps its wide oval thumb even when glass or motion is disabled.
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.adaptive = false,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool adaptive;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (materialExpressiveEnabled(context)) {
      return MaterialExpressiveScope(
        child: M3ESwitch(
          value: value,
          onChanged: onChanged,
          selectedIcon: const AppIcon(Icons.check),
          semanticLabel: semanticLabel,
        ),
      );
    }
    if (!context.isMornye) {
      return adaptive
          ? Switch.adaptive(value: value, onChanged: onChanged)
          : Switch(value: value, onChanged: onChanged);
    }

    return _MornyeSwitch(
      value: value,
      onChanged: onChanged,
      semanticLabel: semanticLabel,
    );
  }
}

class _MornyeSwitch extends StatefulWidget {
  const _MornyeSwitch({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  State<_MornyeSwitch> createState() => _MornyeSwitchState();
}

class _MornyeSwitchState extends State<_MornyeSwitch> {
  double? _dragPosition;
  bool _dragCancelled = false;

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final onChanged = widget.onChanged;
    final scheme = Theme.of(context).colorScheme;
    final active = CupertinoColors.systemGreen.resolveFrom(context);
    final enabled = onChanged != null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final inactive = scheme.brightness == Brightness.dark
        ? const Color(0xff39393d)
        : const Color(0xff8e8e93);

    final position = _dragPosition ?? (value ? 1.0 : 0.0);
    final control = AnimatedContainer(
      duration: duration,
      width: 63,
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: position >= 0.5 ? active : inactive,
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedAlign(
        duration: _dragPosition == null ? duration : Duration.zero,
        curve: Curves.easeOutCubic,
        alignment: AlignmentDirectional(-1 + position * 2, 0),
        child: Container(
          width: 37,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );

    return Listener(
      onPointerDown: (_) => _dragCancelled = false,
      onPointerCancel: (_) => _dragCancelled = true,
      child: Semantics(
        label: widget.semanticLabel,
        toggled: value,
        enabled: enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled ? () => onChanged(!value) : null,
              borderRadius: BorderRadius.circular(22),
              // InkWell supplies keyboard and accessible activation. The
              // thumb uses only paint/layout, even on a page of switches.
              child: ExcludeSemantics(
                child: GestureDetector(
                  onHorizontalDragStart: enabled
                      ? (_) => setState(() => _dragPosition = value ? 1 : 0)
                      : null,
                  onHorizontalDragUpdate: enabled
                      ? (event) {
                          final direction =
                              Directionality.of(context) == TextDirection.rtl
                              ? -1.0
                              : 1.0;
                          setState(
                            () => _dragPosition =
                                ((_dragPosition ?? (value ? 1 : 0)) +
                                        event.delta.dx * direction / 22)
                                    .clamp(0, 1),
                          );
                        }
                      : null,
                  onHorizontalDragEnd: enabled
                      ? (_) {
                          final next =
                              (_dragPosition ?? (value ? 1 : 0)) >= 0.5;
                          setState(() => _dragPosition = null);
                          if (!_dragCancelled && next != value) onChanged(next);
                        }
                      : null,
                  onHorizontalDragCancel: enabled
                      ? () => setState(() => _dragPosition = null)
                      : null,
                  child: SizedBox(
                    width: 71,
                    height: 44,
                    child: Center(child: control),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppSwitchListTile extends StatelessWidget {
  const AppSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    this.adaptive = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool adaptive;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye && !materialExpressiveEnabled(context)) {
      return adaptive
          ? SwitchListTile.adaptive(
              value: value,
              onChanged: onChanged,
              title: title,
              subtitle: subtitle,
              contentPadding: contentPadding,
            )
          : SwitchListTile(
              value: value,
              onChanged: onChanged,
              title: title,
              subtitle: subtitle,
              contentPadding: contentPadding,
            );
    }
    return MergeSemantics(
      child: ListTile(
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: AppSwitch(value: value, onChanged: onChanged),
      ),
    );
  }
}
