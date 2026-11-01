import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/extension_storage_setting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/setup_progress_store.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/constants/language_choices.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/widgets/scroll_edge_fade.dart';
import 'package:mornye/utils/logger.dart';

part 'setup_steps.dart';

final _log = AppLogger('SetupScreen');

// Height of the back-button/progress header row above the PageView
// (16 vertical padding * 2 + 48 button).
const _headerHeight = 80.0;

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen>
    with WidgetsBindingObserver {
  final _progressStore = SetupProgressStore();
  final _platform = defaultTargetPlatform;
  // Desktop has no runtime storage permission: setup skips that step and
  // picks a plain folder.
  final _isDesktop = isDesktopPlatform;
  PageController? _pageController;
  final ScrollController _languageScrollController = ScrollController();
  late final Future<void> _initialization;
  StreamSubscription<void>? _folderSelectionSubscription;
  Future<void>? _folderRecovery;
  bool _initializing = true;
  int _currentStep = 0;

  String _selectedLocale = 'system';
  bool _storagePermissionGranted = false;
  bool _notificationPermissionGranted = false;
  bool _notificationPermissionSkipped = false;
  bool _nearbyGranted = false;

  /// Set once Android refuses Nearby devices, so setup can go on.
  bool _nearbyRefused = false;
  String? _selectedDirectory;
  String? _selectedDirectoryBookmark;
  String? _selectedTreeUri;
  bool _isLoading = false;
  int _androidSdkVersion = 0;

  int get _totalSteps => _isDesktop || isAndroidTv
      ? 3
      : _androidSdkVersion >= 33
      ? (_asksNearby ? 6 : 5)
      : 4;

  /// Android 17 asks for Nearby devices before LAN access, which Mornye Link
  /// and network storage need. Earlier releases allow it without asking.
  bool get _asksNearby =>
      _platform == TargetPlatform.android &&
      !isAndroidTv &&
      _androidSdkVersion >= 37;

  void _setState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialization = _initDeviceInfo();
    if (_platform == TargetPlatform.android) {
      _folderSelectionSubscription = PlatformBridge.setupFolderSelectionEvents()
          .listen((_) => unawaited(_refreshAfterResume()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_folderSelectionSubscription?.cancel());
    _pageController?.dispose();
    _languageScrollController.dispose();
    super.dispose();
  }

  Future<void> _initDeviceInfo() async {
    try {
      await ref.read(settingsProvider.notifier).ensureLoaded();
      if (_platform == TargetPlatform.android) {
        _androidSdkVersion =
            await PlatformBridge.getAndroidSdkVersion() ??
            (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      }
      final saved = await _progressStore.readDraft();
      if (!mounted) return;
      _selectedLocale = ref.read(settingsProvider).locale;
      if (saved != null) {
        final draft = jsonDecode(saved) as Map<String, dynamic>;
        _currentStep = ((draft['step'] as int?) ?? 0).clamp(0, _totalSteps - 1);
        _selectedDirectory = draft['directory'] as String?;
        _selectedDirectoryBookmark = draft['bookmark'] as String?;
        _selectedTreeUri = draft['treeUri'] as String?;
        _notificationPermissionSkipped = draft['skipNotifications'] == true;
        _nearbyRefused = draft['nearbyRefused'] == true;
      }
      if (_isDesktop) {
        _selectedDirectory ??= await resolveDesktopDefaultOutputDirectory();
      } else if (isAndroidTv) {
        _selectedDirectory ??= await _getDefaultDirectory();
      }
      await _checkInitialPermissions();
      if (_platform == TargetPlatform.android) await _restoreSelectedFolder();
    } catch (e, stack) {
      _log.e('Failed to restore setup progress', e, stack);
    } finally {
      if (mounted) {
        _pageController = PageController(initialPage: _currentStep);
        setState(() => _initializing = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshAfterResume());
    }
  }

  Future<void> _refreshAfterResume() async {
    await _initialization;
    if (!mounted) return;
    try {
      await _checkInitialPermissions();
      if (_platform == TargetPlatform.android) await _restoreSelectedFolder();
    } catch (e, stack) {
      _log.e('Failed to refresh setup permissions', e, stack);
    }
  }

  Future<void> _saveProgress({int? step}) async {
    await _progressStore.writeDraft({
      'step': step ?? _currentStep,
      'directory': _selectedDirectory,
      'bookmark': _selectedDirectoryBookmark,
      'treeUri': _selectedTreeUri,
      'skipNotifications': _notificationPermissionSkipped,
      'nearbyRefused': _nearbyRefused,
    });
  }

  Future<void> _restoreSelectedFolder() => _folderRecovery ??=
      _readSelectedFolder().whenComplete(() => _folderRecovery = null);

  Future<void> _readSelectedFolder() async {
    final payload = await PlatformBridge.readSetupFolderSelection();
    if (payload == null || !mounted) return;
    final result = jsonDecode(payload) as Map<String, dynamic>;
    final uri = result['tree_uri'] as String? ?? '';
    if (uri.isNotEmpty) {
      final name = result['display_name'] as String? ?? '';
      setState(() {
        _selectedTreeUri = uri;
        _selectedDirectory = name.isEmpty ? uri : name;
      });
      await _saveProgress();
    }
    // Acknowledge only after the recovered selection is durable in Dart.
    await PlatformBridge.acknowledgeSetupFolderSelection(payload);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _checkInitialPermissions() async {
    if (isAndroidTv) {
      if (mounted) {
        setState(() {
          _storagePermissionGranted = true;
          _notificationPermissionGranted = true;
        });
      }
      return;
    }
    if (_platform == TargetPlatform.iOS) {
      final notificationStatus = await Permission.notification.status;
      if (mounted) {
        setState(() {
          _storagePermissionGranted = true;
          _notificationPermissionGranted =
              notificationStatus.isGranted || notificationStatus.isProvisional;
        });
      }
    } else if (_platform == TargetPlatform.android) {
      final storageGranted = await _hasAndroidStoragePermission();

      PermissionStatus notificationStatus = PermissionStatus.granted;
      if (_androidSdkVersion >= 33) {
        notificationStatus = await Permission.notification.status;
      }
      final nearbyGranted = await LocalNetworkAccess.instance.isGranted();

      if (mounted) {
        setState(() {
          _storagePermissionGranted = storageGranted;
          _notificationPermissionGranted = notificationStatus.isGranted;
          _nearbyGranted = nearbyGranted;
        });
      }
    } else {
      setState(() {
        _storagePermissionGranted = true;
        _notificationPermissionGranted = true;
      });
    }
  }

  Future<bool> _hasAndroidStoragePermission() async {
    if (_androidSdkVersion >= 33 && await Permission.audio.isGranted) {
      return true;
    }
    if (_androidSdkVersion >= 30) {
      return Permission.manageExternalStorage.isGranted;
    }
    return Permission.storage.isGranted;
  }

  Future<void> _requestStoragePermission() async {
    if (_isLoading) return;
    final permissionAudio = context.l10n.permissionAudio;
    final permissionStorage = context.l10n.permissionStorage;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      if (!mounted) return;
      if (_platform == TargetPlatform.iOS) {
        setState(() => _storagePermissionGranted = true);
      } else if (_platform == TargetPlatform.android) {
        var allGranted = await _hasAndroidStoragePermission();

        if (!allGranted && _androidSdkVersion >= 33) {
          var audioStatus = await Permission.audio.status;
          if (!audioStatus.isGranted) {
            audioStatus = await Permission.audio.request();
          }
          allGranted = audioStatus.isGranted;

          if (audioStatus.isPermanentlyDenied) {
            await _showPermissionDeniedDialog(permissionAudio);
            return;
          }
        } else if (!allGranted && _androidSdkVersion >= 30) {
          var manageStatus = await Permission.manageExternalStorage.status;
          if (!manageStatus.isGranted) {
            final shouldOpen = await _showAndroid11StorageDialog();
            if (shouldOpen) {
              await Permission.manageExternalStorage.request();
              await Future<void>.delayed(const Duration(milliseconds: 500));
              manageStatus = await Permission.manageExternalStorage.status;
            }
          }
          allGranted = manageStatus.isGranted;
        } else if (!allGranted) {
          final status = await Permission.storage.request();
          allGranted = status.isGranted;
          if (status.isPermanentlyDenied) {
            await _showPermissionDeniedDialog(permissionStorage);
            return;
          }
        }

        if (!mounted) return;
        setState(() => _storagePermissionGranted = allGranted);
        if (!allGranted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.setupPermissionDeniedMessage)),
          );
        }
      } else {
        setState(() => _storagePermissionGranted = true);
      }
    } catch (e) {
      debugPrint('Permission error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _showAndroid11StorageDialog() => showAppConfirmDialog(
    context,
    title: context.l10n.setupStorageAccessRequired,
    message:
        '${context.l10n.setupStorageAccessMessageAndroid11}\n\n'
        '${context.l10n.setupAllowAccessToManageFiles}',
    confirmLabel: context.l10n.setupOpenSettings,
  );

  Future<void> _requestNotificationPermission() async {
    if (_isLoading) return;
    final permissionNotification = context.l10n.permissionNotification;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      if (!mounted) return;
      if (_platform == TargetPlatform.iOS) {
        final status = await Permission.notification.request();
        if (!mounted) return;
        if (status.isGranted || status.isProvisional) {
          setState(() => _notificationPermissionGranted = true);
        } else if (status.isPermanentlyDenied) {
          await _showPermissionDeniedDialog(permissionNotification);
        }
      } else if (_androidSdkVersion >= 33) {
        final status = await Permission.notification.request();
        if (!mounted) return;
        if (status.isGranted) {
          setState(() => _notificationPermissionGranted = true);
        } else if (status.isPermanentlyDenied) {
          await _showPermissionDeniedDialog(permissionNotification);
        }
      } else {
        setState(() => _notificationPermissionGranted = true);
      }
    } catch (e, stack) {
      _log.e('Failed to request notification permission', e, stack);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _requestNearbyDevices() async {
    final permissionNearby = context.l10n.permissionNearbyDevices;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      // Through Link, so discovery that found nothing without it starts over.
      await ref
          .read(linkClientControllerProvider.notifier)
          .requestLocalNetworkAccess();
      if (mounted) setState(() => _nearbyGranted = true);
    } on LocalNetworkPermissionException {
      if (!mounted) return;
      setState(() => _nearbyRefused = true);
      await _saveProgress();
      if (mounted) await _showPermissionDeniedDialog(permissionNearby);
    } catch (e, stack) {
      _log.e('Failed to request nearby devices permission', e, stack);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showPermissionDeniedDialog(String permissionType) async {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.setupPermissionRequired(permissionType)),
        content: Text(
          context.l10n.setupPermissionRequiredMessage(permissionType),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: Text(context.l10n.setupOpenSettings),
          ),
        ],
      ),
    );
  }

  Future<void> _selectDirectory() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      // Persist before leaving Flutter: the OS may destroy this screen while
      // the external picker is visible, including on Android 13 devices.
      await _saveProgress();
      if (!mounted) return;
      if (_isDesktop) {
        await _pickDesktopDirectory();
      } else if (_platform == TargetPlatform.iOS) {
        await _showIOSDirectoryOptions();
      } else if (_platform == TargetPlatform.android) {
        Map<String, dynamic>? result;
        try {
          result = await PlatformBridge.pickSafTree(forSetup: true);
        } catch (e) {
          _log.w('Failed to open Android SAF picker: $e');
          if (mounted) showCannotOpenFileSnackBar(context, e);
        }
        if (!mounted) return;
        if (result != null) {
          final treeUri = result['tree_uri'] as String? ?? '';
          final displayName = result['display_name'] as String? ?? '';
          if (treeUri.isNotEmpty) {
            setState(() {
              _selectedTreeUri = treeUri;
              _selectedDirectory = displayName.isNotEmpty
                  ? displayName
                  : treeUri;
            });
            await _saveProgress();
          }
        }
        await _restoreSelectedFolder();
        if (!mounted) return;

        // Android fallback if user cancelled SAF picker
        if (_selectedTreeUri == null || _selectedTreeUri!.isEmpty) {
          final defaultDir = await _getDefaultDirectory();
          if (mounted) {
            final useDefault = await showAppConfirmDialog(
              context,
              title: context.l10n.setupUseDefaultFolder,
              message: '${context.l10n.setupNoFolderSelected}\n\n$defaultDir',
              confirmLabel: context.l10n.setupUseDefault,
            );
            if (useDefault) {
              if (!mounted) return;
              setState(() {
                _selectedTreeUri = '';
                _selectedDirectory = defaultDir;
              });
              await _saveProgress();
            }
          }
        }
      }
    } catch (e, stack) {
      _log.e('Failed to select setup folder', e, stack);
      if (mounted) showCannotOpenFileSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Desktop folders are plain paths: no SAF tree and no iOS bookmark.
  Future<void> _pickDesktopDirectory() async {
    final title = context.l10n.setupDownloadLocationTitle;
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: title,
      initialDirectory: await resolveDesktopPickerInitialDirectory(
        _selectedDirectory,
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      _selectedDirectory = picked;
      _selectedDirectoryBookmark = null;
      _selectedTreeUri = null;
    });
    await _saveProgress();
  }

  Future<void> _showIOSDirectoryOptions() async {
    final colorScheme = Theme.of(context).colorScheme;
    await showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text(
                context.l10n.setupDownloadLocationTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                context.l10n.setupDownloadLocationIosMessage,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.folder_special, color: colorScheme.primary),
              title: Text(context.l10n.setupAppDocumentsFolder),
              onTap: () async {
                final dir = await _getDefaultDirectory();
                if (!mounted) return;
                setState(() {
                  _selectedDirectory = dir;
                  _selectedDirectoryBookmark = null;
                });
                if (ctx.mounted) Navigator.pop(ctx);
                await _saveProgress();
              },
            ),
            ListTile(
              leading: Icon(Icons.cloud, color: colorScheme.onSurfaceVariant),
              title: Text(context.l10n.setupChooseFromFiles),
              onTap: () async {
                Navigator.pop(ctx);
                await Future<void>.delayed(const Duration(milliseconds: 250));

                IosPickedDirectory? picked;
                try {
                  picked = await PlatformBridge.pickIosDirectory();
                } catch (e) {
                  if (mounted) {
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

                if (picked == null) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.l10n.setupNoFolderSelected),
                      ),
                    );
                  }
                  return;
                }

                final validation = validateIosPath(
                  picked.path,
                  bookmark: picked.bookmark,
                );
                if (!validation.isValid) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          validation.errorReason ??
                              context.l10n.errorInvalidFolderSelected,
                        ),
                        backgroundColor: Theme.of(context).colorScheme.error,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                  return;
                }

                final pickedDir = picked;
                if (!mounted) return;
                setState(() {
                  _selectedDirectory = pickedDir.path;
                  _selectedDirectoryBookmark = pickedDir.bookmark;
                });
                await _saveProgress();
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<String> _getDefaultDirectory() async {
    if (isAndroidTv) {
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/Mornye';
    }
    if (_platform == TargetPlatform.android) {
      final downloadDir = Directory('/storage/emulated/0/Download/Mornye');
      try {
        if (!await downloadDir.exists()) {
          await downloadDir.create(recursive: true);
        }
        return downloadDir.path;
      } catch (e) {
        debugPrint('Cannot create Download folder: $e');
      }
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/Mornye';
  }

  Future<void> _completeSetup() async {
    if (_selectedDirectory == null) return;
    setState(() => _isLoading = true);

    try {
      if (_platform != TargetPlatform.android ||
          _selectedTreeUri == null ||
          _selectedTreeUri!.isEmpty) {
        final iosBookmark = _platform == TargetPlatform.iOS
            ? _selectedDirectoryBookmark
            : null;
        if (iosBookmark == null || iosBookmark.isEmpty) {
          final dir = Directory(_selectedDirectory!);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
        }
        ref.read(settingsProvider.notifier).setStorageMode('app');
        ref
            .read(settingsProvider.notifier)
            .setDownloadDirectory(
              _selectedDirectory!,
              iosBookmark: iosBookmark,
            );
        ref.read(settingsProvider.notifier).setDownloadTreeUri('');
      } else {
        ref.read(settingsProvider.notifier).setStorageMode('saf');
        ref
            .read(settingsProvider.notifier)
            .setDownloadTreeUri(
              _selectedTreeUri!,
              displayName: _selectedDirectory,
            );
      }

      await ref.read(settingsProvider.notifier).setFirstLaunchComplete();
      await _progressStore.clear();

      if (mounted) context.go('/tutorial');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.snackbarError(context.friendlyError(e))),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _nextPage() {
    bool canProceed = false;
    if (_currentStep == 0) {
      canProceed = true;
    } else {
      canProceed = _isStepCompleted(_currentStep);
    }

    if (canProceed) {
      unawaited(_goToStep(_currentStep + 1));
    }
  }

  void _prevPage() {
    unawaited(_goToStep(_currentStep - 1));
  }

  Future<void> _goToStep(int step) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _saveProgress(step: step);
      if (!mounted) return;
      setState(() => _currentStep = step);
      await _pageController?.animateToPage(
        step,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } catch (e, stack) {
      _log.e('Failed to save setup step', e, stack);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _isStepCompleted(int step) {
    if (step == 0) return true;
    if (step == 1) return true;

    final logicStep = step - 2;

    if (_isDesktop || isAndroidTv) {
      return logicStep == 0 && _selectedDirectory != null;
    }
    if (_androidSdkVersion >= 33) {
      // Nearby devices, when asked, comes before the folder.
      final folderStep = _asksNearby ? 3 : 2;
      if (logicStep == folderStep) return _selectedDirectory != null;
      switch (logicStep) {
        case 0:
          return _storagePermissionGranted;
        case 1:
          return _notificationPermissionGranted ||
              _notificationPermissionSkipped;
        case 2:
          return _nearbyGranted || _nearbyRefused;
      }
    } else {
      switch (logicStep) {
        case 0:
          return _storagePermissionGranted;
        case 1:
          return _selectedDirectory != null;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_initializing) {
      return const Scaffold(body: Center(child: AppLoadingIndicator()));
    }

    final progress = (_currentStep + 1) / _totalSteps;
    final stepMotion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );

    final isLastStep = _currentStep >= _totalSteps - 1;
    final nextButton = materialExpressiveEnabled(context)
        ? _buildExpressiveFab(colorScheme)
        : !isLastStep
        ? FloatingActionButton.extended(
            onPressed: !_isLoading && _isStepCompleted(_currentStep)
                ? _nextPage
                : null,
            label: Row(
              children: [
                Text(context.l10n.setupNext),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward),
              ],
            ),
            icon: const SizedBox.shrink(), // Custom layout
          )
        : FloatingActionButton.extended(
            onPressed: _isLoading ? null : _completeSetup,
            label: _isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: colorScheme.onPrimary,
                    ),
                  )
                : Text(context.l10n.setupGetStarted),
            icon: const Icon(Icons.check),
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
          );

    Widget content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            children: [
              if (_currentStep > 0)
                AppIconButton.filledTonal(
                  onPressed: _prevPage,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back),
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    foregroundColor: colorScheme.onSurfaceVariant,
                  ),
                )
              else
                const SizedBox(width: 48),
              const Spacer(),
              SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Expressive steps fill on a spring around a wavy
                    // ring; the fallback jumps straight to the step.
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: progress),
                      duration: stepMotion.duration,
                      curve: stepMotion.curve,
                      builder: (context, value, _) =>
                          AppProgressIndicator.circular(
                            wavy: false,
                            value: value,
                            strokeWidth: 4,
                            trackColor: colorScheme.surfaceContainerHighest,
                            color: colorScheme.primary,
                            strokeCap: StrokeCap.round,
                          ),
                    ),
                    Center(
                      child: Text(
                        '${_currentStep + 1}/$_totalSteps',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildWelcomeStep(colorScheme),
              _buildLanguageStep(colorScheme),
              if (!_isDesktop && !isAndroidTv) _buildStorageStep(colorScheme),
              if (_androidSdkVersion >= 33 && !isAndroidTv)
                _buildNotificationStep(colorScheme),
              if (_asksNearby) _buildNearbyStep(colorScheme),
              _buildDirectoryStep(colorScheme),
            ],
          ),
        ),
        // Desktop windows keep the button in the centered column, beside the
        // content, rather than in the far corner of a wide window.
        if (_isDesktop)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: nextButton,
            ),
          ),
      ],
    );
    if (_isDesktop) {
      content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: content,
        ),
      );
    }

    final scaffold = Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(child: content),
      floatingActionButton: _isDesktop ? null : nextButton,
    );
    if (!_isDesktop) return scaffold;
    // Enter moves on, as the default button of a desktop window would.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _advanceFromKeyboard,
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            _advanceFromKeyboard,
      },
      child: Focus(autofocus: true, child: scaffold),
    );
  }

  void _advanceFromKeyboard() {
    if (_isLoading) return;
    if (_currentStep >= _totalSteps - 1) {
      unawaited(_completeSetup());
    } else if (_isStepCompleted(_currentStep)) {
      _nextPage();
    }
  }
}
