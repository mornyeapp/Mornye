import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/audio_route_info.dart';
import 'package:mornye/services/link/link_source_names.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/hires_check_card.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Technical details of the playing track, from the file through the
/// processing chain to the output device. [linkSources] names the Mornye
/// Link devices behind network sources (`linkSourceNamesProvider`).
Future<void> showAudioInfoSheet(
  BuildContext context, {
  required PlayerMetadataController metadata,
  Map<String, String> linkSources = const {},
}) {
  unawaited(metadata.ensureFileMetadata());
  return showAppScrollableBottomSheet<void>(
    context: context,
    title: context.l10n.audioInfoTitle,
    subtitle: metadata.qualityLabel,
    builder: (context, controller) => _AudioInfoSheet(
      metadata: metadata,
      controller: controller,
      linkSources: linkSources,
    ),
  );
}

class _AudioInfoSheet extends StatefulWidget {
  const _AudioInfoSheet({
    required this.metadata,
    required this.controller,
    required this.linkSources,
  });

  final PlayerMetadataController metadata;
  final ScrollController controller;
  final Map<String, String> linkSources;

  @override
  State<_AudioInfoSheet> createState() => _AudioInfoSheetState();
}

class _AudioInfoSheetState extends State<_AudioInfoSheet>
    with WidgetsBindingObserver {
  AudioRouteInfo? _route;
  int? _fileSize;
  String? _loadedPath;
  int _loadGeneration = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.metadata.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.metadata.removeListener(_load);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(force: true));
  }

  Future<void> _load({bool force = false}) async {
    final path = widget.metadata.filePath;
    if (!force && path == _loadedPath && (_loading || _route != null)) return;
    final generation = ++_loadGeneration;
    _loadedPath = path;
    _loading = true;
    _route = null;
    _fileSize = null;
    final results = await Future.wait<Object?>([
      readAudioRouteInfo(path: path),
      _sizeOf(path),
    ]);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      _route = results[0] as AudioRouteInfo?;
      _fileSize = results[1] as int?;
    });
  }

  static Future<int?> _sizeOf(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      if (path.startsWith('content://')) {
        final size = (await PlatformBridge.safStat(path))['size'];
        return size is num && size > 0 ? size.toInt() : null;
      }
      if (!path.startsWith('/')) return null;
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.metadata,
      usbAudioStatus,
      playbackEqualizer,
    ]),
    builder: (context, _) {
      final facts = _AudioFacts(
        l10n: context.l10n,
        metadata: widget.metadata.metadata ?? const {},
        loading: widget.metadata.loading,
        path: widget.metadata.filePath,
        fileSize: _fileSize,
        route: _route,
        usb: usbAudioStatus.value,
        equalizer: playbackEqualizer.value,
        processing: musicPlayerRuntime.handler?.processing,
        settings: musicPlayerRuntime.settings,
        linkDevice: linkSourceName(
          widget.linkSources,
          widget.metadata.filePath,
        ),
      );
      final sections = facts.sections();
      final path = widget.metadata.filePath;
      final analyzable =
          path != null &&
          path.isNotEmpty &&
          !const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme);
      final format = widget.metadata.metadata?['format']?.toString();
      return SingleChildScrollView(
        controller: widget.controller,
        padding: EdgeInsets.only(bottom: context.tokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final section in sections) ...[
              SettingsSectionHeader(title: section.title),
              _FactGroup(
                children: [
                  for (final (index, fact) in section.facts.indexed)
                    _FactRow(
                      fact: fact,
                      last: index == section.facts.length - 1,
                    ),
                ],
              ),
            ],
            if (analyzable) ...[
              SettingsSectionHeader(title: context.l10n.audioInfoAnalysis),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.tokens.gapLg),
                child: Column(
                  children: [
                    AudioAnalysisCard(filePath: path, codecHint: format),
                    if (HiResCheckCard.isCandidate(path, format)) ...[
                      SizedBox(height: context.tokens.gapLg),
                      HiResCheckCard(filePath: path, formatHint: format),
                    ],
                  ],
                ),
              ),
            ],
            SizedBox(height: context.tokens.gapLg),
            if (context.isMornye)
              _FactGroup(
                children: [
                  CupertinoButton(
                    minimumSize: Size.square(context.tokens.minTouchTarget),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    onPressed: () => _copy(context, sections),
                    child: Text(
                      context.l10n.audioInfoCopy,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              )
            else
              Center(
                child: ExpressiveButton(
                  tonal: true,
                  icon: const AppIcon(Icons.copy_rounded),
                  onPressed: () => _copy(context, sections),
                  child: Text(context.l10n.audioInfoCopy),
                ),
              ),
          ],
        ),
      );
    },
  );

  Future<void> _copy(BuildContext context, List<_Section> sections) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final copied = context.l10n.audioInfoCopied;
    final report = StringBuffer(widget.metadata.qualityLabel ?? '');
    for (final section in sections) {
      report
        ..writeln()
        ..writeln()
        ..writeln(section.title);
      for (final fact in section.facts) {
        report.writeln('${fact.label}: ${fact.value}');
      }
    }
    await Clipboard.setData(ClipboardData(text: report.toString().trim()));
    messenger?.showSnackBar(SnackBar(content: Text(copied)));
  }
}

