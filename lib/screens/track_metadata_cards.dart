part of 'track_metadata_screen.dart';

const _trackMetadataHeroScheme = ColorScheme.dark(
  surface: Colors.black,
  onSurface: Colors.white,
  onSurfaceVariant: Colors.white70,
);

/// Content width, inside the page padding, at which the cards split into two
/// columns of about 470 or more each.
const double _trackMetadataTwoColumnMinWidth = 960;

/// The content width for a window [width]: the reading width on phones and
/// small windows, wide enough for the two columns once they fit.
double _trackMetadataContentMaxWidth(double width) =>
    width >= _trackMetadataTwoColumnMinWidth + 32
    ? math.min(width, desktopMaterialContentMaxWidth)
    : adaptiveContentMaxWidth(width);

final ImageFilter _trackMetadataBackdropBlur = ImageFilter.blur(
  sigmaX: 32,
  sigmaY: 32,
);

extension _TrackMetadataCards on _TrackMetadataScreenState {
  List<Widget> _headerMetadataItems(BuildContext context) => [
    if (_displayAudioQuality != null && _displayAudioQuality!.isNotEmpty)
      HeaderMetaItem(_displayAudioQuality!),
    if (duration != null) HeaderMetaItem(formatClock(duration!)),
    if (_service == 'local')
      HeaderMetaItem(
        context.l10n.librarySourceLocal,
        icon: context.isMornye ? CupertinoIcons.folder : Icons.folder,
      )
    else if (_service.isNotEmpty)
      HeaderMetaItem(_service[0].toUpperCase() + _service.substring(1)),
  ];

