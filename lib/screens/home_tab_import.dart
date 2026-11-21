part of 'home_tab.dart';

extension _HomeTabCsvImport on _HomeTabState {
  Future<void> _importCsv(BuildContext context, WidgetRef ref) async {
    if (_isCsvImporting) return;
    _setCsvImporting(true);

    int currentProgress = 0;
    int totalTracks = 0;

    bool progressDialogInitialized = false;
    bool progressDialogVisible = false;
    BuildContext? progressDialogContext;
    StateSetter? setDialogState;

    void showProgressDialog() {
      if (progressDialogInitialized || !mounted) return;
      progressDialogInitialized = true;
      progressDialogVisible = true;
      showAppDialog<void>(
        context: this.context,
        useRootNavigator: false,
        barrierDismissible: false,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (dialogCtx, setState) {
            progressDialogContext = dialogCtx;
            setDialogState = setState;
            return AppAlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLoadingIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    totalTracks > 0
                        ? context.l10n.progressFetchingMetadata(
                            currentProgress,
                            totalTracks,
                          )
                        : context.l10n.progressReadingCsv,
                  ),
                ],
              ),
            );
          },
        ),
      ).then((_) {
        progressDialogVisible = false;
        progressDialogContext = null;
      });
    }

    void closeProgressDialog() {
      if (!progressDialogVisible) return;
      setDialogState = null;
      try {
        if (progressDialogContext != null) {
          Navigator.of(progressDialogContext!).pop();
        } else if (mounted) {
          final navigator = Navigator.of(this.context);
          if (navigator.canPop()) {
            navigator.pop();
          }
        }
      } catch (_) {}
      progressDialogVisible = false;
      progressDialogContext = null;
    }

    try {
      final List<Track> tracks;
      try {
        final parsed = await CsvImportService.pickAndParseCsv(
          onProgress: (current, total) {
            currentProgress = current;
            totalTracks = total;
            if (!progressDialogInitialized && total > 0) {
              showProgressDialog();
            }
            setDialogState?.call(() {});
          },
          // Link rows need the extensions' URL handlers.
          beforeEnrich: () =>
              ref.read(extensionProvider.notifier).waitForInitialization(),
        );
        if (parsed == null) return;
        tracks = parsed;
      } catch (_) {
        closeProgressDialog();
        if (mounted) {
          showAppSnackBar(
            this.context,
            content: Text(this.context.l10n.playlistImportFailed),
          );
        }
        return;
      }

      closeProgressDialog();

      if (tracks.isEmpty) {
        if (mounted) {
          showAppSnackBar(
            this.context,
            content: Text(this.context.l10n.playlistImportNoTracks),
          );
        }
      } else {
        final settings = ref.read(settingsProvider);

        if (!mounted) return;

        final l10n = this.context.l10n;

        final options = await showAppDialog<_CsvImportOptions>(
          context: this.context,
          useRootNavigator: false,
          builder: (dialogCtx) {
            var skipDownloaded = true;
            return StatefulBuilder(
              builder: (dialogCtx, setDialogState) => AppAlertDialog(
                title: Text(l10n.dialogImportPlaylistTitle),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.dialogImportPlaylistMessage(tracks.length)),
                    const SizedBox(height: 12),
                    if (dialogCtx.isMornye)
                      AppSwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.homeSkipAlreadyDownloaded),
                        value: skipDownloaded,
                        onChanged: (value) => setDialogState(() {
                          skipDownloaded = value;
                        }),
                      )
                    else
                      AppCheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.homeSkipAlreadyDownloaded),
                        value: skipDownloaded,
                        onChanged: (value) {
                          setDialogState(() {
                            skipDownloaded = value ?? true;
                          });
                        },
                      ),
                  ],
                ),
                actions: [
                  AppDialogAction(
                    onPressed: () => Navigator.pop(
                      dialogCtx,
                      const _CsvImportOptions(
                        confirmed: false,
                        skipDownloaded: true,
                      ),
                    ),
                    child: Text(l10n.dialogCancel),
                  ),
                  AppDialogAction(
                    filled: true,
                    onPressed: () => Navigator.pop(
                      dialogCtx,
                      _CsvImportOptions(
                        confirmed: true,
                        skipDownloaded: skipDownloaded,
                      ),
                    ),
                    child: Text(l10n.dialogImport),
                  ),
                ],
              ),
            );
          },
        );

        if (options == null || !options.confirmed) return;

        var tracksToQueue = tracks;
        var skippedDownloadedCount = 0;

        if (options.skipDownloaded) {
          final historyLookups = tracks
              .map(historyLookupForTrack)
              .toList(growable: false);
          final existingHistoryKeys = await ref.read(
            downloadHistoryBatchExistsProvider(
              HistoryBatchLookupRequest(historyLookups),
            ).future,
          );
          // Songs another app downloaded are missing from History but can
          // already sit in a Local Library folder.
          final existingLocalIndices = await localLibraryMatchIndices(
            ref,
            tracks,
          );
          tracksToQueue = [];
          for (var i = 0; i < tracks.length; i++) {
            final track = tracks[i];
            final isDownloaded =
                existingHistoryKeys.contains(historyLookups[i].lookupKey) ||
                existingLocalIndices.contains(i);
            if (isDownloaded) {
              skippedDownloadedCount++;
              continue;
            }
            tracksToQueue.add(track);
          }
        }

        if (tracksToQueue.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(this.context).showSnackBar(
              SnackBar(
                content: Text(
                  l10n.discographySkippedDownloaded(0, skippedDownloadedCount),
                ),
              ),
            );
          }
          return;
        }

        final queueSnackbarMessage = skippedDownloadedCount > 0
            ? l10n.discographySkippedDownloaded(
                tracksToQueue.length,
                skippedDownloadedCount,
              )
            : l10n.snackbarAddedTracksToQueue(tracksToQueue.length);

        if (!mounted) return;

        if (settings.askQualityBeforeDownload ||
            settings.allowQualityVariants) {
          DownloadServicePicker.show(
            this.context,
            trackName: l10n.csvImportTracks(tracksToQueue.length),
            artistName: l10n.dialogImportPlaylistTitle,
            onSelect: (quality, service) {
              ref
                  .read(downloadQueueProvider.notifier)
                  .addMultipleToQueue(
                    tracksToQueue,
                    service,
                    qualityOverride: quality,
                  );
              if (mounted) {
                showAppSnackBar(
                  this.context,
                  content: Text(queueSnackbarMessage),
                  action: buildViewQueueSnackBarAction(this.context),
                );
              }
            },
          );
        } else {
          final extensionState = ref.read(extensionProvider);
          final service = resolveEffectiveDownloadService(
            settings.defaultService,
            extensionState,
          );
          if (service.isEmpty) {
            if (mounted) {
              ScaffoldMessenger.of(this.context).showSnackBar(
                SnackBar(
                  content: Text(this.context.l10n.extensionsNoDownloadProvider),
                ),
              );
            }
            return;
          }
          ref
              .read(downloadQueueProvider.notifier)
              .addMultipleToQueue(tracksToQueue, service);
          if (mounted) {
            showAppSnackBar(
              this.context,
              content: Text(queueSnackbarMessage),
              action: buildViewQueueSnackBarAction(this.context),
            );
          }
        }
      }
    } finally {
      closeProgressDialog();
      _setCsvImporting(false);
    }
  }
}
