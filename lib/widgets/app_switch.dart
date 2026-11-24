import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoColors;
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassBackdropGroup;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';

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
      return Switch(value: value, onChanged: onChanged);
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

class _MornyeSwitchState extends State<_MornyeSwitch>
    with TickerProviderStateMixin {
  /// How far the thumb travels, from off to on.
  static const double _travel = 22;

  /// The held lens at iOS 27's size: 58 x 38.33 around the 37 x 24 thumb.
  static const double _heldWidthGrowth = 21;
  static const double _heldHeightGrowth = 43 / 3;

  /// The iOS 27 switch lens bends more than the selection lens.
  static const double _heldRefractiveIndex = 1.38;

  double? _dragPosition;
  bool _dragCancelled = false;

  /// The thumb, from off (0) to on (1). A drag places it under the finger;
  /// otherwise the snappy spring carries it to rest, starting from the
  /// finger's velocity on release and from its own velocity when a new
  /// value interrupts it.
  late final AnimationController _thumb = AnimationController.unbounded(
    vsync: this,
    value: widget.value ? 1 : 0,
  );

  /// The side the thumb is moving to, or null after a drag placed it.
  late double? _thumbTarget = _thumb.value;

  /// The finger's velocity, in thumb travels a second, for the next move.
  double? _releaseVelocity;

  /// How far a held thumb has turned to glass.
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );
  late final Listenable _thumbChanges = Listenable.merge([_thumb, _press]);

  @override
  void didUpdateWidget(_MornyeSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null && _press.value != 0) _press.value = 0;
  }

  @override
  void dispose() {
    _thumb.dispose();
    _press.dispose();
    super.dispose();
  }

  /// The lens lifts within about 120 ms and settles more slowly, as on iOS 27.
  void _hold(bool held) {
    if (!held && _press.value == 0 && !_press.isAnimating) return;
    _press.animateWith(
      SpringSimulation(
        held ? MornyeMotion.effectsFastSpring : MornyeMotion.fastSpring,
        _press.value,
        held ? 1 : 0,
        _press.velocity,
        snapToEnd: true,
      ),
    );
  }

  /// Sends the thumb to the current value's side unless a drag holds it.
  /// Runs during build, after the parent has applied a new value, so a
  /// released thumb never heads for the old side first.
  void _followValue() {
    if (_dragPosition != null) return;
    final target = widget.value ? 1.0 : 0.0;
    final velocity = _releaseVelocity;
    _releaseVelocity = null;
    if (MediaQuery.disableAnimationsOf(context)) {
      _thumbTarget = target;
      if (_thumb.value != target) _thumb.value = target;
      return;
    }
    if (target == _thumbTarget && velocity == null) return;
    _thumbTarget = target;
    _thumb.animateWith(
      SpringSimulation(
        MornyeMotion.snappySpring,
        _thumb.value,
        target,
        velocity ?? _thumb.velocity,
        snapToEnd: true,
      ),
    );
  }

  void _place(double position) {
    _dragPosition = position;
    _thumbTarget = null;
    _thumb.value = position;
  }

  @override
  Widget build(BuildContext context) {
    // Only a device that draws shader lenses reads the glass settings.
    final lensPossible =
        MornyeGlass.shaderFiltersSupported &&
        !MediaQuery.disableAnimationsOf(context);
    if (!lensPossible) return _build(context, lens: false);
    return Consumer(
      builder: (context, ref, _) => _build(
        context,
        // Where MornyeGlass would draw a lens: liquid level, clarity above
        // its lens threshold, no contrast request.
        lens:
            widget.onChanged != null &&
            ref.watch(mornyeLiquidGlassProvider) &&
            ref.watch(mornyeBlurEnabledProvider) &&
            MornyeTheme.glassClarityOf(context) > 0.2 &&
            !ref.watch(
              mornyeGlassContrastBlockedProvider(
                MediaQuery.highContrastOf(context),
              ),
            ),
      ),
    );
  }

  /// The thumb as a clear lens, grown around its resting center.
  Widget _heldThumb(double held) {
    final height = 24 + _heldHeightGrowth * held;
    final radius = BorderRadius.circular(height / 2);
    return SizedBox(
      width: 37,
      height: 24,
      child: OverflowBox(
        minWidth: 37 + _heldWidthGrowth * held,
        maxWidth: 37 + _heldWidthGrowth * held,
        minHeight: height,
        maxHeight: height,
        // A held lens lies over the track and reads it, even inside a group.
        child: GlassBackdropGroup(
          enabled: false,
          child: MornyeLiquidBackdrop(
            borderRadius: radius,
            interaction: true,
            progress: held,
            refractiveIndex: 1 + (_heldRefractiveIndex - 1) * held,
            pinch: 1 - (1 - held) * (1 - held),
            // The white thumb fills the growing lens and fades as it lifts.
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(
                  alpha: (1 - held * 1.4).clamp(0.0, 1.0),
                ),
                borderRadius: radius,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _build(BuildContext context, {required bool lens}) {
    final value = widget.value;
    final onChanged = widget.onChanged;
    final scheme = Theme.of(context).colorScheme;
    final active = CupertinoColors.systemGreen.resolveFrom(context);
    final enabled = onChanged != null;
    final fade = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : MornyeMotion.effectsFast.duration;
    final inactive = scheme.brightness == Brightness.dark
        ? const Color(0xff39393d)
        : const Color(0xff8e8e93);
    _followValue();

    final position = _dragPosition ?? (value ? 1.0 : 0.0);
    final control = AnimatedContainer(
      duration: fade,
      curve: MornyeMotion.effectsFast.curve,
      width: 63,
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: position >= 0.5 ? active : inactive,
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedBuilder(
        animation: _thumbChanges,
        // The thumb stays inside the track when the spring runs past a side.
        builder: (context, child) {
          final held = lens ? _press.value.clamp(0.0, 1.0) : 0.0;
          return Align(
            alignment: AlignmentDirectional(
              -1 + _thumb.value.clamp(0.0, 1.0) * 2,
              0,
            ),
            child: held > 0 ? _heldThumb(held) : child,
          );
        },
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
      onPointerUp: (_) => _hold(false),
      onPointerCancel: (_) {
        _dragCancelled = true;
        _hold(false);
      },
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
                  // The thumb turns to glass as the finger lands, and back
                  // when a scroll or a tap takes the pointer.
                  onHorizontalDragDown: enabled && lens
                      ? (_) => _hold(true)
                      : null,
                  // A drag picks the thumb up where it is, also mid-move.
                  onHorizontalDragStart: enabled
                      ? (_) =>
                            setState(() => _place(_thumb.value.clamp(0.0, 1.0)))
                      : null,
                  onHorizontalDragUpdate: enabled
                      ? (event) {
                          final direction =
                              Directionality.of(context) == TextDirection.rtl
                              ? -1.0
                              : 1.0;
                          setState(
                            () => _place(
                              ((_dragPosition ?? (value ? 1 : 0)) +
                                      event.delta.dx * direction / _travel)
                                  .clamp(0.0, 1.0),
                            ),
                          );
                        }
                      : null,
                  onHorizontalDragEnd: enabled
                      ? (details) {
                          final next =
                              (_dragPosition ?? (value ? 1 : 0)) >= 0.5;
                          final direction =
                              Directionality.of(context) == TextDirection.rtl
                              ? -1.0
                              : 1.0;
                          setState(() {
                            _dragPosition = null;
                            // The thumb leaves the finger at its speed.
                            _releaseVelocity =
                                (details.primaryVelocity ?? 0) *
                                direction /
                                _travel;
                          });
                          _hold(false);
                          if (!_dragCancelled && next != value) onChanged(next);
                        }
                      : null,
                  onHorizontalDragCancel: enabled
                      ? () {
                          setState(() => _dragPosition = null);
                          _hold(false);
                        }
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
      return SwitchListTile(
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
