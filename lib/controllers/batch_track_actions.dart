import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/conversion_library_service.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/replaygain_service.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/utils/saf_display_path.dart';

final _batchActionsLog = AppLogger('BatchActions');

class _BatchConversionFailure implements Exception {
  final String stage;
  final String message;

  const _BatchConversionFailure(this.stage, this.message);

  @override
  String toString() => '$stage: $message';
}

/// Outcome of [convertLibraryTrack]: success, a checked pipeline failure
/// (no SAF copy, no converter output, no SAF destination), or a thrown error.
class LibraryTrackConversionResult {
  const LibraryTrackConversionResult._({
    this.failureStage,
    this.error,
    this.stackTrace,
  });

  const LibraryTrackConversionResult.success() : this._();

  /// Pipeline stage that was running when the conversion failed.
  final String? failureStage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get succeeded => error == null;

  /// Whether the failure is a checked pipeline outcome, not a thrown error.
  bool get isPipelineFailure => error is _BatchConversionFailure;

  /// `stage: message` summary of the failure.
  String get failureDetail =>
      isPipelineFailure ? error.toString() : '$failureStage: $error';
}

/// Shows the batch format-conversion sheet for [selectedItems] and runs the
/// conversion when confirmed. Handles both history-backed and local-backed
/// items, including SAF-hosted files.
///
/// [onSheetOpen] / [onSheetClosed] let the caller hide and restore any
/// selection UI around the sheet; [onSheetClosed] receives whether a
/// conversion was started.
Future<void> showBatchConvertSheet(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> selectedItems, {
  required VoidCallback onExitSelectionMode,
  VoidCallback? onSheetOpen,
  Future<void> Function(bool didStartConversion)? onSheetClosed,
}) async {
  final sourceFormats = <String>{};
  final sourceBitDepths = <int?>[];
  final sourceSampleRates = <int?>[];
  for (final item in selectedItems) {
    final sourceFormat = convertibleAudioSourceFormat(
      storedFormat: item.localItem?.format ?? item.historyItem?.format,
      filePath: item.filePath,
      fileName: item.historyItem?.safFileName,
    );
    if (sourceFormat != null) sourceFormats.add(sourceFormat);
    sourceBitDepths.add(item.historyItem?.bitDepth ?? item.localItem?.bitDepth);
    sourceSampleRates.add(
      item.historyItem?.sampleRate ?? item.localItem?.sampleRate,
    );
  }

  final formats = audioConversionTargetFormats
      .where(
        (target) => sourceFormats.any(
          (source) =>
              canConvertAudioFormat(sourceFormat: source, targetFormat: target),
        ),
      )
      .toList();

  if (formats.isEmpty) return;

  var didStartConversion = false;

  // The queue launches this action from a temporary OverlayEntry. Its
  // onSheetOpen callback removes that entry, which deactivates [context]. Keep
  // the root Navigator's context before doing so; it remains mounted for the
  // sheet, the confirmation dialog, progress updates, and the final snackbar.
  final modalContext = Navigator.of(context, rootNavigator: true).context;

  // Resolve localized strings up front; the builder must not look up
  // Localizations via a possibly deactivated context.
  final sheetTitle = modalContext.l10n.selectionBatchConvertConfirmTitle;
  final sheetConfirmLabel = modalContext.l10n.selectionConvertCount(
    selectedItems.length,
  );

  onSheetOpen?.call();

  await showAppModalBottomSheet<void>(
    context: modalContext,
    useRootNavigator: true,
    isScrollControlled: true,
    // The sheet draws its own glass.
    mornyeGlass: false,
    builder: (sheetContext) => BatchConvertSheet(
      formats: formats,
      title: sheetTitle,
      confirmLabel: sheetConfirmLabel,
      sourceBitDepth: lowestKnownPositiveInt(sourceBitDepths),
      sourceSampleRate: lowestKnownPositiveInt(sourceSampleRates),
      onConvert:
          (format, bitrate, losslessQuality, losslessProcessing, keepOriginal) {
            didStartConversion = true;
            Navigator.pop(sheetContext);
            _performBatchConversion(
              modalContext,
              ref,
              selectedItems: selectedItems,
              targetFormat: format,
              bitrate: bitrate,
              losslessQuality: losslessQuality,
              losslessProcessing: losslessProcessing,
              keepOriginal: keepOriginal,
              onExitSelectionMode: onExitSelectionMode,
            );
          },
    ),
  );

  await onSheetClosed?.call(didStartConversion);
}

