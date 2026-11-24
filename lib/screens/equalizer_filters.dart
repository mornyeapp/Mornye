part of 'equalizer_screen.dart';

String _filterTypeLabel(AppLocalizations l10n, EqualizerFilterType type) =>
    switch (type) {
      EqualizerFilterType.peak => l10n.equalizerFilterPeak,
      EqualizerFilterType.lowShelf => l10n.equalizerFilterLowShelf,
      EqualizerFilterType.highShelf => l10n.equalizerFilterHighShelf,
    };

String _filterHz(double hz) => '${hz.toStringAsFixed(hz % 1 == 0 ? 0 : 1)} Hz';

/// A single-select row in the page's two styles, like the band count.
class _Segments extends StatelessWidget {
  const _Segments({
    required this.labels,
    required this.selected,
    required this.onChanged,
    required this.semanticLabel,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => context.isMornye
      ? Semantics(
          label: semanticLabel,
          child: MornyeSegmentedControl(
            labels: labels,
            selectedIndex: selected,
            onChanged: onChanged,
            samplesBackdrop: false,
          ),
        )
      : SettingsSegmentedChoice<int>(
          options: [
            for (final (index, label) in labels.indexed)
              SettingsSegmentOption(value: index, label: label),
          ],
          selected: selected,
          onChanged: onChanged,
          semanticLabel: semanticLabel,
        );
}

/// Graphic bands or parametric filters. Each keeps its values while the
/// other plays.
class _ModePicker extends ConsumerWidget {
  const _ModePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parametric = ref.watch(
      equalizerProvider.select((state) => state.settings.parametric),
    );
    final l10n = context.l10n;
    final tokens = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(tokens.gapLg, tokens.gapLg, tokens.gapLg, 0),
      child: _Segments(
        labels: [l10n.equalizerModeGraphic, l10n.equalizerModeParametric],
        selected: parametric ? 1 : 0,
        semanticLabel: l10n.equalizerTitle,
        onChanged: (index) => ref
            .read(equalizerProvider.notifier)
            .update(
              ref
                  .read(equalizerProvider)
                  .settings
                  .copyWith(parametric: index == 1),
            ),
      ),
    );
  }
}

/// Android plays the filters through its media3 engine alone.
class _EngineNotice extends ConsumerWidget {
  const _EngineNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needed = ref.watch(
      equalizerProvider.select((state) => state.settings.parametric),
    );
    final engine = ref.watch(
      settingsProvider.select((settings) => settings.media3Engine),
    );
    if (!needed || engine || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return SettingsInfoCard(
      message: l10n.equalizerNeedsEngine,
      icon: Icons.info_outline,
      action: ExpressiveButton(
        tonal: true,
        onPressed: () =>
            ref.read(settingsProvider.notifier).setMedia3Engine(true),
        child: Text(l10n.equalizerNeedsEngineAction),
      ),
    );
  }
}

class _FilterList extends ConsumerWidget {
  const _FilterList();

  void _add(BuildContext context, WidgetRef ref) {
    final settings = ref.read(equalizerProvider).settings;
    if (settings.filters.length >= EqualizerSettings.maxFilters) return;
    ref
        .read(equalizerProvider.notifier)
        .update(
          settings.copyWith(
            filters: [...settings.filters, const EqualizerFilter()],
          ),
        );
    _edit(context, settings.filters.length);
  }

  void _edit(BuildContext context, int index) => showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.equalizerFilterNumber(index + 1),
    maxHeightFactor: 0.85,
    builder: (_) => _FilterSheet(index: index),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filterCount = ref.watch(
      equalizerProvider.select((state) => state.settings.filters.length),
    );
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final full = filterCount >= EqualizerSettings.maxFilters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: tokens.gapSm),
        if (filterCount == 0)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.rowPaddingH,
              vertical: tokens.gapMd,
            ),
            child: Text(
              l10n.equalizerFiltersEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        for (var index = 0; index < filterCount; index++)
          _FilterRow(index: index, onEdit: () => _edit(context, index)),
        if (mornye)
          _ActionRow(
            label: l10n.equalizerAddFilter,
            onTap: full ? null : () => _add(context, ref),
            last: true,
          )
        else
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.rowPaddingH,
              tokens.gapSm,
              tokens.rowPaddingH,
              tokens.gapLg,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ExpressiveButton(
                tonal: true,
                onPressed: full ? null : () => _add(context, ref),
                icon: const AppIcon(Icons.add),
                child: Text(l10n.equalizerAddFilter),
              ),
            ),
          ),
      ],
    );
  }
}

