part of 'audio_analysis_widget.dart';

/// Whether this device can pick a second file for the null test. Android TV
/// has no dependable document picker.
bool get audioCompareAvailable => !isAndroidTv;

/// Whether the picked file is the reference itself: the same path, or (for
/// pickers that hand back a private copy) the same name and size.
@visibleForTesting
bool isSameAudioCompareFile({
  required String referencePath,
  required int referenceSize,
  required String otherPath,
  required String otherName,
  required int otherSize,
}) {
  if (!referencePath.contains('://')) {
    String normalize(String path) {
      final value = p.normalize(File(path).absolute.path);
      return Platform.isWindows || Platform.isMacOS
          ? value.toLowerCase()
          : value;
    }

    if (normalize(referencePath) == normalize(otherPath)) return true;
  }
  return referenceSize > 0 &&
      referenceSize == otherSize &&
      audioCompareDisplayName(referencePath).toLowerCase() ==
          otherName.toLowerCase();
}

/// Whether [path] is the private copy the Android picker made for this pick
/// alone. It copies every pick to `<cache>/file_picker/<time>/<name>`, so
/// the copy is never shared with a song opened through Open audio and can
/// be deleted once the comparison closes.
@visibleForTesting
bool isAudioComparePickerCopy(String path, {required String cacheDir}) {
  final parts = p.split(p.relative(p.normalize(path), from: cacheDir));
  return parts.length == 3 &&
      parts[0] == 'file_picker' &&
      int.tryParse(parts[1]) != null;
}

Future<void> _deleteAudioComparePickerCopy(
  String path,
  String referencePath,
) async {
  if (!Platform.isAndroid || path == referencePath) return;
  try {
    final cache = await getTemporaryDirectory();
    if (!isAudioComparePickerCopy(path, cacheDir: cache.path)) return;
    final file = File(path);
    await file.delete();
    // Not recursive: the picker's folder goes only when nothing else is in it.
    await file.parent.delete();
  } catch (_) {
    // The picker clears its cache on its own later.
  }
}

/// Lets the user pick another version of the song, then opens the null
/// test of it against [referencePath].
Future<void> pickAndShowAudioCompare(
  BuildContext context, {
  required String referencePath,
  int referenceSize = 0,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  void say(String message) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  PlatformFile? file;
  try {
    file = await FilePicker.pickFile(
      dialogTitle: l10n.audioComparePickTitle,
      type: FileType.custom,
      allowedExtensions: openAudioExtensions,
    );
  } catch (e) {
    if (context.mounted) {
      say(l10n.audioCompareErrorGeneric(context.friendlyError(e)));
    }
    return;
  }
  final path = file?.path;
  if (file == null || path == null || !context.mounted) return;
  final otherSize = await file.length().catchError((_) => null) ?? 0;
  if (!context.mounted) return;
  if (isSameAudioCompareFile(
    referencePath: referencePath,
    referenceSize: referenceSize,
    otherPath: path,
    otherName: file.name,
    otherSize: otherSize,
  )) {
    say(l10n.audioCompareSameFile);
    await _deleteAudioComparePickerCopy(path, referencePath);
    return;
  }
  await showAppScrollableBottomSheet<void>(
    context: context,
    title: l10n.audioCompareTitle,
    subtitle: file.name,
    dialogSize: AppDialogSize.wide,
    builder: (context, controller) => AudioComparePanel(
      referencePath: referencePath,
      otherPath: path,
      controller: controller,
    ),
  );
  await _deleteAudioComparePickerCopy(path, referencePath);
}

String _mediaSource(MediaItem? item) {
  final source = item?.extras?['source']?.toString() ?? '';
  return source.startsWith('EXISTS:') ? source.substring(7) : source;
}

/// Runs the null test while it is shown; closing it cancels the run and
/// removes its temporary files.
class AudioComparePanel extends ConsumerStatefulWidget {
  const AudioComparePanel({
    super.key,
    required this.referencePath,
    required this.otherPath,
    this.controller,
  });

  final String referencePath;
  final String otherPath;
  final ScrollController? controller;

  @override
  ConsumerState<AudioComparePanel> createState() => _AudioComparePanelState();
}

class _AudioComparePanelState extends ConsumerState<AudioComparePanel> {
  final _engine = AudioCompareEngine();
  AudioCompareStage? _stage = AudioCompareStage.preparing;
  AudioCompareResult? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _engine.dispose();
    _result?.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _stage = AudioCompareStage.preparing;
      _error = null;
    });
    try {
      final result = await _engine.compare(
        referencePath: widget.referencePath,
        otherPath: widget.otherPath,
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (!mounted) {
        result.dispose();
        return;
      }
      setState(() {
        _result?.dispose();
        _result = result;
        _stage = null;
      });
    } on AudioAnalysisCancelled {
      // Closing the sheet cancelled the run; nothing is left to show.
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _stage = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only the song this device or the active remote is playing can seek.
    final playing = ref.watch(
      currentMediaItemProvider.select(
        (state) => _mediaSource(state.value) == widget.referencePath,
      ),
    );
    return AudioCompareView(
      controller: widget.controller,
      stage: _stage,
      result: _result,
      error: _error,
      onCancel: () => Navigator.of(context).maybePop(),
      onRetry: _run,
      onSeek: playing
          ? (seconds) => unawaited(
              ref
                  .read(musicPlayerControllerProvider)
                  .seek(Duration(milliseconds: (seconds * 1000).round())),
            )
          : null,
    );
  }
}

