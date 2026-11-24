import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/hires_check_card.dart';
import 'package:mornye/widgets/hires_report_content.dart';
import 'package:mornye/widgets/hires_report_view.dart';
import 'package:share_plus/share_plus.dart';

/// The songs among [items] the check can read: FLAC and WAV files.
List<UnifiedLibraryItem> hiResCheckableItems(List<UnifiedLibraryItem> items) =>
    [
      for (final item in items)
        if (!isCueVirtualPath(item.filePath) &&
            HiResCheckCard.isCandidate(
              item.filePath,
              item.localItem?.format ?? item.historyItem?.format,
            ))
          item,
    ];

/// Checks the FLAC and WAV files among [items] one after another, each read
/// whole, and lists every song with its outcome. Closing the sheet stops
/// before the next song.
Future<void> showHiResBatchCheckSheet(
  BuildContext context,
  List<UnifiedLibraryItem> items,
) {
  final songs = hiResCheckableItems(items);
  return showAppScrollableBottomSheet<void>(
    context: context,
    title: context.l10n.hiResCheckTitle,
    dialogSize: AppDialogSize.wide,
    builder: (context, controller) => HiResBatchCheck(
      songs: songs,
      skipped: items.length - songs.length,
      controller: controller,
    ),
  );
}

class _Entry {
  _Entry(this.item);

  final UnifiedLibraryItem item;
  HiResCheckResult? result;
  String? error;

  /// Its place among the songs on the shared chart; null without a spectrum.
  int? slot;

  String get name => '${item.artistName} - ${item.trackName}';
}

/// The body of [showHiResBatchCheckSheet]. [check] reads one file; tests
/// replace it.
class HiResBatchCheck extends StatefulWidget {
  const HiResBatchCheck({
    super.key,
    required this.songs,
    this.skipped = 0,
    this.controller,
    this.check,
  });

  final List<UnifiedLibraryItem> songs;

  /// Songs left out because the check cannot read their format.
  final int skipped;
  final ScrollController? controller;
  final Future<HiResCheckResult> Function(String filePath)? check;

  @override
  State<HiResBatchCheck> createState() => _HiResBatchCheckState();
}

class _HiResBatchCheckState extends State<HiResBatchCheck> {
  late final _entries = [for (final item in widget.songs) _Entry(item)];
  final _networkInput = NetworkAudioAnalysisInput();

  /// The song being read; the number of songs once all are done.
  int _current = 0;
  String? _expandedId;

  /// Songs read so far that have a spectrum to draw.
  int _charted = 0;

  bool get _done => _current >= _entries.length;

