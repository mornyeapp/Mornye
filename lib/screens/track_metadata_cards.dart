part of 'track_metadata_screen.dart';

/// Content width, inside the page padding, at which the cards split into two
/// columns of about 470 or more each.
const double _trackMetadataTwoColumnMinWidth = 960;

/// The content width for a window [width]: the reading width on phones and
/// small windows, wide enough for the two columns once they fit.
double _trackMetadataContentMaxWidth(double width) =>
    width >= _trackMetadataTwoColumnMinWidth + 32
    ? math.min(width, desktopMaterialContentMaxWidth)
    : adaptiveContentMaxWidth(width);

/// Inner padding of a section, the same as the analysis cards below them.
const double _trackMetadataSectionPadding = 20;

/// The song's facts by the section that shows them. [all] keeps them in
/// reading order for Copy all.
typedef _MetadataFacts = ({
  List<_MetadataItem> tags,
  List<_MetadataItem> release,
  List<_MetadataItem> audio,
  List<_MetadataItem> file,
  List<_MetadataItem> all,
});

extension _TrackMetadataCards on _TrackMetadataScreenState {
  Widget _buildAnimatedTrackContent(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) {
    final currentKey = ValueKey<String>('metadata_content_$_itemId');
    final incoming = AppMotion.effects(
      context,
      AppMotionSpec(context.tokens.motionMedium, Curves.easeOutCubic),
    );
    final outgoing = AppMotion.effectsFast(
      context,
      AppMotionSpec(context.tokens.motionFast, Curves.easeInCubic),
    );
    return AnimatedSwitcher(
      duration: incoming.duration,
      reverseDuration: outgoing.duration,
      switchInCurve: incoming.curve,
      switchOutCurve: outgoing.leaving,
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
        return ClipRect(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: begin,
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
        );
      },
      child: Padding(
        key: currentKey,
        padding: EdgeInsets.all(context.tokens.gapLg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final gap = SizedBox(height: context.tokens.gapLg);
            final facts = _metadataFacts(context);
            final details = [
              _buildFactsSection(
                context,
                colorScheme,
                title: context.l10n.trackMetadata,
                items: facts.tags,
                all: facts.all,
              ),
              if (facts.release.isNotEmpty || upc != null || _hasServiceLink)
                _buildFactsSection(
                  context,
                  colorScheme,
                  title: context.l10n.trackSectionRelease,
                  items: facts.release,
                  all: facts.all,
                  footer: [
                    if (upc case final barcodeValue?)
                      MetadataBarcode(
                        value: barcodeValue,
                        label: context.l10n.editMetadataFieldUpc,
                        onCopy: () => _copyToClipboard(context, barcodeValue),
                      ),
                    if (_hasServiceLink) _buildOpenServiceButton(context),
                  ],
                ),
              if (facts.audio.isNotEmpty)
                _buildFactsSection(
                  context,
                  colorScheme,
                  title: context.l10n.trackSectionAudio,
                  items: facts.audio,
                  all: facts.all,
                ),
              _buildFileInfoCard(context, colorScheme, facts),
            ];
            final media = [
              _buildLyricsCard(context, colorScheme),
              if (_fileExists) ...[
                AudioAnalysisCard(
                  filePath: _filePath,
                  codecHint: _storedAudioFormat,
                  exportName: _buildSaveBaseName(),
                ),
                if (HiResCheckCard.isCandidate(_filePath, _storedAudioFormat))
                  HiResCheckCard(
                    filePath: _filePath,
                    formatHint: _storedAudioFormat,
                    name: '$artistName - $trackName',
                  ),
              ],
            ];
            Widget column(List<Widget> children) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, child) in children.indexed) ...[
                  if (index > 0) gap,
                  child,
                ],
              ],
            );
            final twoColumns =
                constraints.maxWidth >= _trackMetadataTwoColumnMinWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_fileAccessMessage(context) case final message?)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.tokens.gapLg),
                    child: ErrorCard(error: message, colorScheme: colorScheme),
                  ),
                // Wide windows put the tags and file facts beside lyrics and
                // analysis instead of one long column of stretched rows.
                if (twoColumns)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: context.tokens.gapLg,
                    children: [
                      Expanded(child: column(details)),
                      Expanded(child: column(media)),
                    ],
                  )
                else
                  column([...details, ...media]),
                SizedBox(height: context.tokens.gapLg * 2),
              ],
            );
          },
        ),
      ),
    );
  }

  bool get _hasServiceLink => _spotifyId != null && _spotifyId!.isNotEmpty;

  /// The service this song's catalog ID belongs to.
  String get _linkedService =>
      _serviceForTrackId(_spotifyId!, fallbackService: _service.toLowerCase());

  _MetadataFacts _metadataFacts(BuildContext context) {
    final l10n = context.l10n;
    String? edited(String key) =>
        normalizeOptionalString(_editedMetadata?[key]?.toString());
    final replayGainTrackGain = edited('replaygain_track_gain');
    final replayGainTrackPeak = edited('replaygain_track_peak');
    final replayGainAlbumGain = edited('replaygain_album_gain');
    final replayGainAlbumPeak = edited('replaygain_album_peak');

    final tags = <_MetadataItem>[
      _MetadataItem(l10n.trackTrackName, trackName),
      _MetadataItem(l10n.trackArtist, artistName),
      if (albumArtist != null && albumArtist != artistName)
        _MetadataItem(l10n.trackAlbumArtist, albumArtist!),
      _MetadataItem(l10n.trackAlbum, albumName),
      if (trackNumber != null && trackNumber! > 0)
        _MetadataItem(l10n.trackTrackNumber, trackNumber.toString()),
      if (totalTracks != null && totalTracks! > 0)
        _MetadataItem(l10n.editMetadataFieldTrackTotal, totalTracks.toString()),
      if (discNumber != null && discNumber! > 0)
        _MetadataItem(l10n.trackDiscNumber, discNumber.toString()),
      if (totalDiscs != null && totalDiscs! > 0)
        _MetadataItem(l10n.editMetadataFieldDiscTotal, totalDiscs.toString()),
      if (releaseDate != null && releaseDate!.isNotEmpty)
        _MetadataItem(l10n.trackReleaseDate, releaseDate!),
      if (genre != null && genre!.isNotEmpty)
        _MetadataItem(l10n.trackGenre, genre!),
      if (edited('mood') case final String mood)
        _MetadataItem(l10n.trackMood, mood),
      if (composer != null && composer!.isNotEmpty)
        _MetadataItem(l10n.editMetadataFieldComposer, composer!),
      if (comment != null)
        _MetadataItem(l10n.editMetadataFieldComment, comment!),
    ];

    final release = <_MetadataItem>[
      if (albumType != null) _MetadataItem(l10n.trackAlbumType, albumType!),
      if (label != null && label!.isNotEmpty)
        _MetadataItem(l10n.trackLabel, label!),
      if (copyright != null && copyright!.isNotEmpty)
        _MetadataItem(l10n.trackCopyright, copyright!),
      if (isrc != null && isrc!.isNotEmpty)
        _MetadataItem(
          'ISRC',
          formatIsrcForDisplay(isrc),
          rawValue: canonicalIsrcForCopy(isrc),
          copyable: true,
        ),
      if (!_isLocalItem && _hasServiceLink)
        _MetadataItem(
          switch (_linkedService) {
            MusicServices.deezer => 'Deezer ID',
            MusicServices.amazon => 'Amazon ASIN',
            MusicServices.tidal => 'Tidal ID',
            MusicServices.qobuz => 'Qobuz ID',
            _ => 'Spotify ID',
          },
          _displayServiceTrackId(_spotifyId!),
          copyable: true,
        ),
    ];

    final audio = <_MetadataItem>[
      if (duration != null)
        _MetadataItem(l10n.trackDuration, formatClock(duration!)),
      if (_displayAudioQuality case final quality?)
        _MetadataItem(l10n.trackAudioQuality, quality),
      if (_editedMetadata?['bpm'] case final int bpm when bpm > 0)
        _MetadataItem(l10n.trackBpm, bpm.toString()),
      if (replayGainTrackGain != null)
        _MetadataItem(l10n.trackReplayGainTrackGain, replayGainTrackGain),
      if (replayGainTrackPeak != null)
        _MetadataItem(l10n.trackReplayGainTrackPeak, replayGainTrackPeak),
      if (replayGainAlbumGain != null)
        _MetadataItem(l10n.trackReplayGainAlbumGain, replayGainAlbumGain),
      if (replayGainAlbumPeak != null)
        _MetadataItem(l10n.trackReplayGainAlbumPeak, replayGainAlbumPeak),
    ];

    final file = <_MetadataItem>[
      if (_embeddedCoverDimensions case final dimensions?)
        _MetadataItem(
          l10n.trackCoverResolution,
          '${dimensions.width} × ${dimensions.height} px',
        ),
      _MetadataItem(l10n.trackMetadataService, _service.toUpperCase()),
      _MetadataItem(l10n.trackDownloaded, _formatFullDate(_addedAt)),
    ];

    return (
      tags: tags,
      release: release,
      audio: audio,
      file: file,
      all: [...tags, ...release, ...audio, ...file],
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) => Text(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );

  /// One titled section of facts, with [footer] widgets under its rows.
  Widget _buildFactsSection(
    BuildContext context,
    ColorScheme colorScheme, {
    required String title,
    required List<_MetadataItem> items,
    required List<_MetadataItem> all,
    List<Widget> footer = const [],
  }) {
    final tokens = context.tokens;
    return _metadataSectionSurface(
      context,
      colorScheme,
      child: Padding(
        padding: const EdgeInsets.all(_trackMetadataSectionPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(context, title),
            SizedBox(height: tokens.gapSm),
            for (final (index, item) in items.indexed)
              _buildFactRow(
                context,
                colorScheme,
                item,
                all: all,
                showDivider: index != items.length - 1,
              ),
            for (final widget in footer) ...[
              SizedBox(height: tokens.gapMd),
              widget,
            ],
          ],
        ),
      ),
    );
  }

  /// A label and its value. A tap copies a [_MetadataItem.copyable] value;
  /// a long press offers to copy the value, the field or every fact.
  Widget _buildFactRow(
    BuildContext context,
    ColorScheme colorScheme,
    _MetadataItem item, {
    required List<_MetadataItem> all,
    required bool showDivider,
  }) {
    final tokens = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final onTap = item.copyable
        ? () => _copyToClipboard(context, item.rawValue)
        : null;
    void onLongPress() =>
        _showMetadataCopySheet(context, metadata: item, allMetadata: all);
    final copy = item.copyable
        ? AppIcon.adaptive(
            Icons.copy,
            size: 16,
            color: colorScheme.onSurfaceVariant,
          )
        : null;
    if (context.isMornye) {
      return MornyeMetadataRow(
        label: item.label,
        value: item.value,
        showDivider: showDivider,
        trailing: copy,
        onTap: onTap,
        onLongPress: onLongPress,
      );
    }
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: tokens.borderRadiusThumb,
      // Every row keeps the minimum touch target for its long press.
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: tokens.gapSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            spacing: tokens.gapMd,
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  item.label,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(item.value, style: textTheme.bodyLarge),
              ),
              ?copy,
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the song in the service its catalog ID belongs to.
  Widget _buildOpenServiceButton(BuildContext context) {
    final l10n = context.l10n;
    final label = switch (_linkedService) {
      MusicServices.deezer => l10n.trackOpenInDeezer,
      MusicServices.amazon => l10n.trackOpenInService('Amazon Music'),
      MusicServices.tidal => l10n.trackOpenInService('Tidal'),
      MusicServices.qobuz => l10n.trackOpenInService('Qobuz'),
      _ => l10n.trackOpenInSpotify,
    };
    if (context.isMornye) {
      return HeaderFilledButton(
        icon: CupertinoIcons.arrow_up_right_square,
        label: label,
        tonal: true,
        onPressed: () => _openServiceUrl(context),
      );
    }
    return ExpressiveButton(
      outlined: true,
      onPressed: () => _openServiceUrl(context),
      icon: const AppIcon.adaptive(Icons.open_in_new, size: 18),
      child: Text(label),
    );
  }

  Future<void> _openServiceUrl(BuildContext context) async {
    if (_spotifyId == null) return;

    // Unknown services open as Spotify, as this button always has.
    final link = ServiceTrackLink(
      _linkedService,
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
    BuildContext context,
    ColorScheme colorScheme,
    String label, {
    bool emphasized = false,
  }) {
    final tokens = context.tokens;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: emphasized
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.gapMd,
          vertical: tokens.gapSm * 0.75,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: emphasized
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildFileInfoCard(
    BuildContext context,
    ColorScheme colorScheme,
    _MetadataFacts facts,
  ) {
    final tokens = context.tokens;
    final fileSize = _fileSize;
    final displayFilePath = _formatPathForDisplay(rawFilePath);
    final fileName = _extractFileNameFromPathOrUri(rawFilePath);
    final fileExtension = _displayFormatLabelForFile(fileName);
    final resolvedQuality = _displayAudioQuality;
    final lossyBitrateLabel = _extractLossyBitrateLabel(resolvedQuality);
    Widget pill(String label, {bool emphasized = false}) =>
        _fileInfoPill(context, colorScheme, label, emphasized: emphasized);

    return _metadataSectionSurface(
      context,
      colorScheme,
      child: Padding(
        padding: const EdgeInsets.all(_trackMetadataSectionPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(context, context.l10n.trackFileInfo),
            SizedBox(height: tokens.gapLg),
            Wrap(
              spacing: tokens.gapSm,
              runSpacing: tokens.gapSm,
              children: [
                pill(fileExtension, emphasized: true),
                if (fileSize != null) pill(formatBytes(fileSize)),
                if (_isBitrateFormatLabel(fileExtension) &&
                    lossyBitrateLabel != null)
                  pill(lossyBitrateLabel)
                else if (_audioBitrate != null &&
                    _audioBitrate! > 0 &&
                    _isBitrateFormatLabel(fileExtension))
                  pill('${_audioBitrate}kbps')
                else if (bitDepth != null &&
                    bitDepth! > 0 &&
                    sampleRate != null)
                  pill(
                    buildDisplayAudioQuality(
                          bitDepth: bitDepth,
                          sampleRate: sampleRate,
                        ) ??
                        '',
                  ),
                if (!_isBitrateFormatLabel(fileExtension) &&
                    _audioBitrate != null &&
                    _audioBitrate! > 0)
                  pill('${_audioBitrate}kbps'),
              ],
            ),
            SizedBox(height: tokens.gapSm),
            for (final item in facts.file)
              _buildFactRow(
                context,
                colorScheme,
                item,
                all: facts.all,
                showDivider: true,
              ),
            // The path is a flat copy row like the facts above it, in both
            // styles, instead of a filled box inside the card.
            InkWell(
              onTap: () => _copyToClipboard(context, cleanFilePath),
              borderRadius: tokens.borderRadiusThumb,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: tokens.minTouchTarget),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: tokens.gapSm),
                  child: Row(
                    spacing: tokens.gapSm,
                    children: [
                      Expanded(
                        child: Text(
                          displayFilePath,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontFamily: 'monospace',
                                color: colorScheme.onSurfaceVariant,
                              ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      AppIcon.adaptive(
                        Icons.copy,
                        size: 18,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
