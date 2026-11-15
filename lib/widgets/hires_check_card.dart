import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';

/// On-demand sampled spectrum and bit-depth analysis for one FLAC/WAV file.
class HiResCheckCard extends StatefulWidget {
  final String filePath;
  final String? formatHint;

  const HiResCheckCard({super.key, required this.filePath, this.formatHint});

  /// Only FLAC and PCM WAV are decoded by the Rust checker.
  static bool isCandidate(String filePath, String? formatHint) {
    final format = formatHint?.toLowerCase().trim() ?? '';
    if (format == 'flac' || format == 'wav') return true;
    final lower = filePath.toLowerCase();
    return lower.endsWith('.flac') || lower.endsWith('.wav');
  }

  @override
  State<HiResCheckCard> createState() => _HiResCheckCardState();
}

class _HiResCheckCardState extends State<HiResCheckCard> {
  HiResCheckResult? _result;
  bool _checking = false;
  String? _error;
  int _requestId = 0;
  final _networkInput = NetworkAudioAnalysisInput();

  @override
  void didUpdateWidget(covariant HiResCheckCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _requestId++;
      _networkInput.cancel();
      _result = null;
      _error = null;
      _checking = false;
    }
  }

  @override
  void dispose() {
    _requestId++;
    _networkInput.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final requestId = ++_requestId;
    setState(() {
      _checking = true;
      _error = null;
    });
    String? error;
    HiResCheckResult? result;
    try {
      result = await HiResCheckService.check(
        widget.filePath,
        networkInput: _networkInput,
      );
    } on AudioAnalysisCancelled {
      return;
    } on StateError catch (e) {
      error = e.message;
    } catch (e) {
      error = e.toString();
    }
    if (!mounted || requestId != _requestId) return;
    setState(() {
      _checking = false;
      _result = result;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!HiResCheckCard.isCandidate(widget.filePath, widget.formatHint)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final result = _result;
    final mornye = context.isMornye;

    return AppContentCard(
      elevation: 0,
      color: settingsGroupColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: EdgeInsets.all(mornye ? 20 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.hiResCheckTitle,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                    ),
                  ),
                ),
                if (_checking)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: mornye
                        ? const CupertinoActivityIndicator()
                        : const AppLoadingIndicator(size: 20, strokeWidth: 2.5),
                  )
                else if (mornye && (result != null || _error != null))
                  Tooltip(
                    message: l10n.audioAnalysisRescan,
                    child: CupertinoButton(
                      padding: const EdgeInsets.all(12),
                      onPressed: _check,
                      child: Icon(
                        CupertinoIcons.refresh,
                        color: cs.onSurfaceVariant,
                        size: 22,
                        semanticLabel: l10n.audioAnalysisRescan,
                      ),
                    ),
                  )
                else if (result != null || _error != null)
                  AppIconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: l10n.audioAnalysisRescan,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    color: cs.onSurfaceVariant,
                    onPressed: _check,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_checking)
              _secondaryText(l10n.hiResCheckChecking, cs)
            else if (_error != null)
              Text(
                l10n.hiResCheckFailed(_error!),
                style: TextStyle(color: cs.error, fontSize: 15),
              )
            else if (result == null) ...[
              _secondaryText(l10n.hiResCheckSummary, cs),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: mornye
                    ? AppActionButton(
                        outlined: true,
                        tonal: true,
                        onPressed: _check,
                        icon: const Icon(Icons.search),
                        label: Text(l10n.hiResCheckRun),
                      )
                    : ExpressiveButton(
                        tonal: true,
                        onPressed: _check,
                        icon: const Icon(Icons.search, size: 20),
                        child: Text(l10n.hiResCheckRun),
                      ),
              ),
            ] else if (!result.supported)
              _secondaryText(l10n.hiResCheckUnsupported, cs)
            else
              ..._buildResult(context, result, cs),
          ],
        ),
      ),
    );
  }

  Widget _secondaryText(String text, ColorScheme cs) {
    return Text(
      text,
      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15, height: 1.35),
    );
  }

  List<Widget> _buildResult(
    BuildContext context,
    HiResCheckResult result,
    ColorScheme cs,
  ) {
    final l10n = context.l10n;
    final (IconData icon, Color color, String label) = switch (result.verdict) {
      'fake_hires' when result.isCertain => (
        Icons.error_outline,
        cs.error,
        l10n.hiResCheckVerdictFakeCertain,
      ),
      _ when result.hasLimitedBandwidth => (
        Icons.info_outline,
        cs.onSurface,
        l10n.hiResCheckLimitedBandwidth,
      ),
      'fake_hires' => (
        Icons.warning_amber_rounded,
        cs.error,
        l10n.hiResCheckVerdictFake,
      ),
      'genuine_hires' => (
        Icons.check_circle_outline,
        cs.onSurface,
        l10n.hiResCheckNoEvidence,
      ),
      'standard_definition' => (
        Icons.info_outline,
        cs.onSurfaceVariant,
        l10n.hiResCheckVerdictStandard,
      ),
      _ => (
        Icons.help_outline,
        cs.onSurfaceVariant,
        l10n.hiResCheckVerdictInconclusive,
      ),
    };

    final effectiveBits = result.effectiveBitDepth > 0
        ? result.effectiveBitDepth
        : null;
    final reasons = <String>[
      if (result.upsamplingArtifact == 'sample_hold')
        l10n.hiResCheckReasonSampleHold,
      if (result.upsamplingArtifact == 'linear_interpolation')
        l10n.hiResCheckReasonInterpolation,
      if (result.upsamplingArtifact == 'imaging')
        l10n.hiResCheckImagingEvidence,
      if (result.isFake &&
          result.confidence == 'likely' &&
          result.upsamplingArtifact.isEmpty &&
          result.brickwallHz > 0)
        l10n.hiResCheckRateEvidence(_formatKHz(result.brickwallHz)),
      if (result.isFake && result.paddedBitDepth)
        l10n.hiResCheckReasonDepth(
          result.declaredBitDepth,
          result.effectiveBitDepth,
        ),
    ];

    return [
      Row(
        children: [
          Icon(context.adaptiveIcon(icon), color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      for (final reason in reasons) ...[
        const SizedBox(height: 10),
        _secondaryText('• $reason', cs),
      ],
      if (result.ultrasonicNoiseOnly) ...[
        const SizedBox(height: 10),
        _secondaryText(
          l10n.hiResCheckSteadyEnergy(_formatKHz(result.musicCutoffHz)),
          cs,
        ),
      ],
      if (result.verdict != 'inconclusive') ...[
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 8),
        _detail(
          l10n.audioAnalysisSampleRate,
          _formatKHz(result.declaredSampleRate.toDouble()),
          cs,
        ),
        _detail(
          l10n.audioAnalysisNyquist,
          _formatKHz(result.declaredSampleRate / 2),
          cs,
        ),
        _detail(
          l10n.hiResCheckEstimatedCutoff,
          '~${_formatKHz(result.cutoffFrequencyHz)}',
          cs,
        ),
        if (result.declaredBitDepth > 0)
          _detail(
            l10n.hiResCheckActiveBits,
            '${effectiveBits ?? '?'} / ${result.declaredBitDepth}',
            cs,
          ),
      ],
      if (result.hasLimitedBandwidth) ...[
        const SizedBox(height: 16),
        _secondaryText(l10n.hiResCheckBandwidthExplanation, cs),
      ],
      if (result.analyzedDurationSeconds > 0) ...[
        const SizedBox(height: 12),
        _secondaryText(
          l10n.hiResCheckSampledExplanation(
            result.analyzedDurationSeconds.toStringAsFixed(1),
          ),
          cs,
        ),
      ],
    ];
  }

  Widget _detail(String label, String value, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatKHz(double hz) => '${(hz / 1000).toStringAsFixed(1)} kHz';
}