/// The progress, error or result of a null test.
class AudioCompareView extends StatelessWidget {
  const AudioCompareView({
    super.key,
    this.controller,
    this.stage,
    this.result,
    this.error,
    this.onCancel,
    this.onRetry,
    this.onSeek,
  });

  final ScrollController? controller;

  /// The running step, or null once finished.
  final AudioCompareStage? stage;
  final AudioCompareResult? result;
  final Object? error;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  /// Seeks the playing reference; null when it is not playing.
  final ValueChanged<double>? onSeek;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final result = this.result;
    final error = this.error;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = settingsHorizontalInset(context, constraints.maxWidth);
        Widget padded(Widget child) => Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: child,
        );
        final children = <Widget>[
          if (stage != null)
            padded(_CompareProgress(stage: stage!, onCancel: onCancel))
          else if (error != null)
            padded(
              _CompareNotice(
                key: const ValueKey('audio-compare-error'),
                icon: Icons.error_outline,
                lines: [_audioCompareErrorMessage(context, error)],
                action:
                    error is AudioCompareException &&
                        error.failure == AudioCompareFailure.decodeFailed
                    ? onRetry
                    : null,
              ),
            )
          else if (result != null)
            ..._buildResult(context, result, padded),
          SizedBox(height: tokens.gapLg),
        ];
        return SingleChildScrollView(
          controller: controller,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }

  List<Widget> _buildResult(
    BuildContext context,
    AudioCompareResult result,
    Widget Function(Widget) padded,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final cs = theme.colorScheme;
    return [
      if (!result.meaningful) ...[
        padded(
          _CompareNotice(
            key: const ValueKey('audio-compare-notice'),
            icon: Icons.warning_amber_rounded,
            warning: true,
            title: l10n.audioCompareNoticeTitle,
            lines: [
              for (final notice in result.notices)
                _audioCompareNoticeText(context, result, notice),
              l10n.audioCompareNoticeFooter,
            ],
          ),
        ),
        SizedBox(height: tokens.gapMd),
      ],
      padded(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _audioCompareLevelText(context, result.level),
              style: theme.textTheme.titleMedium,
            ),
            for (final line in _audioCompareDetailLines(context, result)) ...[
              SizedBox(height: tokens.gapXs),
              Text(
                line,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      SettingsSectionHeader(title: l10n.audioCompareTimelineTitle),
      _CompareGroup(
        children: [
          Padding(
            padding: EdgeInsets.all(tokens.gapMd),
            child: _ResidualTimeline(result: result, onSeek: onSeek),
          ),
        ],
      ),
      SettingsSectionHeader(title: l10n.audioCompareSummaryTitle),
      _CompareGroup(children: _summaryRows(context, result)),
      if (result.spectrogram case final image?) ...[
        SettingsSectionHeader(title: l10n.audioCompareSpectrogramTitle),
        padded(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SpectrogramView(
                image: image,
                sampleRate: result.sampleRate,
                maxFreq: result.sampleRate / 2,
                duration: result.durationSeconds,
                channels: 1,
                selectedChannel: -1,
                channelLoading: false,
                onChannelChanged: (_) {},
                onSave: null,
                canSave: false,
              ),
              SizedBox(height: tokens.gapXs),
              Text(
                l10n.audioCompareSpectrogramCaption,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
      SizedBox(height: tokens.gapMd),
      padded(const _CompareExplanation()),
    ];
  }

  List<Widget> _summaryRows(BuildContext context, AudioCompareResult result) {
    final l10n = context.l10n;
    final rows = <({String label, String value, String? detail})>[
      (
        label: l10n.audioCompareReference,
        value: result.reference.name,
        detail: _audioCompareFileDetail(context, result.reference),
      ),
      (
        label: l10n.audioCompareOther,
        value: result.other.name,
        detail: _audioCompareFileDetail(context, result.other),
      ),
      (
        label: l10n.audioCompareOffset,
        value: l10n.audioCompareOffsetValue(
          result.offsetFrames.toString(),
          result.offsetMs.toStringAsFixed(1),
        ),
        detail: result.offsetFrames > 0
            ? l10n.audioCompareOffsetLater
            : result.offsetFrames < 0
            ? l10n.audioCompareOffsetEarlier
            : null,
      ),
      (
        label: l10n.audioCompareGain,
        value: _signedDb(result.gainDb, digits: 2),
        detail: result.polarityInverted
            ? l10n.audioCompareGainInverted
            : l10n.audioCompareGainDetail,
      ),
      (
        label: l10n.audioCompareOverall,
        value: _formatDb(result.overallDb),
        detail: l10n.audioCompareOverallDetail,
      ),
      (
        label: l10n.audioCompareMatch,
        value: '${(result.correlation * 100).toStringAsFixed(2)}%',
        detail: null,
      ),
      if (result.resampled)
        (
          label: l10n.audioAnalysisSampleRate,
          value: _formatKHz(result.sampleRate),
          detail: l10n.audioCompareNoteResampled(_formatKHz(result.sampleRate)),
        ),
      if (result.channelsConverted)
        (
          label: l10n.audioAnalysisChannels,
          value: result.channels == 1
              ? l10n.audioAnalysisMono
              : l10n.audioAnalysisStereo,
          detail: l10n.audioCompareNoteChannels,
        ),
    ];
    return [
      for (final (index, row) in rows.indexed)
        _CompareRow(
          label: row.label,
          value: row.value,
          detail: row.detail,
          last: index == rows.length - 1,
        ),
    ];
  }
}

String _formatKHz(int hz) {
  final khz = hz / 1000;
  return '${khz == khz.roundToDouble() ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)} kHz';
}

String _formatDb(double db) {
  if (db <= audioCompareFloorDb) return '-${(-audioCompareFloorDb).round()} dB';
  return '${db.toStringAsFixed(1)} dB';
}

String _signedDb(double db, {int digits = 1}) =>
    '${db > 0 ? '+' : ''}${db.toStringAsFixed(digits)} dB';

String _audioCompareFileDetail(
  BuildContext context,
  AudioCompareFileInfo file,
) {
  final l10n = context.l10n;
  return [
    if (file.codec.isNotEmpty) file.codec,
    if (file.sampleRate > 0) _formatKHz(file.sampleRate),
    if (file.bitsPerSample > 0) '${file.bitsPerSample}-bit',
    if (file.channels == 1)
      l10n.audioAnalysisMono
    else if (file.channels == 2)
      l10n.audioAnalysisStereo
    else if (file.channels > 2)
      '${file.channels} ch',
    if (file.durationSeconds > 0) formatClock(file.durationSeconds),
  ].join(' · ');
}

String _audioCompareErrorMessage(BuildContext context, Object error) {
  final l10n = context.l10n;
  return switch (error) {
    UnsupportedAudioAnalysisCodecException(:final codecLabel) =>
      '${l10n.snackbarUnsupportedAudioFormat}: $codecLabel',
    AudioCompareException(
      failure: AudioCompareFailure.unreadable,
      :final fileName,
    ) =>
      l10n.audioCompareErrorUnreadable(fileName ?? ''),
    AudioCompareException(failure: AudioCompareFailure.tooShort) =>
      l10n.audioCompareErrorTooShort,
    AudioCompareException(failure: AudioCompareFailure.decodeFailed) =>
      l10n.audioCompareErrorDecode,
    _ => l10n.audioCompareErrorGeneric(context.friendlyError(error)),
  };
}

String _audioCompareLevelText(BuildContext context, AudioCompareLevel level) {
  final l10n = context.l10n;
  return switch (level) {
    AudioCompareLevel.identical => l10n.audioCompareLevelIdentical,
    AudioCompareLevel.nearlyIdentical => l10n.audioCompareLevelNearlyIdentical,
    AudioCompareLevel.mostlyIdentical => l10n.audioCompareLevelMostlyIdentical,
    AudioCompareLevel.moderate => l10n.audioCompareLevelModerate,
    AudioCompareLevel.large => l10n.audioCompareLevelLarge,
  };
}

List<String> _audioCompareDetailLines(
  BuildContext context,
  AudioCompareResult result,
) {
  final l10n = context.l10n;
  final band = switch (result.band) {
    AudioCompareBand.high => l10n.audioCompareBandHigh,
    AudioCompareBand.low => l10n.audioCompareBandLow,
    AudioCompareBand.broadband => l10n.audioCompareBandBroadband,
    AudioCompareBand.none => null,
  };
  final peak = result.peak;
  return [
    if (result.meaningful && band != null) band,
    if (peak != null &&
        result.level.index >= AudioCompareLevel.mostlyIdentical.index)
      l10n.audioComparePeak(formatClock(peak.seconds), _formatDb(peak.db)),
  ];
}

String _audioCompareNoticeText(
  BuildContext context,
  AudioCompareResult result,
  AudioCompareNotice notice,
) {
  final l10n = context.l10n;
  return switch (notice) {
    AudioCompareNotice.weakAlignment => l10n.audioCompareNoticeWeakAlignment,
    AudioCompareNotice.residualHigh => l10n.audioCompareNoticeResidualHigh,
    AudioCompareNotice.drift => l10n.audioCompareNoticeDrift(
      (result.driftMs ?? 0).abs().toStringAsFixed(1),
    ),
    AudioCompareNotice.durationMismatch => l10n.audioCompareNoticeDuration(
      ((result.other.durationSeconds - result.offsetMs / 1000) -
              result.reference.durationSeconds)
          .abs()
          .toStringAsFixed(1),
    ),
  };
}

/// What a null test is, folded away until asked for.
class _CompareExplanation extends StatefulWidget {
  const _CompareExplanation();

  @override
  State<_CompareExplanation> createState() => _CompareExplanationState();
}

class _CompareExplanationState extends State<_CompareExplanation> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = context.tokens;
    // The chevron turns on the fast spatial spring and the text unfolds on
    // the default one; reduced motion changes both at once.
    const still = AppMotionSpec(Duration.zero, Curves.linear);
    final turn = AppMotion.spatialFast(
      context,
      still,
      mornye: MornyeMotion.fast,
    );
    final unfold = AppMotion.spatial(
      context,
      still,
      mornye: MornyeMotion.standard,
    );
    final body = _open
        ? Padding(
            padding: EdgeInsets.only(top: tokens.gapXs),
            child: Text(
              l10n.audioCompareExplainBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            key: const ValueKey('audio-compare-explain'),
            borderRadius: BorderRadius.circular(tokens.gapSm),
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
              child: Row(
                children: [
                  AppIcon.adaptive(
                    Icons.help_outline,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  SizedBox(width: tokens.gapSm),
                  Expanded(
                    child: Text(
                      l10n.audioCompareExplainTitle,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: turn.duration,
                    curve: turn.curve,
                    child: AppIcon.adaptive(
                      Icons.expand_more,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // A zero-length AnimatedSize re-dirties itself during layout.
        if (unfold.duration == Duration.zero)
          body
        else
          AnimatedSize(
            duration: unfold.duration,
            curve: unfold.curve,
            alignment: Alignment.topCenter,
            child: body,
          ),
      ],
    );
  }
}

class _CompareProgress extends StatelessWidget {
  const _CompareProgress({required this.stage, this.onCancel});

  final AudioCompareStage stage;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final total = AudioCompareStage.values.length;
    final label = switch (stage) {
      AudioCompareStage.preparing => l10n.audioCompareStagePreparing,
      AudioCompareStage.aligning => l10n.audioCompareStageAligning,
      AudioCompareStage.measuring => l10n.audioCompareStageMeasuring,
      AudioCompareStage.spectrogram => l10n.audioCompareStageSpectrogram,
    };
    final cancel = Text(l10n.dialogCancel);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.gapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppLoadingIndicator(size: 28, strokeWidth: 2.5),
              SizedBox(width: tokens.gapMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.titleSmall),
                    Text(
                      l10n.audioCompareStepLabel(
                        (stage.index + 1).toString(),
                        total.toString(),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.gapLg),
          AppProgressIndicator.linear(
            value: (stage.index + 1) / (total + 1),
            semanticsLabel: label,
          ),
          SizedBox(height: tokens.gapMd),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: context.isMornye
                ? CupertinoButton(
                    key: const ValueKey('audio-compare-cancel'),
                    minimumSize: Size.square(tokens.minTouchTarget),
                    onPressed: onCancel,
                    child: cancel,
                  )
                : ExpressiveButton(
                    key: const ValueKey('audio-compare-cancel'),
                    text: true,
                    onPressed: onCancel,
                    child: cancel,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The notice of the result sheet, laid out as [ErrorCard]. A [warning]
/// (the result stands but may mean little) takes the tertiary container
/// instead of the error container.
class _CompareNotice extends StatelessWidget {
  const _CompareNotice({
    super.key,
    required this.icon,
    this.title,
    required this.lines,
    this.action,
    this.warning = false,
  });

  final IconData icon;
  final String? title;
  final List<String> lines;

  /// Retries the comparison.
  final VoidCallback? action;

  final bool warning;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final foreground = warning ? cs.onTertiaryContainer : cs.onErrorContainer;
    final body = theme.textTheme.bodyMedium?.copyWith(color: foreground);
    return AppContentCard(
      elevation: 0,
      color: warning ? cs.tertiaryContainer : cs.errorContainer,
      mornyeSurface: false,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: tokens.borderRadiusCard),
      child: Padding(
        padding: EdgeInsets.all(tokens.gapLg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon.adaptive(icon, color: foreground),
            SizedBox(width: tokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: body?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: tokens.gapXs),
                  ],
                  for (final (index, line) in lines.indexed) ...[
                    if (index > 0) SizedBox(height: tokens.gapXs),
                    Text(line, style: body),
                  ],
                  if (action != null) ...[
                    SizedBox(height: tokens.gapMd),
                    context.isMornye
                        ? CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.square(tokens.minTouchTarget),
                            onPressed: action,
                            child: Text(
                              context.l10n.dialogRetry,
                              style: body?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : ExpressiveButton(
                            tonal: true,
                            onPressed: action,
                            child: Text(context.l10n.dialogRetry),
                          ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One grouped surface of the result sheet, as the Audio info sheet groups
/// its facts.
class _CompareGroup extends StatelessWidget {
  const _CompareGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      return SettingsGroup(connected: true, children: children);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: MornyeTheme.controlFill(context),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _CompareRow extends StatelessWidget {
  const _CompareRow({
    required this.label,
    required this.value,
    this.detail,
    required this.last,
  });

  final String label;
  final String value;
  final String? detail;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final inset = mornye ? 16.0 : tokens.rowPaddingH;
    return MergeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: inset,
                vertical: tokens.rowPaddingVCompact,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) => Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(label, style: theme.textTheme.bodyLarge),
                        ),
                        SizedBox(width: tokens.gapMd),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.55,
                          ),
                          child: Text(
                            value,
                            textAlign: TextAlign.end,
                            style:
                                (mornye
                                        ? theme.textTheme.bodyLarge
                                        : theme.textTheme.bodyMedium)
                                    ?.copyWith(
                                      color: cs.onSurfaceVariant,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (detail case final detail?) ...[
                    SizedBox(height: tokens.gapXs),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!last && !settingsRowsConnected(context))
            Divider(
              height: 1,
              indent: inset,
              endIndent: mornye ? 0 : inset,
              color: mornye
                  ? MornyeTheme.metadataDividerColor(context)
                  : cs.outlineVariant.withValues(alpha: 0.3),
            ),
        ],
      ),
    );
  }
}

/// The residual over the song: a line on a dB scale, filled with the accent
/// where the files differ and muted where they cancel. A tap or drag reads
/// one window.
class _ResidualTimeline extends StatefulWidget {
  const _ResidualTimeline({required this.result, this.onSeek});

  final AudioCompareResult result;
  final ValueChanged<double>? onSeek;

  @override
  State<_ResidualTimeline> createState() => _ResidualTimelineState();
}

class _ResidualTimelineState extends State<_ResidualTimeline> {
  AudioCompareChannel _channel = AudioCompareChannel.combined;
  int? _selected;
  late List<double> _values;
  late (double, double) _range;
  AudioComparePeak? _peak;

  @override
  void initState() {
    super.initState();
    _recomputeSeries();
  }

  @override
  void didUpdateWidget(_ResidualTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.result, widget.result)) {
      _recomputeSeries();
    }
  }

  void _recomputeSeries() {
    _values = audioCompareSeries(widget.result.windows, _channel);
    _range = _audioCompareRange(_values);
    _peak = audioComparePeakFor(widget.result.windows, _channel);
  }

  void _setChannel(AudioCompareChannel channel) {
    if (_channel == channel) return;
    setState(() {
      _channel = channel;
      _recomputeSeries();
    });
  }

  void _select(Offset position, double width) {
    final windows = widget.result.windows;
    if (windows.isEmpty) return;
    final plot = width - _ResidualTimelinePainter.leftGutter;
    if (plot <= 0) return;
    final ratio = ((position.dx - _ResidualTimelinePainter.leftGutter) / plot)
        .clamp(0.0, 1.0);
    final index = (ratio * windows.length).floor().clamp(0, windows.length - 1);
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = context.tokens;
    final result = widget.result;
    final values = _values;
    final range = _range;
    final selected = _selected;
    final peak = _peak;
    final stereo = result.channels > 1;
    final labels = [
      l10n.audioCompareChannelBoth,
      l10n.audioCompareChannelLeft,
      l10n.audioCompareChannelRight,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stereo) ...[
          if (context.isMornye)
            MornyeSegmentedControl(
              labels: labels,
              selectedIndex: _channel.index,
              samplesBackdrop: false,
              onChanged: (index) =>
                  _setChannel(AudioCompareChannel.values[index]),
            )
          else
            SettingsSegmentedChoice<AudioCompareChannel>(
              options: [
                for (final channel in AudioCompareChannel.values)
                  SettingsSegmentOption(
                    value: channel,
                    label: labels[channel.index],
                  ),
              ],
              selected: _channel,
              onChanged: _setChannel,
            ),
          SizedBox(height: tokens.gapMd),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = (width * 0.42).clamp(160.0, 280.0);
            return Semantics(
              label: l10n.audioCompareTimelineTitle,
              value: peak == null
                  ? _audioCompareLevelText(context, result.level)
                  : l10n.audioComparePeak(
                      formatClock(peak.seconds),
                      _formatDb(peak.db),
                    ),
              child: GestureDetector(
                key: const ValueKey('audio-compare-timeline'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => _select(details.localPosition, width),
                onHorizontalDragStart: (details) =>
                    _select(details.localPosition, width),
                onHorizontalDragUpdate: (details) =>
                    _select(details.localPosition, width),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: CustomPaint(
                          size: Size(width, height),
                          painter: _ResidualTimelinePainter(
                            values: values,
                            duration: result.durationSeconds,
                            minDb: range.$1,
                            maxDb: range.$2,
                            accent: cs.primary,
                            muted: cs.outlineVariant,
                            grid: cs.outlineVariant.withValues(alpha: 0.5),
                            label: cs.onSurfaceVariant,
                            labelStyle:
                                theme.textTheme.labelSmall ??
                                const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                      if (selected != null)
                        RepaintBoundary(
                          child: CustomPaint(
                            size: Size(width, height),
                            painter: _ResidualTimelineSelectionPainter(
                              values: values,
                              minDb: range.$1,
                              maxDb: range.$2,
                              selected: selected,
                              accent: cs.primary,
                              label: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        SizedBox(height: tokens.gapSm),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selected == null
                      ? l10n.audioCompareTimelineHint
                      : '${formatClock(result.windows[selected].startSeconds)}'
                            '   ${_formatDb(values[selected])}',
                  key: const ValueKey('audio-compare-readout'),
                  style:
                      (selected == null
                              ? theme.textTheme.bodySmall
                              : theme.textTheme.titleSmall)
                          ?.copyWith(
                            color: selected == null
                                ? cs.onSurfaceVariant
                                : cs.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                ),
              ),
              if (selected != null && widget.onSeek != null)
                context.isMornye
                    ? CupertinoButton(
                        key: const ValueKey('audio-compare-seek'),
                        minimumSize: Size.square(tokens.minTouchTarget),
                        padding: EdgeInsets.symmetric(horizontal: tokens.gapSm),
                        onPressed: () => widget.onSeek!(
                          result.windows[selected].startSeconds,
                        ),
                        child: Text(l10n.audioComparePlayFromHere),
                      )
                    : ExpressiveButton(
                        key: const ValueKey('audio-compare-seek'),
                        tonal: true,
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        onPressed: () => widget.onSeek!(
                          result.windows[selected].startSeconds,
                        ),
                        child: Text(l10n.audioComparePlayFromHere),
                      ),
            ],
          ),
        ),
        Text(
          l10n.audioCompareTimelineCaption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The dB range of the timeline: the floor up to at least 0 dB, tightened
/// to the quietest real difference so a lossy residual fills the plot.
(double, double) _audioCompareRange(List<double> values) {
  final real = [
    for (final value in values)
      if (value > audioCompareFloorDb) value,
  ]..sort();
  var maxDb = 0.0;
  if (real.isNotEmpty && real.last > 0) {
    maxDb = (real.last / 10).ceil() * 10.0;
  }
  if (real.isEmpty) return (audioCompareFloorDb, maxDb);
  final low = real[(real.length * 0.05).floor()] - 10;
  final minDb = ((low / 20).floor() * 20.0).clamp(audioCompareFloorDb, -40.0);
  return (minDb, maxDb);
}

class _ResidualTimelinePainter extends CustomPainter {
  _ResidualTimelinePainter({
    required this.values,
    required this.duration,
    required this.minDb,
    required this.maxDb,
    required this.accent,
    required this.muted,
    required this.grid,
    required this.label,
    required this.labelStyle,
  });

  static const double leftGutter = 40;
  static const double bottomGutter = 18;

  final List<double> values;
  final double duration;
  final double minDb;
  final double maxDb;
  final Color accent;
  final Color muted;
  final Color grid;
  final Color label;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      leftGutter,
      4,
      size.width,
      size.height - bottomGutter,
    );
    if (plot.width <= 0 || plot.height <= 0) return;
    double yFor(double db) =>
        plot.bottom -
        ((db.clamp(minDb, maxDb) - minDb) / (maxDb - minDb)) * plot.height;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final step = (maxDb - minDb) > 60 ? 20.0 : 10.0;
    for (var db = maxDb; db >= minDb - 0.001; db -= step) {
      final y = yFor(db);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(
        canvas,
        '${db.round()}',
        Offset(plot.left - 6, y),
        rightAlign: true,
      );
    }
    if (duration > 0) {
      final seconds = _SpectrogramPainter._niceStepSec(duration);
      for (var t = 0.0; t <= duration + 0.001; t += seconds) {
        final x = plot.left + t / duration * plot.width;
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
        _text(canvas, formatClock(t), Offset(x, plot.bottom + 3), top: true);
      }
    }

    if (values.isNotEmpty) {
      final line = Path();
      final fill = Path()..moveTo(plot.left, plot.bottom);
      for (var i = 0; i < values.length; i++) {
        final x = plot.left + (i + 0.5) / values.length * plot.width;
        final y = yFor(values[i]);
        if (i == 0) {
          line.moveTo(x, y);
        } else {
          line.lineTo(x, y);
        }
        fill.lineTo(x, y);
      }
      fill
        ..lineTo(plot.right, plot.bottom)
        ..close();
      // Louder differences take the accent; the floor stays muted.
      final shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [accent, accent, muted],
        stops: const [0, 0.35, 1],
      ).createShader(plot);
      canvas.save();
      canvas.clipRect(plot);
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: 0.45),
              accent.withValues(alpha: 0.12),
              muted.withValues(alpha: 0),
            ],
            stops: const [0, 0.6, 1],
          ).createShader(plot),
      );
      canvas.drawPath(
        line,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.restore();
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset anchor, {
    bool rightAlign = false,
    bool top = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: labelStyle.copyWith(color: label),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    try {
      final dx = rightAlign
          ? anchor.dx - painter.width
          : anchor.dx - painter.width / 2;
      final dy = top ? anchor.dy : anchor.dy - painter.height / 2;
      painter.paint(canvas, Offset(dx, dy));
    } finally {
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _ResidualTimelinePainter old) =>
      !identical(old.values, values) ||
      old.duration != duration ||
      old.minDb != minDb ||
      old.maxDb != maxDb ||
      old.accent != accent ||
      old.muted != muted ||
      old.grid != grid ||
      old.label != label ||
      old.labelStyle != labelStyle;
}

class _ResidualTimelineSelectionPainter extends CustomPainter {
  _ResidualTimelineSelectionPainter({
    required this.values,
    required this.minDb,
    required this.maxDb,
    required this.selected,
    required this.accent,
    required this.label,
  });

  final List<double> values;
  final double minDb;
  final double maxDb;
  final int selected;
  final Color accent;
  final Color label;

  @override
  void paint(Canvas canvas, Size size) {
    if (selected < 0 || selected >= values.length) return;
    final plot = Rect.fromLTRB(
      _ResidualTimelinePainter.leftGutter,
      4,
      size.width,
      size.height - _ResidualTimelinePainter.bottomGutter,
    );
    if (plot.width <= 0 || plot.height <= 0) return;
    final x = plot.left + (selected + 0.5) / values.length * plot.width;
    final y =
        plot.bottom -
        ((values[selected].clamp(minDb, maxDb) - minDb) / (maxDb - minDb)) *
            plot.height;
    canvas.drawLine(
      Offset(x, plot.top),
      Offset(x, plot.bottom),
      Paint()
        ..color = label
        ..strokeWidth = 1,
    );
    canvas.drawCircle(Offset(x, y), 4, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant _ResidualTimelineSelectionPainter old) =>
      !identical(old.values, values) ||
      old.selected != selected ||
      old.minDb != minDb ||
      old.maxDb != maxDb ||
      old.accent != accent ||
      old.label != label;
}
