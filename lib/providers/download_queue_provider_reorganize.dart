// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

final _playlistFolderTokenPattern = RegExp(
  r'\{playlist(?:_position|position| position)?(?::\d+)?\}',
  caseSensitive: false,
);

class _StoredLocation {
  const _StoredLocation(this.relativeDir, this.fileName);
  final String relativeDir;
  final String fileName;
}

class _RuleTarget {
  const _RuleTarget(this.relativeDir, this.fileName);
  final String relativeDir;
  final String fileName;
}

/// What the rules need about one stored track, from either source.
class _TrackFacts {
  const _TrackFacts(this.track, {this.service = '', this.quality = ''});
  final Track track;
  final String service;
  final String quality;
}

/// The Local Library scan names a file with no artist tag "Unknown Artist".
const _untaggedArtist = 'unknown artist';

/// Re-applies the Files settings (folder organization and filename format)
/// to tracks already on disk, not only to new downloads: Mornye's downloads
/// and the files the Local Library scan found inside the download folder.
extension DownloadQueueLibraryReorganization on DownloadQueueNotifier {
  /// Moving files while the queue writes into the same folders could race
  /// with a download that is resolving its own destination.
  bool get hasActiveDownloads => state.items.any(
    (item) =>
        item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing,
  );

  /// Works out where every track in the download folder would be stored
  /// under the current rules. Downloads come from history; other files come
  /// from the Local Library scan, so a folder must be scanned as a Local
  /// Library source for its files to be included. Nothing is moved; see
  /// [applyLibraryReorganization].
  ///
  /// Throws [FormatException] when the custom folder template is invalid.
  Future<LibraryReorganizationPlan> planLibraryReorganization({
    void Function(int scanned)? onScanned,
  }) async {
    final settings = ref.read(settingsProvider);
    updateSettings(settings);
    final safMode = _isSafMode(settings);
    if (!safMode && state.outputDir.isEmpty) await _initOutputDir();
    final root = safMode
        ? settings.downloadTreeUri
        : p.normalize(plainWindowsPath(state.outputDir));

    if (!settings.separateSingles && settings.folderOrganization == 'custom') {
      // Fail fast with a clear error instead of once per track.
      FolderPathTemplate.segments(settings.folderPathTemplate);
    }
    final keepsPlaylistFolders =
        !settings.separateSingles &&
        (settings.folderOrganization == 'playlist' ||
            (settings.folderOrganization == 'custom' &&
                _playlistFolderTokenPattern.hasMatch(
                  settings.folderPathTemplate,
                )));
    final dropsPlaylistFolders =
        !keepsPlaylistFolders && settings.createPlaylistFolder;

    final movesBySource = <String, LibraryReorganizationMove>{};
    // Every file already accounted for, keyed by [_pathKey]. For downloads
    // the value collects the history rows that point at the file.
    final idsBySource = <String, List<String>>{};
    final occupied = <String>[];
    var alreadyOrganized = 0;
    var outside = 0;
    var missing = 0;
    var untagged = 0;
    var scanned = 0;

    Future<void> consider({
      required String key,
      required String filePath,
      required _StoredLocation location,
      required _TrackFacts facts,
      required List<String> historyIds,
    }) async {
      final target = await _reorganizationTarget(
        facts,
        settings,
        location,
        safMode: safMode,
        keepCurrentFolder: keepsPlaylistFolders,
      );
      final sameDir = _sameStoredName(
        target.relativeDir,
        location.relativeDir,
        ignoreCase: safMode,
      );
      final sameName = _sameStoredName(
        target.fileName,
        location.fileName,
        ignoreCase: safMode,
      );
      if (sameDir && sameName) {
        alreadyOrganized++;
        occupied.add(
          joinRelativeLibraryPath(location.relativeDir, location.fileName),
        );
        return;
      }
      movesBySource[key] = LibraryReorganizationMove(
        historyIds: historyIds,
        trackName: facts.track.name,
        sourcePath: filePath,
        sourceRelativeDir: location.relativeDir,
        sourceFileName: location.fileName,
        targetRelativeDir: target.relativeDir,
        targetFileName: target.fileName,
      );
    }

    const pageSize = 500;
    for (var offset = 0; ; offset += pageSize) {
      final rows = await HistoryDatabase.instance.getAll(
        limit: pageSize,
        offset: offset,
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        scanned++;
        final DownloadHistoryItem item;
        try {
          item = DownloadHistoryItem.fromJson(row);
        } catch (e) {
          _log.w('Skipping unreadable history row during reorganize: $e');
          continue;
        }
        final key = _pathKey(item.filePath, safMode: safMode);
        final sharedIds = idsBySource[key];
        if (sharedIds != null) {
          // Another history row already accounts for this file.
          sharedIds.add(item.id);
          continue;
        }

        final location = _storedLocation(item, root: root, safMode: safMode);
        if (location == null) {
          outside++;
          continue;
        }
        if (!safMode && !await File(item.filePath).exists()) {
          missing++;
          continue;
        }
        final historyIds = idsBySource[key] = [item.id];
        await consider(
          key: key,
          filePath: item.filePath,
          location: location,
          facts: _TrackFacts(
            _trackFromHistory(item),
            service: item.service,
            quality: item.quality ?? '',
          ),
          historyIds: historyIds,
        );
      }
      onScanned?.call(scanned);
      if (rows.length < pageSize) break;
    }

    for (var offset = 0; ; offset += pageSize) {
      final rows = await LibraryDatabase.instance.getPage(
        limit: pageSize,
        offset: offset,
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        scanned++;
        final LocalLibraryItem item;
        try {
          item = LocalLibraryItem.fromJson(row);
        } catch (e) {
          _log.w('Skipping unreadable library row during reorganize: $e');
          continue;
        }
        // A CUE track is a slice of a shared file, not a file of its own.
        if (isCueVirtualPath(item.filePath)) continue;
        final key = _pathKey(item.filePath, safMode: safMode);
        // Downloads were planned above with their richer history metadata.
        if (idsBySource.containsKey(key)) continue;
        idsBySource[key] = const [];

        final location = _libraryLocation(
          item.filePath,
          root: root,
          safMode: safMode,
        );
        if (location == null) {
          outside++;
          continue;
        }
        final artist = item.artistName.trim();
        if (item.trackName.trim().isEmpty ||
            artist.isEmpty ||
            artist.toLowerCase() == _untaggedArtist) {
          // Without tags the rules would only file it under "Unknown".
          untagged++;
          continue;
        }
        if (!safMode && !await File(item.filePath).exists()) {
          missing++;
          continue;
        }
        await consider(
          key: key,
          filePath: item.filePath,
          location: location,
          facts: _TrackFacts(_trackFromLibrary(item)),
          historyIds: const [],
        );
      }
      onScanned?.call(scanned);
      if (rows.length < pageSize) break;
    }

    final moves = <LibraryReorganizationMove>[];
    for (final move in resolveLibraryReorganizationConflicts(
      movesBySource.values.toList(growable: false),
      occupied: occupied,
    )) {
      // A file already carrying the de-duplicated name it would get is fine
      // where it is.
      if (_sameStoredName(
        move.sourceDisplayPath,
        move.targetDisplayPath,
        ignoreCase: safMode,
      )) {
        alreadyOrganized++;
      } else {
        moves.add(move);
      }
    }
    _log.i(
      'Reorganize plan: ${moves.length} to move, $alreadyOrganized organized, '
      '$outside outside download folder, $missing missing, '
      '$untagged untagged',
    );
    return LibraryReorganizationPlan(
      root: root,
      safMode: safMode,
      moves: moves,
      alreadyOrganized: alreadyOrganized,
      outsideDownloadFolder: outside,
      missing: missing,
      untagged: untagged,
      keepsPlaylistFolders: keepsPlaylistFolders,
      dropsPlaylistFolders: dropsPlaylistFolders,
    );
  }

