import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Conversion options shared by the queue, album and single-track sheets.
class BatchConvertSheet extends StatefulWidget {
  final List<String> formats;
  final String title;
  final String? subtitle;
  final String? confirmLabel;
  final String Function(
    String format,
    String bitrate,
    bool isLosslessTarget,
    LosslessConversionQuality losslessQuality,
  )?
  confirmLabelBuilder;
  final bool sourceIsLossless;
  final int? sourceBitDepth;
  final int? sourceSampleRate;
  final void Function(
    String format,
    String bitrate,
    LosslessConversionQuality losslessQuality,
    LosslessConversionProcessing losslessProcessing,
    bool keepOriginal,
  )
  onConvert;

  const BatchConvertSheet({
    super.key,
    required this.formats,
    required this.title,
    required this.onConvert,
    this.confirmLabel,
    this.confirmLabelBuilder,
    this.sourceIsLossless = true,
    this.subtitle,
    this.sourceBitDepth,
    this.sourceSampleRate,
  });

  @override
  State<BatchConvertSheet> createState() => _BatchConvertSheetState();
}

class _BatchConvertSheetState extends State<BatchConvertSheet> {
  static const _bitrates = ['128k', '192k', '256k', '320k'];

  late String _selectedFormat;
  late bool _isLosslessTarget;
  late String _selectedBitrate;
  int? _selectedMaxBitDepth;
  int? _selectedMaxSampleRate;
  String _selectedDither = 'none';
  String _selectedResampler = 'swr';
  bool _keepOriginal = false;

  String _defaultBitrateForFormat(String format) {
    if (format == 'Opus') return '128k';
    if (format == 'AAC') return '256k';
    return '320k';
  }

