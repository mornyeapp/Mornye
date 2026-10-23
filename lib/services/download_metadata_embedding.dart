import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/download_metadata_resolver.dart';
import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_replaygain.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/replaygain_service.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/string_utils.dart';

/// Embeds tags into a local working file; the queue owns publication and state.
class DownloadMetadataEmbedding {
  static final _log = AppLogger('DownloadEmbedding');
  static const _coverCacheMax = 8;
  final Map<String, Future<String?>> _coverCache = {};
  final void Function(Track, String, ReplayGainResult) onReplayGain;
  final Future<String?> Function(String, int) _loadCover;
  final Future<String> Function(Track) _loadLyrics;
  final Future<Map<String, dynamic>> Function(String, Map<String, String>)
  _editMetadata;
  final Future<ReplayGainResult?> Function(String) _scanReplayGain;
  final Future<ReplayGainResult?> Function(String) _scanAndApplyReplayGain;
  final Future<bool> Function(String, String, String) _writeReplayGain;
  final Future<String?> Function(
    String,
    String,
    String?,
    Map<String, String>,
    String,
  )
  _writeWithFFmpeg;

  DownloadMetadataEmbedding({
    required this.onReplayGain,
    Future<String?> Function(String, int)? loadCover,
    Future<String> Function(Track)? loadLyrics,
    Future<Map<String, dynamic>> Function(String, Map<String, String>)?
    editMetadata,
    Future<ReplayGainResult?> Function(String)? scanReplayGain,
    Future<ReplayGainResult?> Function(String)? scanAndApplyReplayGain,
    Future<bool> Function(String, String, String)? writeReplayGain,
    Future<String?> Function(
      String,
      String,
      String?,
      Map<String, String>,
      String,
    )?
    writeWithFFmpeg,
  }) : _loadCover = loadCover ?? _downloadCover,
       _loadLyrics = loadLyrics ?? _fetchLyrics,
       _editMetadata = editMetadata ?? PlatformBridge.editFileMetadata,
       _scanReplayGain = scanReplayGain ?? FFmpegReplayGain.scan,
       _scanAndApplyReplayGain =
           scanAndApplyReplayGain ?? ReplayGainService.scanAndApplyToFile,
       _writeReplayGain = writeReplayGain ?? ReplayGainService.writeTrackTags,
       _writeWithFFmpeg = writeWithFFmpeg ?? _embedWithFFmpeg;

  static Future<String> _fetchLyrics(Track track) =>
      PlatformBridge.getLyricsLRC(
        track.id,
        track.name,
        track.artistName,
        filePath: '',
        durationMs: track.duration * 1000,
      );