/// Mornye sheets are glass, so a settings cell color would vanish into them;
/// rows use the translucent control fill, like the track details page.
class _FactGroup extends StatelessWidget {
  const _FactGroup({required this.children});

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

class _FactRow extends StatelessWidget {
  const _FactRow({required this.fact, required this.last});

  final _Fact fact;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    // Mornye rows line up with the section header, as in iOS inset lists.
    final inset = mornye ? 16.0 : tokens.rowPaddingH;
    final valueStyle =
        (mornye ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
            ?.copyWith(
              color: fact.emphasis ? colors.primary : colors.onSurfaceVariant,
              fontWeight: fact.emphasis ? FontWeight.w600 : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
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
              child: LayoutBuilder(
                // The value keeps its natural width up to just over half the
                // row, so short values never squeeze long labels onto two lines.
                builder: (context, constraints) => Row(
                  children: [
                    Expanded(
                      child: Text(fact.label, style: theme.textTheme.bodyLarge),
                    ),
                    SizedBox(width: tokens.gapMd),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.55,
                      ),
                      child: Text(
                        fact.value,
                        textAlign: TextAlign.end,
                        style: valueStyle,
                      ),
                    ),
                  ],
                ),
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
                  : colors.outlineVariant.withValues(alpha: 0.3),
            ),
        ],
      ),
    );
  }
}

class _Section {
  const _Section(this.title, this.facts);

  final String title;
  final List<_Fact> facts;
}

class _Fact {
  const _Fact(this.label, this.value, {this.emphasis = false});

  final String label;
  final String value;
  final bool emphasis;
}

const _losslessFormats = {'flac', 'alac', 'wav', 'aiff', 'ape', 'wv', 'pcm'};

/// Derives the displayed facts; kept separate from widgets so the copied
/// report matches the sheet exactly.
class _AudioFacts {
  _AudioFacts({
    required this.l10n,
    required this.metadata,
    required this.loading,
    required this.path,
    required this.fileSize,
    required this.route,
    required this.usb,
    required this.equalizer,
    required this.processing,
    required this.settings,
    this.linkDevice,
  });

  final AppLocalizations l10n;
  final Map<String, dynamic> metadata;
  final bool loading;
  final String? path;
  final int? fileSize;
  final AudioRouteInfo? route;
  final UsbAudioStatus usb;
  final EqualizerSettings equalizer;
  final PlaybackProcessing? processing;
  final AppSettings settings;

  /// The paired computer or phone the network song plays from.
  final String? linkDevice;

  late final String format = (metadata['format'] ?? '').toString().trim();
  late final String codec = (metadata['audio_codec'] ?? '').toString().trim();
  late final int? sampleRate =
      readPositiveInt(metadata['sample_rate']) ?? route?.stream?.sampleRate;
  late final int? bitDepth =
      readPositiveInt(metadata['bit_depth']) ?? route?.stream?.pcmBits;
  late final int? channels =
      route?.stream?.channels ?? readPositiveInt(metadata['channels']);
  late final int? bitrateKbps =
      readPositiveInt(metadata['bitrate']) ??
      ((route?.stream?.bitrate ?? 0) > 0
          ? (route!.stream!.bitrate! / 1000).round()
          : null);
  late final int? durationSeconds = readPositiveInt(metadata['duration']);
  late final bool lossless =
      _losslessFormats.contains(format.toLowerCase()) ||
      _losslessFormats.contains(codec.toLowerCase());
  late final bool direct =
      (processing?.direct ?? false) && usb.reason == 'active';

