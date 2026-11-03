part of 'queue_tab.dart';

extension _QueueTabFilterSheet on _QueueTabState {
  void _showFilterSheet(BuildContext context) {
    String? tempSource = _filterSource;
    String? tempQuality = _filterQuality;
    String? tempFormat = _filterFormat;
    String? tempMetadata = _filterMetadata;
    String tempSortMode = _sortMode;

    _showLibraryOptionsSheet<void>(
      context,
      builder: (context, scrollController) => StatefulBuilder(
        builder: (context, setSheetState) {
          return AppBottomSheet(
            title: context.l10n.libraryFilterTitle,
            titleTrailing: ExpressiveButton(
              text: true,
              onPressed: () {
                setSheetState(() {
                  tempSource = null;
                  tempQuality = null;
                  tempFormat = null;
                  tempMetadata = null;
                  tempSortMode = 'latest';
                });
              },
              child: Text(context.l10n.libraryFilterReset),
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.libraryFilterSource,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in <(String?, String)>[
                        (null, context.l10n.libraryFilterAll),
                        ('downloaded', context.l10n.libraryFilterDownloaded),
                        ('local', context.l10n.libraryFilterLocal),
                      ])
                        AppChoiceChip(
                          label: Text(label),
                          selected: tempSource == value,
                          onSelected: (_) =>
                              setSheetState(() => tempSource = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Text(
                    context.l10n.libraryFilterQuality,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in <(String?, String)>[
                        (null, context.l10n.libraryFilterAll),
                        ('hires', context.l10n.libraryFilterQualityHiRes),
                        ('cd', context.l10n.libraryFilterQualityCD),
                        ('lossy', context.l10n.libraryFilterQualityLossy),
                      ])
                        AppChoiceChip(
                          label: Text(label),
                          selected: tempQuality == value,
                          onSelected: (_) =>
                              setSheetState(() => tempQuality = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Text(
                    context.l10n.libraryFilterFormat,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      AppChoiceChip(
                        label: Text(context.l10n.libraryFilterAll),
                        selected: tempFormat == null,
                        onSelected: (_) =>
                            setSheetState(() => tempFormat = null),
                      ),
                      for (final format in libraryFormatFilterAliases.keys)
                        AppChoiceChip(
                          label: Text(switch (format) {
                            'm4a' => 'M4A / MP4',
                            'wv' => 'WavPack',
                            _ => format.toUpperCase(),
                          }),
                          selected: tempFormat == format,
                          onSelected: (_) =>
                              setSheetState(() => tempFormat = format),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Text(
                    context.l10n.libraryFilterMetadata,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in <(String?, String)>[
                        (null, context.l10n.libraryFilterAll),
                        (
                          'complete',
                          context.l10n.libraryFilterMetadataComplete,
                        ),
                        (
                          'missing-any',
                          context.l10n.libraryFilterMetadataMissingAny,
                        ),
                        (
                          'missing-year',
                          context.l10n.libraryFilterMetadataMissingYear,
                        ),
                        (
                          'missing-genre',
                          context.l10n.libraryFilterMetadataMissingGenre,
                        ),
                        (
                          'missing-album-artist',
                          context.l10n.libraryFilterMetadataMissingAlbumArtist,
                        ),
                        (
                          'missing-track-number',
                          context.l10n.libraryFilterMetadataMissingTrackNumber,
                        ),
                        (
                          'missing-disc-number',
                          context.l10n.libraryFilterMetadataMissingDiscNumber,
                        ),
                        (
                          'missing-artist',
                          context.l10n.libraryFilterMetadataMissingArtist,
                        ),
                        (
                          'incorrect-isrc-format',
                          context.l10n.libraryFilterMetadataIncorrectIsrcFormat,
                        ),
                        (
                          'missing-isrc',
                          context.l10n.libraryFilterMetadataMissingIsrc,
                        ),
                        (
                          'missing-label',
                          context.l10n.libraryFilterMetadataMissingLabel,
                        ),
                        (
                          'missing-lyrics',
                          context.l10n.libraryFilterMetadataMissingLyrics,
                        ),
                        (
                          'has-replaygain',
                          context.l10n.libraryFilterMetadataHasReplayGain,
                        ),
                        (
                          'missing-replaygain',
                          context.l10n.libraryFilterMetadataMissingReplayGain,
                        ),
                        (
                          incompleteAlbumFilter,
                          context.l10n.libraryFilterIncompleteAlbums,
                        ),
                        (
                          unknownAlbumCompletenessFilter,
                          context.l10n.libraryAlbumCompletenessUnknown,
                        ),
                      ])
                        AppChoiceChip(
                          label: Text(label),
                          selected: tempMetadata == value,
                          onSelected: (_) =>
                              setSheetState(() => tempMetadata = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Text(
                    context.l10n.libraryFilterSort,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in _availableLibrarySortModes)
                        AppChoiceChip(
                          label: Text(_sortLabel(context, mode)),
                          selected: tempSortMode == mode,
                          onSelected: (_) =>
                              setSheetState(() => tempSortMode = mode),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  SizedBox(
                    width: double.infinity,
                    child: AppDialogAction(
                      filled: true,
                      onPressed: () {
                        _setState(() {
                          _filterSource = tempSource;
                          _filterQuality = tempQuality;
                          _filterFormat = tempFormat;
                          _filterMetadata = tempMetadata;
                          _sortMode = tempSortMode;
                          _resetLibraryPaging();
                        });
                        _rememberSortMode(tempSortMode);
                        Navigator.pop(context);
                        if (widget.librarySection == null &&
                            isAlbumCompletenessFilter(tempMetadata)) {
                          _animateToFilterPage(_filterModes.indexOf('albums'));
                        }
                      },
                      child: Text(context.l10n.libraryFilterApply),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
