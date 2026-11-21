part of 'audio_analysis_widget.dart';

class _SpectrogramView extends StatelessWidget {
  final ui.Image image;
  final int sampleRate;
  final double maxFreq;
  final double duration;
  final int channels;
  final int selectedChannel;
  final bool channelLoading;
  final ValueChanged<int> onChannelChanged;

  /// Saves the plot as an image; null while a save or channel load runs.
  final VoidCallback? onSave;

  /// Shows the save button. Off for plots that are not a file's own, such
  /// as the null test residual.
  final bool canSave;

  const _SpectrogramView({
    required this.image,
    required this.sampleRate,
    required this.maxFreq,
    required this.duration,
    required this.channels,
    required this.selectedChannel,
    required this.channelLoading,
    required this.onChannelChanged,
    required this.onSave,
    this.canSave = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const labelColor = Color(0xFFB5B5B5);

    final card = AppContentCard(
      preserveColor: true,
      color: Colors.black,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (channels > 1 || canSave)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: channels > 1
                        ? SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                AppChoiceChip(
                                  singleChoice: true,
                                  label: Text(
                                    context.l10n.audioAnalysisChannels,
                                  ),
                                  selected: selectedChannel < 0,
                                  onSelected: channelLoading
                                      ? null
                                      : (_) => onChannelChanged(-1),
                                ),
                                for (
                                  var channel = 0;
                                  channel < channels;
                                  channel++
                                ) ...[
                                  const SizedBox(width: 6),
                                  AppChoiceChip(
                                    singleChoice: true,
                                    label: Text('Ch ${channel + 1}'),
                                    selected: selectedChannel == channel,
                                    onSelected: channelLoading
                                        ? null
                                        : (_) => onChannelChanged(channel),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (canSave)
                    AppIconButton(
                      key: const ValueKey('audio-analysis-save-spectrogram'),
                      icon: const AppIcon.adaptive(
                        Icons.download_outlined,
                        size: 20,
                      ),
                      tooltip: context.l10n.audioAnalysisSaveSpectrogram,
                      color: labelColor,
                      onPressed: onSave,
                    ),
                ],
              ),
            ),
          if (channelLoading)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: AppProgressIndicator.linear(minHeight: 2),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const leftGutter = 34.0;
                const bottomGutter = 18.0;
                final plotWidth = constraints.maxWidth - leftGutter;
                final plotHeight = plotWidth / 2.0;
                final totalHeight = plotHeight + bottomGutter;
                return SizedBox(
                  width: constraints.maxWidth,
                  height: totalHeight,
                  child: CustomPaint(
                    painter: _SpectrogramPainter(
                      image: image,
                      maxFreqHz: maxFreq,
                      durationSec: duration,
                      labelColor: labelColor,
                      gridColor: Colors.white.withValues(alpha: 0.10),
                    ),
                    size: Size(constraints.maxWidth, totalHeight),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 10, 8),
            child: Row(
              children: [
                const Text(
                  '-120 dBFS',
                  style: TextStyle(color: labelColor, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: LinearGradient(colors: _legendColors()),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '0 dBFS',
                  style: TextStyle(color: labelColor, fontSize: 11),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.25)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text(
                  '${context.l10n.audioAnalysisSampleRate}: $sampleRate Hz',
                  style: const TextStyle(color: labelColor, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  '${context.l10n.audioAnalysisNyquist}: ${(maxFreq / 1000).toStringAsFixed(1)} kHz',
                  style: const TextStyle(color: labelColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // The plot stays black in both appearances; its controls need matching
    // contrast even when the surrounding Mornye page uses the light theme.
    return context.isMornye
        ? Theme(
            data: MornyeTheme.fromContext(context, brightness: Brightness.dark),
            child: card,
          )
        : card;
  }

  static List<Color> _legendColors() {
    return List.generate(20, (i) {
      final c = _spekColorRGB(i / 19.0);
      return Color.fromARGB(255, c[0], c[1], c[2]);
    });
  }
}

class _SpectrogramPainter extends CustomPainter {
  final ui.Image image;
  final double maxFreqHz;
  final double durationSec;
  final Color labelColor;
  final Color gridColor;

  static const double leftGutter = 34;
  static const double bottomGutter = 18;

  _SpectrogramPainter({
    required this.image,
    required this.maxFreqHz,
    required this.durationSec,
    required this.labelColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      leftGutter,
      0,
      size.width - leftGutter,
      size.height - bottomGutter,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      plot,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    // Frequency axis (Y): 0 Hz at the bottom, maxFreq at the top.
    final maxKHz = maxFreqHz / 1000.0;
    if (maxKHz > 0) {
      final stepKHz = _niceStepKHz(maxKHz);
      for (double fk = 0; fk <= maxKHz + 0.001; fk += stepKHz) {
        final ratio = (fk * 1000) / maxFreqHz;
        final y = plot.bottom - ratio * plot.height;
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
        _drawText(
          canvas,
          fk == 0 ? '0' : '${fk.toStringAsFixed(0)}k',
          Offset(plot.left - 5, y),
          align: _TextAlignV.rightCenter,
        );
      }
    }

    if (durationSec > 0) {
      final stepSec = _niceStepSec(durationSec);
      for (double ts = 0; ts <= durationSec + 0.001; ts += stepSec) {
        final ratio = ts / durationSec;
        final x = plot.left + ratio * plot.width;
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
        _drawText(
          canvas,
          formatClock(ts),
          Offset(x, plot.bottom + 3),
          align: _TextAlignV.topCenter,
        );
      }
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset anchor, {
    required _TextAlignV align,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: labelColor, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    try {
      double dx = anchor.dx;
      double dy = anchor.dy;
      switch (align) {
        case _TextAlignV.rightCenter:
          dx = anchor.dx - tp.width;
          dy = anchor.dy - tp.height / 2;
          break;
        case _TextAlignV.topCenter:
          dx = anchor.dx - tp.width / 2;
          dy = anchor.dy;
          break;
      }
      tp.paint(canvas, Offset(dx, dy));
    } finally {
      tp.dispose();
    }
  }

  static double _niceStepKHz(double maxKHz) {
    const candidates = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0];
    for (final c in candidates) {
      if (maxKHz / c <= 6) return c;
    }
    return 100.0;
  }

  static double _niceStepSec(double dur) {
    const candidates = [5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0];
    for (final c in candidates) {
      if (dur / c <= 6) return c;
    }
    return 1200.0;
  }

  @override
  bool shouldRepaint(covariant _SpectrogramPainter old) =>
      old.image != image ||
      old.maxFreqHz != maxFreqHz ||
      old.durationSec != durationSec ||
      old.labelColor != labelColor ||
      old.gridColor != gridColor;
}

enum _TextAlignV { rightCenter, topCenter }

final _invalidExportNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1F]');

/// The file name stem for a saved spectrogram: [exportName] when it has
/// one, otherwise the audio file's name without its extension. Content and
/// network URIs use their decoded last path segment.
String audioSpectrogramExportBaseName(String filePath, {String? exportName}) {
  String sanitize(String value) => value
      .replaceAll(_invalidExportNameChars, '_')
      .trim()
      .replaceAll(RegExp(r'^\.+|\.+$'), '');

  final named = sanitize(exportName ?? '');
  if (named.isNotEmpty) return named;

  var name = filePath;
  final uri = Uri.tryParse(filePath);
  // One-letter schemes are Windows drive letters, not URIs.
  if (uri != null && uri.scheme.length > 1) {
    name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  }
  // SAF document IDs keep their folders after decoding ("primary:Music/a").
  name = name.split(RegExp(r'[/\\:]')).last;
  final stem = sanitize(p.basenameWithoutExtension(name));
  return stem.isEmpty ? 'audio' : stem;
}

/// Draws the spectrogram as the card shows it (axes, grid and the dBFS
/// legend) under a [title] and a line of [details], and encodes it as PNG.
/// [scale] multiplies the logical layout into image pixels.
Future<Uint8List> renderAudioSpectrogramPng({
  required ui.Image image,
  required String title,
  required int sampleRate,
  required double duration,
  List<String> details = const [],
  double scale = 2,
}) async {
  const labelColor = Color(0xFFB5B5B5);
  const padding = 16.0;
  const plotWidth = 800.0;
  const plotHeight = plotWidth / 2;
  const legendHeight = 8.0;
  const chartWidth = _SpectrogramPainter.leftGutter + plotWidth;
  const chartHeight = plotHeight + _SpectrogramPainter.bottomGutter;

  TextPainter text(String value, TextStyle style) => TextPainter(
    text: TextSpan(text: value, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '...',
  )..layout(maxWidth: chartWidth);

  final titlePainter = text(
    title,
    const TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
  );
  final detailsPainter = text(
    details.join('   '),
    const TextStyle(color: labelColor, fontSize: 11),
  );
  const legendStyle = TextStyle(color: labelColor, fontSize: 11);
  final minLabel = text('-120 dBFS', legendStyle);
  final maxLabel = text('0 dBFS', legendStyle);

  final chartTop =
      padding + titlePainter.height + 4 + detailsPainter.height + 12;
  final legendTop = chartTop + chartHeight + 10;
  final legendRowHeight = math.max(legendHeight, minLabel.height);
  final width = padding * 2 + chartWidth;
  final height = legendTop + legendRowHeight + padding;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = Colors.black,
  );
  titlePainter.paint(canvas, const Offset(padding, padding));
  detailsPainter.paint(
    canvas,
    Offset(padding, padding + titlePainter.height + 4),
  );

  canvas.save();
  canvas.translate(padding, chartTop);
  _SpectrogramPainter(
    image: image,
    maxFreqHz: sampleRate / 2,
    durationSec: duration,
    labelColor: labelColor,
    gridColor: Colors.white.withValues(alpha: 0.10),
  ).paint(canvas, const Size(chartWidth, chartHeight));
  canvas.restore();

  final barLeft = padding + _SpectrogramPainter.leftGutter;
  final barStart = barLeft + minLabel.width + 8;
  final barEnd = padding + chartWidth - maxLabel.width - 8;
  final rowCenter = legendTop + legendRowHeight / 2;
  minLabel.paint(canvas, Offset(barLeft, rowCenter - minLabel.height / 2));
  maxLabel.paint(canvas, Offset(barEnd + 8, rowCenter - maxLabel.height / 2));
  final bar = Rect.fromLTRB(
    barStart,
    rowCenter - legendHeight / 2,
    barEnd,
    rowCenter + legendHeight / 2,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(bar, const Radius.circular(4)),
    Paint()
      ..shader = LinearGradient(
        colors: _SpectrogramView._legendColors(),
      ).createShader(bar),
  );

  final picture = recorder.endRecording();
  final rendered = await picture.toImage(
    (width * scale).round(),
    (height * scale).round(),
  );
  picture.dispose();
  try {
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('Could not encode the spectrogram image');
    }
    return bytes.buffer.asUint8List();
  } finally {
    rendered.dispose();
  }
}

List<int> _spekColorRGB(double intensity) {
  int r, g, b;
  if (intensity < 0.08) {
    final t = intensity / 0.08;
    r = 0;
    g = 0;
    b = (t * 80).floor();
  } else if (intensity < 0.18) {
    final t = (intensity - 0.08) / 0.10;
    r = (t * 50).floor();
    g = (t * 30).floor();
    b = (80 + t * 175).floor();
  } else if (intensity < 0.28) {
    final t = (intensity - 0.18) / 0.10;
    r = (50 + t * 150).floor();
    g = (30 - t * 30).floor();
    b = (255 - t * 55).floor();
  } else if (intensity < 0.40) {
    final t = (intensity - 0.28) / 0.12;
    r = (200 + t * 55).floor();
    g = 0;
    b = (200 - t * 200).floor();
  } else if (intensity < 0.52) {
    final t = (intensity - 0.40) / 0.12;
    r = 255;
    g = (t * 100).floor();
    b = 0;
  } else if (intensity < 0.65) {
    final t = (intensity - 0.52) / 0.13;
    r = 255;
    g = (100 + t * 80).floor();
    b = 0;
  } else if (intensity < 0.78) {
    final t = (intensity - 0.65) / 0.13;
    r = 255;
    g = (180 + t * 55).floor();
    b = (t * 30).floor();
  } else if (intensity < 0.90) {
    final t = (intensity - 0.78) / 0.12;
    r = 255;
    g = (235 + t * 20).floor();
    b = (30 + t * 100).floor();
  } else {
    final t = (intensity - 0.90) / 0.10;
    r = 255;
    g = 255;
    b = (130 + t * 125).floor();
  }
  return [r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)];
}