class _FilterRow extends ConsumerWidget {
  const _FilterRow({required this.index, required this.onEdit});

  final int index;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(
      equalizerProvider.select(
        (state) => index < state.settings.filters.length
            ? state.settings.filters[index]
            : null,
      ),
    );
    if (filter == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    return SettingsItem(
      title: _filterHz(filter.frequency),
      subtitle:
          '${_filterTypeLabel(l10n, filter.type)} · '
          '${_signed(filter.gain)} dB · '
          '${l10n.equalizerFilterQ} ${filter.q.toStringAsFixed(2)}',
      trailing: AppSwitch(
        value: filter.enabled,
        semanticLabel:
            '${l10n.equalizerFilterNumber(index + 1)}, '
            '${_filterHz(filter.frequency)}',
        onChanged: (enabled) {
          final settings = ref.read(equalizerProvider).settings;
          if (index >= settings.filters.length) return;
          ref
              .read(equalizerProvider.notifier)
              .update(
                settings.copyWith(
                  filters: [
                    for (final (i, other) in settings.filters.indexed)
                      i == index ? other.copyWith(enabled: enabled) : other,
                  ],
                ),
              );
        },
      ),
      onTap: onEdit,
    );
  }
}

/// One filter's type, frequency, gain and Q. Edits play at once.
class _FilterSheet extends ConsumerWidget {
  const _FilterSheet({required this.index});

  final int index;

  static const _hzSpan =
      EqualizerFilter.maxFrequency / EqualizerFilter.minFrequency;
  static const _qSpan = EqualizerFilter.maxQ / EqualizerFilter.minQ;

  /// A slider cannot land on every hertz of ten octaves: whole steps that
  /// grow with the frequency. Typed values are kept as typed.
  static double _roundHz(double hz) {
    final step = hz < 100
        ? 1.0
        : hz < 1000
        ? 5.0
        : hz < 10000
        ? 50.0
        : 100.0;
    return _snap(hz, step);
  }

  static double _roundQ(double q) => _snap(
    q,
    q < 1
        ? 0.01
        : q < 5
        ? 0.05
        : 0.1,
  );

  void _change(WidgetRef ref, EqualizerFilter next) {
    final settings = ref.read(equalizerProvider).settings;
    if (index >= settings.filters.length) return;
    ref
        .read(equalizerProvider.notifier)
        .update(
          settings.copyWith(
            filters: [
              for (final (i, filter) in settings.filters.indexed)
                i == index ? next : filter,
            ],
          ),
        );
  }