  /// Moves the files in [plan]. The caller should reload history and the
  /// local library afterwards.
  Future<LibraryReorganizationResult> applyLibraryReorganization(
    LibraryReorganizationPlan plan, {
    void Function(int done, LibraryReorganizationMove move)? onProgress,
    bool Function()? isCancelled,
    LibraryReorganizer? reorganizer,
  }) async {
    String? scope;
    if (!plan.safMode) {
      try {
        scope = await PlatformBridge.acquireDownloadDirectory(plan.root);
      } catch (e) {
        _log.w('Could not acquire download folder access: $e');
      }
    }
    try {
      return await (reorganizer ?? LibraryReorganizer()).run(
        plan,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } finally {
      if (scope != null && scope.isNotEmpty) {
        try {
          await PlatformBridge.releaseDownloadDirectory(scope);
        } catch (e) {
          _log.w('Failed to release download folder access: $e');
        }
      }
    }
  }

  bool _sameStoredName(String a, String b, {required bool ignoreCase}) =>
      ignoreCase ? a.toLowerCase() == b.toLowerCase() : a == b;

  /// Identity of a stored file across history and the Local Library.
  /// Windows paths ignore case and the verbatim `\\?\` prefix, as the file
  /// system does.
  String _pathKey(String path, {required bool safMode}) {
    final trimmed = path.trim();
    if (safMode || isContentUri(trimmed)) return trimmed;
    final normalized = p.normalize(plainWindowsPath(trimmed));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// Where [item] currently lives relative to the download folder, or null
  /// when it is stored elsewhere (another folder, another SAF tree, network).
  _StoredLocation? _storedLocation(
    DownloadHistoryItem item, {
    required String root,
    required bool safMode,
  }) {
    final path = item.filePath.trim();
    if (path.isEmpty) return null;
    if (safMode) {
      final fileName = normalizeOptionalString(item.safFileName);
      if (!isContentUri(path) ||
          fileName == null ||
          item.storageMode != 'saf' ||
          item.downloadTreeUri != root) {
        return null;
      }
      return _StoredLocation(
        normalizeRelativeLibraryDir(item.safRelativeDir ?? ''),
        fileName,
      );
    }
    return _localLocation(path, root);
  }

  /// Like [_storedLocation] for a Local Library row, which knows only its
  /// path. A SAF row counts when its document is inside the download tree.
  _StoredLocation? _libraryLocation(
    String filePath, {
    required String root,
    required bool safMode,
  }) {
    final path = filePath.trim();
    if (path.isEmpty) return null;
    if (safMode) {
      final document = resolveSafDocumentLocation(path);
      if (document == null || !_sameSafTree(document.treeUri, root)) {
        return null;
      }
      return _StoredLocation(
        normalizeRelativeLibraryDir(document.relativeDir),
        document.fileName,
      );
    }
    return _localLocation(path, root);
  }

  _StoredLocation? _localLocation(String path, String root) {
    if (isContentUri(path) || root.isEmpty) return null;
    // Scanned Windows files arrive as `\\?\C:\…`; compare plain spellings.
    final normalized = p.normalize(plainWindowsPath(path));
    if (!p.isWithin(root, normalized)) return null;
    final relativeDir = p.relative(p.dirname(normalized), from: root);
    return _StoredLocation(
      normalizeRelativeLibraryDir(relativeDir == '.' ? '' : relativeDir),
      p.basename(normalized),
    );
  }

  /// Tree URIs differ in percent-encoding depending on who built them.
  bool _sameSafTree(String a, String b) {
    String canonical(String uri) {
      try {
        return Uri.decodeFull(uri).toLowerCase();
      } catch (_) {
        return uri.toLowerCase();
      }
    }

    return canonical(a) == canonical(b);
  }

  Track _trackFromHistory(DownloadHistoryItem item) => Track(
    id: normalizeOptionalString(item.spotifyId) ?? item.id,
    name: item.trackName,
    artistName: item.artistName,
    albumName: item.albumName,
    albumArtist: item.albumArtist,
    coverUrl: item.coverUrl,
    isrc: item.isrc,
    duration: item.duration ?? 0,
    trackNumber: item.trackNumber,
    discNumber: item.discNumber,
    totalDiscs: item.totalDiscs,
    releaseDate: item.releaseDate,
    totalTracks: item.totalTracks,
    composer: item.composer,
    genre: item.genre,
    label: item.label,
    copyright: item.copyright,
    explicit: item.explicit,
  );

  Track _trackFromLibrary(LocalLibraryItem item) => Track(
    id: item.id,
    name: item.trackName,
    artistName: item.artistName,
    albumName: item.albumName,
    albumArtist: item.albumArtist,
    isrc: item.isrc,
    duration: item.duration ?? 0,
    trackNumber: item.trackNumber,
    discNumber: item.discNumber,
    totalDiscs: item.totalDiscs,
    releaseDate: item.releaseDate,
    totalTracks: item.totalTracks,
    composer: item.composer,
    genre: item.genre,
    label: item.label,
    copyright: item.copyright,
    explicit: item.explicit,
  );

  /// Neither source keeps the release type, so single/album is inferred
  /// from the track count. When that guess would put the track in a different
  /// folder than the other classification, and the file already sits in the
  /// other one's folder (say a 3-track EP filed under Singles), the existing
  /// placement wins. Filenames alone are never used as evidence: they are
  /// exactly what a changed filename rule is meant to replace.
  Future<_RuleTarget> _reorganizationTarget(
    _TrackFacts facts,
    AppSettings settings,
    _StoredLocation current, {
    required bool safMode,
    required bool keepCurrentFolder,
  }) async {
    final track = facts.track;
    Future<_RuleTarget> targetFor(Track candidate) => _ruleTargetFor(
      candidate,
      facts,
      settings,
      current,
      safMode: safMode,
      keepCurrentFolder: keepCurrentFolder,
    );
    final inferred = await targetFor(track);
    if (!settings.separateSingles ||
        keepCurrentFolder ||
        normalizeOptionalString(track.albumType) != null) {
      return inferred;
    }
    bool sameDir(String a, String b) =>
        _sameStoredName(a, b, ignoreCase: safMode);
    if (sameDir(inferred.relativeDir, current.relativeDir)) return inferred;
    final alternative = await targetFor(
      track.copyWith(
        albumType: _shouldTreatAsSingleRelease(track) ? 'album' : 'single',
      ),
    );
    final alternativeFitsCurrentFolder =
        !sameDir(alternative.relativeDir, inferred.relativeDir) &&
        sameDir(alternative.relativeDir, current.relativeDir);
    return alternativeFitsCurrentFolder ? alternative : inferred;
  }

  Future<_RuleTarget> _ruleTargetFor(
    Track track,
    _TrackFacts facts,
    AppSettings settings,
    _StoredLocation current, {
    required bool safMode,
    required bool keepCurrentFolder,
  }) async {
    final service = facts.service;
    final providerTrackId = service.isEmpty
        ? ''
        : _knownProviderTrackId(track, service);
    final quality = facts.quality;

    final String relativeDir;
    if (keepCurrentFolder) {
      relativeDir = current.relativeDir;
    } else {
      final customFolderPath =
          !settings.separateSingles && settings.folderOrganization == 'custom'
          ? await FolderPathTemplate.expand(settings.folderPathTemplate, {
              ..._filenameMetadataForTrack(
                track,
                provider: service,
                providerTrackId: providerTrackId,
                quality: quality,
              ),
              'artist': _folderArtistForTrack(track, settings),
              'album_artist':
                  normalizeOptionalString(track.albumArtist) ??
                  track.artistName,
              'playlist': '',
            })
          : null;
      // No playlistName: the source playlist is not recorded, so no
      // playlist folder prefix is added.
      final raw = _buildRelativeOutputDir(
        track,
        settings,
        customFolderPath: customFolderPath,
      );
      relativeDir = normalizeRelativeLibraryDir(
        safMode ? _sanitizeSafRelativeDir(raw) : raw,
      );
    }

    final baseFormat = _shouldTreatAsSingleRelease(track)
        ? settings.singleFilenameFormat
        : settings.filenameFormat;
    var format = baseFormat.trim();
    if (format.isEmpty) format = '{title} - {artist}';
    // Same rule album/playlist downloads use: a format without a per-track
    // token would give every track of an album the same name.
    if (!_batchUniqueFilenameTokenPattern.hasMatch(format)) {
      format = '$format - {track:02} - {title}';
    }

    var baseName = await PlatformBridge.buildFilename(
      format,
      _filenameMetadataForTrack(
        track,
        provider: service,
        providerTrackId: providerTrackId,
        quality: quality,
      ),
    );
    if (baseName.trim().isEmpty) {
      baseName = '${track.artistName} - ${track.name}';
    }
    final extension = _storedExtension(current.fileName);
    final fileName = safMode
        ? await _buildSafFileName(baseName, extension)
        : '${await PlatformBridge.sanitizeFilename(baseName)}$extension';
    return _RuleTarget(relativeDir, fileName);
  }

  String _storedExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(dot) : '';
  }
}
