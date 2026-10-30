import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/controllers/batch_track_actions.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/replaygain_service.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

final _log = AppLogger('LinkLibrary');

/// Runs the same file services as the desktop menus, after resolving a live
/// catalog row. Source paths and preview results are owned by the desktop.
class LinkLibraryExecutor {
  LinkLibraryExecutor({
    required this.container,
    required this.index,
    Future<Map<String, dynamic>?> Function(String id)? readLocalRecord,
    Future<Map<String, dynamic>?> Function(String id)? readDownloadRecord,
  }) : _readLocalRecord = readLocalRecord ?? LibraryDatabase.instance.getById,
       _readDownloadRecord =
           readDownloadRecord ?? HistoryDatabase.instance.getById;

  final ProviderContainer container;
  final DesktopLinkCatalogIndex? Function() index;
  final Future<Map<String, dynamic>?> Function(String id) _readLocalRecord;
  final Future<Map<String, dynamic>?> Function(String id) _readDownloadRecord;
  final _previews =
      <String, ({BatchReEnrichPreview preview, int modified, int size})>{};

  Future<UnifiedLibraryItem?> _resolve(String songId) async {
    final song = index()?.songById(songId);
    if (song == null) return null;
    final id = linkRecordIdOf(songId);
    final row = songId.startsWith('l:')
        ? await _readLocalRecord(id)
        : await _readDownloadRecord(id);
    if (row == null) return null;
    final item = songId.startsWith('l:')
        ? UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(row))
        : UnifiedLibraryItem.fromDownloadHistory(
            DownloadHistoryItem.fromJson(row),
          );
    final path = linkCleanPath(item.filePath);
    if (path != song.path || !p.isAbsolute(path) || isCueVirtualPath(path)) {
      return null;
    }
    return await File(path).exists() ? item : null;
  }

  Future<Map<String, dynamic>> call(LinkLibraryWork work, String songId) async {
    final item = await _resolve(songId);
    if (item == null) return {'error': 'not_found'};
    final path = linkCleanPath(item.filePath);
    final settings = container.read(settingsProvider);
    final local =
        item.localItem ??
        LocalLibraryItem.fromJson({
          ...item.historyItem!.toJson(),
          'scannedAt': item.addedAt.toIso8601String(),
        });
    final options = work.options;
    switch (work.action) {
      case LinkLibraryAction.readMetadata:
        final metadata = await PlatformBridge.readFileMetadata(path);
        if (metadata['error'] != null) return {'error': 'read_failed'};
        const fields = {
          'title',
          'artist',
          'album',
          'album_artist',
          'date',
          'track_number',
          'total_tracks',
          'disc_number',
          'total_discs',
          'genre',
          'isrc',
          'lyrics',
          'label',
          'copyright',
          'composer',
          'comment',
          'album_type',
          'explicit',
          'upc',
        };
        return {
          'metadata': {
            for (final key in fields) key: metadata[key]?.toString() ?? '',
          },
        };
      case LinkLibraryAction.delete:
        if (!await deleteFile(path)) return {'error': 'delete_failed'};
        await removeDeletedLibraryFileEntries(container, [path]);
      case LinkLibraryAction.replayGain:
      case LinkLibraryAction.removeReplayGain:
        final remove = work.action == LinkLibraryAction.removeReplayGain;
        final ok = remove
            ? await ReplayGainService.removeFromFile(path)
            : await ReplayGainService.applyToFile(path);
        if (!ok) return {'error': 'replaygain_failed'};
        if (item.localItem case final local?) {
          await LibraryDatabase.instance.updateAudioMetadata(
            local.id,
            hasReplayGain: !remove,
          );
        }
        if (item.historyItem case final history?) {
          await container
              .read(downloadHistoryProvider.notifier)
              .updateAudioMetadataForItem(
                id: history.id,
                hasReplayGain: !remove,
                replayGainMetadataScanVersion: 1,
              );
        }
      case LinkLibraryAction.convert:
        final format = options['format'];
        final bitrate = options['bitrate'];
        if (format is! String ||
            !audioConversionTargetFormats.contains(format) ||
            bitrate is! String ||
            !RegExp(r'^(\d{2,4}k|auto)$').hasMatch(bitrate)) {
          return {'error': 'invalid_conversion'};
        }
        final sourceFormat = convertibleAudioSourceFormat(
          storedFormat: local.format,
          filePath: path,
        );
        if (sourceFormat == null ||
            !canConvertAudioFormat(
              sourceFormat: sourceFormat,
              targetFormat: format,
            )) {
          return {'error': 'unsupported_format'};
        }
        final result = await convertLibraryTrack(
          filePath: path,
          metadata: {
            'TITLE': item.trackName,
            'ARTIST': item.artistName,
            'ALBUM': item.albumName,
            if (local.explicit) 'ITUNESADVISORY': '1',
          },
          trackName: item.trackName,
          artistName: item.artistName,
          spotifyId: item.historyItem?.spotifyId ?? '',
          durationMs: (local.duration ?? 0) * 1000,
          sourceBitDepth: local.bitDepth,
          sourceSampleRate: local.sampleRate,
          historyItem: item.historyItem,
          localItem: item.localItem,
          targetFormat: format,
          bitrate: bitrate,
          losslessQuality: LosslessConversionQuality(
            maxBitDepth: _optionInt(
              options,
              'maxBitDepth',
              losslessConversionBitDepthOptions,
            ),
            maxSampleRate: _optionInt(
              options,
              'maxSampleRate',
              losslessConversionSampleRateOptions,
            ),
          ),
          losslessProcessing: LosslessConversionProcessing(
            dither: options['dither'] as String? ?? 'none',
            resampler: options['resampler'] as String? ?? 'swr',
          ),
          keepOriginal: options['keepOriginal'] != false,
          shouldEmbedLyrics:
              settings.embedLyrics && settings.lyricsMode != 'external',
          readArtistTagMode: () => settings.artistTagMode,
          losslessLabels: const LosslessConversionLabels(
            original: 'Original',
            originalQuality: 'Original quality',
            lossless: 'Lossless',
          ),
          coverTempPrefix: 'link_cover_',
          treatEmptySafTempPathAsFailure: true,
          onCleanupFailed: (path, error) =>
              _log.w('Temporary file cleanup failed: $error'),
        );
        if (!result.succeeded) {
          _log.w('Desktop conversion failed: ${result.failureDetail}');
          return {'error': 'conversion_failed'};
        }
        final removed =
            options['keepOriginal'] == false && !await File(path).exists();
        if (removed) await SourceDeletionEvents.instance.publish(path);
        return {'removed': removed};
      case LinkLibraryAction.reEnrichPreview:
        final mode = ReEnrichBatchMode.values.asNameMap()[options['mode']];
        if (mode == null) return {'error': 'invalid_fields'};
        final selection = ReEnrichFieldSelection(
          mode: mode,
          fields: [
            for (final field in options['fields'] as List? ?? const [])
              if (field is String && ReEnrichFields.all.contains(field)) field,
          ],
          manualValues: linkLibraryMap(
            options['manualValues'],
          ).map((key, value) => MapEntry(key, value.toString())),
        );
        final before = await File(path).stat();
        final previews = await _runner(item).preview(
          [local],
          selection,
          shouldStop: () => false,
          onProgress: (_, _) {},
        );
        if (previews.isEmpty) return {'changes': const <Object?>[]};
        final preview = previews.single;
        while (_previews.length >= 800) {
          _previews.remove(_previews.keys.first);
        }
        _previews['${work.deviceId}:${work.id}:$songId'] = (
          preview: preview,
          modified: before.modified.microsecondsSinceEpoch,
          size: before.size,
        );
        return {
          'changes': [
            for (final change in preview.changes)
              {
                'field': change.field,
                'oldValue': change.oldValue,
                'newValue': change.newValue,
              },
          ],
        };
      case LinkLibraryAction.reEnrich:
        final prepared =
            _previews['${work.deviceId}:${options['previewJobId']}:$songId'];
        if (prepared == null || prepared.preview.item.filePath != path) {
          return {'error': 'preview_expired'};
        }
        final stat = await File(path).stat();
        if (stat.size != prepared.size ||
            stat.modified.microsecondsSinceEpoch != prepared.modified) {
          return {'error': 'file_changed'};
        }
        final successes = await _runner(item).apply(
          [prepared.preview],
          shouldStop: () => false,
          onProgress: (_, _) {},
        );
        if (successes != 1) return {'error': 'metadata_failed'};
        await _refreshMetadata(item);
      case LinkLibraryAction.editMetadata:
        const fields = {
          'title',
          'artist',
          'album',
          'album_artist',
          'date',
          'track_number',
          'track_total',
          'disc_number',
          'disc_total',
          'genre',
          'isrc',
          'lyrics',
          'label',
          'copyright',
          'composer',
          'comment',
          'album_type',
          'explicit',
          'upc',
          'compilation',
        };
        final metadata = linkLibraryMap(options['metadata']);
        if (metadata.isEmpty ||
            metadata.entries.any(
              (entry) =>
                  !fields.contains(entry.key) ||
                  entry.value is! String ||
                  (entry.value as String).length > 200000,
            )) {
          return {'error': 'invalid_fields'};
        }
        final covers = MetadataCoverResources();
        try {
          final saved = await MetadataPersistenceService(covers: covers).save(
            MetadataSaveRequest(
              filePath: path,
              metadata: metadata.map(
                (key, value) => MapEntry(key, value as String),
              ),
              artistTagMode: artistTagModeForExistingTags(
                settings.artistTagMode,
              ),
            ),
          );
          if (saved.failure != null) return {'error': 'metadata_failed'};
        } finally {
          await covers.dispose();
        }
        await _refreshMetadata(item);
      case LinkLibraryAction.saveCover:
      case LinkLibraryAction.saveLyrics:
        await container
            .read(settingsProvider.notifier)
            .syncLyricsSettingsToBackend(settings: settings);
        return _exportSidecar(
          item,
          songId,
          cover: work.action == LinkLibraryAction.saveCover,
        );
    }
    if (linkLibraryActionChangesCatalog(work.action) &&
        work.action != LinkLibraryAction.delete) {
      await SourceMetadataEvents.instance.publish(path);
    }
    return {};
  }

  int? _optionInt(Map<String, dynamic> options, String key, List<int> allowed) {
    final value = options[key];
    if (value == null) return null;
    if (value is! int || !allowed.contains(value)) {
      invalidLinkLibraryRequest('Invalid conversion quality');
    }
    return value;
  }

  BatchReEnrichRunner _runner(UnifiedLibraryItem item) => BatchReEnrichRunner(
    sourceTrackIds: item.historyItem == null
        ? const {}
        : {item.historyItem!.id: ?item.historyItem!.spotifyId},
    saveMotionArtwork: (local, metadata) => saveReEnrichedMotionArtwork(
      container,
      metadata: metadata,
      albumName: local.albumName,
      artistName: local.artistName,
    ),
    beginPhase: () async {
      final settings = container.read(settingsProvider);
      await container
          .read(settingsProvider.notifier)
          .syncLyricsSettingsToBackend(settings: settings);
      return settings;
    },
  );

  Future<void> _refreshMetadata(UnifiedLibraryItem item) async {
    final path = item.filePath;
    await DownloadedEmbeddedCoverResolver.invalidate(path);
    final metadata = await PlatformBridge.readDisplayAudioMetadata(path);
    if (metadata['error'] != null) return;
    final title = metadata['title'] as String? ?? item.trackName;
    final artist = metadata['artist'] as String? ?? item.artistName;
    final album = metadata['album'] as String? ?? item.albumName;
    final explicit = parseExplicitFlag(metadata['explicit']);
    final hasLyrics =
        metadata.containsKey('hasLyrics') || metadata.containsKey('lyrics')
        ? metadata['hasLyrics'] == true ||
              hasUsableLyricsContent(metadata['lyrics']?.toString() ?? '')
        : null;
    final cover = await DownloadedEmbeddedCoverResolver.resolveOrExtract(path);
    if (item.historyItem case final history?) {
      await container
          .read(downloadHistoryProvider.notifier)
          .updateMetadataForItem(
            id: history.id,
            trackName: title,
            artistName: artist,
            albumName: album,
            coverUrl: cover,
            explicit: explicit,
            hasLyrics: hasLyrics,
            albumArtist: metadata['album_artist'] as String?,
            isrc: metadata['isrc'] as String?,
            trackNumber: readPositiveInt(metadata['track_number']),
            totalTracks: readPositiveInt(metadata['total_tracks']),
            discNumber: readPositiveInt(metadata['disc_number']),
            totalDiscs: readPositiveInt(metadata['total_discs']),
            releaseDate: metadata['date'] as String?,
            genre: metadata['genre'] as String?,
            composer: metadata['composer'] as String?,
            label: metadata['label'] as String?,
            copyright: metadata['copyright'] as String?,
          );
    }
    if (item.localItem case final local?) {
      final values = LibraryRowMapper.encode({
        ...local.toJson(),
        'trackName': title,
        'artistName': artist,
        'albumName': album,
        'coverPath': cover ?? local.coverPath,
        'explicit': ?explicit,
        'hasLyrics': ?hasLyrics,
        'albumArtist': metadata['album_artist'],
        'isrc': metadata['isrc'],
        'trackNumber': readPositiveInt(metadata['track_number']),
        'totalTracks': readPositiveInt(metadata['total_tracks']),
        'discNumber': readPositiveInt(metadata['disc_number']),
        'totalDiscs': readPositiveInt(metadata['total_discs']),
        'releaseDate': metadata['date'],
        'genre': metadata['genre'],
        'composer': metadata['composer'],
        'label': metadata['label'],
        'copyright': metadata['copyright'],
        'fileModTime': (await File(
          path,
        ).stat()).modified.millisecondsSinceEpoch,
      });
      final db = await LibraryDatabase.instance.database;
      await db.update(
        'library',
        values,
        where: 'id = ? AND file_path = ?',
        whereArgs: [local.id, path],
      );
    }
  }

  Future<Map<String, dynamic>> _exportSidecar(
    UnifiedLibraryItem item,
    String songId, {
    required bool cover,
  }) async {
    final temp = await (await getTemporaryDirectory()).createTemp(
      'link_sidecar_',
    );
    final suffix = cover ? '.jpg' : '.lrc';
    final output = p.setExtension(item.filePath, suffix);
    final staged = p.join(temp.path, 'sidecar$suffix');
    try {
      var result = cover
          ? await PlatformBridge.extractCoverToFile(item.filePath, staged)
          : await PlatformBridge.fetchAndSaveLyrics(
              trackName: item.trackName,
              artistName: item.artistName,
              spotifyId: item.historyItem?.spotifyId ?? '',
              durationMs:
                  (item.localItem?.duration ??
                      item.historyItem?.duration ??
                      0) *
                  1000,
              outputPath: staged,
              audioFilePath: item.filePath,
            );
      if (cover && result['error'] != null) {
        final cached = index()?.coverFor(songId);
        if (cached != null && cached.startsWith('http')) {
          result = await PlatformBridge.downloadCoverToFile(cached, staged);
        } else if (cached != null && await File(cached).exists()) {
          await File(cached).copy(staged);
          result = {};
        }
      }
      if (result['error'] != null ||
          !await File(staged).exists() ||
          await File(staged).length() == 0) {
        return {'error': cover ? 'cover_missing' : 'lyrics_missing'};
      }
      if (!await FFmpegOutput.promote(
        staged,
        output,
        onError: (error) => _log.w('Sidecar publication failed: $error'),
      )) {
        return {'error': 'write_failed'};
      }
      return {'fileName': p.basename(output)};
    } finally {
      await temp.delete(recursive: true);
    }
  }
}