  /// Returns fetched lyrics for a later SAF sidecar save without refetching.
  Future<String?> embed(
    String filePath,
    Track track, {
    required AppSettings settings,
    required ExtensionState extensionState,
    required String format,
    String? genre,
    String? label,
    String? copyright,
    String? comment,
    String? lyricsLrc,
    String? downloadService,
    bool writeExternalLrc = true,
  }) async {
    if (!settings.embedMetadata) {
      if (settings.embedReplayGain) {
        final gain = await _scanAndApplyReplayGain(filePath);
        if (gain != null) onReplayGain(track, filePath, gain);
      }
      return null;
    }

    final isFlac = format == 'flac';
    final isM4a = format == 'm4a';
    final isMp3 = format == 'mp3';
    final albumArtist = DownloadMetadataResolver.albumArtistForMetadata(
      track,
      settings,
    );
    final fields = _trackFields(
      track,
      albumArtist: albumArtist,
      genre: genre ?? track.genre,
      label: label ?? track.label,
      copyright: copyright ?? track.copyright,
      comment: comment ?? track.comment,
    );
    // Start artwork before fetching lyrics so both network round trips overlap.
    final coverUrl = normalizeRemoteHttpUrl(track.coverUrl);
    final coverFuture = coverUrl == null || coverUrl.isEmpty
        ? null
        : _sharedCover(coverUrl, settings.embeddedCoverMaxDimension);
    String? lrcContent;
    try {
      final formattedFields = formatDownloadTagFields(
        applyArtistTagModeToMetadata(fields, settings.artistTagMode),
        settings.metadataSeparators,
      );
      final metadata = _ffmpegFields(formattedFields, format);
      metadata.addAll(settings.metadataSeparators.writerFields);
      final lyricsEnabled =
          settings.embedLyrics &&
          !DownloadMetadataResolver.shouldSkipLyrics(
            extensionState,
            track.source,
            downloadService,
          );
      final shouldEmbedLyrics =
          lyricsEnabled &&
          (settings.lyricsMode == 'embed' || settings.lyricsMode == 'both');
      final shouldSaveExternalLyrics =
          lyricsEnabled &&
          (settings.lyricsMode == 'external' || settings.lyricsMode == 'both');
      if (shouldEmbedLyrics || shouldSaveExternalLyrics) {
        try {
          final fetched = lyricsLrc != null && hasUsableLyricsContent(lyricsLrc)
              ? lyricsLrc
              : await _loadLyrics(track);
          if (hasUsableLyricsContent(fetched) &&
              !isInstrumentalLyricsMarker(fetched)) {
            lrcContent = fetched;
          }
        } catch (error) {
          _log.w('Failed to fetch lyrics for $format: $error');
        }
      }
      if (shouldEmbedLyrics && lrcContent != null) {
        metadata['LYRICS'] = lrcContent;
        if (isFlac || isMp3) metadata['UNSYNCEDLYRICS'] = lrcContent;
      } else if ((isFlac || isM4a) && !shouldEmbedLyrics) {
        metadata['LYRICS'] = '';
        if (isFlac) metadata['UNSYNCEDLYRICS'] = '';
      }
      if (writeExternalLrc && shouldSaveExternalLyrics && lrcContent != null) {
        try {
          final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
          await File(
            lrcPath == filePath ? '$filePath.lrc' : lrcPath,
          ).writeAsString(lrcContent);
        } catch (error) {
          _log.w('Failed to save external LRC file for $format: $error');
        }
      }

      ReplayGainResult? scannedReplayGain;
      if (settings.embedReplayGain && !isFlac) {
        try {
          scannedReplayGain = await _scanReplayGain(filePath);
          if (scannedReplayGain != null && format != 'opus') {
            metadata['REPLAYGAIN_TRACK_GAIN'] = scannedReplayGain.trackGain;
            metadata['REPLAYGAIN_TRACK_PEAK'] = scannedReplayGain.trackPeak;
            onReplayGain(track, filePath, scannedReplayGain);
          }
        } catch (error) {
          _log.w('Failed to scan ReplayGain for $format: $error');
        }
      }
      final coverPath = coverFuture == null ? null : await coverFuture;
      final validCover = coverPath != null && await File(coverPath).exists()
          ? coverPath
          : null;

      // AC-4 needs its native MP4 writer. FFmpeg's mov muxer would rewrap it
      // as QuickTime; non-AC-4 M4A falls through to the usual tag writers.
      if (isM4a) {
        try {
          final ac4Result = await PlatformBridge.writeAC4Metadata(filePath, {
            ..._ac4Fields(formattedFields, artistTagModeJoined),
            if (shouldEmbedLyrics) 'lyrics': ?lrcContent,
          }, validCover ?? '');
          if (ac4Result['handled'] == true) return lrcContent;
        } catch (error) {
          _log.w('AC-4 metadata path failed, falling back to FFmpeg: $error');
        }
      }

      var embeddedNatively = false;
      // Opus R128 tags are written and verified after the metadata writer.
      if (scannedReplayGain == null || format == 'opus') {
        try {
          final response = await _editMetadata(filePath, {
            ...fields,
            'artist_tag_mode': settings.artistTagMode,
            ...settings.metadataSeparators.writerFields,
            'cover_path': ?validCover,
            if (shouldEmbedLyrics && lrcContent != null) ...{
              'lyrics': lrcContent,
              'unsyncedlyrics': lrcContent,
            } else if ((isFlac || isM4a) && !shouldEmbedLyrics) ...{
              'lyrics': '',
              if (isFlac) 'unsyncedlyrics': '',
            },
          });
          embeddedNatively =
              response['success'] == true &&
              response['error'] == null &&
              response['method'] != 'ffmpeg';
        } catch (error) {
          _log.w(
            'Native $format tag embed failed, falling back to FFmpeg: $error',
          );
        }
      }
      if (!embeddedNatively) {
        final result = await _writeWithFFmpeg(
          filePath,
          format,
          validCover,
          metadata,
          settings.artistTagMode,
        );
        if (result == null) _log.w('FFmpeg $format metadata embed failed');
      }
      if (format == 'opus' && scannedReplayGain != null) {
        if (await _writeReplayGain(
          filePath,
          scannedReplayGain.trackGain,
          scannedReplayGain.trackPeak,
        )) {
          onReplayGain(track, filePath, scannedReplayGain);
        } else {
          _log.w('Failed to write Opus ReplayGain');
        }
      }
      if (isM4a && settings.embedReplayGain && scannedReplayGain != null) {
        try {
          await _editMetadata(filePath, {
            'replaygain_track_gain': scannedReplayGain.trackGain,
            'replaygain_track_peak': scannedReplayGain.trackPeak,
          });
        } catch (error) {
          _log.w('Failed to write native ReplayGain tags for $format: $error');
        }
      }
      if (isFlac) {
        // Only FFmpeg needs a second rewrite for repeated Vorbis artist tags.
        if (!embeddedNatively &&
            settings.artistTagMode == artistTagModeSplitVorbis &&
            (settings.metadataSeparators.artist.isEmpty ||
                settings.metadataSeparators.albumArtist.isEmpty)) {
          try {
            await PlatformBridge.rewriteSplitArtistTags(
              filePath,
              settings.metadataSeparators.artist.isEmpty
                  ? track.artistName
                  : '',
              settings.metadataSeparators.albumArtist.isEmpty
                  ? albumArtist ?? ''
                  : '',
            );
          } catch (error) {
            _log.w('Failed to rewrite split artist tags: $error');
          }
        }
        if (settings.embedReplayGain) {
          try {
            final gain = await _scanAndApplyReplayGain(filePath);
            if (gain != null) onReplayGain(track, filePath, gain);
          } catch (error) {
            _log.w('Failed to embed ReplayGain via native writer: $error');
          }
        }
      }
    } catch (error) {
      _log.e('Failed to embed metadata to $format: $error');
    }
    // The cache owns artwork until eviction or queue drain, allowing reuse.
    return lrcContent;
  }