Future<void> _performBatchConversion(
  BuildContext context,
  WidgetRef ref, {
  required List<UnifiedLibraryItem> selectedItems,
  required String targetFormat,
  required String bitrate,
  LosslessConversionQuality losslessQuality = const LosslessConversionQuality(),
  LosslessConversionProcessing losslessProcessing =
      const LosslessConversionProcessing(),
  bool keepOriginal = false,
  required VoidCallback onExitSelectionMode,
}) async {
  final convertibleItems = <UnifiedLibraryItem>[];
  for (final item in selectedItems) {
    final sourceFormat = convertibleAudioSourceFormat(
      storedFormat: item.localItem?.format ?? item.historyItem?.format,
      filePath: item.filePath,
      fileName: item.historyItem?.safFileName,
    );
    if (sourceFormat == null ||
        !canConvertAudioFormat(
          sourceFormat: sourceFormat,
          targetFormat: targetFormat,
        )) {
      continue;
    }
    convertibleItems.add(item);
  }

  if (convertibleItems.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.selectionConvertNoConvertible)),
      );
    }
    return;
  }

  final isLossless = isLosslessConversionTarget(targetFormat);
  final losslessLabels = context.l10n.losslessConversionLabels;
  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.selectionBatchConvertConfirmTitle,
    message: keepOriginal
        ? context.l10n.selectionBatchConvertConfirmKeepOriginal(
            convertibleItems.length,
            targetFormat,
          )
        : isLossless && losslessQuality.hasCaps
        ? context.l10n.selectionBatchConvertConfirmMessageLosslessCapped(
            convertibleItems.length,
            targetFormat,
            losslessQualityLabel(
              losslessQuality,
              originalLabel: losslessLabels.original,
              originalQualityLabel: losslessLabels.originalQuality,
            ),
          )
        : isLossless
        ? context.l10n.selectionBatchConvertConfirmMessageLossless(
            convertibleItems.length,
            targetFormat,
          )
        : context.l10n.selectionBatchConvertConfirmMessage(
            convertibleItems.length,
            targetFormat,
            bitrate,
          ),
    confirmLabel: context.l10n.trackConvertFormat,
    confirmIsDefault: true,
  );

  if (!confirmed || !context.mounted) return;

  int successCount = 0;
  final failures = <String>[];
  final total = convertibleItems.length;
  final settings = ref.read(settingsProvider);
  final shouldEmbedLyrics =
      settings.embedLyrics && settings.lyricsMode != 'external';

  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.trackConvertConverting,
    total: total,
    icon: Icons.transform,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  for (int i = 0; i < total; i++) {
    if (!context.mounted || cancelled) break;
    final item = convertibleItems[i];

    BatchProgressDialog.update(current: i + 1, detail: item.trackName);

    final result = await convertLibraryTrack(
      filePath: item.filePath,
      metadata: <String, String>{
        'TITLE': item.trackName,
        'ARTIST': item.artistName,
        'ALBUM': item.albumName,
        if (item.historyItem?.explicit == true ||
            item.localItem?.explicit == true)
          'ITUNESADVISORY': '1',
      },
      trackName: item.trackName,
      artistName: item.artistName,
      spotifyId: item.historyItem?.spotifyId ?? '',
      durationMs:
          ((item.historyItem?.duration ?? item.localItem?.duration) ?? 0) *
          1000,
      sourceBitDepth: item.historyItem?.bitDepth ?? item.localItem?.bitDepth,
      sourceSampleRate:
          item.historyItem?.sampleRate ?? item.localItem?.sampleRate,
      historyItem: item.historyItem,
      localItem: item.localItem,
      targetFormat: targetFormat,
      bitrate: bitrate,
      losslessQuality: losslessQuality,
      losslessProcessing: losslessProcessing,
      keepOriginal: keepOriginal,
      shouldEmbedLyrics: shouldEmbedLyrics,
      readArtistTagMode: () => settings.artistTagMode,
      losslessLabels: losslessLabels,
      coverTempPrefix: 'batch_cover_',
      treatEmptySafTempPathAsFailure: true,
      onCleanupFailed: (path, error) =>
          _batchActionsLog.w('Failed to clean temporary file $path: $error'),
    );

    if (result.succeeded) {
      successCount++;
    } else {
      final detail = result.failureDetail;
      failures.add('${item.trackName} — $detail');
      _batchActionsLog.e(
        'Batch conversion failed for ${item.trackName} at ${result.failureStage}',
        result.error,
        result.stackTrace,
      );
    }
  }

  await ref.read(downloadHistoryProvider.notifier).reloadFromStorage();
  await ref.read(localLibraryProvider.notifier).reloadFromStorage();

  onExitSelectionMode();

  if (context.mounted) {
    if (!cancelled) {
      BatchProgressDialog.dismiss(context);
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${context.l10n.selectionBatchConvertSuccess(successCount, total, targetFormat)}'
          '${failures.isEmpty ? '' : ' • ${context.l10n.trackConvertFailed}: ${failures.length} (${failures.first})'}',
        ),
      ),
    );
  }
}

