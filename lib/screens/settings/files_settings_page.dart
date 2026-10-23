import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/saf_download_tree.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

part 'files_settings_page_widgets.dart';

class FilesSettingsPage extends ConsumerStatefulWidget {
  const FilesSettingsPage({super.key});

  @override
  ConsumerState<FilesSettingsPage> createState() => _FilesSettingsPageState();
}

class _FilesSettingsPageState extends ConsumerState<FilesSettingsPage> {
  int _androidSdkVersion = 0;
  bool _hasAllFilesAccess = false;
  bool _artistFolderFiltersExpanded = false;
  bool _safAccessLost = false;

  @override
  void initState() {
    super.initState();
    _initDeviceInfo();
    _checkSafAccess();
  }

  Future<void> _checkSafAccess() async {
    if (!Platform.isAndroid) return;
    final settings = ref.read(settingsProvider);
    if (settings.storageMode != 'saf' || settings.downloadTreeUri.isEmpty) {
      if (mounted && _safAccessLost) setState(() => _safAccessLost = false);
      return;
    }
    final accessible = await PlatformBridge.isSafTreeAccessible(
      settings.downloadTreeUri,
    );
    if (mounted) setState(() => _safAccessLost = !accessible);
  }

  Future<void> _pickSafTreeAndSave() async {
    await pickAndStoreSafDownloadTree(ref);
  }