  List<_Section> sections() => [
    _Section(l10n.audioInfoSource, _source()),
    if (_signal().isNotEmpty) _Section(l10n.audioInfoSignal, _signal()),
    _Section(l10n.audioInfoLoudness, _loudness()),
    _Section(l10n.audioInfoProcessing, _processing()),
    if (_output().isNotEmpty) _Section(l10n.audioInfoOutput, _output()),
  ];

  List<_Fact> _source() {
    final hiRes =
        lossless && ((bitDepth ?? 0) > 16 || (sampleRate ?? 0) > 48000);
    return [
      _Fact(
        l10n.audioInfoQuality,
        hiRes
            ? l10n.audioInfoHiResLossless
            : lossless
            ? l10n.audioInfoLossless
            : l10n.audioInfoLossy,
        emphasis: true,
      ),
      if (format.isNotEmpty) _Fact(l10n.audioInfoFormat, format.toUpperCase()),
      if (codec.isNotEmpty || route?.stream?.mime != null)
        _Fact(
          l10n.audioInfoCodec,
          [
            if (codec.isNotEmpty) codec.toUpperCase(),
            ?route?.stream?.mime,
          ].join(' · '),
        ),
      if (sampleRate != null)
        _Fact(l10n.audioInfoSampleRate, _khz(sampleRate!)),
      if (bitDepth != null) _Fact(l10n.audioInfoBitDepth, '$bitDepth-bit'),
      if (channels != null)
        _Fact(l10n.audioInfoChannels, l10n.audioInfoChannelCount(channels!)),
      if (bitrateKbps != null)
        _Fact(l10n.audioInfoBitrate, '${_thousands(bitrateKbps!)} kbps'),
      if (durationSeconds != null)
        _Fact(l10n.audioInfoDuration, formatClock(durationSeconds!)),
      if (fileSize != null)
        _Fact(l10n.audioInfoFileSize, formatBytes(fileSize!)),
      if (_pcmKbps case final pcm? when bitrateKbps != null)
        _Fact(
          l10n.audioInfoCompression,
          l10n.audioInfoCompressionValue(
            (bitrateKbps! / pcm * 100).toStringAsFixed(lossless ? 0 : 1),
          ),
        ),
      if (_location case final location?)
        _Fact(l10n.audioInfoLocation, location),
    ];
  }

  double? get _pcmKbps {
    final rate = sampleRate, bits = lossless ? bitDepth : 16, ch = channels;
    if (rate == null || bits == null || ch == null) return null;
    return rate * bits * ch / 1000;
  }

