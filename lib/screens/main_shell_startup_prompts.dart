part of 'main_shell.dart';

extension _MainShellStartupPrompts on _MainShellState {
  Future<void> _repairSafAccessIfNeeded({bool knownLost = false}) async {
    if (!Platform.isAndroid || _safRepairDialogVisible) return;

    var accessLost = knownLost;
    if (!accessLost) {
      final settings = ref.read(settingsProvider);
      if (settings.storageMode != 'saf' || settings.downloadTreeUri.isEmpty) {
        return;
      }
      accessLost = !await PlatformBridge.isSafTreeAccessible(
        settings.downloadTreeUri,
      );
    }
    if (!accessLost || !mounted) return;

    _safRepairDialogVisible = true;
    try {
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var isPickingFolder = false;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return PopScope(
                canPop: false,
                child: AppAlertDialog(
                  icon: AppIcon(
                    Icons.folder_off_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(context.l10n.downloadFolderAccessLostTitle),
                  content: Text(context.l10n.downloadFolderAccessLostSubtitle),
                  actions: [
                    AppDialogAction(
                      onPressed: isPickingFolder
                          ? null
                          : () {
                              final notifier = ref.read(
                                settingsProvider.notifier,
                              );
                              notifier.setStorageMode('app');
                              notifier.setDownloadTreeUri('');
                              notifier.setDownloadDirectory('');
                              Navigator.of(dialogContext).pop();
                            },
                      child: Text(context.l10n.storageAutomaticFolder),
                    ),
                    AppDialogAction(
                      filled: true,
                      onPressed: isPickingFolder
                          ? null
                          : () async {
                              setDialogState(() => isPickingFolder = true);
                              try {
                                if (!await pickAndStoreSafDownloadTree(ref)) {
                                  return;
                                }
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop();
                                }
                              } catch (e) {
                                _log.w(
                                  'Failed to repair SAF access from startup: $e',
                                );
                                if (context.mounted) {
                                  showCannotOpenFileSnackBar(context, e);
                                }
                              } finally {
                                if (dialogContext.mounted) {
                                  setDialogState(() => isPickingFolder = false);
                                }
                              }
                            },
                      child: isPickingFolder
                          ? const AppLoadingIndicator(size: 18, strokeWidth: 2)
                          : Text(context.l10n.downloadFolderReselect),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      _safRepairDialogVisible = false;
    }
  }

  Future<bool> _checkForUpdates() async {
    if (_hasCheckedUpdate) return false;
    _hasCheckedUpdate = true;

    final settings = ref.read(settingsProvider);

    // The check runs even when the user disabled update prompts: versions
    // that fall forceUpdateThreshold stable releases behind must update, and
    // that enforcement cannot be opted out of.
    final updateInfo = await UpdateChecker().checkForUpdate(
      channel: settings.updateChannel,
    );
    if (updateInfo == null || !mounted) return false;

    final forced =
        updateInfo.releasesBehind >= UpdateChecker.forceUpdateThreshold;
    if (!forced && !settings.checkForUpdates) return false;

    showUpdateDialog(
      context,
      updateInfo: updateInfo,
      forced: forced,
      onDisableUpdates: () {
        ref.read(settingsProvider.notifier).setCheckForUpdates(false);
      },
    );
    return true;
  }

  Future<void> _checkAppAnnouncement() async {
    if (_hasCheckedAppAnnouncement) return;
    _hasCheckedAppAnnouncement = true;

    final locale = Localizations.localeOf(context).toLanguageTag();
    final remoteConfigService = AppRemoteConfigService();
    final announcement = await remoteConfigService.fetchActiveAnnouncement(
      locale: locale,
    );
    if (announcement == null || !mounted) return;

    showAppAnnouncementDialog(
      context,
      announcement: announcement,
      onDismiss: () {
        remoteConfigService.markAnnouncementDismissed(announcement.id);
      },
    );
  }

  static const _safMigrationPromptStore = SafMigrationPromptStore();

  Future<void> _checkSafMigration() async {
    if (!Platform.isAndroid || isAndroidTv) return;

    final settings = ref.read(settingsProvider);
    if (settings.storageMode == 'saf') return;
    if (settings.downloadDirectory.isEmpty) return;

    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    if (androidInfo.version.sdkInt < 29) return;

    if (await _safMigrationPromptStore.wasShown()) return;
    await _safMigrationPromptStore.markShown();

    if (!mounted) return;

    final colorScheme = Theme.of(context).colorScheme;

    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AppAlertDialog(
        icon: AppIcon(
          Icons.folder_special_outlined,
          size: 32,
          color: colorScheme.primary,
        ),
        title: Text(context.l10n.safMigrationTitle),
        content: ConstrainedBox(
          // Keeps the text column readable on tablets/landscape.
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.safMigrationMessage1),
              const SizedBox(height: 12),
              Text(context.l10n.safMigrationMessage2),
            ],
          ),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.updateLater),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () async {
              Navigator.pop(ctx);
              final saved = await pickAndStoreSafDownloadTree(
                ref,
                setStorageModeFirst: false,
              );
              if (saved) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.safMigrationSuccess)),
                  );
                }
              }
            },
            child: Text(context.l10n.setupSelectFolder),
          ),
        ],
      ),
    );
  }
}
