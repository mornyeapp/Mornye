import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:file_picker/file_picker.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_analysis_cache.dart';
import 'package:mornye/services/audio_analysis_ffmpeg.dart';
import 'package:mornye/services/audio_analysis_models.dart';
import 'package:mornye/services/audio_analysis_runner.dart';
import 'package:mornye/services/audio_compare_dsp.dart';
import 'package:mornye/services/audio_compare_engine.dart';
import 'package:mornye/services/audio_file_open_service.dart'
    show openAudioExtensions;
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/string_utils.dart';

export 'package:mornye/services/audio_analysis_ffmpeg.dart';
export 'package:mornye/services/audio_analysis_models.dart';

part 'audio_analysis_info_card.dart';
part 'audio_compare_view.dart';
part 'audio_analysis_spectrogram.dart';

class AudioAnalysisCard extends StatefulWidget {
  final String filePath;
  final String? codecHint;

  /// Names the saved spectrogram image, such as "Artist - Title". Without
  /// it the name comes from [filePath].
  final String? exportName;

  const AudioAnalysisCard({
    super.key,
    required this.filePath,
    this.codecHint,
    this.exportName,
  });

  @override
  State<AudioAnalysisCard> createState() => _AudioAnalysisCardState();
}

class _AudioAnalysisCardState extends State<AudioAnalysisCard> {
  AudioAnalysisData? _data;
  bool _analyzing = false;
  bool _checkingCache = true;
  String? _error;
  ui.Image? _spectrogramImage;
  int _spectrogramChannel = -1;
  bool _spectrogramChannelLoading = false;
  int _spectrogramRequestId = 0;
  bool _savingSpectrogram = false;
  String? _unsupportedCodec;
  final _runner = AudioAnalysisRunner();

  bool _isStaleRequest(int requestId) =>
      !mounted || requestId != _spectrogramRequestId;

  void _checkAnalysisRequest(int requestId) {
    if (_isStaleRequest(requestId)) {
      throw const AudioAnalysisCancelled();
    }
  }

  static const _supportedExtensions = {
    '.flac',
    '.mp3',
    '.m4a',
    '.mp4',
    '.aac',
    '.ac3',
    '.eac3',
    '.opus',
    '.ogg',
    '.wav',
    '.wma',
    '.mka',
    '.wv',
    '.ape',
    '.tta',
    '.aif',
    '.aiff',
  };

  bool get _isSupported {
    final lower = widget.filePath.toLowerCase();
    return _supportedExtensions.any((ext) => lower.endsWith(ext));
  }

  @override
  void initState() {
    super.initState();
    _unsupportedCodec = unsupportedAudioAnalysisCodecLabel(widget.codecHint);
    if (_isSupported) {
      if (_unsupportedCodec == null) {
        _tryLoadFromCache();
      } else {
        _checkingCache = false;
      }
    }
  }

  @override
  void didUpdateWidget(covariant AudioAnalysisCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath == widget.filePath &&
        oldWidget.codecHint == widget.codecHint) {
      return;
    }

    _spectrogramRequestId++;
    _runner.cancel();
    _spectrogramImage?.dispose();
    _spectrogramImage = null;
    _spectrogramChannel = -1;
    _spectrogramChannelLoading = false;
    _data = null;
    _error = null;
    _analyzing = false;
    _unsupportedCodec = unsupportedAudioAnalysisCodecLabel(widget.codecHint);
    _checkingCache = _isSupported && _unsupportedCodec == null;