  void _remove(BuildContext context, WidgetRef ref) {
    final settings = ref.read(equalizerProvider).settings;
    Navigator.pop(context);
    if (index >= settings.filters.length) return;
    ref
        .read(equalizerProvider.notifier)
        .update(
          settings.copyWith(filters: [...settings.filters]..removeAt(index)),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(
      equalizerProvider.select(
        (state) => index < state.settings.filters.length
            ? state.settings.filters[index]
            : null,
      ),
    );
    if (filter == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final tokens = context.tokens;
    const types = EqualizerFilterType.values;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.rowPaddingH,
          tokens.gapSm,
          tokens.rowPaddingH,
          tokens.gapLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Segments(
              labels: [for (final type in types) _filterTypeLabel(l10n, type)],
              selected: types.indexOf(filter.type),
              semanticLabel: l10n.equalizerFilterNumber(index + 1),
              onChanged: (value) =>
                  _change(ref, filter.copyWith(type: types[value])),
            ),
            SizedBox(height: tokens.gapLg),
            _FilterSlider(
              title: l10n.equalizerFilterFrequency,
              label: _filterHz(filter.frequency),
              // The slider moves in octaves, as the ear hears pitch.
              position:
                  math.log(filter.frequency / EqualizerFilter.minFrequency) /
                  math.log(_hzSpan),
              min: 0,
              max: 1,
              typed: filter.frequency,
              typedMin: EqualizerFilter.minFrequency,
              typedMax: EqualizerFilter.maxFrequency,
              unit: 'Hz',
              onSlide: (position) => _change(
                ref,
                filter.copyWith(
                  frequency:
                      _roundHz(
                        EqualizerFilter.minFrequency *
                            math.pow(_hzSpan, position),
                      ).clamp(
                        EqualizerFilter.minFrequency,
                        EqualizerFilter.maxFrequency,
                      ),
                ),
              ),
              onTyped: (value) =>
                  _change(ref, filter.copyWith(frequency: value)),
            ),
            _FilterSlider(
              title: l10n.equalizerFilterGain,
              label: '${_signed(filter.gain)} dB',
              position: filter.gain,
              min: -EqualizerFilter.maxGain,
              max: EqualizerFilter.maxGain,
              centered: true,
              typed: filter.gain,
              typedMin: -EqualizerFilter.maxGain,
              typedMax: EqualizerFilter.maxGain,
              unit: 'dB',
              onSlide: (value) =>
                  _change(ref, filter.copyWith(gain: _snap(value, 0.1))),
              onTyped: (value) => _change(ref, filter.copyWith(gain: value)),
            ),
            _FilterSlider(
              title: l10n.equalizerFilterQ,
              label: filter.q.toStringAsFixed(2),
              position:
                  math.log(filter.q / EqualizerFilter.minQ) / math.log(_qSpan),
              min: 0,
              max: 1,
              typed: filter.q,
              typedMin: EqualizerFilter.minQ,
              typedMax: EqualizerFilter.maxQ,
              unit: '',
              onSlide: (position) => _change(
                ref,
                filter.copyWith(
                  q: _roundQ(
                    EqualizerFilter.minQ * math.pow(_qSpan, position),
                  ).clamp(EqualizerFilter.minQ, EqualizerFilter.maxQ),
                ),
              ),
              onTyped: (value) => _change(ref, filter.copyWith(q: value)),
            ),
            SizedBox(height: tokens.gapSm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ExpressiveButton(
                text: true,
                onPressed: () => _remove(context, ref),
                icon: AppIcon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                child: Text(
                  l10n.equalizerRemoveFilter,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slider with its value, and a button to type the value exactly.
class _FilterSlider extends StatelessWidget {
  const _FilterSlider({
    required this.title,
    required this.label,
    required this.position,
    required this.min,
    required this.max,
    required this.typed,
    required this.typedMin,
    required this.typedMax,
    required this.unit,
    required this.onSlide,
    required this.onTyped,
    this.centered = false,
  });

  final String title, label, unit;

  /// The slider's own scale, which for frequency and Q is logarithmic.
  final double position, min, max;

  /// The value in its unit, and the range a typed value is brought into.
  final double typed, typedMin, typedMax;
  final ValueChanged<double> onSlide, onTyped;
  final bool centered;

  Future<void> _type(BuildContext context) async {
    final value = await showAppDialog<double>(
      context: context,
      builder: (context) => _NumberDialog(
        title: title,
        unit: unit,
        value: typed,
        min: typedMin,
        max: typedMax,
      ),
    );
    if (value != null) onTyped(value);
  }

  @override
  Widget build(BuildContext context) {
    final value = position.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SliderValueHeader(
          title: title,
          value: label,
          trailing: IconButton(
            tooltip: '${context.l10n.equalizerFilterTypeValue}: $title',
            icon: const AppIcon(Icons.edit_outlined),
            onPressed: () => _type(context),
          ),
        ),
        if (context.isMornye)
          MornyeLevelSlider(
            value: value,
            min: min,
            max: max,
            origin: centered ? (min + max) / 2 : null,
            semanticLabel: title,
            semanticFormatterCallback: (_) => label,
            onChanged: onSlide,
          )
        else
          AppSlider(
            value: value,
            min: min,
            max: max,
            centered: centered,
            semanticLabel: title,
            semanticFormatterCallback: (_) => label,
            onChanged: onSlide,
          ),
      ],
    );
  }
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({
    required this.title,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
  });

  final String title, unit;
  final double value, min, max;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  late final _controller = TextEditingController(
    text: widget.value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), ''),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    // A decimal comma is what many keyboards offer.
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite) return;
    Navigator.pop(context, value.clamp(widget.min, widget.max));
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: Text(widget.title),
    content: AppTextField(
      controller: _controller,
      label: widget.unit.isEmpty
          ? widget.title
          : '${widget.title} (${widget.unit})',
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
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