  Future<void> _initDeviceInfo() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkVersion = androidInfo.version.sdkInt;
      final hasAccess = await Permission.manageExternalStorage.isGranted;
      if (mounted) {
        setState(() {
          _androidSdkVersion = sdkVersion;
          _hasAllFilesAccess = hasAccess;
        });
      }
    }
  }

  Future<void> _requestAllFilesAccess() async {
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) {
      ref.read(settingsProvider.notifier).setUseAllFilesAccess(true);
      if (mounted) setState(() => _hasAllFilesAccess = true);
    } else if (status.isPermanentlyDenied && mounted) {
      final shouldOpen = await showAppConfirmDialog(
        context,
        title: context.l10n.setupStorageAccessRequired,
        message: context.l10n.allFilesAccessDeniedMessage,
        confirmLabel: context.l10n.setupOpenSettings,
        confirmIsDefault: true,
      );
      if (shouldOpen) await openAppSettings();
    }
  }

  Future<void> _disableAllFilesAccess() async {
    ref.read(settingsProvider.notifier).setUseAllFilesAccess(false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.allFilesAccessDisabledMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.settingsFiles),

            ...settingsSectionSlivers(
              title: context.l10n.setupDownloadLocationTitle,
              children: [
                SettingsItem(
                  icon: Icons.folder_outlined,
                  title: context.l10n.downloadDirectory,
                  subtitle: settings.downloadDirectory.isEmpty
                      ? (Platform.isIOS
                            ? context.l10n.setupAppDocumentsFolder
                            : isDesktopPlatform
                            ? 'Music/$desktopOutputFolderName'
                            : 'Download/Mornye')
                      : settings.downloadDirectory,
                  onTap: () => _pickDirectory(context, ref),
                  showDivider: false,
                ),
                SettingsItem(
                  icon: Icons.dns_outlined,
                  title: context.l10n.networkDownloadDestination,
                  subtitle: settings.networkDownloadFolder.isEmpty
                      ? context.l10n.networkUseForDownloads
                      : settings.networkDownloadLabel,
                  onTap: () => pushPage<void>(
                    context,
                    (_) => const NetworkStorageScreen(),
                  ),
                  showDivider: settings.networkDownloadFolder.isNotEmpty,
                ),
                if (settings.networkDownloadFolder.isNotEmpty)
                  SettingsItem(
                    icon: Icons.phone_android_outlined,
                    title: context.l10n.networkUseLocalDownloads,
                    onTap: () => ref
                        .read(settingsProvider.notifier)
                        .setNetworkDownloadFolder('', ''),
                    showDivider: false,
                  ),
              ],
            ),
            if (Platform.isAndroid &&
                _safAccessLost &&
                settings.storageMode == 'saf' &&
                settings.downloadTreeUri.isNotEmpty)
              SliverToBoxAdapter(
                child: SettingsInfoCard(
                  icon: Icons.warning_amber_outlined,
                  tone: SettingsInfoTone.error,
                  title: context.l10n.downloadFolderAccessLostTitle,
                  message: context.l10n.downloadFolderAccessLostSubtitle,
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  action: ExpressiveButton(
                    tonal: true,
                    onPressed: () async {
                      await _pickSafTreeAndSave();
                      await _checkSafAccess();
                    },
                    child: Text(context.l10n.downloadFolderReselect),
                  ),
                ),
              ),

            ...settingsSectionSlivers(
              title: context.l10n.sectionFileSettings,
              children: [
                SettingsItem(
                  icon: Icons.text_fields,
                  title: context.l10n.downloadFilenameFormat,
                  subtitle: settings.filenameFormat,
                  onTap: () =>
                      _showFormatEditor(context, ref, settings.filenameFormat),
                ),
                SettingsItem(
                  icon: Icons.music_note_outlined,
                  title: context.l10n.downloadSingleFilenameFormat,
                  subtitle: settings.singleFilenameFormat,
                  onTap: () => _showFormatEditor(
                    context,
                    ref,
                    settings.singleFilenameFormat,
                    onSave: ref
                        .read(settingsProvider.notifier)
                        .setSingleFilenameFormat,
                    title: context.l10n.downloadSingleFilenameFormat,
                    description:
                        context.l10n.downloadSingleFilenameFormatDescription,
                  ),
                  showDivider: false,
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.downloadFolderOrganization,
              children: [
                SettingsSwitchItem(
                  icon: Icons.library_music_outlined,
                  title: context.l10n.downloadSeparateSinglesFolder,
                  subtitle: settings.separateSingles
                      ? context.l10n.downloadSeparateSinglesEnabled
                      : context.l10n.downloadSeparateSinglesDisabled,
                  value: settings.separateSingles,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setSeparateSingles(value),
                ),
                SettingsItem(
                  icon: Icons.folder_copy_outlined,
                  title: context.l10n.downloadFolderTemplate,
                  subtitle:
                      !settings.separateSingles &&
                          settings.folderOrganization == 'custom'
                      ? settings.folderPathTemplate
                      : context.l10n.downloadFolderTemplateDescription,
                  onTap: () => _showFolderTemplateEditor(context, ref),
                ),
                if (settings.separateSingles)
                  SettingsItem(
                    icon: Icons.folder_outlined,
                    title: context.l10n.downloadAlbumFolderStructure,
                    subtitle: _getAlbumFolderStructureLabel(
                      context,
                      settings.albumFolderStructure,
                    ),
                    onTap: () => _showAlbumFolderStructurePicker(
                      context,
                      ref,
                      settings.albumFolderStructure,
                    ),
                  ),
                if (!settings.separateSingles)
                  SettingsItem(
                    icon: Icons.create_new_folder_outlined,
                    title: context.l10n.downloadFolderOrganization,
                    subtitle: _getFolderOrganizationLabel(
                      context,
                      settings.folderOrganization,
                    ),
                    onTap: () => _showFolderOrganizationPicker(
                      context,
                      ref,
                      settings.folderOrganization,
                    ),
                  ),
                SettingsSwitchItem(
                  icon: Icons.playlist_play_outlined,
                  title: context.l10n.downloadCreatePlaylistSourceFolder,
                  subtitle: _getPlaylistFolderSubtitle(settings),
                  value: settings.createPlaylistFolder,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setCreatePlaylistFolder(value),
                ),
                SettingsSwitchItem(
                  icon: Icons.person_search_outlined,
                  title: context.l10n.downloadUseAlbumArtistForFolders,
                  subtitle: settings.useAlbumArtistForFolders
                      ? context
                            .l10n
                            .downloadUseAlbumArtistForFoldersAlbumSubtitle
                      : context
                            .l10n
                            .downloadUseAlbumArtistForFoldersTrackSubtitle,
                  value: settings.useAlbumArtistForFolders,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setUseAlbumArtistForFolders(value),
                ),
                SettingsItem(
                  icon: Icons.filter_alt_outlined,
                  title: context.l10n.downloadArtistNameFilters,
                  subtitle: _getArtistFolderFilterSubtitle(
                    context,
                    usePrimaryArtistOnly: settings.usePrimaryArtistOnly,
                    filterAlbumArtistContributors:
                        settings.filterContributingArtistsInAlbumArtist,
                  ),
                  trailing: AppIcon(
                    _artistFolderFiltersExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                  onTap: () => setState(() {
                    _artistFolderFiltersExpanded =
                        !_artistFolderFiltersExpanded;
                  }),
                  showDivider: !_artistFolderFiltersExpanded,
                ),
                if (_artistFolderFiltersExpanded) ...[
                  SettingsSwitchItem(
                    icon: Icons.person_outline,
                    title: context.l10n.downloadUsePrimaryArtistOnly,
                    subtitle: settings.usePrimaryArtistOnly
                        ? context.l10n.downloadUsePrimaryArtistOnlyEnabled
                        : context.l10n.downloadUsePrimaryArtistOnlyDisabled,
                    value: settings.usePrimaryArtistOnly,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setUsePrimaryArtistOnly(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.group_remove_outlined,
                    title: context.l10n.downloadFilterContributing,
                    subtitle: settings.filterContributingArtistsInAlbumArtist
                        ? context.l10n.downloadFilterContributingEnabled
                        : context.l10n.downloadFilterContributingDisabled,
                    value: settings.filterContributingArtistsInAlbumArtist,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setFilterContributingArtistsInAlbumArtist(value),
                    showDivider: false,
                  ),
                ],
              ],
            ),

            if (Platform.isAndroid && _androidSdkVersion >= 33) ...[
              ...settingsSectionSlivers(
                title: context.l10n.sectionStorageAccess,
                children: [
                  SettingsSwitchItem(
                    icon: Icons.folder_special_outlined,
                    title: context.l10n.allFilesAccess,
                    subtitle: _hasAllFilesAccess
                        ? context.l10n.allFilesAccessEnabledSubtitle
                        : context.l10n.allFilesAccessDisabledSubtitle,
                    value: _hasAllFilesAccess && settings.useAllFilesAccess,
                    onChanged: (value) {
                      if (value) {
                        _requestAllFilesAccess();
                      } else {
                        _disableAllFilesAccess();
                      }
                    },
                    showDivider: false,
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppIcon(
                        Icons.info_outline,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.allFilesAccessDescription,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  String _getAlbumFolderStructureLabel(BuildContext context, String structure) {
    switch (structure) {
      case 'album_only':
        return context.l10n.albumFolderAlbumOnlySubtitle;
      case 'artist_year_album':
        return context.l10n.albumFolderArtistYearAlbumSubtitle;
      case 'year_album':
        return context.l10n.albumFolderYearAlbumSubtitle;
      case 'artist_album_singles':
        return context.l10n.albumFolderArtistAlbumSinglesSubtitle;
      case 'artist_album_flat':
        return context.l10n.albumFolderArtistAlbumFlatSubtitle;
      default:
        return context.l10n.albumFolderArtistAlbumSubtitle;
    }
  }

  String _getFolderOrganizationLabel(BuildContext context, String value) {
    switch (value) {
      case 'custom':
        return context.l10n.folderOrganizationCustom;
      case 'playlist':
        return context.l10n.folderOrganizationByPlaylist;
      case 'artist':
        return context.l10n.folderOrganizationByArtist;
      case 'album':
        return context.l10n.folderOrganizationByAlbum;
      case 'artist_album':
        return context.l10n.folderOrganizationByArtistAlbum;
      default:
        return context.l10n.folderOrganizationNone;
    }
  }

  String _getPlaylistFolderSubtitle(AppSettings settings) {
    if (settings.folderOrganization == 'playlist') {
      return context.l10n.downloadCreatePlaylistSourceFolderRedundant;
    }
    if (settings.createPlaylistFolder) {
      return context.l10n.downloadCreatePlaylistSourceFolderEnabled;
    }
    return context.l10n.downloadCreatePlaylistSourceFolderDisabled;
  }

  String _getArtistFolderFilterSubtitle(
    BuildContext context, {
    required bool usePrimaryArtistOnly,
    required bool filterAlbumArtistContributors,
  }) {
    final l10n = context.l10n;
    final statuses = <String>[
      usePrimaryArtistOnly
          ? l10n.downloadPrimaryArtistOnlyOn
          : l10n.downloadPrimaryArtistOnlyOff,
      filterAlbumArtistContributors
          ? l10n.downloadAlbumArtistMetadataPrimaryOnly
          : l10n.downloadAlbumArtistMetadataFull,
    ];
    return statuses.join(' | ');
  }

  Future<void> _pickDirectory(BuildContext context, WidgetRef ref) async {
    if (isDesktopPlatform) {
      await _pickDesktopDirectory(context, ref);
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      _showIOSDirectoryOptions(context, ref);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      _showAndroidDirectoryOptions(context, ref);
    }
  }

  /// Desktop folders are plain paths: no SAF tree and no iOS bookmark.
  Future<void> _pickDesktopDirectory(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final title = context.l10n.setupDownloadLocationTitle;
    final current = ref.read(settingsProvider).downloadDirectory;
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: title,
        initialDirectory: await resolveDesktopPickerInitialDirectory(current),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.snackbarFolderPickerFailed(context.friendlyError(e)),
            ),
          ),
        );
      }
      return;
    }
    if (picked == null || picked.isEmpty) return;
    await ref.read(settingsProvider.notifier).useAppFolderStorage(picked);
  }

  Future<String> _getDefaultAndroidDirectory() async {
    const directDownloadPath = '/storage/emulated/0/Download/Mornye';
    try {
      final downloadDir = Directory(directDownloadPath);
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return downloadDir.path;
    } catch (_) {}
    try {
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        final downloadDir = Directory(
          '${externalDir.parent.parent.parent.parent.path}/Download/Mornye',
        );
        if (!await downloadDir.exists()) {
          await downloadDir.create(recursive: true);
        }
        return downloadDir.path;
      }
    } catch (_) {}
    final appDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory('${appDir.path}/Mornye');
    if (!await fallbackDir.exists()) await fallbackDir.create(recursive: true);
    return fallbackDir.path;
  }

  void _showAndroidDirectoryOptions(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final settings = ref.read(settingsProvider);
    final isSafMode =
        settings.storageMode == 'saf' && settings.downloadTreeUri.isNotEmpty;
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.setupDownloadLocationTitle,
      subtitle: context.l10n.downloadLocationSubtitle,
      builder: (ctx, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption.choice(
              leading: AppIcon(
                Icons.folder_special,
                color: colorScheme.primary,
              ),
              title: Text(context.l10n.storageAutomaticFolder),
              subtitle: Text(context.l10n.storageAutomaticDownloadFolder),
              selected: !isSafMode,
              onTap: () async {
                Navigator.pop(ctx);
                final defaultDir = await _getDefaultAndroidDirectory();
                final notifier = ref.read(settingsProvider.notifier);
                notifier.setStorageMode('app');
                notifier.setDownloadDirectory(defaultDir);
                notifier.setDownloadTreeUri('');
              },
            ),
            AppSheetOption.choice(
              leading: AppIcon(Icons.folder_open, color: colorScheme.primary),
              title: Text(context.l10n.storageSafRecommended),
              subtitle: Text(context.l10n.storageDownloadFolderHint),
              selected: isSafMode,
              onTap: () async {
                Navigator.pop(ctx);
                await _pickSafTreeAndSave();
                await _checkSafAccess();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showIOSDirectoryOptions(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.setupDownloadLocationTitle,
      subtitle: context.l10n.setupDownloadLocationIosMessage,
      builder: (ctx, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption(
              leading: AppIcon(
                Icons.folder_special,
                color: colorScheme.primary,
              ),
              title: Text(context.l10n.setupAppDocumentsFolder),
              subtitle: Text(context.l10n.setupAppDocumentsFolderSubtitle),
              trailing: AppIcon(Icons.check_circle, color: colorScheme.primary),
              onTap: () async {
                final dir = await getApplicationDocumentsDirectory();
                ref
                    .read(settingsProvider.notifier)
                    .setDownloadDirectory(dir.path);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            AppSheetOption(
              leading: AppIcon(
                Icons.cloud,
                color: context.isMornye
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              title: Text(context.l10n.setupChooseFromFiles),
              subtitle: Text(context.l10n.setupChooseFromFilesSubtitle),
              onTap: () async {
                Navigator.pop(ctx);
                await Future<void>.delayed(const Duration(milliseconds: 250));
                IosPickedDirectory? picked;
                try {
                  picked = await PlatformBridge.pickIosDirectory();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.l10n.snackbarFolderPickerFailed(
                            context.friendlyError(e),
                          ),
                        ),
                        backgroundColor: Theme.of(context).colorScheme.error,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                  return;
                }
                if (picked == null || !context.mounted) return;

                final validation = validateIosPath(
                  picked.path,
                  bookmark: picked.bookmark,
                );
                if (!validation.isValid) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          validation.errorReason ??
                              context.l10n.setupIcloudNotSupported,
                        ),
                        backgroundColor: Theme.of(context).colorScheme.error,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                  return;
                }

                ref
                    .read(settingsProvider.notifier)
                    .setDownloadDirectory(
                      picked.path,
                      iosBookmark: picked.bookmark,
                    );
              },
            ),
            SettingsInfoCard(
              icon: Icons.info_outline,
              tone: SettingsInfoTone.warning,
              message: context.l10n.setupIosEmptyFolderWarning,
              margin: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showFormatEditor(
    BuildContext context,
    WidgetRef ref,
    String current, {
    void Function(String)? onSave,
    String? title,
    String? description,
  }) {
    final save =
        onSave ?? ref.read(settingsProvider.notifier).setFilenameFormat;

    showAppScrollableBottomSheet<void>(
      context: context,
      title: title ?? context.l10n.filenameFormat,
      subtitle:
          description ??
          context.l10n.downloadFilenameDescription(
            '{album}',
            '{artist}',
            '{date}',
            '{disc}',
            '{title}',
            '{track}',
            '{year}',
          ),
      builder: (context, controller) => _FilenameFormatEditorSheet(
        initialText: current,
        onSave: save,
        scrollController: controller,
      ),
    );
  }

  void _showFolderTemplateEditor(BuildContext context, WidgetRef ref) {
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.downloadFolderTemplate,
      subtitle: context.l10n.downloadFolderTemplateDescription,
      builder: (context, controller) => _FilenameFormatEditorSheet(
        initialText: ref.read(settingsProvider).folderPathTemplate,
        onSave: ref.read(settingsProvider.notifier).setFolderPathTemplate,
        scrollController: controller,
        folderTemplate: true,
      ),
    );
  }

  void _showAlbumFolderStructurePicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) => showAppChoiceSheet(
    context: context,
    title: context.l10n.downloadAlbumFolderStructure,
    subtitle: context.l10n.albumFolderStructureDescription,
    selected: current,
    bottomSpacing: 0,
    choices: [
      AppChoice(
        'artist_album',
        Icons.folder_outlined,
        context.l10n.albumFolderArtistAlbum,
        subtitle: context.l10n.albumFolderArtistAlbumSubtitle,
      ),
      AppChoice(
        'artist_year_album',
        Icons.calendar_today_outlined,
        context.l10n.albumFolderArtistYearAlbum,
        subtitle: context.l10n.albumFolderArtistYearAlbumSubtitle,
      ),
      AppChoice(
        'album_only',
        Icons.album_outlined,
        context.l10n.albumFolderAlbumOnly,
        subtitle: context.l10n.albumFolderAlbumOnlySubtitle,
      ),
      AppChoice(
        'year_album',
        Icons.event_outlined,
        context.l10n.albumFolderYearAlbum,
        subtitle: context.l10n.albumFolderYearAlbumSubtitle,
      ),
      AppChoice(
        'artist_album_singles',
        Icons.person_outlined,
        context.l10n.albumFolderArtistAlbumSingles,
        subtitle: context.l10n.albumFolderArtistAlbumSinglesSubtitle,
      ),
      AppChoice(
        'artist_album_flat',
        Icons.person_outline_outlined,
        context.l10n.albumFolderArtistAlbumFlat,
        subtitle: context.l10n.albumFolderArtistAlbumFlatSubtitle,
      ),
    ],
    onSelected: (structure) =>
        ref.read(settingsProvider.notifier).setAlbumFolderStructure(structure),
  );

  void _showFolderOrganizationPicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.downloadFolderOrganization,
      subtitle: context.l10n.folderOrganizationDescription,
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final option in [
              (
                'none',
                context.l10n.folderOrganizationNone,
                context.l10n.folderOrganizationNoneSubtitle,
                'Mornye/Track.flac',
              ),
              (
                'playlist',
                context.l10n.folderOrganizationByPlaylist,
                context.l10n.folderOrganizationByPlaylistSubtitle,
                'Mornye/Playlist Name/Track.flac',
              ),
              (
                'artist',
                context.l10n.folderOrganizationByArtist,
                context.l10n.folderOrganizationByArtistSubtitle,
                'Mornye/Artist Name/Track.flac',
              ),
              (
                'album',
                context.l10n.folderOrganizationByAlbum,
                context.l10n.folderOrganizationByAlbumSubtitle,
                'Mornye/Album Name/Track.flac',
              ),
              (
                'artist_album',
                context.l10n.folderOrganizationByArtistAlbum,
                context.l10n.folderOrganizationByArtistAlbumSubtitle,
                'Mornye/Artist/Album/Track.flac',
              ),
              (
                'custom',
                context.l10n.folderOrganizationCustom,
                context.l10n.downloadFolderTemplateDescription,
                ref.read(settingsProvider).folderPathTemplate,
              ),
            ])
              _FolderOption(
                title: option.$2,
                subtitle: option.$3,
                example: option.$4,
                isSelected: current == option.$1,
                onTap: () {
                  if (option.$1 == 'custom') {
                    Navigator.pop(context);
                    _showFolderTemplateEditor(this.context, ref);
                    return;
                  }
                  ref
                      .read(settingsProvider.notifier)
                      .setFolderOrganization(option.$1);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }
}
