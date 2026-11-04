part of 'audio_analysis_widget.dart';

class _AudioInfoCard extends StatelessWidget {
  final AudioAnalysisData data;
  final VoidCallback? onRescan;

  const _AudioInfoCard({required this.data, this.onRescan});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nyquist = data.sampleRate / 2;

    return AppContentCard(
      elevation: 0,
      color: settingsGroupColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.audioAnalysisTitle,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (onRescan != null)
                  AppIconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: context.l10n.audioAnalysisRescan,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    color: cs.onSurfaceVariant,
                    onPressed: onRescan,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                if (data.codec.isNotEmpty)
                  _MetricChip(
                    icon: Icons.memory,
                    label: context.l10n.audioAnalysisCodec,
                    value: data.codec,
                    cs: cs,
                  ),
                if (data.container.isNotEmpty)
                  _MetricChip(
                    icon: Icons.inventory_2_outlined,
                    label: context.l10n.audioAnalysisContainer,
                    value: data.container,
                    cs: cs,
                  ),
                _MetricChip(
                  icon: Icons.graphic_eq,
                  label: context.l10n.audioAnalysisSampleRate,
                  value: '${(data.sampleRate / 1000).toStringAsFixed(1)} kHz',
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.audio_file,
                  label: context.l10n.audioAnalysisBitDepth,
                  value: data.bitDepth,
                  cs: cs,
                ),
                if (data.decodedSampleFormat.isNotEmpty)
                  _MetricChip(
                    icon: Icons.data_object,
                    label: context.l10n.audioAnalysisDecodedFormat,
                    value: data.decodedSampleFormat,
                    cs: cs,
                  ),
                if (data.bitrate > 0)
                  _MetricChip(
                    icon: Icons.speed,
                    label: data.bitrateIsFileAverage
                        ? context.l10n.audioAnalysisFileBitrate
                        : context.l10n.trackConvertBitrate,
                    value: formatAudioAnalysisBitrate(data.bitrate),
                    cs: cs,
                  ),
                _MetricChip(
                  icon: Icons.surround_sound,
                  label: context.l10n.audioAnalysisChannels,
                  value: _formatChannels(context, data),
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.timer_outlined,
                  label: context.l10n.audioAnalysisDuration,
                  value: formatClock(data.duration),
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.multiline_chart,
                  label: context.l10n.audioAnalysisNyquist,
                  value: '${(nyquist / 1000).toStringAsFixed(1)} kHz',
                  cs: cs,
                ),
                if (data.fileSize > 0)
                  _MetricChip(
                    icon: Icons.storage,
                    label: context.l10n.audioAnalysisFileSize,
                    value: formatBytes(data.fileSize),
                    cs: cs,
                  ),
              ],
            ),
            if (data.bitrate > 0 && data.bitrateIsFileAverage) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.audioAnalysisFileBitrateHint,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Divider(color: cs.outlineVariant),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _MetricChip(
                  icon: Icons.trending_up,
                  label: context.l10n.audioAnalysisDynamicRange,
                  value: '${data.dynamicRange.toStringAsFixed(2)} dB',
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.show_chart,
                  label: context.l10n.audioAnalysisPeak,
                  value: '${data.peakAmplitude.toStringAsFixed(2)} dB',
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.equalizer,
                  label: context.l10n.audioAnalysisRms,
                  value: '${data.rmsLevel.toStringAsFixed(2)} dB',
                  cs: cs,
                ),
                if (data.integratedLufs != null)
                  _MetricChip(
                    icon: Icons.volume_up_outlined,
                    label: context.l10n.audioAnalysisLufs,
                    value: '${data.integratedLufs!.toStringAsFixed(1)} LUFS',
                    cs: cs,
                  ),
                if (data.truePeakDb != null)
                  _MetricChip(
                    icon: Icons.warning_amber_outlined,
                    label: context.l10n.audioAnalysisTruePeak,
                    value: '${data.truePeakDb!.toStringAsFixed(2)} dBTP',
                    cs: cs,
                  ),
                _MetricChip(
                  icon: Icons.report_gmailerrorred_outlined,
                  label: context.l10n.audioAnalysisClipping,
                  value: _formatClipping(context, data.clippingSamples),
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.filter_alt_outlined,
                  label: context.l10n.audioAnalysisSpectralCutoff,
                  value: formatAudioAnalysisSpectralCutoff(
                    data.spectralCutoffHz,
                    notDetectedLabel:
                        context.l10n.audioAnalysisCutoffNotDetected,
                  ),
                  cs: cs,
                ),
                _MetricChip(
                  icon: Icons.numbers,
                  label: context.l10n.audioAnalysisSamples,
                  value: _formatNumber(data.totalSamples),
                  cs: cs,
                ),
              ],
            ),
            if (data.channelStats.length > 1) ...[
              const SizedBox(height: 8),
              Divider(color: cs.outlineVariant),
              const SizedBox(height: 8),
              Text(
                context.l10n.audioAnalysisChannelStats,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: data.channelStats.map((stats) {
                  return _MetricChip(
                    icon: Icons.surround_sound,
                    label: 'Ch ${stats.channel}',
                    value: _formatChannelStats(stats),
                    cs: cs,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatChannels(BuildContext context, AudioAnalysisData data) {
    final layout = data.channelLayout.trim();
    if (layout.isNotEmpty && layout != 'unknown') {
      return data.channels > 0 ? '${data.channels} ($layout)' : layout;
    }
    if (data.channels == 2) return context.l10n.audioAnalysisStereo;
    if (data.channels == 1) return context.l10n.audioAnalysisMono;
    return data.channels > 0 ? '${data.channels}' : 'N/A';
  }

  String _formatClipping(BuildContext context, int samples) {
    if (samples <= 0) return context.l10n.audioAnalysisNoClipping;
    return _formatNumber(samples);
  }

  String _formatChannelStats(ChannelAnalysisStats stats) {
    final parts = <String>[];
    if (stats.peakDb != null) {
      parts.add('P ${stats.peakDb!.toStringAsFixed(1)}');
    }
    if (stats.rmsDb != null) {
      parts.add('R ${stats.rmsDb!.toStringAsFixed(1)}');
    }
    if (stats.dynamicRangeDb != null) {
      parts.add('DR ${stats.dynamicRangeDb!.toStringAsFixed(1)}');
    }
    if (stats.peakCount > 0 && (stats.peakDb ?? -100) >= -0.1) {
      parts.add('Clip ${_formatNumber(stats.peakCount)}');
    }
    return parts.isEmpty ? 'N/A' : parts.join(' / ');
  }

  String _formatNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }
}

/// Match file metadata's whole-kbps precision without rounding it up by 1 kbps.
String formatAudioAnalysisBitrate(int bitsPerSecond) {
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
  }
  return '${bitsPerSecond ~/ 1000} kbps';
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ColorScheme cs;

  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