  @override
  void initState() {
    super.initState();
    _selectedFormat = widget.formats.first;
    _isLosslessTarget = isLosslessConversionTarget(_selectedFormat);
    _selectedBitrate = _isLosslessTarget
        ? '320k'
        : _defaultBitrateForFormat(_selectedFormat);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = context.l10n.losslessConversionLabels;
    final bitDepthOptions = availableLosslessBitDepthOptions(
      widget.sourceBitDepth,
    );
    final sampleRateOptions = availableLosslessSampleRateOptions(
      widget.sourceSampleRate,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => _sheetSurface(
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSheetHandle(),
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 20),

                _choiceSection(
                  cs,
                  context.l10n.trackConvertTargetFormat,
                  values: widget.formats,
                  labelOf: (format) => format,
                  selected: _selectedFormat,
                  onSelect: (format) {
                    _selectedFormat = format;
                    _isLosslessTarget = isLosslessConversionTarget(format);
                    if (!_isLosslessTarget) {
                      _selectedBitrate = _defaultBitrateForFormat(format);
                    } else {
                      _selectedMaxBitDepth = null;
                      _selectedMaxSampleRate = null;
                      _selectedDither = 'none';
                      _selectedResampler = 'swr';
                    }
                  },
                ),

                if (!_isLosslessTarget)
                  _choiceSection(
                    cs,
                    context.l10n.trackConvertBitrate,
                    values: _bitrates,
                    labelOf: (br) => br,
                    selected: _selectedBitrate,
                    onSelect: (br) => _selectedBitrate = br,
                  ),

                if (_isLosslessTarget && bitDepthOptions.isNotEmpty)
                  _choiceSection<int?>(
                    cs,
                    context.l10n.audioAnalysisBitDepth,
                    values: [null, ...bitDepthOptions],
                    labelOf: (depth) => losslessBitDepthLabel(
                      depth,
                      originalLabel: labels.original,
                    ),
                    selected: _selectedMaxBitDepth,
                    onSelect: (depth) {
                      _selectedMaxBitDepth = depth;
                      if (depth == null) _selectedDither = 'none';
                    },
                  ),

                if (_isLosslessTarget && sampleRateOptions.isNotEmpty)
                  _choiceSection<int?>(
                    cs,
                    context.l10n.audioAnalysisSampleRate,
                    values: [null, ...sampleRateOptions],
                    labelOf: (rate) => losslessSampleRateLabel(
                      rate,
                      originalLabel: labels.original,
                    ),
                    selected: _selectedMaxSampleRate,
                    onSelect: (rate) {
                      _selectedMaxSampleRate = rate;
                      if (rate == null) _selectedResampler = 'swr';
                    },
                  ),

                if (_isLosslessTarget && _selectedMaxBitDepth != null)
                  _choiceSection(
                    cs,
                    context.l10n.trackConvertDithering,
                    values: losslessDitherOptions,
                    labelOf: context.l10n.losslessDitherOptionLabel,
                    selected: _selectedDither,
                    onSelect: (mode) => _selectedDither = mode,
                  ),

                if (_isLosslessTarget && _selectedMaxSampleRate != null)
                  _choiceSection(
                    cs,
                    context.l10n.trackConvertResampler,
                    values: losslessResamplerOptions,
                    labelOf: context.l10n.losslessResamplerOptionLabel,
                    selected: _selectedResampler,
                    onSelect: (mode) => _selectedResampler = mode,
                  ),

                if (_isLosslessTarget && widget.sourceIsLossless)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: context.isMornye
                        ? null
                        : BoxDecoration(
                            color: cs.primaryContainer.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(14),
                          ),
                    child: Row(
                      children: [
                        Icon(
                          context.isMornye
                              ? CupertinoIcons.checkmark_seal
                              : Icons.verified,
                          size: 18,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _selectedMaxBitDepth == null &&
                                    _selectedMaxSampleRate == null
                                ? context.l10n.trackConvertLosslessHint
                                : context.l10n
                                      .trackConvertLosslessOutputWithCap(
                                        losslessQualityLabel(
                                          LosslessConversionQuality(
                                            maxBitDepth: _selectedMaxBitDepth,
                                            maxSampleRate:
                                                _selectedMaxSampleRate,
                                          ),
                                          originalLabel: labels.original,
                                          originalQualityLabel:
                                              labels.originalQuality,
                                        ),
                                      ),
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: cs.primary),
                          ),
                        ),
                      ],
                    ),
                  ),

                _card(
                  cs,
                  child: AppSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.l10n.trackConvertKeepOriginal),
                    subtitle: Text(
                      context.l10n.trackConvertKeepOriginalDescription,
                    ),
                    value: _keepOriginal,
                    onChanged: (value) => setState(() => _keepOriginal = value),
                  ),
                ),

                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: AppActionButton(
                    onPressed: () => widget.onConvert(
                      _selectedFormat,
                      _selectedBitrate,
                      LosslessConversionQuality(
                        maxBitDepth: _selectedMaxBitDepth,
                        maxSampleRate: _selectedMaxSampleRate,
                      ),
                      LosslessConversionProcessing(
                        dither: _selectedDither,
                        resampler: _selectedResampler,
                      ),
                      _keepOriginal,
                    ),
                    icon: const Icon(Icons.swap_horiz),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    label: Text(
                      widget.confirmLabelBuilder?.call(
                            _selectedFormat,
                            _selectedBitrate,
                            _isLosslessTarget,
                            LosslessConversionQuality(
                              maxBitDepth: _selectedMaxBitDepth,
                              maxSampleRate: _selectedMaxSampleRate,
                            ),
                          ) ??
                          widget.confirmLabel!,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetSurface({required Widget child}) {
    final content = SafeArea(child: child);
    return context.isMornye
        ? MornyeGlassPanel.overlay(child: content)
        : content;
  }

  Widget _card(ColorScheme cs, {required Widget child}) {
    if (context.isMornye) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            child,
            const SizedBox(height: 20),
            const Divider(height: 1),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: settingsGroupColor(context),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  Widget _choiceSection<T>(
    ColorScheme cs,
    String label, {
    required Iterable<T> values,
    required String Function(T value) labelOf,
    required T selected,
    required void Function(T value) onSelect,
  }) {
    return _card(
      cs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 2, bottom: 12),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                _choice(
                  cs,
                  label: labelOf(value),
                  selected: value == selected,
                  onTap: () => setState(() => onSelect(value)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choice(
    ColorScheme cs, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    if (context.isMornye) {
      return MornyeFilterChip(
        label: label,
        selected: selected,
        onTap: onTap,
        icon: selected ? CupertinoIcons.checkmark : null,
      );
    }
    return AppChoiceChip(
      singleChoice: true,
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
