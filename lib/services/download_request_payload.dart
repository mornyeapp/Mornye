import 'package:mornye/models/metadata_separators.dart';

class DownloadRequestPayload {
  static const int nativeWorkerContractVersion = 1;

  final int contractVersion;
  final String isrc;
  final String service;
  final String downloadProvider;
  final String providerTrackId;
  final String spotifyId;
  final String trackName;
  final String artistName;
  final String albumName;
  final String albumArtist;
  final String coverUrl;
  final int coverMaxDimension;
  final String outputDir;
  final String albumFolderTemplate;
  final String filenameFormat;
  final String quality;
  final bool embedMetadata;
  final String artistTagMode;
  final MetadataSeparators metadataSeparators;
  final bool embedLyrics;
  final bool embedReplayGain;
  final bool postProcessingEnabled;
  final bool autoConvertDownloads;
  final String autoConvertFormat;
  final String autoConvertBitrate;
  final int autoConvertMaxBitDepth;
  final int autoConvertMaxSampleRate;
  final int trackNumber;
  final int playlistPosition;
  final int discNumber;
  final int totalTracks;
  final int totalDiscs;
  final String releaseDate;
  final String itemId;
  final int durationMs;
  final String source;
  final String genre;
  final String label;
  final String copyright;
  final String composer;
  final String comment;
  final bool explicit;
  final String albumType;
  final String upc;
  final String tidalId;
  final String qobuzId;
  final String deezerId;
  final String lyricsMode;
  final bool useExtensions;
  final bool useFallback;
  final String storageMode;
  final String safTreeUri;
  final String safRelativeDir;
  final String safFileName;
  final String safOutputExt;
  final String outputExt;
  final bool stageSafOutput;
  final bool deferSafPublish;
  final bool requiresContainerConversion;
  final bool allowQualityVariant;
  final String qualityVariant;
  final bool qualityVariantCollisionOnly;
  final String songLinkRegion;
  final int networkConcurrencyLimit;

  const DownloadRequestPayload({
    this.contractVersion = nativeWorkerContractVersion,
    this.isrc = '',
    this.service = '',
    this.downloadProvider = '',
    this.providerTrackId = '',
    this.spotifyId = '',
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.albumArtist = '',
    this.coverUrl = '',
    this.coverMaxDimension = 0,
    required this.outputDir,
    this.albumFolderTemplate = '',
    required this.filenameFormat,
    this.quality = 'LOSSLESS',
    this.embedMetadata = true,
    this.artistTagMode = 'joined',
    this.metadataSeparators = const MetadataSeparators(),
    this.embedLyrics = true,
    this.embedReplayGain = false,
    this.postProcessingEnabled = false,
    this.autoConvertDownloads = false,
    this.autoConvertFormat = 'mp3',
    this.autoConvertBitrate = '320k',
    this.autoConvertMaxBitDepth = 16,
    this.autoConvertMaxSampleRate = 48000,
    this.trackNumber = 0,
    this.playlistPosition = 0,
    this.discNumber = 0,
    this.totalTracks = 1,
    this.totalDiscs = 0,
    this.releaseDate = '',
    this.itemId = '',
    this.durationMs = 0,
    this.source = '',
    this.genre = '',
    this.label = '',
    this.copyright = '',
    this.composer = '',
    this.comment = '',
    this.explicit = false,
    this.albumType = '',
    this.upc = '',
    this.tidalId = '',
    this.qobuzId = '',
    this.deezerId = '',
    this.lyricsMode = 'embed',
    this.useExtensions = false,
    this.useFallback = false,
    this.storageMode = 'app',
    this.safTreeUri = '',
    this.safRelativeDir = '',
    this.safFileName = '',
    this.safOutputExt = '',
    this.outputExt = '',
    this.stageSafOutput = false,
    this.deferSafPublish = false,
    this.requiresContainerConversion = false,
    this.allowQualityVariant = false,
    this.qualityVariant = '',
    this.qualityVariantCollisionOnly = false,
    this.songLinkRegion = 'US',
    this.networkConcurrencyLimit = 3,
  });