  /// One song has nothing to be compared with, so the shared chart and the
  /// colors that go with it wait for a second.
  bool get _showsChart => _charted > 1;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _networkInput.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final check =
        widget.check ??
        (String path) => HiResCheckService.check(
          path,
          networkInput: _networkInput,
          detailed: true,
        );
    for (final entry in _entries) {
      try {
        final result = await check(entry.item.filePath);
        final report = result.report;
        if (result.supported && report != null) {
          entry.result = result;
          // Taken in reading order and never given away, so a song keeps
          // its color while the others are still being read.
          if (report.spectrumDb.length > 1) entry.slot = _charted++;
        } else {
          entry.error = '';
        }
      } on AudioAnalysisCancelled {
        return;
      } on StateError catch (e) {
        entry.error = e.message;
      } catch (e) {
        entry.error = e.toString();
      }
      if (!mounted) return;
      setState(() => _current++);
    }
  }

  HiResReportContent? _content(_Entry entry) {
    final result = entry.result;
    final report = result?.report;
    if (result == null || report == null) return null;
    return HiResReportContent.of(context.l10n, result, report);
  }

  /// What the songs have in common and where they differ, once all are
  /// read.
  List<String> _summary() {
    final l10n = context.l10n;
    var flagged = 0;
    var failed = 0;
    final formats = <String, int>{};
    for (final entry in _entries) {
      final content = _content(entry);
      if (content == null) {
        failed++;
        continue;
      }
      if (content.level == HiResLevel.warning ||
          content.level == HiResLevel.bad) {
        flagged++;
      }
      final result = entry.result!;
      final format = buildDisplayAudioQuality(
        bitDepth: result.declaredBitDepth,
        sampleRate: result.declaredSampleRate,
      );
      if (format != null) formats[format] = (formats[format] ?? 0) + 1;
    }
    final checked = _entries.length - failed;
    return [
      if (checked > 0) l10n.hiResBatchSummary(flagged, checked),
      if (failed > 0) l10n.hiResBatchFailed(failed),
      if (widget.skipped > 0) l10n.hiResBatchSkipped(widget.skipped),
      if (formats.length > 1)
        l10n.hiResBatchMixedFormats(
          [
            for (final MapEntry(:key, :value) in formats.entries)
              '$key ($value)',
          ].join(', '),
        ),
    ];
  }

  void _share() {
    final l10n = context.l10n;
    final text = [
      l10n.hiResCheckTitle,
      ..._summary(),
      for (final (index, entry) in _entries.indexed) ...[
        '',
        _content(entry)?.text(name: '${index + 1}. ${entry.name}') ??
            '${index + 1}. ${entry.name}\n${_failure(entry)}',
      ],
    ].join('\n');
    SharePlus.instance.share(
      ShareParams(text: text, subject: l10n.hiResCheckTitle),
    );
  }

  String _failure(_Entry entry) {
    final error = entry.error ?? '';
    return error.isEmpty
        ? context.l10n.hiResCheckUnsupported
        : context.l10n.hiResCheckFailed(error);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final total = _entries.length;
    final secondary = TextStyle(
      color: cs.onSurfaceVariant,
      fontSize: 15,
      height: 1.35,
    );
    return CustomScrollView(
      controller: widget.controller,
      shrinkWrap: _entries.length <= 8,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            // In line with the sheet title and the rows below.
            padding: EdgeInsets.fromLTRB(tokens.gapXl, 0, tokens.gapXl, 8),
            child: _done
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in _summary())
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(line, style: secondary),
                        ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.hiResBatchProgress(_current + 1, total),
                        style: secondary,
                      ),
                      const SizedBox(height: 10),
                      AppProgressIndicator.linear(value: _current / total),
                    ],
                  ),
          ),
        ),
        if (_showsChart)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapXl,
                tokens.gapSm,
                tokens.gapXl,
                tokens.gapSm,
              ),
              child: HiResSpectrumOverlay(
                lines: [
                  for (final entry in _entries)
                    if (entry.slot case final slot?)
                      (
                        db: entry.result!.report!.spectrumDb,
                        stepHz: entry.result!.report!.spectrumStepHz,
                        color: HiResSongColors.of(context, slot),
                      ),
                ],
              ),
            ),
          ),
        SliverList.builder(
          itemCount: _entries.length,
          itemBuilder: (context, index) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _row(context, index, _entries[index]),
          ),
        ),
        if (_done && _entries.any((entry) => entry.result != null))
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapXl,
                tokens.gapMd,
                tokens.gapXl,
                0,
              ),
              child: mornye
                  ? AppActionButton(
                      outlined: true,
                      tonal: true,
                      onPressed: _share,
                      icon: const Icon(Icons.share_outlined),
                      label: Text(l10n.hiResReportShare),
                    )
                  : ExpressiveButton(
                      tonal: true,
                      onPressed: _share,
                      icon: const Icon(Icons.share_outlined, size: 20),
                      child: Text(l10n.hiResReportShare),
                    ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: tokens.gapLg)),
      ],
    );
  }

  List<Widget> _row(BuildContext context, int index, _Entry entry) {
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final content = _content(entry);
    final result = entry.result;
    final reading = index == _current;
    final waiting = index > _current;
    final expanded = content != null && _expandedId == entry.item.id;
    final Widget leading;
    final String status;
    var statusColor = cs.onSurfaceVariant;
    if (content != null) {
      leading = AppIcon(
        HiResLevelIcon.iconOf(content.level),
        color: HiResLevelIcon.colorOf(cs, content.level),
      );
      status = content.title;
      if (content.level == HiResLevel.warning ||
          content.level == HiResLevel.bad) {
        statusColor = cs.error;
      }
    } else if (reading) {
      leading = const SizedBox(
        width: 24,
        height: 24,
        child: Center(child: AppLoadingIndicator(size: 20, strokeWidth: 2.5)),
      );
      status = l10n.hiResBatchReading;
    } else if (waiting) {
      leading = AppIcon(
        Icons.history_toggle_off_outlined,
        color: cs.onSurfaceVariant,
      );
      status = l10n.hiResBatchWaiting;
    } else {
      leading = AppIcon(Icons.error_outline, color: cs.error);
      status = _failure(entry);
      statusColor = cs.error;
    }
    final slot = _showsChart ? entry.slot : null;
    final color = slot == null ? null : HiResSongColors.of(context, slot);
    final title = Text(
      entry.item.trackName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return [
      AppSheetOption(
        leading: leading,
        // The dot is the chart's legend: the song's line has this color.
        title: color == null
            ? title
            : Row(
                children: [
                  ExcludeSemantics(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: title),
                ],
              ),
        subtitle: Text(status, style: TextStyle(color: statusColor)),
        trailing: content == null
            ? null
            : AppIcon(
                expanded ? Icons.expand_less : Icons.expand_more,
                color: cs.onSurfaceVariant,
              ),
        onTap: content == null
            ? null
            : () =>
                  setState(() => _expandedId = expanded ? null : entry.item.id),
      ),
      if (expanded && result != null)
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.tokens.gapXl,
            4,
            context.tokens.gapXl,
            context.tokens.gapLg,
          ),
          child: HiResReportView(
            result: result,
            report: result.report!,
            spectrumColor: color,
          ),
        ),
    ];
  }
}
