part of 'equalizer_screen.dart';

/// iOS section footer: secondary text under the group it explains.
class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = settingsHorizontalInset(context, constraints.maxWidth) + 16;
      final theme = Theme.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(inset, 4, inset, 8),
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    },
  );
}

/// iOS "value" cell detail: the current choice in secondary text before the
/// disclosure chevron.
class _DetailValue extends StatelessWidget {
  const _DetailValue(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(color: secondary),
          ),
        ),
        const SizedBox(width: 6),
        AppIcon(Icons.chevron_right, size: 20, color: secondary),
      ],
    );
  }
}

/// iOS action cell: tinted text that runs a command instead of navigating.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.last = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool destructive, last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final color = onTap == null
        ? theme.disabledColor
        : destructive
        ? colors.error
        : colors.primary;
    return Semantics(
      button: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            highlightColor: colors.onSurface.withValues(alpha: 0.06),
            splashFactory: NoSplash.splashFactory,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.rowPaddingH,
                  vertical: tokens.rowPaddingV,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(color: color),
                  ),
                ),
              ),
            ),
          ),
          if (!last)
            Divider(
              height: 1,
              indent: tokens.rowPaddingH,
              endIndent: tokens.rowPaddingH,
              color: colors.outlineVariant,
            ),
        ],
      ),
    );
  }
}

/// Status, master switch and the estimated response of the whole chain.
class _EqualizerOverview extends ConsumerWidget {
  const _EqualizerOverview({this.onEnabledChanged});