  Widget _buildAnimatedTrackContent(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) {
    final currentKey = ValueKey<String>('metadata_content_$_itemId');
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[...previousChildren, ?currentChild],
        );
      },
      transitionBuilder: (child, animation) {
        if (_metadataTransitionDirection == 0) {
          return child;
        }
        final isIncoming = child.key == currentKey;
        final direction = _metadataTransitionDirection.toDouble();
        final begin = Offset(
          isIncoming ? 0.18 * direction : -0.18 * direction,
          0,
        );
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return ClipRect(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: begin,
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: animation, child: child),
          ),
        );
      },
      child: Padding(
        key: currentKey,
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = [
              _buildMetadataCard(context, colorScheme, _fileSize),
              const SizedBox(height: 16),
              _buildFileInfoCard(context, colorScheme, _fileExists, _fileSize),
            ];
            final media = [
              _buildLyricsCard(context, colorScheme),
              if (_fileExists) ...[
                const SizedBox(height: 16),
                AudioAnalysisCard(
                  filePath: _filePath,
                  codecHint: _storedAudioFormat,
                  exportName: _buildSaveBaseName(),
                ),
                if (HiResCheckCard.isCandidate(
                  _filePath,
                  _storedAudioFormat,
                )) ...[
                  const SizedBox(height: 16),
                  HiResCheckCard(
                    filePath: _filePath,
                    formatHint: _storedAudioFormat,
                  ),
                ],
              ],
            ];
            Widget column(List<Widget> children) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            );
            final twoColumns =
                constraints.maxWidth >= _trackMetadataTwoColumnMinWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_fileAccessMessage(context) case final message?
                    when !context.isMornye)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      message,
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ),
                // Wide windows put the tags and file facts beside lyrics and
                // analysis instead of one long column of stretched rows.
                if (twoColumns)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: column(details)),
                      const SizedBox(width: 16),
                      Expanded(child: column(media)),
                    ],
                  )
                else
                  column([...details, const SizedBox(height: 16), ...media]),

                if (!context.isMornye) ...[
                  const SizedBox(height: 24),
                  _buildActionButtons(context, ref, colorScheme, _fileExists),
                ],

                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeaderBackground(
    BuildContext context,
    ColorScheme colorScheme,
    double expandedHeight,
    bool showContent,
  ) {
    final coverCacheWidth = coverCacheWidthForViewport(context);
    final backdropCacheWidth = metadataBackdropCacheExtent(context);
    // Downloaded-item entry points must await resolveOrExtract before pushing
    // this route. That precondition keeps the Hero, foreground, and backdrop
    // on one source from the first frame; this synchronous lookup also covers
    // cached rebuilds and in-screen swipe navigation.
    final sharedEmbeddedCoverPath = _hasPath(_embeddedCoverPreviewPath)
        ? _embeddedCoverPreviewPath
        : DownloadedEmbeddedCoverResolver.resolve(_filePath);
    final artworkSource = resolveMetadataArtworkSource(
      embeddedCoverPath: sharedEmbeddedCoverPath,
      localCoverPath: _localCoverPath,
      remoteCoverUrl: _coverUrl,
    );

    Widget artworkImage({required int cacheWidth, int? cacheHeight}) {
      final source = artworkSource;
      if (source == null) {
        return Container(
          color: colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.music_note,
            size: 80,
            color: colorScheme.onSurfaceVariant,
          ),
        );
      }

      if (isHttpCoverUrl(source)) {
        return CachedCoverImage(
          imageUrl: source,
          fit: BoxFit.cover,
          memCacheWidth: cacheWidth,
          memCacheHeight: cacheHeight,
          placeholder: (_, _) => Container(color: colorScheme.surface),
          errorWidget: (_, _, _) => Container(color: colorScheme.surface),
        );
      }

      final filePath = coverFilePath(source);
      if (filePath == null) return Container(color: colorScheme.surface);
      return Image.file(
        File(filePath),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => Container(color: colorScheme.surface),
      );
    }

    Widget coverImage() => artworkImage(cacheWidth: coverCacheWidth);
    Widget backdropImage() => artworkImage(
      cacheWidth: backdropCacheWidth,
      cacheHeight: backdropCacheWidth,
    );

    // Centered square cover over a blurred backdrop (same layout as the album
    // header) so the Hero flight from a list thumbnail keeps its square shape.
    // Landscape headers are short: the cover also yields to the height left
    // below the toolbar after the title block, so nothing rises into it.
    final toolbarBottom = MediaQuery.paddingOf(context).top + kToolbarHeight;
    const textBlockHeight = 190.0;
    // Desktop allows up to 260, close to the desktop album header's cover.
    final coverSize = math.min(
      (MediaQuery.sizeOf(context).width * 0.5).clamp(
        150.0,
        isDesktopPlatform ? 260.0 : 210.0,
      ),
      math.max(96.0, expandedHeight - toolbarBottom - textBlockHeight),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          key: ValueKey<String>('metadata_backdrop_$_itemId'),
          child: ImageFiltered(
            imageFilter: _trackMetadataBackdropBlur,
            child: backdropImage(),
          ),
        ),
        Container(color: Colors.black.withValues(alpha: 0.35)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: expandedHeight * 0.65,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.85),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 40,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: showContent ? 1.0 : 0.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Hero(
                  tag: _coverHeroTag,
                  child: Container(
                    width: coverSize,
                    height: coverSize,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: coverSize,
                        height: coverSize,
                        child: coverImage(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ExplicitTrackTitle(
                  title: trackName,
                  explicit: isExplicit,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  colorScheme: _trackMetadataHeroScheme,
                ),
                const SizedBox(height: 6),
                Text(
                  artistName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  albumName,
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                HeaderPalette(
                  scheme: _trackMetadataHeroScheme,
                  child: HeaderMetaRow(items: _headerMetadataItems(context)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  RoundedRectangleBorder _sectionCardShape(ColorScheme colorScheme) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(
        color: colorScheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _buildMetadataCard(
    BuildContext context,
    ColorScheme colorScheme,
    int? fileSize,
  ) {
    return _metadataSectionSurface(
      context,
      colorScheme,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.trackMetadata,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 16),

            _buildMetadataGrid(context, colorScheme),

            if (upc case final barcodeValue?) ...[
              const SizedBox(height: 16),
              MetadataBarcode(
                value: barcodeValue,
                label: context.l10n.editMetadataFieldUpc,
                onCopy: () => _copyToClipboard(context, barcodeValue),
              ),
            ],

            if (_spotifyId != null && _spotifyId!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final openService = _serviceForTrackId(
                    _spotifyId!,
                    fallbackService: _service.toLowerCase(),
                  );
                  String buttonLabel;
                  if (openService == MusicServices.deezer) {
                    buttonLabel = context.l10n.trackOpenInDeezer;
                  } else if (openService == MusicServices.amazon) {
                    buttonLabel = context.l10n.trackOpenInService(
                      'Amazon Music',
                    );
                  } else if (openService == MusicServices.tidal) {
                    buttonLabel = context.l10n.trackOpenInService('Tidal');
                  } else if (openService == MusicServices.qobuz) {
                    buttonLabel = context.l10n.trackOpenInService('Qobuz');
                  } else {
                    buttonLabel = context.l10n.trackOpenInSpotify;
                  }
                  if (context.isMornye) {
                    return HeaderFilledButton(
                      icon: CupertinoIcons.arrow_up_right_square,
                      label: buttonLabel,
                      onPressed: () => _openServiceUrl(context),
                    );
                  }
                  return ExpressiveButton(
                    outlined: true,
                    onPressed: () => _openServiceUrl(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(buttonLabel),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openServiceUrl(BuildContext context) async {
    if (_spotifyId == null) return;

    final openService = _serviceForTrackId(
      _spotifyId!,
      fallbackService: _service.toLowerCase(),
    );
    // Unknown services open as Spotify, as this button always has.
    final link = ServiceTrackLink(
      openService,
      _displayServiceTrackId(_spotifyId!),
    );
    final webUrl = link.webUrl;
    final appUri = link.appUri;
    final serviceName = link.serviceName;

    try {
      final launched = await launchUrl(
        appUri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        await launchUrl(
          Uri.parse(webUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (e) {
      try {
        await launchUrl(
          Uri.parse(webUrl),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        if (context.mounted) {
          _copyToClipboard(context, webUrl);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.snackbarUrlCopied(serviceName)),
            ),
          );
        }
      }
    }
  }

  Widget _buildMetadataGrid(BuildContext context, ColorScheme colorScheme) {
    final audioQualityStr = _displayAudioQuality;
    final replayGainTrackGain = normalizeOptionalString(
      _editedMetadata?['replaygain_track_gain']?.toString(),
    );
    final replayGainTrackPeak = normalizeOptionalString(
      _editedMetadata?['replaygain_track_peak']?.toString(),
    );
    final replayGainAlbumGain = normalizeOptionalString(
      _editedMetadata?['replaygain_album_gain']?.toString(),
    );
    final replayGainAlbumPeak = normalizeOptionalString(
      _editedMetadata?['replaygain_album_peak']?.toString(),
    );

    final items = <_MetadataItem>[
      _MetadataItem(context.l10n.trackTrackName, trackName),
      _MetadataItem(context.l10n.trackArtist, artistName),
      if (albumArtist != null && albumArtist != artistName)
        _MetadataItem(context.l10n.trackAlbumArtist, albumArtist!),
      _MetadataItem(context.l10n.trackAlbum, albumName),
      if (trackNumber != null && trackNumber! > 0)
        _MetadataItem(context.l10n.trackTrackNumber, trackNumber.toString()),
      if (totalTracks != null && totalTracks! > 0)
        _MetadataItem(
          context.l10n.editMetadataFieldTrackTotal,
          totalTracks.toString(),
        ),
      if (discNumber != null && discNumber! > 0)
        _MetadataItem(context.l10n.trackDiscNumber, discNumber.toString()),
      if (totalDiscs != null && totalDiscs! > 0)
        _MetadataItem(
          context.l10n.editMetadataFieldDiscTotal,
          totalDiscs.toString(),
        ),
      if (duration != null)
        _MetadataItem(context.l10n.trackDuration, formatClock(duration!)),
      if (audioQualityStr != null)
        _MetadataItem(context.l10n.trackAudioQuality, audioQualityStr),
      if (_editedMetadata?['bpm'] case final int bpm when bpm > 0)
        _MetadataItem(context.l10n.trackBpm, bpm.toString()),
      if (normalizeOptionalString(_editedMetadata?['mood']?.toString())
          case final String mood)
        _MetadataItem(context.l10n.trackMood, mood),
      if (replayGainTrackGain != null)
        _MetadataItem(
          context.l10n.trackReplayGainTrackGain,
          replayGainTrackGain,
        ),
      if (replayGainTrackPeak != null)
        _MetadataItem(
          context.l10n.trackReplayGainTrackPeak,
          replayGainTrackPeak,
        ),
      if (replayGainAlbumGain != null)
        _MetadataItem(
          context.l10n.trackReplayGainAlbumGain,
          replayGainAlbumGain,
        ),
      if (replayGainAlbumPeak != null)
        _MetadataItem(
          context.l10n.trackReplayGainAlbumPeak,
          replayGainAlbumPeak,
        ),
      if (_embeddedCoverDimensions case final dimensions?)
        _MetadataItem(
          context.l10n.trackCoverResolution,
          '${dimensions.width} × ${dimensions.height} px',
        ),
      if (releaseDate != null && releaseDate!.isNotEmpty)
        _MetadataItem(context.l10n.trackReleaseDate, releaseDate!),
      if (genre != null && genre!.isNotEmpty)
        _MetadataItem(context.l10n.trackGenre, genre!),
      if (label != null && label!.isNotEmpty)
        _MetadataItem(context.l10n.trackLabel, label!),
      if (copyright != null && copyright!.isNotEmpty)
        _MetadataItem(context.l10n.trackCopyright, copyright!),
      if (composer != null && composer!.isNotEmpty)
        _MetadataItem(context.l10n.editMetadataFieldComposer, composer!),
      if (albumType != null)
        _MetadataItem(context.l10n.trackAlbumType, albumType!),
      if (comment != null)
        _MetadataItem(context.l10n.editMetadataFieldComment, comment!),
      if (isrc != null && isrc!.isNotEmpty)
        _MetadataItem(
          'ISRC',
          formatIsrcForDisplay(isrc),
          rawValue: canonicalIsrcForCopy(isrc),
        ),
    ];

    if (!_isLocalItem && _spotifyId != null && _spotifyId!.isNotEmpty) {
      final idService = _serviceForTrackId(
        _spotifyId!,
        fallbackService: _service.toLowerCase(),
      );
      final cleanId = _displayServiceTrackId(_spotifyId!);
      String idLabel;
      switch (idService) {
        case MusicServices.deezer:
          idLabel = 'Deezer ID';
        case MusicServices.amazon:
          idLabel = 'Amazon ASIN';
        case MusicServices.tidal:
          idLabel = 'Tidal ID';
        case MusicServices.qobuz:
          idLabel = 'Qobuz ID';
        default:
          idLabel = 'Spotify ID';
      }
      items.add(_MetadataItem(idLabel, cleanId));
    }

    items.add(
      _MetadataItem(context.l10n.trackMetadataService, _service.toUpperCase()),
    );
    items.add(
      _MetadataItem(context.l10n.trackDownloaded, _formatFullDate(_addedAt)),
    );

    return Column(
      children: items.map((metadata) {
        final isCopyable =
            metadata.label == 'ISRC' ||
            metadata.label == 'Spotify ID' ||
            metadata.label == 'Deezer ID' ||
            metadata.label == 'Amazon ASIN' ||
            metadata.label == 'Tidal ID' ||
            metadata.label == 'Qobuz ID';
        if (context.isMornye) {
          return MornyeMetadataRow(
            label: metadata.label,
            value: metadata.value,
            showDivider: metadata != items.last,
            trailing: isCopyable
                ? Icon(
                    CupertinoIcons.doc_on_doc,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  )
                : null,
            onTap: isCopyable
                ? () => _copyToClipboard(context, metadata.rawValue)
                : null,
            onLongPress: () => _showMetadataCopySheet(
              context,
              metadata: metadata,
              allMetadata: items,
            ),
          );
        }
        return InkWell(
          onTap: isCopyable
              ? () => _copyToClipboard(context, metadata.rawValue)
              : null,
          onLongPress: () => _showMetadataCopySheet(
            context,
            metadata: metadata,
            allMetadata: items,
          ),
          borderRadius: BorderRadius.circular(8),
          // Copyable rows keep the 48dp minimum touch target.
          child: Container(
            constraints: BoxConstraints(
              minHeight: context.tokens.minTouchTarget,
            ),
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SizedBox(
                  width: 100,
                  child: Text(
                    metadata.label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    metadata.value,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                if (isCopyable)
                  Icon(
                    Icons.copy,
                    size: 14,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _showMetadataCopySheet(
    BuildContext context, {
    required _MetadataItem metadata,
    required List<_MetadataItem> allMetadata,
  }) async {
    final action = await showAppBottomSheet<String>(
      context: context,
      title: metadata.label,
      subtitle: metadata.value,
      maxHeightFactor: 0.58,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.content_copy_rounded,
                showIconInMornye: true,
                title: sheetContext.l10n.metadataCopyValue,
                onTap: () => Navigator.pop(sheetContext, 'value'),
              ),
              SettingsItem(
                icon: Icons.label_outline_rounded,
                showIconInMornye: true,
                title: sheetContext.l10n.metadataCopyField,
                onTap: () => Navigator.pop(sheetContext, 'field'),
              ),
              SettingsItem(
                icon: Icons.copy_all_rounded,
                showIconInMornye: true,
                title: sheetContext.l10n.metadataCopyAll,
                showDivider: false,
                onTap: () => Navigator.pop(sheetContext, 'all'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    final text = switch (action) {
      'field' => '${metadata.label}: ${metadata.rawValue}',
      'all' =>
        allMetadata.map((item) => '${item.label}: ${item.rawValue}').join('\n'),
      _ => metadata.rawValue,
    };
    _copyToClipboard(context, text);
  }

  String _formatLabelForRaw(String raw) {
    final normalized = raw.toLowerCase().replaceAll('-', '_');
    return switch (normalized) {
      'flac' => 'FLAC',
      'alac' => 'ALAC',
      'wav' || 'wave' => 'WAV',
      'aiff' || 'aif' || 'aifc' => 'AIFF',
      'eac3' || 'ec_3' => 'EAC3',
      'ac3' || 'ac_3' => 'AC3',
      'ac4' || 'ac_4' => 'AC4',
      'aac' || 'mp4a' => 'AAC',
      'm4a' || 'mp4' => 'M4A',
      'mp3' => 'MP3',
      'opus' => 'Opus',
      'ogg' => 'OGG',
      _ => raw.toUpperCase(),
    };
  }

  String _displayFormatLabelForFile(String fileName) {
    final storedFormat = normalizeOptionalString(_storedAudioFormat);
    final raw =
        storedFormat ??
        (fileName.contains('.') ? fileName.split('.').last : 'Unknown');
    return _formatLabelForRaw(raw);
  }

  bool _isBitrateFormatLabel(String label) {
    return const {
      'MP3',
      'OPUS',
      'OGG',
      'M4A',
      'AAC',
      'EAC3',
      'AC3',
      'AC4',
    }.contains(label.toUpperCase());
  }

  /// One file detail pill. Only the format is emphasized, so the group keeps
  /// a single strong container; the others stay neutral.
  Widget _fileInfoPill(
    ColorScheme colorScheme,
    String label, {
    bool emphasized = false,
    IconData? icon,
  }) {
    final foreground = emphasized
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: emphasized
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileInfoCard(
    BuildContext context,
    ColorScheme colorScheme,
    bool fileExists,
    int? fileSize,
  ) {
    final displayFilePath = _formatPathForDisplay(rawFilePath);
    final fileName = _extractFileNameFromPathOrUri(rawFilePath);
    final fileExtension = _displayFormatLabelForFile(fileName);
    final resolvedQuality = _displayAudioQuality;
    final lossyBitrateLabel = _extractLossyBitrateLabel(resolvedQuality);

    return _metadataSectionSurface(
      context,
      colorScheme,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.trackFileInfo,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 16),

            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _fileInfoPill(colorScheme, fileExtension, emphasized: true),
                if (fileSize != null)
                  _fileInfoPill(colorScheme, formatBytes(fileSize)),
                if (_isBitrateFormatLabel(fileExtension) &&
                    lossyBitrateLabel != null)
                  _fileInfoPill(colorScheme, lossyBitrateLabel)
                else if (_audioBitrate != null &&
                    _audioBitrate! > 0 &&
                    _isBitrateFormatLabel(fileExtension))
                  _fileInfoPill(colorScheme, '${_audioBitrate}kbps')
                else if (bitDepth != null &&
                    bitDepth! > 0 &&
                    sampleRate != null)
                  _fileInfoPill(
                    colorScheme,
                    buildDisplayAudioQuality(
                          bitDepth: bitDepth,
                          sampleRate: sampleRate,
                        ) ??
                        '',
                  ),
                if (!_isBitrateFormatLabel(fileExtension) &&
                    _audioBitrate != null &&
                    _audioBitrate! > 0)
                  _fileInfoPill(colorScheme, '${_audioBitrate}kbps'),
                _fileInfoPill(
                  colorScheme,
                  _service.toUpperCase(),
                  icon: _getServiceIcon(_service),
                ),
              ],
            ),

            const SizedBox(height: 16),

            InkWell(
              onTap: () => _copyToClipboard(context, cleanFilePath),
              borderRadius: BorderRadius.circular(12),
              // Material keeps the path as a flat copy row like the metadata
              // rows above, instead of a filled box inside the card.
              child: Container(
                constraints: BoxConstraints(
                  minHeight: context.tokens.minTouchTarget,
                ),
                padding: context.isMornye
                    ? const EdgeInsets.all(12)
                    : const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                decoration: context.isMornye
                    ? BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      )
                    : null,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayFilePath,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      context.isMornye ? CupertinoIcons.doc_on_doc : Icons.copy,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