    if (_checkingCache) {
      unawaited(_tryLoadFromCache());
    }
  }

  @override
  void dispose() {
    _spectrogramRequestId++;
    _runner.dispose();
    _spectrogramImage?.dispose();
    super.dispose();
  }

  Future<void> _tryLoadFromCache() async {
    final expectedPath = widget.filePath;
    final requestId = _spectrogramRequestId;
    final releaseCache = AudioAnalysisDiskCache.cacheBudget.retain(
      AudioAnalysisDiskCache.cacheKey(expectedPath),
    );
    bool isCurrentRequest() =>
        mounted &&
        widget.filePath == expectedPath &&
        requestId == _spectrogramRequestId;

    try {
      final cached = await AudioAnalysisDiskCache.loadFromCache(
        expectedPath,
        _runner.networkInput,
      );
      if (cached != null && isCurrentRequest()) {
        final unsupported = unsupportedAudioAnalysisCodecLabel(cached.codec);
        if (unsupported != null) {
          await AudioAnalysisDiskCache.clearCache(expectedPath);
          if (isCurrentRequest()) {
            setState(() {
              _unsupportedCodec = unsupported;
              _checkingCache = false;
            });
          }
          return;
        }
        setState(() {
          _data = cached;
          _checkingCache = false;
        });
        var image = await AudioAnalysisDiskCache.loadSpectrogramFromCache(
          expectedPath,
          channel: _spectrogramChannel,
        );
        if (image == null &&
            NetworkAudioAnalysisInput.isNetwork(expectedPath)) {
          return; // Opening metadata must not fetch the complete remote audio.
        }
        image ??= await _generateAndCacheSpectrogram(
          filePath: expectedPath,
          analysisData: cached,
          requestId: requestId,
        );
        if (isCurrentRequest()) {
          setState(() {
            _spectrogramImage?.dispose();
            _spectrogramImage = image;
          });
        } else {
          image.dispose();
        }
        return;
      }
    } catch (_) {
      // Missing or unreadable cache entries fall back to the Analyze action.
    } finally {
      releaseCache();
      unawaited(AudioAnalysisDiskCache.trimCache());
    }
    if (isCurrentRequest()) {
      setState(() => _checkingCache = false);
    }
  }

  Future<ui.Image> _generateAndCacheSpectrogram({
    String? filePath,
    AudioAnalysisData? analysisData,
    required int requestId,
  }) async {
    _checkAnalysisRequest(requestId);
    final sourcePath = filePath ?? widget.filePath;
    final data = analysisData ?? _data;
    final channel = _spectrogramChannel;
    final artifact = await _runner.generateSpectrogramForFile(
      sourcePath,
      isCancelled: () => _isStaleRequest(requestId),
      channel: channel,
      durationSeconds: data?.duration,
      sampleRate: data?.sampleRate,
      channels: data?.channels,
    );
    await AudioAnalysisDiskCache.saveSpectrogramToCache(
      sourcePath,
      artifact.image,
      channel: channel,
    );
    return artifact.image;
  }

  Future<void> _analyze({bool forceRefresh = false}) async {
    if (_analyzing) return;
    final sourcePath = widget.filePath;
    final releaseCache = AudioAnalysisDiskCache.cacheBudget.retain(
      AudioAnalysisDiskCache.cacheKey(sourcePath),
    );
    final requestId = ++_spectrogramRequestId;
    _runner.cancel();
    setState(() {
      _analyzing = true;
      _spectrogramChannelLoading = false;
      _error = null;
      if (forceRefresh) {
        _spectrogramImage?.dispose();
        _spectrogramImage = null;
        _data = null;
        _spectrogramChannel = -1;
      }
    });

    try {
      if (forceRefresh) {
        await AudioAnalysisDiskCache.clearCache(sourcePath);
      }

      final cached = forceRefresh
          ? null
          : await AudioAnalysisDiskCache.loadFromCache(
              sourcePath,
              _runner.networkInput,
            );
      _checkAnalysisRequest(requestId);
      AudioAnalysisData data;
      ui.Image? image;

      if (cached != null) {
        final unsupported = unsupportedAudioAnalysisCodecLabel(cached.codec);
        if (unsupported != null) {
          throw UnsupportedAudioAnalysisCodecException(unsupported);
        }
        data = cached;
        image = await AudioAnalysisDiskCache.loadSpectrogramFromCache(
          sourcePath,
          channel: _spectrogramChannel,
        );
      } else {
        final result = await _runner.runAnalysis(
          sourcePath,
          () => _isStaleRequest(requestId),
        );
        data = result.data;
        image = result.spectrogramImage;
        await AudioAnalysisDiskCache.saveToCache(sourcePath, data);
        await AudioAnalysisDiskCache.saveSpectrogramToCache(
          sourcePath,
          image,
          channel: _spectrogramChannel,
        );
      }

      image ??= await _generateAndCacheSpectrogram(
        filePath: sourcePath,
        analysisData: data,
        requestId: requestId,
      );

      if (mounted && requestId == _spectrogramRequestId) {
        setState(() {
          _data = data;
          _spectrogramImage?.dispose();
          _spectrogramImage = image;
          _analyzing = false;
        });
      } else {
        image.dispose();
      }
    } on AudioAnalysisCancelled {
      // A new file/request owns the state; cancelled native work is cleaned up.
    } on UnsupportedAudioAnalysisCodecException catch (e) {
      if (mounted && requestId == _spectrogramRequestId) {
        setState(() {
          _unsupportedCodec = e.codecLabel;
          _error = null;
          _analyzing = false;
        });
      }
    } catch (e) {
      if (mounted && requestId == _spectrogramRequestId) {
        setState(() {
          _error = context.friendlyError(e);
          _analyzing = false;
        });
      }
    } finally {
      releaseCache();
      unawaited(AudioAnalysisDiskCache.trimCache());
    }
  }

  Future<void> _changeSpectrogramChannel(int channel) async {
    final data = _data;
    if (data == null ||
        _spectrogramChannelLoading ||
        _analyzing ||
        channel == _spectrogramChannel ||
        channel < -1 ||
        channel >= data.channels) {
      return;
    }

    final previousChannel = _spectrogramChannel;
    final sourcePath = widget.filePath;
    final releaseCache = AudioAnalysisDiskCache.cacheBudget.retain(
      AudioAnalysisDiskCache.cacheKey(sourcePath),
    );
    final requestId = ++_spectrogramRequestId;
    setState(() {
      _spectrogramChannel = channel;
      _spectrogramChannelLoading = true;
    });

    ui.Image? image;
    try {
      image = await AudioAnalysisDiskCache.loadSpectrogramFromCache(
        sourcePath,
        channel: channel,
      );
      if (image == null) {
        final artifact = await _runner.generateSpectrogramForFile(
          sourcePath,
          isCancelled: () => _isStaleRequest(requestId),
          channel: channel,
          durationSeconds: data.duration,
          sampleRate: data.sampleRate,
          channels: data.channels,
        );
        image = artifact.image;
        await AudioAnalysisDiskCache.saveSpectrogramToCache(
          sourcePath,
          image,
          channel: channel,
        );
      }

      if (!mounted || requestId != _spectrogramRequestId) {
        image.dispose();
        return;
      }
      setState(() {
        _spectrogramImage?.dispose();
        _spectrogramImage = image;
        _spectrogramChannelLoading = false;
      });
    } catch (_) {
      image?.dispose();
      if (mounted && requestId == _spectrogramRequestId) {
        setState(() {
          _spectrogramChannel = previousChannel;
          _spectrogramChannelLoading = false;
        });
      }
    } finally {
      releaseCache();
      unawaited(AudioAnalysisDiskCache.trimCache());
    }
  }

  /// Renders the spectrogram with its axes and legend, then asks where to
  /// save it: the save panel on desktop, the system file picker on mobile.
  Future<void> _saveSpectrogram() async {
    final data = _data;
    final shown = _spectrogramImage;
    if (data == null || shown == null || _savingSpectrogram) return;
    final l10n = context.l10n;
    final channel = _spectrogramChannel;
    final baseName = audioSpectrogramExportBaseName(
      widget.filePath,
      exportName: widget.exportName,
    );
    final fileName = channel < 0
        ? '${baseName}_spectrogram.png'
        : '${baseName}_spectrogram_ch${channel + 1}.png';
    // A channel switch disposes the shown image while this still renders.
    final image = shown.clone();
    setState(() => _savingSpectrogram = true);
    try {
      final bytes = await renderAudioSpectrogramPng(
        image: image,
        title: baseName,
        sampleRate: data.sampleRate,
        duration: data.duration,
        details: [
          '${l10n.audioAnalysisSampleRate}: ${data.sampleRate} Hz',
          '${l10n.audioAnalysisNyquist}: '
              '${(data.sampleRate / 2000).toStringAsFixed(1)} kHz',
          if (channel >= 0) 'Ch ${channel + 1}',
        ],
      );
      final saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'image/png',
        dialogTitle: l10n.audioAnalysisSaveSpectrogram,
      );
      if (saved == null || !mounted) return;
      final savedName = saved.scheme == 'file'
          ? p.basename(saved.toFilePath())
          : fileName;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.audioAnalysisSpectrogramSaved(savedName)),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.trackSaveFailed(context.friendlyError(e))),
          ),
        );
    } finally {
      image.dispose();
      if (mounted) setState(() => _savingSpectrogram = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSupported) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    if (_checkingCache) return const SizedBox.shrink();

    if (_unsupportedCodec != null) {
      return AppContentCard(
        elevation: 0,
        color: settingsGroupColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.audioAnalysisTitle,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l10n.snackbarUnsupportedAudioFormat}: '
                      '$_unsupportedCodec',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_analyzing) {
      final isRescan = _data != null || _spectrogramImage != null;
      return AppContentCard(
        elevation: 0,
        color: settingsGroupColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppLoadingIndicator(size: 24, strokeWidth: 2.5),
                const SizedBox(height: 12),
                Text(
                  isRescan
                      ? l10n.audioAnalysisRescanning
                      : l10n.audioAnalysisAnalyzing,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return AppContentCard(
        preserveColor: true,
        color: cs.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: cs.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                ),
              ),
              AppIconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: l10n.audioAnalysisRescan,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                color: cs.onErrorContainer,
                onPressed: () => _analyze(forceRefresh: true),
              ),
            ],
          ),
        ),
      );
    }

    if (_data == null) {
      return AppContentCard(
        elevation: 0,
        color: settingsGroupColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: InkWell(
          onTap: _analyze,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.audioAnalysisTitle,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.audioAnalysisDescription,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
    }

    final data = _data!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AudioInfoCard(
          data: data,
          onRescan: () => _analyze(forceRefresh: true),
          onCompare: audioCompareAvailable
              ? () => pickAndShowAudioCompare(
                  context,
                  referencePath: widget.filePath,
                  referenceSize: data.fileSize,
                )
              : null,
        ),
        if (_spectrogramImage != null) ...[
          const SizedBox(height: 12),
          _SpectrogramView(
            image: _spectrogramImage!,
            sampleRate: data.sampleRate,
            maxFreq: data.sampleRate / 2,
            duration: data.duration,
            channels: data.channels,
            selectedChannel: _spectrogramChannel,
            channelLoading: _spectrogramChannelLoading,
            onChannelChanged: _changeSpectrogramChannel,
            onSave: _savingSpectrogram || _spectrogramChannelLoading
                ? null
                : _saveSpectrogram,
          ),
        ],
      ],
    );
  }
}