  Map<String, dynamic> toJson() {
    return {
      'contract_version': contractVersion,
      'isrc': isrc,
      'service': service,
      'download_provider': downloadProvider,
      'provider_track_id': providerTrackId,
      'spotify_id': spotifyId,
      'track_name': trackName,
      'artist_name': artistName,
      'album_name': albumName,
      'album_artist': albumArtist,
      'cover_url': coverUrl,
      'cover_max_dimension': coverMaxDimension,
      'output_dir': outputDir,
      if (albumFolderTemplate.isNotEmpty)
        'album_folder_template': albumFolderTemplate,
      'filename_format': filenameFormat,
      'quality': quality,
      'embed_metadata': embedMetadata,
      'artist_tag_mode': artistTagMode,
      if (!metadataSeparators.isDefault)
        'metadata_separators': metadataSeparators.toJson(),
      'embed_lyrics': embedLyrics,
      'embed_replaygain': embedReplayGain,
      'post_processing_enabled': postProcessingEnabled,
      'auto_convert_downloads': autoConvertDownloads,
      'auto_convert_format': autoConvertFormat,
      'auto_convert_bitrate': autoConvertBitrate,
      'auto_convert_max_bit_depth': autoConvertMaxBitDepth,
      'auto_convert_max_sample_rate': autoConvertMaxSampleRate,
      'track_number': trackNumber,
      'playlist_position': playlistPosition,
      'disc_number': discNumber,
      'total_tracks': totalTracks,
      'total_discs': totalDiscs,
      'release_date': releaseDate,
      'item_id': itemId,
      'duration_ms': durationMs,
      'source': source,
      'genre': genre,
      'label': label,
      'copyright': copyright,
      'composer': composer,
      'comment': comment,
      'explicit': explicit,
      'album_type': albumType,
      'upc': upc,
      'tidal_id': tidalId,
      'qobuz_id': qobuzId,
      'deezer_id': deezerId,
      'lyrics_mode': lyricsMode,
      'use_extensions': useExtensions,
      'use_fallback': useFallback,
      'storage_mode': storageMode,
      'saf_tree_uri': safTreeUri,
      'saf_relative_dir': safRelativeDir,
      'saf_file_name': safFileName,
      'saf_output_ext': safOutputExt,
      'output_ext': outputExt,
      'stage_saf_output': stageSafOutput,
      'defer_saf_publish': deferSafPublish,
      'requires_container_conversion': requiresContainerConversion,
      'allow_quality_variant': allowQualityVariant,
      'quality_variant': qualityVariant,
      'quality_variant_collision_only': qualityVariantCollisionOnly,
      'songlink_region': songLinkRegion,
      'network_concurrency_limit': networkConcurrencyLimit,
    };
  }

  DownloadRequestPayload withStrategy({
    bool? useExtensions,
    bool? useFallback,
  }) {
    return DownloadRequestPayload(
      contractVersion: contractVersion,
      isrc: isrc,
      service: service,
      downloadProvider: downloadProvider,
      providerTrackId: providerTrackId,
      spotifyId: spotifyId,
      trackName: trackName,
      artistName: artistName,
      albumName: albumName,
      albumArtist: albumArtist,
      coverUrl: coverUrl,
      coverMaxDimension: coverMaxDimension,
      outputDir: outputDir,
      albumFolderTemplate: albumFolderTemplate,
      filenameFormat: filenameFormat,
      quality: quality,
      embedMetadata: embedMetadata,
      artistTagMode: artistTagMode,
      metadataSeparators: metadataSeparators,
      embedLyrics: embedLyrics,
      embedReplayGain: embedReplayGain,
      postProcessingEnabled: postProcessingEnabled,
      autoConvertDownloads: autoConvertDownloads,
      autoConvertFormat: autoConvertFormat,
      autoConvertBitrate: autoConvertBitrate,
      autoConvertMaxBitDepth: autoConvertMaxBitDepth,
      autoConvertMaxSampleRate: autoConvertMaxSampleRate,
      trackNumber: trackNumber,
      playlistPosition: playlistPosition,
      discNumber: discNumber,
      totalTracks: totalTracks,
      totalDiscs: totalDiscs,
      releaseDate: releaseDate,
      itemId: itemId,
      durationMs: durationMs,
      source: source,
      genre: genre,
      label: label,
      copyright: copyright,
      composer: composer,
      comment: comment,
      explicit: explicit,
      albumType: albumType,
      upc: upc,
      tidalId: tidalId,
      qobuzId: qobuzId,
      deezerId: deezerId,
      lyricsMode: lyricsMode,
      useExtensions: useExtensions ?? this.useExtensions,
      useFallback: useFallback ?? this.useFallback,
      storageMode: storageMode,
      safTreeUri: safTreeUri,
      safRelativeDir: safRelativeDir,
      safFileName: safFileName,
      safOutputExt: safOutputExt,
      outputExt: outputExt,
      stageSafOutput: stageSafOutput,
      deferSafPublish: deferSafPublish,
      requiresContainerConversion: requiresContainerConversion,
      allowQualityVariant: allowQualityVariant,
      qualityVariant: qualityVariant,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
      songLinkRegion: songLinkRegion,
      networkConcurrencyLimit: networkConcurrencyLimit,
    );
  }
}