/// Converts the track at [filePath] to [targetFormat], publishes SAF output
/// and records the result on [historyItem] or [localItem] (with neither, the
/// converted file is not recorded). Temporary files are removed before this
/// returns. Shared by batch conversion and the track metadata screen.
///
/// [metadata] holds the caller's fallback tags and is completed from the
/// file. [readArtistTagMode] is read when FFmpeg starts.
/// [coverTempPrefix] names the extracted cover in the temp directory.
/// [treatEmptySafTempPathAsFailure] also fails an empty SAF temp copy path.
/// [historySafFileNameFallback] is the original SAF file name used when
/// [historyItem] has none. [eagerTempCleanup] deletes the cover right after
/// FFmpeg and the temp files before each checked failure, not only at the
/// end. [onPersisted] runs right after the history or library row is written.
/// [diagnosticsLog] receives metadata fallback and SAF original delete
/// warnings. [onCleanupFailed] reports a temp file that could not be deleted.
Future<LibraryTrackConversionResult> convertLibraryTrack({
  required String filePath,
  required Map<String, String> metadata,
  required String trackName,
  required String artistName,
  required String spotifyId,
  required int durationMs,
  required int? sourceBitDepth,
  required int? sourceSampleRate,
  required DownloadHistoryItem? historyItem,
  required LocalLibraryItem? localItem,
  required String targetFormat,
  required String bitrate,
  required LosslessConversionQuality losslessQuality,
  required LosslessConversionProcessing losslessProcessing,
  required bool keepOriginal,
  required bool shouldEmbedLyrics,
  required String Function() readArtistTagMode,
  required LosslessConversionLabels losslessLabels,
  required String coverTempPrefix,
  required bool treatEmptySafTempPathAsFailure,
  String historySafFileNameFallback = '',
  bool eagerTempCleanup = false,
  Future<void> Function()? onPersisted,
  AppLogger? diagnosticsLog,
  required void Function(String path, Object error) onCleanupFailed,
}) async {
  String failureStage = 'metadata';
  String? coverPath;
  String? safTempPath;
  String? convertedSafTempPath;

  Future<void> cleanUpEagerly(List<String?> paths) async {
    if (!eagerTempCleanup) return;
    for (final path in paths) {
      if (path != null) await _deleteFileQuietly(path);
    }
  }

  try {
    String workingPath = filePath;
    final isSaf = isContentUri(filePath);
    if (isSaf) {
      failureStage = 'read SAF source';
      safTempPath = await ConversionLibraryService.copySafSourceToTemp(
        filePath,
      );
      if (safTempPath == null ||
          (treatEmptySafTempPathAsFailure && safTempPath.isEmpty)) {
        throw const _BatchConversionFailure(
          'read SAF source',
          'temporary copy was not created',
        );
      }
      workingPath = safTempPath;
    }

    // Reuse the conversion copy for tags and artwork. Pipe-backed SAF
    // providers otherwise download the whole source again for each read.
    failureStage = 'metadata';
    try {
      final result = await PlatformBridge.readFileMetadata(workingPath);
      if (result['error'] == null) {
        mergePlatformMetadataForTagEmbed(target: metadata, source: result);
      } else {
        diagnosticsLog?.w(
          'readFileMetadata returned error, using fallback metadata',
        );
      }
    } catch (e) {
      diagnosticsLog?.w('readFileMetadata threw, using fallback metadata: $e');
    }
    await ensureLyricsMetadataForConversion(
      metadata: metadata,
      sourcePath: filePath,
      shouldEmbedLyrics: shouldEmbedLyrics,
      trackName: trackName,
      artistName: artistName,
      spotifyId: spotifyId,
      durationMs: durationMs,
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final coverOutput =
          '${tempDir.path}${Platform.pathSeparator}$coverTempPrefix${DateTime.now().millisecondsSinceEpoch}.jpg';
      final coverResult = await PlatformBridge.extractCoverToFile(
        workingPath,
        coverOutput,
      );
      if (coverResult['error'] == null) {
        coverPath = coverOutput;
      }
    } catch (_) {}

    failureStage = 'FFmpeg conversion';
    final newPath = await FFmpegConversion.convertAudioFormat(
      inputPath: workingPath,
      targetFormat: targetFormat.toLowerCase(),
      bitrate: bitrate,
      metadata: metadata,
      coverPath: coverPath,
      artistTagMode: readArtistTagMode(),
      deleteOriginal: !isSaf && !keepOriginal,
      sourceBitDepth: sourceBitDepth,
      losslessQuality: losslessQuality,
      losslessProcessing: losslessProcessing,
    );
    await cleanUpEagerly([coverPath]);

    if (newPath == null) {
      await cleanUpEagerly([safTempPath]);
      throw const _BatchConversionFailure(
        'FFmpeg conversion',
        'converter returned no output',
      );
    }
    if (isSaf) convertedSafTempPath = newPath;

    final isLosslessOutput = isLosslessConversionTarget(targetFormat);
    int? convertedBitDepth;
    int? convertedSampleRate;
    if (isLosslessOutput) {
      try {
        final convertedMetadata = await PlatformBridge.readFileMetadata(
          newPath,
        );
        if (convertedMetadata['error'] == null) {
          convertedBitDepth = readPositiveInt(convertedMetadata['bit_depth']);
          convertedSampleRate = readPositiveInt(
            convertedMetadata['sample_rate'],
          );
        }
      } catch (_) {}
      convertedBitDepth ??= losslessQuality.effectiveBitDepth(sourceBitDepth);
      convertedSampleRate ??= losslessQuality.effectiveSampleRate(
        sourceSampleRate,
      );
    }
    final newQuality = convertedAudioQualityLabel(
      targetFormat: targetFormat,
      bitrate: bitrate,
      labels: losslessLabels,
      losslessQuality: losslessQuality,
      actualBitDepth: convertedBitDepth,
      actualSampleRate: convertedSampleRate,
    );

    Future<({String uri, String fileName})> publishSafOutput({
      required String treeUri,
      required String relativeDir,
      required String originalFileName,
    }) async {
      final published = await ConversionLibraryService.publishSafConversion(
        treeUri: treeUri,
        relativeDir: relativeDir,
        originalFileName: originalFileName,
        targetFormat: targetFormat,
        sourcePath: newPath,
        keepOriginal: keepOriginal,
      );
      final safUri = published?.uri;

      if (safUri == null || safUri.isEmpty) {
        await cleanUpEagerly([newPath, safTempPath]);
        throw const _BatchConversionFailure(
          'publish SAF output',
          'destination file was not created',
        );
      }

      if (!keepOriginal && !isSameContentUri(filePath, safUri)) {
        final deletedOriginal = await PlatformBridge.safDelete(
          filePath,
        ).catchError((_) => false);
        if (deletedOriginal != true) {
          diagnosticsLog?.w(
            'Converted SAF file created but failed deleting original URI',
          );
        }
      }
      return published!;
    }

    if (isSaf && historyItem != null) {
      failureStage = 'publish SAF output';
      final treeUri = historyItem.downloadTreeUri;
      if (treeUri != null && treeUri.isNotEmpty) {
        final safFileName = historyItem.safFileName;
        final published = await publishSafOutput(
          treeUri: treeUri,
          relativeDir: historyItem.safRelativeDir ?? '',
          originalFileName: safFileName != null && safFileName.isNotEmpty
              ? safFileName
              : historySafFileNameFallback,
        );
        await ConversionLibraryService.persistHistoryConversion(
          source: historyItem,
          newFilePath: published.uri,
          newQuality: newQuality,
          targetFormat: targetFormat,
          bitrate: bitrate,
          bitDepth: convertedBitDepth,
          sampleRate: convertedSampleRate,
          keepOriginal: keepOriginal,
          newSafFileName: published.fileName,
        );
        await onPersisted?.call();
      } else {
        await cleanUpEagerly([newPath, safTempPath]);
        throw const _BatchConversionFailure(
          'publish SAF output',
          'download folder permission is unavailable',
        );
      }
      await _deleteFileQuietly(newPath);
      if (safTempPath != null) await _deleteFileQuietly(safTempPath);
    } else if (isSaf && localItem != null) {
      failureStage = 'publish SAF output';
      final location = resolveSafDocumentLocation(filePath);

      if (location != null) {
        final published = await publishSafOutput(
          treeUri: location.treeUri,
          relativeDir: location.relativeDir,
          originalFileName: location.fileName,
        );
        await LibraryDatabase.instance.replaceWithConvertedItem(
          item: localItem,
          newFilePath: published.uri,
          targetFormat: targetFormat,
          bitrate: bitrate,
          bitDepth: convertedBitDepth,
          sampleRate: convertedSampleRate,
          keepOriginal: keepOriginal,
        );
        await onPersisted?.call();
      } else {
        await cleanUpEagerly([newPath, safTempPath]);
        throw const _BatchConversionFailure(
          'publish SAF output',
          'source document location could not be resolved',
        );
      }

      await _deleteFileQuietly(newPath);
      if (safTempPath != null) await _deleteFileQuietly(safTempPath);
    } else if (historyItem != null) {
      await ConversionLibraryService.persistHistoryConversion(
        source: historyItem,
        newFilePath: newPath,
        newQuality: newQuality,
        targetFormat: targetFormat,
        bitrate: bitrate,
        bitDepth: convertedBitDepth,
        sampleRate: convertedSampleRate,
        keepOriginal: keepOriginal,
      );
      await onPersisted?.call();
    } else if (localItem != null) {
      await LibraryDatabase.instance.replaceWithConvertedItem(
        item: localItem,
        newFilePath: newPath,
        targetFormat: targetFormat,
        bitrate: bitrate,
        bitDepth: convertedBitDepth,
        sampleRate: convertedSampleRate,
        keepOriginal: keepOriginal,
      );
      await onPersisted?.call();
    }

    return const LibraryTrackConversionResult.success();
  } catch (error, stackTrace) {
    return LibraryTrackConversionResult._(
      failureStage: failureStage,
      error: error,
      stackTrace: stackTrace,
    );
  } finally {
    for (final path in <String?>[
      coverPath,
      safTempPath,
      convertedSafTempPath,
    ]) {
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        onCleanupFailed(path, error);
      }
    }
  }
}

