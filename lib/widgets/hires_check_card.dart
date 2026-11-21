import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/hires_report_content.dart';
import 'package:mornye/widgets/hires_report_view.dart';
import 'package:share_plus/share_plus.dart';

/// On-demand inspection of one whole FLAC/WAV file: integrity, real bit
/// depth, frequency range and traces of lossy compression.
class HiResCheckCard extends StatefulWidget {
  final String filePath;
  final String? formatHint;

  /// What a shared report calls the song.
  final String? name;

  const HiResCheckCard({
    super.key,
    required this.filePath,
    this.formatHint,
    this.name,
  });

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
        detailed: true,
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

  void _share(HiResCheckResult result, HiResReport report) {
    final l10n = context.l10n;
    final text = HiResReportContent.of(
      l10n,
      result,
      report,
    ).text(name: widget.name);
    SharePlus.instance.share(
      ShareParams(
        text: '${l10n.hiResCheckTitle}\n$text',
        subject: l10n.hiResCheckTitle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!HiResCheckCard.isCandidate(widget.filePath, widget.formatHint)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final result = _result;
    final report = result?.report;
    final mornye = context.isMornye;
    final onShare = result != null && result.supported && report != null
        ? () => _share(result, report)
        : null;

    return AppContentCard(
      elevation: 0,
      color: settingsGroupColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_checking)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: AppLoadingIndicator(size: 20, strokeWidth: 2.5),
                  )
                else if (mornye && (result != null || _error != null)) ...[
                  if (onShare != null)
                    Tooltip(
                      message: l10n.hiResReportShare,
                      child: CupertinoButton(
                        padding: const EdgeInsets.all(12),
                        onPressed: onShare,
                        child: Icon(
                          CupertinoIcons.share,
                          color: cs.onSurfaceVariant,
                          size: 22,
                          semanticLabel: l10n.hiResReportShare,
                        ),
                      ),
                    ),
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
                  ),
                ] else if (result != null || _error != null) ...[
                  if (onShare != null)
                    AppIconButton(
                      icon: const Icon(Icons.share_outlined, size: 20),
                      tooltip: l10n.hiResReportShare,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      color: cs.onSurfaceVariant,
                      onPressed: onShare,
                    ),
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
              ],
            ),
            const SizedBox(height: 8),
            if (_checking)
              _secondaryText(l10n.hiResReportChecking, cs)
            else if (_error != null)
              Text(
                l10n.hiResCheckFailed(_error!),
                style: TextStyle(color: cs.error, fontSize: 15),
              )
            else if (result == null) ...[
              _secondaryText(l10n.hiResReportSummary, cs),
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
              HiResReportView(
                result: result,
                report: result.report ?? const HiResReport(),
              ),
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
}