  static Map<String, String> _trackFields(
    Track track, {
    String? albumArtist,
    String? genre,
    String? label,
    String? copyright,
    String? comment,
  }) => {
    'title': track.name,
    'artist': track.artistName,
    'album': track.albumName,
    'album_artist': ?albumArtist,
    if (track.releaseDate != null) 'date': track.releaseDate!,
    if (track.isrc != null) 'isrc': track.isrc!,
    for (final entry in {
      'genre': genre,
      'label': label,
      'copyright': copyright,
      'comment': comment,
      'composer': track.composer,
      'album_type': track.albumType,
      'upc': track.upc,
    }.entries)
      if (entry.value != null && entry.value!.isNotEmpty)
        entry.key: entry.value!,
    for (final entry in {
      'track_number': track.trackNumber,
      'track_total': track.totalTracks,
      'disc_number': track.discNumber,
      'disc_total': track.totalDiscs,
    }.entries)
      if (entry.value != null && entry.value! > 0)
        entry.key: entry.value!.toString(),
    if (track.isExplicit) 'explicit': '1',
    if (track.albumType?.toLowerCase() == 'compilation') 'compilation': '1',
  };

  static const _ffmpegKeys = {
    'title': 'TITLE',
    'artist': 'ARTIST',
    'album': 'ALBUM',
    'album_artist': 'ALBUMARTIST',
    'date': 'DATE',
    'isrc': 'ISRC',
    'genre': 'GENRE',
    'label': 'ORGANIZATION',
    'copyright': 'COPYRIGHT',
    'comment': 'COMMENT',
    'composer': 'COMPOSER',
    'explicit': 'ITUNESADVISORY',
    'album_type': 'RELEASETYPE',
    'upc': 'BARCODE',
    'compilation': 'COMPILATION',
  };