  /// Shows the master switch beside the title; Mornye keeps it in its own
  /// row above.
  final ValueChanged<bool>? onEnabledChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(
      equalizerProvider.select((state) => state.settings),
    );
    final presetName =
        ref.watch(_selectedEqualizerPresetProvider)?.name ??
        context.l10n.equalizerCustom;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final enabled = settings.enabled;
    final curveColor = enabled ? colors.primary : colors.outline;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.rowPaddingH,
        tokens.gapLg,
        tokens.gapLg,
        tokens.gapLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: tokens.motionMedium,
                      style: theme.textTheme.headlineSmall!.copyWith(
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                      ),
                      child: Text(
                        presetName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(height: tokens.gapXs),
                    Row(
                      children: [
                        const BetaBadge(),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${settings.gains.length} ${l10n.equalizerBands.toLowerCase()} · ${l10n.equalizerPreamp} ${_signed(settings.inputGain)} dB',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onEnabledChanged != null) ...[
                SizedBox(width: tokens.gapMd),
                AppSwitch(
                  value: enabled,
                  semanticLabel: l10n.equalizerEnable,
                  onChanged: onEnabledChanged,
                ),
              ],
            ],
          ),
          SizedBox(height: tokens.gapLg),
          Semantics(
            label: l10n.equalizerCurveDescription,
            child: SizedBox(
              height: 152,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: curveColor),
                duration: tokens.motionMedium,
                builder: (context, color, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _EqualizerCurve(
                    settings: settings,
                    color: color ?? curveColor,
                    grid: colors.outlineVariant,
                    label: colors.onSurfaceVariant,
                    labelStyle: theme.textTheme.labelSmall!,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: tokens.gapSm),
          Text(
            l10n.equalizerCurve,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Quick-apply chips for every preset, plus save, reset and overflow actions.
class _PresetBar extends ConsumerWidget {
  const _PresetBar({
    required this.busy,
    required this.onApply,
    required this.onSave,
    required this.onReset,
    required this.onAction,
  });

  final bool busy;
  final ValueChanged<EqualizerPreset> onApply;
  final VoidCallback onSave;
  final VoidCallback onReset;
  final ValueChanged<_PresetAction> onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custom = ref.watch(
      equalizerProvider.select((state) => state.presets),
    );
    final presets = [...EqualizerPreset.builtIn, ...custom];
    final selected = ref.watch(_selectedEqualizerPresetProvider);
    final l10n = context.l10n;
    final tokens = context.tokens;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = settingsHorizontalInset(context, constraints.maxWidth);
        final chips = [
          for (final preset in presets)
            AppChoiceChip(
              label: Text(preset.name),
              selected: preset == selected,
              singleChoice: true,
              onSelected: (_) => onApply(preset),
            ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A mouse cannot swipe a clipped row, so desktop windows wrap
            // every preset onto view.
            if (isDesktopPlatform)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: Wrap(
                  spacing: tokens.gapSm,
                  runSpacing: tokens.gapSm,
                  children: chips,
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: Row(spacing: tokens.gapSm, children: chips),
              ),
            SizedBox(height: tokens.gapMd),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: Row(
                children: [
                  Flexible(
                    child: ExpressiveButton(
                      onPressed: onSave,
                      tonal: true,
                      icon: const AppIcon(Icons.bookmark_add_outlined),
                      child: Text(
                        l10n.equalizerSavePreset,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const Spacer(),
                  ExpressiveIconButton(
                    tooltip: l10n.libraryFilterReset,
                    icon: const AppIcon(Icons.restart_alt),
                    onPressed: onReset,
                  ),
                  AppMenuButton<_PresetAction>(
                    icon: const AppIcon(Icons.more_vert),
                    tooltip: l10n.equalizerPresets,
                    onSelected: onAction,
                    items: [
                      AppMenuItem(
                        value: _PresetAction.manage,
                        label: l10n.equalizerManagePresets,
                        leading: const AppIcon(Icons.tune),
                      ),
                      if (!busy)
                        AppMenuItem(
                          value: _PresetAction.import,
                          label: l10n.equalizerImport,
                          leading: const AppIcon(Icons.file_open_outlined),
                        ),
                      AppMenuItem(
                        value: _PresetAction.export,
                        label: l10n.equalizerExport,
                        leading: const AppIcon(Icons.ios_share),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Band count picker and one vertical gain fader per band.
class _BandEditor extends ConsumerWidget {
  const _BandEditor();

  static const _minColumnWidth = 32.0;
  static const _faderHeight = 208.0;

  void _setGain(WidgetRef ref, int index, double value) {
    final settings = ref.read(equalizerProvider).settings;
    if (index >= settings.gains.length) return;
    final gains = [...settings.gains];
    gains[index] = value;
    ref
        .read(equalizerProvider.notifier)
        .update(settings.copyWith(gains: gains));
  }

  Widget _countPicker(BuildContext context, WidgetRef ref, int count) {
    const counts = EqualizerSettings.bandCounts;
    void select(int index) => ref
        .read(equalizerProvider.notifier)
        .update(
          ref.read(equalizerProvider).settings.withBandCount(counts[index]),
        );
    if (context.isMornye) {
      return Semantics(
        label: context.l10n.equalizerBands,
        child: MornyeSegmentedControl(
          labels: [for (final value in counts) '$value'],
          selectedIndex: counts.indexOf(count),
          onChanged: select,
          samplesBackdrop: false,
        ),
      );
    }
    if (materialExpressiveEnabled(context)) {
      return MaterialExpressiveScope(
        skipAutofocus: true,
        child: M3EButtonGroup(
          type: M3EButtonGroupType.connected,
          style: M3EButtonStyle.filled,
          // Connected segments fill the row, so the 40 dp small button gets
          // no inflated target; 48 keeps each segment a full touch target.
          size: M3EButtonSize.sm.copyWith(height: 48),
          selectedIndex: counts.indexOf(count),
          selectionRequired: true,
          onSelectedIndexChanged: (index) {
            if (index != null) select(index);
          },
          semanticLabel: context.l10n.equalizerBands,
          actions: [
            for (final value in counts)
              M3EButtonGroupAction(label: Text('$value')),
          ],
        ),
      );
    }
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (final value in counts)
          ButtonSegment(value: value, label: Text('$value')),
      ],
      selected: {count},
      onSelectionChanged: (value) => select(counts.indexOf(value.first)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = context.l10n;
    final count = ref.watch(
      equalizerProvider.select((state) => state.settings.gains.length),
    );
    final frequencies = ref.read(equalizerProvider).settings.frequencies;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.gapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.gapLg),
            child: SizedBox(
              width: double.infinity,
              child: _countPicker(context, ref, count),
            ),
          ),
          SizedBox(height: tokens.gapLg),
          LayoutBuilder(
            builder: (context, constraints) {
              final available = constraints.maxWidth - tokens.gapSm * 2;
              final width = math.max(_minColumnWidth, available / count);
              final scrolls = width * count > available + 0.5;
              final faders = Row(
                children: [
                  for (var i = 0; i < count; i++)
                    SizedBox(
                      width: width,
                      child: Consumer(
                        builder: (context, ref, _) => _BandFader(
                          frequency: frequencies[i],
                          gain: ref.watch(
                            equalizerProvider.select(
                              (state) => i < state.settings.gains.length
                                  ? state.settings.gains[i]
                                  : 0.0,
                            ),
                          ),
                          width: width,
                          height: _faderHeight,
                          resetLabel: l10n.libraryFilterReset,
                          onChanged: (v) => _setGain(ref, i, v),
                        ),
                      ),
                    ),
                ],
              );
              return Stack(
                children: [
                  // 0 dB reference across every fader.
                  Positioned(
                    left: tokens.gapSm,
                    right: tokens.gapSm,
                    top: _BandFader.labelExtent + _faderHeight / 2,
                    child: Divider(
                      height: 1,
                      color: colors.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  scrolls
                      ? SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.gapSm,
                          ),
                          child: faders,
                        )
                      : Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.gapSm,
                          ),
                          child: faders,
                        ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BandFader extends StatelessWidget {
  const _BandFader({
    required this.frequency,
    required this.gain,
    required this.width,
    required this.height,
    required this.resetLabel,
    required this.onChanged,
  });

  final double frequency;
  final double gain;
  final double width;
  final double height;
  final String resetLabel;
  final ValueChanged<double> onChanged;

  /// Height of the gain label and its gap above the fader, so the 0 dB line
  /// can align with the faders' centers.
  static const labelExtent = 32.0 + 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final active = gain != 0;
    final mornye = context.isMornye;
    final hz = _frequency(frequency);
    final valueStyle = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: !active
          ? colors.onSurfaceVariant
          : mornye
          ? colors.primary
          : colors.onSecondaryContainer,
    );
    final semanticLabel = '$hz Hz';
    String semantics(double v) => '${v.toStringAsFixed(1)} dB';
    return Column(
      children: [
        // Tapping the gain returns the band to 0 dB.
        Tooltip(
          message: '$resetLabel $hz Hz',
          child: SizedBox(
            height: 32,
            child: Center(
              child: Material(
                // iOS shows the gain as plain tinted text, Material as a badge.
                color: active && !mornye
                    ? colors.secondaryContainer
                    : Colors.transparent,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                animationDuration: tokens.motionFast,
                child: InkWell(
                  onTap: active ? () => onChanged(0) : null,
                  child: Container(
                    height: 28,
                    constraints: BoxConstraints(maxWidth: width - 2),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(_signed(gain), style: valueStyle),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: height,
          child: mornye
              ? MornyeLevelSlider(
                  vertical: true,
                  value: gain,
                  min: -15,
                  max: 15,
                  origin: 0,
                  step: 0.5,
                  knobRadius: ((width - 8) / 2).clamp(9.0, 14.0),
                  semanticLabel: semanticLabel,
                  semanticFormatterCallback: semantics,
                  onChanged: (v) => onChanged(_snap(v, 0.5)),
                )
              : AppSlider(
                  vertical: true,
                  centered: true,
                  value: gain,
                  min: -15,
                  max: 15,
                  trackThickness: (width * 0.4).clamp(12.0, 24.0),
                  thumbLength: (width * 0.75).clamp(24.0, 44.0),
                  semanticLabel: semanticLabel,
                  semanticFormatterCallback: semantics,
                  onChanged: (v) => onChanged(_snap(v, 0.5)),
                ),
        ),
        SizedBox(height: tokens.gapSm),
        SizedBox(
          height: 20,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              hz,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A labelled slider row with its live value in a tonal badge.
enum _ToneControl {
  preamp,
  bass,
  treble,
  balance,
  threshold,
  ratio,
  attack,
  release;

  double value(EqualizerSettings settings) => switch (this) {
    preamp => settings.preamp,
    bass => settings.bass,
    treble => settings.treble,
    balance => settings.balance * 100,
    threshold => settings.threshold,
    ratio => settings.ratio,
    attack => settings.attack,
    release => settings.release,
  };

  EqualizerSettings change(EqualizerSettings settings, double value) =>
      switch (this) {
        preamp => settings.copyWith(preamp: value),
        bass => settings.copyWith(bass: value),
        treble => settings.copyWith(treble: value),
        balance => settings.copyWith(balance: value / 100),
        threshold => settings.copyWith(threshold: value),
        ratio => settings.copyWith(ratio: value),
        attack => settings.copyWith(attack: value),
        release => settings.copyWith(release: value),
      };
}

class _SliderTile extends ConsumerWidget {
  const _SliderTile({
    required this.title,
    required this.control,
    required this.min,
    required this.max,
    required this.step,
    required this.unit,
    this.icon,
    this.centered = false,
    this.signed = true,
    this.indented = false,
    this.last = false,
  });

  final IconData? icon;
  final String title;
  final _ToneControl control;
  final double min, max, step;
  final String unit;
  final bool centered, signed;

  /// Aligns an icon-less sub-setting with the text of the rows above it.
  final bool indented;

  /// Ends a Mornye group, which separates rows with hairlines.
  final bool last;

  String _format(double v) {
    final digits = step < 1 ? 1 : 0;
    final text = signed && v > 0
        ? '+${v.toStringAsFixed(digits)}'
        : v.toStringAsFixed(digits).replaceFirst('-', '−');
    return unit == '%' || unit.startsWith(':') ? '$text$unit' : '$text $unit';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (value, inputGain) = ref.watch(
      equalizerProvider.select(
        (state) => (
          control.value(state.settings),
          control == _ToneControl.preamp ? state.settings.inputGain : 0.0,
        ),
      ),
    );
    final subtitle = control == _ToneControl.preamp
        ? '${context.l10n.equalizerEffectivePreamp}: ${_signed(inputGain)} dB'
        : null;
    void onChanged(double value) => ref
        .read(equalizerProvider.notifier)
        .update(control.change(ref.read(equalizerProvider).settings, value));
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final content = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.rowPaddingH + (indented && !mornye ? 24 + tokens.rowIconGap : 0),
        tokens.rowPaddingVCompact,
        tokens.rowPaddingH,
        mornye ? 0 : tokens.gapXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SliderValueHeader(
            title: title,
            subtitle: subtitle,
            value: _format(value),
            // Mornye rows, like iOS Settings, carry no leading glyphs.
            leading: icon == null || mornye
                ? null
                : AppIcon.adaptive(
                    icon!,
                    color: colors.onSurfaceVariant,
                    size: 24,
                  ),
          ),
          if (mornye)
            MornyeLevelSlider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              origin: centered ? (min + max) / 2 : null,
              step: step,
              semanticLabel: title,
              semanticFormatterCallback: _format,
              onChanged: (v) => onChanged(_snap(v, step).clamp(min, max)),
            )
          else
            AppSlider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              centered: centered,
              semanticLabel: title,
              semanticFormatterCallback: _format,
              onChanged: (v) => onChanged(_snap(v, step).clamp(min, max)),
            ),
        ],
      ),
    );
    return SettingsSearchTarget(
      label: title,
      child: mornye && !last
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                content,
                Divider(
                  height: 1,
                  indent: tokens.rowPaddingH,
                  endIndent: tokens.rowPaddingH,
                  color: colors.outlineVariant,
                ),
              ],
            )
          : content,
    );
  }
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog();

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: Text(context.l10n.equalizerSavePreset),
    content: AppTextField(
      controller: _controller,
      label: context.l10n.equalizerPresetName,
      maxLength: 80,
      autofocus: true,
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      AppDialogAction(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(onPressed: _submit, child: Text(context.l10n.dialogSave)),
    ],
  );
}
