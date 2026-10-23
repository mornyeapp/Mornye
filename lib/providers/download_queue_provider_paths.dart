// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueuePaths on DownloadQueueNotifier {
  Directory _defaultDocumentsOutputDir(String documentsPath) {
    return Directory('$documentsPath/$_defaultOutputFolderName');
  }

  Directory _defaultAndroidDownloadOutputDir(String storageRootPath) {
    return Directory('$storageRootPath/$_defaultAndroidDownloadSubpath');
  }

  Future<Directory> _ensureDefaultDocumentsOutputDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final musicDir = _defaultDocumentsOutputDir(dir.path);
    if (!await musicDir.exists()) {
      await musicDir.create(recursive: true);
    }
    return musicDir;
  }

  Future<Directory?> _ensureDefaultAndroidDownloadOutputDir() async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) return null;

    final downloadDir = _defaultAndroidDownloadOutputDir(
      dir.parent.parent.parent.parent.path,
    );
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir;
  }

  /// `<Music>/Mornye` on desktop; null when the OS gives no Music folder.
  Future<Directory?> _ensureDefaultDesktopOutputDir() async {
    final path = await resolveDesktopDefaultOutputDirectory();
    if (path == null) return null;
    final musicDir = Directory(path);
    if (!await musicDir.exists()) {
      await musicDir.create(recursive: true);
    }
    return musicDir;
  }

  Future<Directory?> _ensureAndroidAppSpecificOutputDir() async {
    final externalDir = await getExternalStorageDirectory();
    if (externalDir == null) return null;
    final outputDir = Directory(
      '${externalDir.path}${Platform.pathSeparator}$_defaultOutputFolderName',
    );
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    return outputDir;
  }

  bool _pathIsInside(String path, String directory) {
    String normalize(String value) =>
        value.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final normalizedPath = normalize(path);
    final normalizedDirectory = normalize(directory);
    return normalizedPath == normalizedDirectory ||
        normalizedPath.startsWith('$normalizedDirectory/');
  }

  Future<bool> _isDirectoryWritable(Directory directory) async {
    File? probe;
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      probe = File(
        '${directory.path}${Platform.pathSeparator}'
        '.mornye-write-${DateTime.now().microsecondsSinceEpoch}',
      );
      await probe.writeAsBytes(const [0], flush: true);
      return await probe.exists();
    } catch (_) {
      return false;
    } finally {
      if (probe != null) {
        await deleteFileQuietly(probe);
      }
    }
  }

  Future<Directory> _findWritableAppFolder({String? failedOutputDir}) async {
    final candidates = <Future<Directory?> Function()>[
      if (Platform.isAndroid) _ensureDefaultAndroidDownloadOutputDir,
      if (Platform.isAndroid) _ensureAndroidAppSpecificOutputDir,
      if (isDesktopPlatform) _ensureDefaultDesktopOutputDir,
      () async => _ensureDefaultDocumentsOutputDir(),
    ];

    for (final resolveCandidate in candidates) {
      try {
        final candidate = await resolveCandidate();
        if (candidate == null) continue;
        if (_rejectedAppFolderRoots.contains(candidate.path)) continue;
        if (failedOutputDir != null &&
            failedOutputDir.isNotEmpty &&
            _pathIsInside(failedOutputDir, candidate.path)) {
          _rejectedAppFolderRoots.add(candidate.path);
          continue;
        }
        if (await _isDirectoryWritable(candidate)) return candidate;
      } catch (e) {
        _log.w('App-folder fallback candidate is not writable: $e');
      }
    }

    throw const FileSystemException(
      'No writable app-managed download folder is available',
    );
  }

  /// Switches future requests to a verified writable app-managed directory.
  /// Concurrent SAF failures share one resolution so an album download does
  /// not run several write probes or race settings updates.
  Future<String> _activateAppFolderStorageFallback({
    String? failedOutputDir,
  }) async {
    final existing = _appFolderStorageFallback;
    if (existing != null) {
      final existingPath = await existing;
      if (failedOutputDir == null ||
          failedOutputDir.isEmpty ||
          !_pathIsInside(failedOutputDir, existingPath)) {
        return existingPath;
      }
      _rejectedAppFolderRoots.add(existingPath);
      _appFolderStorageFallback = null;
    }

    final fallback = () async {
      final directory = await _findWritableAppFolder(
        failedOutputDir: failedOutputDir,
      );
      state = state.copyWith(outputDir: directory.path);
      _ensuredDirs.add(directory.path);
      await ref
          .read(settingsProvider.notifier)
          .useAppFolderStorage(directory.path);
      _log.w(
        'Storage access failed; switched downloads to app folder: '
        '${directory.path}',
      );
      return directory.path;
    }();
    _appFolderStorageFallback = fallback;
    try {
      return await fallback;
    } finally {
      if (identical(_appFolderStorageFallback, fallback)) {
        _appFolderStorageFallback = null;
      }
    }
  }

  Future<void> _initOutputDir() async {
    if (state.outputDir.isEmpty) {
      try {
        if (Platform.isIOS) {
          final musicDir = await _ensureDefaultDocumentsOutputDir();
          state = state.copyWith(outputDir: musicDir.path);
        } else if (isDesktopPlatform) {
          final musicDir =
              await _ensureDefaultDesktopOutputDir() ??
              await _ensureDefaultDocumentsOutputDir();
          state = state.copyWith(outputDir: musicDir.path);
        } else {
          final musicDir =
              await _ensureDefaultAndroidDownloadOutputDir() ??
              await _ensureDefaultDocumentsOutputDir();
          state = state.copyWith(outputDir: musicDir.path);
        }
      } catch (e) {
        final musicDir = await _ensureDefaultDocumentsOutputDir();
        state = state.copyWith(outputDir: musicDir.path);
      }
    }
  }

  Future<void> _ensureDirExists(String path, {String? label}) async {
    if (_ensuredDirs.contains(path)) return;
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      if (label != null) {
        _log.d('Created $label: $path');
      } else {
        _log.d('Created folder: $path');
      }
    }
    _ensuredDirs.add(path);
  }

  bool _shouldTreatAsSingleRelease(Track track) {
    if (track.isSingle) {
      return true;
    }

    final normalizedAlbumType = normalizeOptionalString(
      track.albumType,
    )?.toLowerCase();
    if (normalizedAlbumType != null && normalizedAlbumType.isNotEmpty) {
      return false;
    }

    final totalTracks = track.totalTracks;
    if (totalTracks == 1) {
      return true;
    }

    final normalizedAlbumName = normalizeOptionalString(
      track.albumName,
    )?.toLowerCase();
    if (normalizedAlbumName == 'single' || normalizedAlbumName == 'singles') {
      return totalTracks == null || totalTracks <= 2;
    }

    return false;
  }

  Future<String> _buildOutputDir(
    Track track,
    AppSettings settings, {
    String? customFolderPath,
    String? playlistName,
  }) async {
    final baseDir = state.outputDir;
    if (settings.createPlaylistFolder &&
        settings.folderOrganization != 'playlist' &&
        playlistName != null &&
        playlistName.isNotEmpty) {
      final playlistFolder = _sanitizeFolderName(playlistName);
      if (playlistFolder.isNotEmpty) {
        await _ensureDirExists(
          '$baseDir${Platform.pathSeparator}$playlistFolder',
          label: 'Playlist folder',
        );
      }
    }

    final relativeDir = _buildRelativeOutputDir(
      track,
      settings,
      customFolderPath: customFolderPath,
      playlistName: playlistName,
    );
    if (relativeDir.isEmpty) {
      return baseDir;
    }

    final fullPath =
        '$baseDir${Platform.pathSeparator}'
        '${relativeDir.replaceAll('/', Platform.pathSeparator)}';
    await _ensureDirExists(fullPath);
    return fullPath;
  }

  String _sanitizeFolderName(String name) {
    final buffer = StringBuffer();
    for (final rune in name.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        continue;
      }
      final char = String.fromCharCode(rune);
      if (_invalidFolderChars.hasMatch(char)) {
        buffer.write(' ');
        continue;
      }
      buffer.write(char);
    }

    var sanitized = buffer.toString().trim();
    sanitized = sanitized.replaceAll(_trimDotsAndSpacesRegex, '');
    sanitized = sanitized.replaceAll(_multiWhitespaceRegex, ' ');
    sanitized = sanitized.replaceAll(_multiUnderscoreRegex, '_');
    sanitized = sanitized.replaceAll(_trimUnderscoresAndSpacesRegex, '');

    if (sanitized.isEmpty) {
      return 'Unknown';
    }
    return sanitized;
  }

  String _truncateUtf8Bytes(String value, int maxBytes) {
    if (maxBytes <= 0 || utf8.encode(value).length <= maxBytes) {
      return value;
    }

    final buffer = StringBuffer();
    var usedBytes = 0;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final charBytes = utf8.encode(char).length;
      if (usedBytes + charBytes > maxBytes) break;
      buffer.write(char);
      usedBytes += charBytes;
    }
    return buffer.toString();
  }

  String _trimSafeName(String value) {
    var trimmed = value.trim();
    trimmed = trimmed.replaceAll(_trimDotsAndSpacesRegex, '');
    trimmed = trimmed.replaceAll(_trimUnderscoresAndSpacesRegex, '');
    return trimmed.isEmpty ? 'Unknown' : trimmed;
  }

  String _sanitizeSafRelativeDir(String relativeDir) {
    if (relativeDir.trim().isEmpty) return '';
    final parts = relativeDir
        .split('/')
        .map(_sanitizeFolderName)
        .map((part) {
          final truncated = _truncateUtf8Bytes(
            part,
            _maxSafDirSegmentUtf8Bytes,
          );
          return _trimSafeName(truncated);
        })
        .where((part) => part.isNotEmpty && part != '.' && part != '..')
        .toList(growable: false);
    return parts.join('/');
  }

  /// Renders the SAF file name for [item]: filename template → sanitized,
  /// byte-limited SAF name (quality-variant aware).
  Future<String> _buildSafFileNameForItem(
    DownloadItem item,
    Track track, {
    required String filenameFormat,
    required String quality,
    required String outputExt,
  }) async {
    final qualityVariant = item.preserveQualityVariant
        ? qualityVariantStagingLabel(item.id)
        : '';
    final baseName = await PlatformBridge.buildFilename(
      filenameFormat,
      _filenameMetadataForTrack(
        track,
        provider: item.service,
        providerTrackId: _knownProviderTrackId(track, item.service),
        quality: quality,
        qualityVariant: qualityVariant,
        playlistPosition: _validPlaylistPosition(item),
      ),
    );
    return _buildSafFileName(
      baseName,
      outputExt,
      qualityVariant: qualityVariant,
    );
  }

  Future<String> _buildSafFileName(
    String baseName,
    String outputExt, {
    String qualityVariant = '',
  }) async {
    final extBytes = utf8.encode(outputExt).length;
    final maxBaseBytes = max(1, _maxSafFilenameUtf8Bytes - extBytes);
    if (qualityVariant.isNotEmpty && baseName.contains(qualityVariant)) {
      final rawPrefix = baseName
          .replaceAll(qualityVariant, '')
          .replaceFirst(RegExp(r'[\s_-]+$'), '');
      final sanitizedPrefix = await PlatformBridge.sanitizeFilename(rawPrefix);
      final suffix = ' - $qualityVariant';
      final prefixBytes = max(1, maxBaseBytes - utf8.encode(suffix).length);
      final truncatedPrefix = _trimSafeName(
        _truncateUtf8Bytes(sanitizedPrefix, prefixBytes),
      );
      return '$truncatedPrefix$suffix$outputExt';
    }
    final sanitized = await PlatformBridge.sanitizeFilename(baseName);
    final truncated = _truncateUtf8Bytes(sanitized, maxBaseBytes);
    return '${_trimSafeName(truncated)}$outputExt';
  }

  static final _featuredArtistPattern = RegExp(
    r'\s*[,;]\s*|\s+(?:feat\.?|ft\.?|featuring|with|x)\s+',
    caseSensitive: false,
  );

  String _extractPrimaryArtist(String artist) {
    final match = _featuredArtistPattern.firstMatch(artist);
    if (match != null && match.start > 0) {
      return artist.substring(0, match.start).trim();
    }
    return artist;
  }

  String _buildRelativeOutputDir(
    Track track,
    AppSettings settings, {
    String? customFolderPath,
    String? playlistName,
  }) {
    final organization = settings.folderOrganization;
    final hasPlaylist = playlistName != null && playlistName.isNotEmpty;
    final playlistPrefix =
        settings.createPlaylistFolder &&
            organization != 'playlist' &&
            hasPlaylist
        ? _sanitizeFolderName(playlistName)
        : '';
    if (!settings.separateSingles && organization == 'custom') {
      return _joinRelativePath(
        playlistPrefix,
        customFolderPath ??
            (throw StateError('Folder template was not resolved')),
      );
    }
    final artistName = _sanitizeFolderName(
      _folderArtistForTrack(track, settings),
    );
    final albumName = _sanitizeFolderName(track.albumName);

    if (settings.separateSingles) {
      final structure = settings.albumFolderStructure;
      if (_shouldTreatAsSingleRelease(track)) {
        return _joinRelativePath(playlistPrefix, switch (structure) {
          'artist_album_singles' => '$artistName/Singles',
          'artist_album_flat' => artistName,
          _ => 'Singles',
        });
      }
      final year = _extractYear(track.releaseDate);
      final yearAlbum = year != null ? '[$year] $albumName' : albumName;
      return _joinRelativePath(playlistPrefix, switch (structure) {
        'artist_album_singles' ||
        'artist_album_flat' => '$artistName/$albumName',
        'album_only' => 'Albums/$albumName',
        'artist_year_album' => 'Albums/$artistName/$yearAlbum',
        'year_album' => 'Albums/$yearAlbum',
        _ => 'Albums/$artistName/$albumName',
      });
    }

    return switch (organization) {
      'playlist' => hasPlaylist ? _sanitizeFolderName(playlistName) : '',
      'artist' => _joinRelativePath(playlistPrefix, artistName),
      'album' => _joinRelativePath(playlistPrefix, albumName),
      'artist_album' => _joinRelativePath(
        playlistPrefix,
        '$artistName/$albumName',
      ),
      _ => playlistPrefix,
    };
  }

  String _joinRelativePath(String prefix, String suffix) {
    if (prefix.isEmpty) return suffix;
    if (suffix.isEmpty) return prefix;
    return '$prefix/$suffix';
  }

  String _folderArtistForTrack(Track track, AppSettings settings) {
    final albumArtist = normalizeOptionalString(track.albumArtist);
    final useAlbumArtist = settings.useAlbumArtistForFolders;
    var artist = useAlbumArtist
        ? albumArtist ?? track.artistName
        : track.artistName;
    if (settings.usePrimaryArtistOnly ||
        (useAlbumArtist &&
            settings.filterContributingArtistsInAlbumArtist &&
            albumArtist != null)) {
      artist = _extractPrimaryArtist(artist);
    }
    return artist;
  }

  Future<String?> _resolveCustomFolderPath(
    Track track,
    DownloadItem item,
    AppSettings settings,
    String quality,
  ) async {
    if (settings.separateSingles || settings.folderOrganization != 'custom') {
      return null;
    }
    return FolderPathTemplate.expand(settings.folderPathTemplate, {
      ..._filenameMetadataForTrack(
        track,
        provider: item.service,
        providerTrackId: _knownProviderTrackId(track, item.service),
        quality: quality,
        playlistPosition: _validPlaylistPosition(item),
      ),
      'artist': _folderArtistForTrack(track, settings),
      'album_artist':
          normalizeOptionalString(track.albumArtist) ?? track.artistName,
      'playlist': item.playlistName ?? '',
    });
  }

  String _unresolvedAlbumFolderTemplate(
    Track track,
    DownloadItem item,
    AppSettings settings,
  ) {
    // Custom paths are already expanded component by component. The native
    // fallback can only replace one preset leaf, not an arbitrary path.
    if (!settings.separateSingles && settings.folderOrganization == 'custom') {
      return '';
    }
    if (track.albumName.trim().isNotEmpty) return '';
    String folderFor(Track value) => _buildRelativeOutputDir(
      value,
      settings,
      playlistName: item.playlistName,
    );
    final planned = folderFor(track);
    final marked = folderFor(track.copyWith(albumName: '{album}'));
    if (planned == marked) return '';
    final leaf = marked.split('/').last;
    return leaf.contains('{album}') ? leaf : '';
  }

  String? _extensionPreferredOutputExt(String service) {
    final normalizedService = service.trim().toLowerCase();
    if (normalizedService.isEmpty) return null;

    final extensionState = ref.read(extensionProvider);
    for (final ext in extensionState.extensions) {
      if (!ext.enabled || !ext.hasDownloadProvider) continue;
      if (ext.id.toLowerCase() != normalizedService) continue;

      final preferred = ext.preferredDownloadOutputExtension;
      if (preferred == null) return null;

      final normalized = preferred.startsWith('.')
          ? preferred.toLowerCase()
          : '.${preferred.toLowerCase()}';
      if (normalized == '.mp4') {
        return '.m4a';
      }
      const allowed = <String>{'.flac', '.m4a', '.mp3', '.opus'};
      if (allowed.contains(normalized)) {
        return normalized;
      }
      return null;
    }

    return null;
  }

  bool _extensionPreservesNativeOutputExt(String service, String ext) {
    final normalizedService = service.trim().toLowerCase();
    final normalizedExt = ext.trim().toLowerCase();
    if (normalizedService.isEmpty || normalizedExt.isEmpty) return false;

    final extensionState = ref.read(extensionProvider);
    return extensionState.extensions.any(
      (ext) =>
          ext.enabled &&
          ext.hasDownloadProvider &&
          ext.id.toLowerCase() == normalizedService &&
          ext.preservedNativeOutputExtensions.contains(normalizedExt),
    );
  }

  bool _extensionRequiresNativeContainerConversion(String service) {
    final normalizedService = service.trim().toLowerCase();
    if (normalizedService.isEmpty) return false;

    final extensionState = ref.read(extensionProvider);
    return extensionState.extensions.any(
      (ext) =>
          ext.enabled &&
          ext.hasDownloadProvider &&
          (ext.id.toLowerCase() == normalizedService ||
              ext.replacesBuiltInProviders.contains(normalizedService)) &&
          ext.requiresNativeContainerConversion,
    );
  }

  bool _shouldRequestContainerConversion(String service, String outputExt) {
    return outputExt.trim().toLowerCase() == '.flac' &&
        _extensionRequiresNativeContainerConversion(service);
  }

  String _determineOutputExt(String quality, String service) {
    final extensionPreferred = _extensionPreferredOutputExt(service);
    if (extensionPreferred != null) {
      return extensionPreferred;
    }
    if (_downloadProviderReplacesLegacyProvider(service, 'tidal') &&
        quality == 'HIGH') {
      return '.m4a';
    }
    final q = quality.toLowerCase();
    if (q == 'alac' || q.startsWith('aac')) return '.m4a';
    if (q.startsWith('opus')) return '.opus';
    if (q.startsWith('mp3')) return '.mp3';
    return '.flac';
  }

  bool _downloadProviderReplacesLegacyProvider(
    String service,
    String legacyProviderId,
  ) {
    return ref
        .read(extensionProvider.notifier)
        .downloadProviderReplacesLegacyProvider(service, legacyProviderId);
  }

  String _mimeTypeForExt(String ext) => switch (ext.toLowerCase()) {
    '.m4a' || '.mp4' => 'audio/mp4',
    '.mp3' => 'audio/mpeg',
    '.opus' => 'audio/ogg',
    '.flac' => 'audio/flac',
    _ => 'application/octet-stream',
  };

  Future<String?> _getSafMimeType(String uri) async {
    try {
      final stat = await PlatformBridge.safStat(uri);
      return stat['mime_type'] as String?;
    } catch (_) {
      return null;
    }
  }

  String? _extractYear(String? releaseDate) {
    if (releaseDate == null || releaseDate.isEmpty) return null;
    final match = _yearRegex.firstMatch(releaseDate);
    return match?.group(1);
  }

  int _validPlaylistPosition(DownloadItem item) {
    final position = item.playlistPosition;
    if (position == null || position <= 0) return 0;
    return position;
  }

  String _filenameFormatForItem(DownloadItem item, String baseFormat) {
    final trimmed = baseFormat.trim();
    if (trimmed.isEmpty) {
      return baseFormat;
    }
    var effective = trimmed;
    if (item.fromBatch &&
        !_batchUniqueFilenameTokenPattern.hasMatch(effective)) {
      effective = '$effective - {track:02} - {title}';
    }
    if (item.preserveQualityVariant) {
      effective = effective.replaceAll(
        RegExp(r'\{quality\}', caseSensitive: false),
        '{quality_variant}',
      );
    }
    if (item.preserveQualityVariant &&
        !_qualityFilenameTokenPattern.hasMatch(effective)) {
      effective = '$effective - {quality_variant}';
    }
    return effective;
  }

  Map<String, dynamic> _filenameMetadataForTrack(
    Track track, {
    required String provider,
    required String providerTrackId,
    required String quality,
    String qualityVariant = '',
    int playlistPosition = 0,
  }) {
    return {
      'title': track.name,
      'artist': track.artistName,
      'album': track.albumName,
      'track': track.trackNumber ?? 0,
      'disc': track.discNumber ?? 0,
      'year': _extractYear(track.releaseDate) ?? '',
      'date': track.releaseDate ?? '',
      'isrc': track.isrc ?? '',
      'provider': provider,
      'provider_id': providerTrackId,
      'playlist_position': playlistPosition,
      'playlistPosition': playlistPosition,
      'quality': quality,
      'quality_variant': qualityVariant,
    };
  }

  String _knownProviderTrackId(Track track, String provider) {
    final normalizedProvider = provider.trim().toLowerCase();
    final normalizedSource = track.source?.trim().toLowerCase() ?? '';
    final rawId = track.id.trim();
    if (rawId.isEmpty) return '';

    if (normalizedSource == normalizedProvider && normalizedSource.isNotEmpty) {
      final separator = rawId.indexOf(':');
      return separator >= 0 && separator + 1 < rawId.length
          ? rawId.substring(separator + 1)
          : rawId;
    }

    final separator = rawId.indexOf(':');
    if (separator > 0 &&
        rawId.substring(0, separator).toLowerCase() == normalizedProvider) {
      return rawId.substring(separator + 1);
    }
    return '';
  }
}