  String? get _location {
    final path = this.path;
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('network://')) {
      final device = linkDevice;
      return device == null
          ? l10n.audioInfoLocationNetwork
          : l10n.audioInfoLocationLink(device);
    }
    if (path.startsWith('content://')) return l10n.audioInfoLocationShared;
    if (path.startsWith('/')) return l10n.audioInfoLocationLocal;
    return null;
  }

  List<_Fact> _signal() => [
    if (_pcmKbps case final pcm? when lossless)
      _Fact(l10n.audioInfoPcmRate, '${_thousands(pcm.round())} kbps'),
    if (sampleRate != null)
      _Fact(
        l10n.audioInfoFrequencyRange,
        l10n.audioInfoFrequencyRangeValue(_khz(sampleRate! ~/ 2)),
      ),
    if (bitDepth case final bits? when lossless)
      _Fact(l10n.audioInfoDynamicRange, '${(6.02 * bits).round()} dB'),
  ];

  List<_Fact> _loudness() {
    final tags = [
      (l10n.audioInfoTrackGain, metadata['replaygain_track_gain'], false),
      (l10n.audioInfoTrackPeak, metadata['replaygain_track_peak'], true),
      (l10n.audioInfoAlbumGain, metadata['replaygain_album_gain'], false),
      (l10n.audioInfoAlbumPeak, metadata['replaygain_album_peak'], true),
    ];
    final facts = [
      for (final (label, raw, peak) in tags)
        if (_number(raw) case final value?)
          _Fact(label, peak ? _peak(value) : _db(value)),
    ];
    final gain = processing?.normalizationGain ?? 1;
    final String normalization;
    if (!settings.playbackNormalization) {
      normalization = l10n.audioInfoOff;
    } else if (direct || settings.usbBitPerfect) {
      normalization = l10n.audioInfoBypassed;
    } else if (gain > 0 && gain != 1) {
      normalization = l10n.audioInfoApplied(
        _db(20 * math.log(gain) / math.ln10),
      );
    } else {
      normalization = l10n.audioInfoOn;
    }
    return [
      if (facts.isEmpty)
        _Fact(
          l10n.audioInfoTrackGain,
          loading ? l10n.linkFileReading : l10n.audioInfoNoGainTags,
        ),
      ...facts,
      _Fact(l10n.libraryPlaybackNormalization, normalization),
    ];
  }

  List<_Fact> _processing() {
    final route = this.route;
    final String signalPath;
    if (direct && usb.driver == 'usb_direct') {
      signalPath = l10n.audioInfoPathDirect;
    } else if ((direct && usb.driver == 'aaudio_exclusive') ||
        playbackExclusiveStatus.value == ExclusiveOutputStatus.active) {
      signalPath = l10n.audioInfoPathExclusive;
    } else {
      signalPath = l10n.audioInfoPathSystem;
    }
    final eq = !equalizer.enabled
        ? l10n.audioInfoOff
        : direct
        ? l10n.audioInfoBypassed
        : [
            l10n.audioInfoOn,
            l10n.audioInfoBands(equalizer.gains.length),
            if (equalizer.inputGain != 0)
              '${l10n.equalizerPreamp} ${_db(equalizer.inputGain)}',
            if (equalizer.compressor) l10n.equalizerCompressor,
          ].join(' · ');
    final rate = processing?.autoMixRate ?? 1;
    final decoder = route?.stream?.decoder;
    return [
      _Fact(l10n.audioInfoPlayer, l10n.audioInfoPlayerValue),
      _Fact(l10n.audioInfoSignalPath, signalPath),
      if (!direct && decoder != null)
        _Fact(
          l10n.audioInfoDecoder,
          [
            decoder,
            if (route?.stream?.hardwareDecoder case final hardware?)
              hardware ? l10n.audioInfoHardware : l10n.audioInfoSoftware,
          ].join(' · '),
        ),
      _Fact(l10n.equalizerTitle, eq),
      _Fact(
        'AutoMix',
        settings.autoMix &&
                !settings.usbBitPerfect &&
                !playbackExclusiveOutput.value
            ? l10n.audioInfoOn
            : l10n.audioInfoOff,
      ),
      if ((rate - 1).abs() > 0.001)
        _Fact(l10n.audioInfoTempo, '${rate.toStringAsFixed(3)}×'),
      if (_resampling case final value?) _Fact(l10n.audioInfoResampling, value),
      _Fact(
        l10n.audioInfoBitPerfect,
        _bitPerfect
            ? l10n.audioInfoBitPerfectActive
            : l10n.audioInfoBitPerfectNo,
        emphasis: _bitPerfect,
      ),
    ];
  }

  // A preferred mixer format is configuration, not proof of active playback.
  bool get _bitPerfect => direct;

  bool get _bluetoothFormatUnreported =>
      !direct && route?.bluetoothFormatUnreported == true;

  int? get _outputRate {
    if (direct) return usb.sampleRate;
    if (_bluetoothFormatUnreported) return null;
    return route?.device?.mixerSampleRate ?? route?.mixerSampleRate;
  }

  String? get _resampling {
    if (_bluetoothFormatUnreported) return l10n.audioInfoAndroidNotReported;
    final source = sampleRate, output = _outputRate;
    if (source == null || output == null) return null;
    if (_bitPerfect || source == output) return l10n.audioInfoResamplingNone;
    return '${_khz(source)} → ${_khz(output)}';
  }

  List<_Fact> _output() {
    final route = this.route;
    final device = route?.device;
    final bufferMs = route?.bufferMs;
    final volume = route?.volume;
    return [
      if (device != null)
        _Fact(
          l10n.audioInfoDevice,
          [
            l10n.audioInfoDeviceType(device.type),
            if (direct && usb.device?.isNotEmpty == true)
              usb.device!
            else if (device.name.isNotEmpty)
              device.name,
          ].join(' · '),
        ),
      if (_outputRate case final rate?)
        _Fact(l10n.audioInfoOutputRate, _khz(rate)),
      if (_bluetoothFormatUnreported) ...[
        _Fact(l10n.audioInfoBluetoothFormat, l10n.audioInfoAndroidNotReported),
        if (route?.mixerSampleRate case final rate?)
          _Fact(l10n.audioInfoSystemDefaultRate, _khz(rate)),
      ],
      if (direct && usb.bitDepth != null)
        _Fact(
          l10n.audioInfoOutputFormat,
          [
            '${usb.bitDepth}-bit',
            if (usb.transport != 'pcm') usb.transport.toUpperCase(),
          ].join(' · '),
        )
      else if (device?.mixerBitDepth case final bits?
          when !_bluetoothFormatUnreported)
        _Fact(l10n.audioInfoOutputFormat, '$bits-bit'),
      if (device != null && route?.platform == 'android')
        _Fact(
          _bluetoothFormatUnreported
              ? l10n.audioInfoAndroidPcmRates
              : l10n.audioInfoDeviceRates,
          device.sampleRates.isEmpty
              ? l10n.audioInfoAnyRate
              : device.sampleRates.map(_khz).join(', '),
        ),
      if (device != null && (device.bitDepths.isNotEmpty || device.floatOutput))
        _Fact(
          _bluetoothFormatUnreported
              ? l10n.audioInfoAndroidPcmFormats
              : l10n.audioInfoDeviceFormats,
          [
            for (final bits in device.bitDepths)
              if (bits != 32 || !device.floatOutput) '$bits-bit',
            if (device.floatOutput) '32-bit float',
          ].join(', '),
        ),
      if (route?.outputChannels case final count?)
        _Fact(l10n.audioInfoChannels, l10n.audioInfoChannelCount(count)),
      if (bufferMs != null)
        _Fact(
          _bluetoothFormatUnreported
              ? l10n.audioInfoSystemDefaultBuffer
              : l10n.audioInfoBuffer,
          [
            '${bufferMs.toStringAsFixed(1)} ms',
            if (route?.framesPerBuffer case final frames?) '$frames frames',
          ].join(' · '),
        ),
      if (route?.outputLatencyMs case final latency?)
        _Fact(l10n.audioInfoLatency, '${latency.toStringAsFixed(1)} ms'),
      if (route?.lowLatency case final supported?)
        _Fact(l10n.audioInfoLowLatency, _supported(supported)),
      if (route?.proAudio case final supported?)
        _Fact(l10n.audioInfoProAudio, _supported(supported)),
      if (route?.spatialAvailable != null || route?.spatialEnabled != null)
        _Fact(
          l10n.audioInfoSpatial,
          route?.spatialAvailable == false
              ? l10n.audioInfoUnavailable
              : route?.spatialEnabled == true
              ? l10n.audioInfoOn
              : l10n.audioInfoOff,
        ),
      if (route?.headTracking == true)
        _Fact(l10n.audioInfoHeadTracking, l10n.audioInfoSupported),
      if (route?.fixedVolume == true || direct)
        _Fact(l10n.nowPlayingVolume, l10n.audioInfoFixedVolume)
      else if (volume != null)
        _Fact(
          l10n.nowPlayingVolume,
          route?.maxVolume != null
              ? '${volume.round()} / ${route!.maxVolume}'
              : '${(volume * 100).round()}%',
        ),
    ];
  }

  String _supported(bool value) =>
      value ? l10n.audioInfoSupported : l10n.audioInfoNotSupported;
}

String _khz(int hz) {
  final khz = hz / 1000;
  final text = khz == khz.roundToDouble()
      ? khz.toStringAsFixed(0)
      : khz.toStringAsFixed(khz * 10 == (khz * 10).roundToDouble() ? 1 : 2);
  return '$text kHz';
}

String _thousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Signed decibels with a true minus sign.
String _db(double value) {
  final text = value.abs().toStringAsFixed(2);
  if (value.abs() < 0.005) return '0.00 dB';
  return '${value < 0 ? '−' : '+'}$text dB';
}

/// A linear sample peak with its level in dBFS.
String _peak(double value) {
  if (value <= 0) return value.toStringAsFixed(6);
  final dbfs = 20 * math.log(value) / math.ln10;
  return '${value.toStringAsFixed(6)} · ${_db(dbfs).replaceFirst(' dB', ' dBFS')}';
}

final _numberPattern = RegExp(r'[-+]?\d+(?:\.\d+)?');

/// Reads tag values such as "-6.52 dB" or "0.988831".
double? _number(Object? raw) {
  if (raw is num) return raw.toDouble();
  final match = _numberPattern.firstMatch(raw?.toString() ?? '');
  return match == null ? null : double.tryParse(match[0]!);
}