Future<void> _deleteFileQuietly(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}

/// Adds or removes ReplayGain tags for [selectedItems].
///
/// [onConfirmOpen] / [onConfirmClosed] let the caller hide and restore any
/// selection UI around the confirmation dialog; [onConfirmClosed] receives
/// whether the user confirmed.
Future<void> runBatchReplayGain(
  BuildContext sourceContext,
  List<UnifiedLibraryItem> selectedItems, {
  required VoidCallback onExitSelectionMode,
  bool remove = false,
  VoidCallback? onConfirmOpen,
  Future<void> Function(bool confirmed)? onConfirmClosed,
}) async {
  if (selectedItems.isEmpty) return;

  final container = ProviderScope.containerOf(sourceContext, listen: false);
  // The selection overlay can disappear when opening the confirmation dialog.
  final context = Navigator.of(sourceContext, rootNavigator: true).context;

  onConfirmOpen?.call();

  final title = remove
      ? context.l10n.trackRemoveReplayGain
      : context.l10n.replayGainBatchConfirmTitle;
  final confirmed = await showAppConfirmDialog(
    context,
    title: title,
    message: remove
        ? context.l10n.replayGainRemoveConfirmMessage(selectedItems.length)
        : context.l10n.replayGainBatchConfirmMessage(selectedItems.length),
    confirmLabel: title,
    confirmIsDefault: true,
  );

  await onConfirmClosed?.call(confirmed);

  if (!confirmed || !context.mounted) return;

  var cancelled = false;
  int successCount = 0;
  var unsupportedDecoder = false;
  final total = selectedItems.length;

  BatchProgressDialog.show(
    context: context,
    title: remove
        ? context.l10n.replayGainRemoving
        : context.l10n.replayGainBatchAnalyzing,
    total: total,
    icon: Icons.graphic_eq,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  for (int i = 0; i < total; i++) {
    if (!context.mounted || cancelled) break;
    final item = selectedItems[i];
    BatchProgressDialog.update(current: i + 1, detail: item.trackName);
    try {
      final ok = remove
          ? await ReplayGainService.removeFromFile(item.filePath)
          : await ReplayGainService.applyToFile(
              item.filePath,
              onUnsupportedDecoder: () => unsupportedDecoder = true,
            );
      if (ok) {
        successCount++;
        try {
          if (item.historyItem case final history?) {
            await container
                .read(downloadHistoryProvider.notifier)
                .updateAudioMetadataForItem(
                  id: history.id,
                  hasReplayGain: !remove,
                  replayGainMetadataScanVersion: 1,
                );
          }
          if (item.localItem case final local?) {
            await LibraryDatabase.instance.updateAudioMetadata(
              local.id,
              hasReplayGain: !remove,
            );
          }
        } catch (e) {
          _batchActionsLog.w('Could not refresh ReplayGain availability: $e');
        }
      }
    } catch (_) {}
  }

  onExitSelectionMode();

  if (successCount > 0 && context.mounted) {
    await container.read(localLibraryProvider.notifier).reloadFromStorage();
  }

  if (!context.mounted) return;
  if (!cancelled) {
    BatchProgressDialog.dismiss(context);
  }
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        [
          remove
              ? context.l10n.replayGainRemoveBatchSuccess(successCount, total)
              : context.l10n.replayGainBatchSuccess(successCount, total),
          if (unsupportedDecoder) context.l10n.replayGainUnsupportedDecoder,
        ].join('\n'),
      ),
    ),
  );
}