  static Map<String, String> _ffmpegFields(
    Map<String, String> fields,
    String format,
  ) {
    final metadata = {
      for (final entry in _ffmpegKeys.entries)
        if (fields[entry.key] case final String value)
          entry.value: entry.key == 'album_type' ? value.toLowerCase() : value,
    };
    final hasLegacyTags = format == 'flac' || format == 'mp3';
    for (final (number, total, tag, legacyTag) in [
      ('track_number', 'track_total', 'TRACKNUMBER', 'TRACK'),
      ('disc_number', 'disc_total', 'DISCNUMBER', 'DISC'),
    ]) {
      final value = fields[number];
      if (value == null) continue;
      final formatted = fields[total] == null
          ? value
          : '$value/${fields[total]}';
      metadata[tag] = formatted;
      if (hasLegacyTags) metadata[legacyTag] = formatted;
    }
    if (hasLegacyTags && fields['date'] != null) {
      metadata['YEAR'] = fields['date']!.split('-').first;
    }
    return metadata;
  }

  static const _ac4Keys = {
    'title': 'title',
    'artist': 'artist',
    'album': 'album',
    'album_artist': 'albumArtist',
    'date': 'date',
    'genre': 'genre',
    'composer': 'composer',
    'track_number': 'trackNumber',
    'track_total': 'totalTracks',
    'disc_number': 'discNumber',
    'disc_total': 'totalDiscs',
    'isrc': 'isrc',
    'label': 'label',
    'copyright': 'copyright',
    'comment': 'comment',
  };

  static Map<String, String> _ac4Fields(
    Map<String, String> fields,
    String artistMode,
  ) => {
    for (final entry in _ac4Keys.entries)
      if (fields[entry.key] case final String value)
        entry.value: entry.key == 'artist' || entry.key == 'album_artist'
            ? artistTagValueForMode(value, artistMode)
            : value,
  };

  static Future<String?> _embedWithFFmpeg(
    String path,
    String format,
    String? cover,
    Map<String, String> metadata,
    String artistMode,
  ) => switch (format) {
    'flac' => FFmpegMetadata.embedMetadata(
      flacPath: path,
      coverPath: cover,
      metadata: metadata,
      artistTagMode: artistMode,
    ),
    'm4a' => FFmpegMetadata.embedMetadataToM4a(
      m4aPath: path,
      coverPath: cover,
      metadata: metadata,
      artistTagMode: artistMode,
    ),
    'mp3' => FFmpegMetadata.embedMetadataToMp3(
      mp3Path: path,
      coverPath: cover,
      metadata: metadata,
      artistTagMode: artistMode,
    ),
    _ => FFmpegMetadata.embedMetadataToOpus(
      opusPath: path,
      coverPath: cover,
      metadata: metadata,
      artistTagMode: artistMode,
    ),
  };

  Future<String?> _sharedCover(String url, int maxDimension) {
    final key = '$maxDimension\u0000$url';
    final existing = _coverCache.remove(key);
    if (existing != null) {
      _coverCache[key] = existing;
      return existing;
    }
    final fetch = Future<String?>.sync(() => _loadCover(url, maxDimension))
        .catchError((Object error) {
          _log.w('Failed to load cover for embedding: $error');
          return null;
        })
        .then((path) {
          if (path == null) _coverCache.remove(key);
          return path;
        });
    _coverCache[key] = fetch;
    while (_coverCache.length > _coverCacheMax) {
      _evictCover(_coverCache.keys.first);
    }
    return fetch;
  }

  static Future<String?> _downloadCover(String url, int maxDimension) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final uniqueId =
          '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}';
      final path = '${tempDir.path}/cover_embed_$uniqueId.jpg';
      final result = await PlatformBridge.downloadCoverToFile(
        url,
        // The backend may only write inside the folders it owns, so it
        // creates the file and returns its path.
        PlatformBridge.supportsCoreBackend ? '' : path,
        maxDimension: maxDimension,
      );
      if (result['error'] != null) {
        _log.w('Failed to download cover: ${result['error']}');
        return null;
      }
      return result['file_path'] as String? ?? path;
    } catch (error) {
      _log.e('Failed to download cover for embedding: $error');
      return null;
    }
  }

  void _evictCover(String key) {
    _coverCache.remove(key)?.then((path) {
      if (path != null) File(path).delete().catchError((_) => File(path));
    });
  }

  void clearCoverCache() {
    for (final key in _coverCache.keys.toList()) {
      _evictCover(key);
    }
  }
}
