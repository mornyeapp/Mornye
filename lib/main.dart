import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/app.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/share_intent_service.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/services/activity_attachment.dart';
import 'package:mornye/services/app_crash_service.dart';
import 'package:mornye/services/background_favorites.dart';
import 'package:mornye/services/desktop_deep_links.dart';
import 'package:mornye/services/desktop_diagnostics.dart';
import 'package:mornye/services/desktop_library_watcher.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_phone_playback.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/services/player_widget_service.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/local_library_scan_prefs.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart'
    show restoreDesktopSidebar;
import 'package:mornye/widgets/desktop/desktop_inspector.dart'
    show bindDesktopFullScreenLyrics;
import 'package:mornye/widgets/desktop/desktop_window.dart'
    show listenDesktopWindowFullScreen;

final _log = AppLogger('Main');
_StartupBenchmark? _startupBenchmark;

void main() {
  if (const bool.fromEnvironment('CORE_BACKEND_STARTUP_BENCHMARK')) {
    _startupBenchmark = _StartupBenchmark();
  }
  // Catch uncaught Dart errors so a failing async path is logged, not fatal.
  // Native backend crashes still can't be caught here.
  runZonedGuarded(
    () async {
      final binding = WidgetsFlutterBinding.ensureInitialized();
      // The preferences plugin answers without an Activity, so on Android
      // the load overlaps the Activity's creation.
      final preferences = SharedPreferences.getInstance();
      if (Platform.isAndroid) {
        // A media service can start the engine before MainActivity registers
        // the backend and platform channels. Calls made earlier would fail or
        // never be answered, leaving extensions uninitialized. Playback has
        // its channels on the engine, so a car's media browser that started
        // the app can browse and play at once.
        if (!isActivityAttached(binding)) {
          unawaited(_startBackgroundPlayback());
        }
        await waitForActivityAttachment(binding);
      }
      // Asked after attachment, so an app a media browser started long
      // before it opens still reads the current wallpaper colors.
      final dynamicColors = DynamicColors.request();
      // Awaited before runApp, which reports a failure once.
      final orientation = _initializeOrientation()..ignore();
      // Desktop: log files and the unclean-exit marker, before the error
      // hooks below start writing to them.
      await DesktopDiagnostics.initialize();
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          const [AppInfo.appName],
          '${AppInfo.copyright}\n\n${AppInfo.license}\n\n'
          '${await rootBundle.loadString('LICENSE')}\n\n'
          '${await rootBundle.loadString('COPYING')}',
        );
        yield LicenseEntryWithLineBreaks(const [
          'Inter',
        ], await rootBundle.loadString('assets/fonts/Inter-LICENSE.txt'));
        yield LicenseEntryWithLineBreaks(
          const ['Google Sans Flex'],
          await rootBundle.loadString(
            'assets/fonts/GoogleSansFlex-LICENSE.txt',
          ),
        );
        yield LicenseEntryWithLineBreaks(const [
          'libsmb2',
        ], await rootBundle.loadString('assets/licenses/libsmb2.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'Material Color Utilities (native palette)',
          'Dart SDK (native Random compatibility)',
        ], await rootBundle.loadString('assets/licenses/native_palette.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'rusqlite',
          'roxmltree',
        ], await rootBundle.loadString('assets/licenses/native_data_jobs.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'FFmpeg',
        ], await rootBundle.loadString('assets/licenses/ffmpeg.txt'));
        // FFmpegKit (mobile) and the Linux and Windows FFmpeg builds.
        yield LicenseEntryWithLineBreaks(const [
          'FFmpeg',
          'FFmpegKit',
        ], await rootBundle.loadString('assets/licenses/lgpl-3.0.txt'));
        if (Platform.isAndroid) {
          yield LicenseEntryWithLineBreaks(const [
            'libusb',
            'libusb1-sys',
          ], await rootBundle.loadString('assets/licenses/usb.txt'));
          yield LicenseEntryWithLineBreaks(const [
            'Oboe',
          ], await rootBundle.loadString('assets/licenses/oboe.txt'));
          yield LicenseEntryWithLineBreaks(const [
            'WavPack',
          ], await rootBundle.loadString('assets/licenses/wavpack.txt'));
          yield LicenseEntryWithLineBreaks(const [
            'libFLAC',
          ], await rootBundle.loadString('assets/licenses/flac.txt'));
        }
      });
      _startupBenchmark?.observeFirstFrame();

      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        previousOnError?.call(details);
        _log.e('Uncaught Flutter error: ${details.exceptionAsString()}');
        unawaited(
          AppCrashService.recordRuntimeError(details.exception, details.stack),
        );
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        _log.e('Uncaught platform error: $error');
        unawaited(AppCrashService.recordRuntimeError(error, stack));
        return true;
      };

      final prefs = await preferences;
      var bootstrapSettings = loadBootstrapSettings(prefs);
      // The SAF check overlaps the install marker read. An installation
      // reset rewrites the settings, so its result is then replaced.
      var safValidation = _startSafTreeValidation(bootstrapSettings);
      if (await _prepareAndroidInstallationState(prefs)) {
        bootstrapSettings = loadBootstrapSettings(prefs);
        safValidation = _startSafTreeValidation(bootstrapSettings);
      }
      musicPlayerRuntime.configure(bootstrapSettings);
      if (isDesktopPlatform) restoreDesktopSidebar(prefs);
      final bootstrapTheme = loadBootstrapThemeSettings(prefs);
      final initialSafAccessLost = await _detectInitialSafAccessLoss(
        safValidation,
      );
      final runtimeProfile = await _resolveRuntimeProfile(prefs);
      _configureImageCache(runtimeProfile);
      await orientation;
      // Usually answered by now. The first frame then has the final theme,
      // with no fade from the seed colors; a late answer still applies.
      await dynamicColors.settle(const Duration(milliseconds: 100));

      runApp(
        ProviderScope(
          overrides: [
            lowEndDeviceProvider.overrideWithValue(
              runtimeProfile.disableOverscrollEffects,
            ),
            deviceSupportsBackdropBlurProvider.overrideWithValue(
              runtimeProfile.enableBackdropBlur,
            ),
            // The RAM tiers describe Android hardware. Other platforms keep
            // the existing full material by default.
            deviceSupportsLiquidGlassProvider.overrideWithValue(
              !Platform.isAndroid || runtimeProfile.enableBackdropBlur,
            ),
            initialSettingsProvider.overrideWithValue(bootstrapSettings),
            initialSafAccessLostProvider.overrideWithValue(
              initialSafAccessLost,
            ),
            initialThemeSettingsProvider.overrideWithValue(bootstrapTheme),
            initialDynamicColorsProvider.overrideWithValue(dynamicColors),
            // While the paired desktop plays in the phone's place, the
            // player screens show and drive it; on the desktop, the phone
            // it follows.
            activeRemotePlaybackProvider.overrideWith(
              (ref) =>
                  ref.watch(linkRemotePlaybackProvider) ??
                  ref.watch(linkFollowedPhonePlaybackProvider),
            ),
            // Also while songs transfer, so the computer can still ask for
            // this phone's files and hear how a transfer stands.
            linkKeepConnectedProvider.overrideWith(
              (ref) =>
                  ref.watch(linkRemotePlaybackProvider) != null ||
                  ref.watch(linkPhoneTransfersActiveProvider),
            ),
          ],
          child: EagerInitialization(
            child: MornyeApp(
              disableOverscrollEffects: runtimeProfile.disableOverscrollEffects,
            ),
          ),
        ),
      );
      musicPlayerRuntime.prepareCovers();
      // Waits until startup settles, then analyzes how songs sound for
      // Autoplay. Media browsers that start without the app shell skip it.
      musicPlayerRuntime.startSongAnalysis();
      if (Platform.isAndroid || Platform.isIOS) {
        unawaited(
          PlayerWidgetService.instance.initialize((command) async {
            await restorePersistedPlaybackSession();
            final handler = await initMusicPlayer();
            if (command == 'open') {
              await WidgetsBinding.instance.endOfFrame;
              final navigator =
                  AppNavigationService.rootNavigatorKey.currentState;
              if (navigator != null && handler.mediaItem.value != null) {
                unawaited(
                  navigator.push<void>(
                    NowPlayingRoute(child: const NowPlayingScreen()),
                  ),
                );
              }
            } else {
              await PlayerWidgetService.control(handler, command);
            }
          }),
        );
      }
    },
    (error, stack) {
      _log.e('Uncaught zone error: $error');
      unawaited(AppCrashService.recordRuntimeError(error, stack));
    },
  );
}

// Opt-in release measurement. The ordinary startup path owns initialization;
// reporting and validation happen after both measured boundaries are captured.
class _StartupBenchmark {
  final _watch = Stopwatch()..start();
  late final Future<int> _firstFrame;

  void observeFirstFrame() {
    _firstFrame = WidgetsBinding.instance.waitUntilFirstFrameRasterized.then(
      (_) => _watch.elapsedMicroseconds,
    );
  }

  void extensionsReady(ExtensionState state, AppSettings settings) {
    final ready = _watch.elapsedMicroseconds;
    unawaited(_report(state, settings, ready));
  }

  Future<void> _report(
    ExtensionState state,
    AppSettings settings,
    int ready,
  ) async {
    try {
      if (!kReleaseMode) throw StateError('Startup benchmark requires release');
      final firstFrame = await _firstFrame.timeout(const Duration(seconds: 30));
      if (!state.isInitialized || state.error != null) {
        throw StateError('Extensions are not ready: ${state.error}');
      }
      final backends = await PlatformBridge.getBackendImplementations();
      const backend = String.fromEnvironment('EXPECTED_CORE_BACKEND');
      if (!const ['go', 'rust'].contains(backend) ||
          backends.length != 4 ||
          backends.values.any((value) => value != backend)) {
        throw StateError('Unexpected backend ownership: $backends');
      }
      await _write({
        'result': 'CORE_BACKEND_STARTUP_PASS backend=$backend',
        'startup': {
          'schema': 1,
          'backend': backend,
          'mode': 'release',
          'start_boundary': 'Dart main entry before bindings',
          'first_frame_boundary': 'first rasterized frame observed',
          'ready_boundary': 'production ensureInitialized completed',
          'cache': 'fresh process; warm filesystem',
          'first_frame_us': firstFrame,
          'extensions_ready_us': ready,
          'settings_sha256': sha256
              .convert(utf8.encode(jsonEncode(settings.toJson())))
              .toString(),
          'extensions': [
            for (final extension in state.extensions)
              {
                'id': extension.id,
                'enabled': extension.enabled,
                'status': extension.status,
              },
          ],
        },
      });
    } catch (error) {
      await _write({'result': 'CORE_BACKEND_STARTUP_FAIL $error'});
    }
  }

  Future<void> _write(Map<String, Object?> result) async {
    final support = await getApplicationSupportDirectory();
    await File(
      '${support.path}/core-backend-probe-result.json',
    ).writeAsString(jsonEncode({'pid': pid, ...result}), flush: true);
  }
}

/// The player, its saved session and the media controls, from the stored
/// settings, for a media browser such as Android Auto that starts the app
/// without an Activity. The app shell takes the controls over once it opens.
Future<void> _startBackgroundPlayback() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // An Activity that attached meanwhile runs the full startup instead.
    if (isActivityAttached(WidgetsBinding.instance)) return;
    final settings = loadBootstrapSettings(prefs);
    final runtime = musicPlayerRuntime
      ..configure(settings)
      ..prepareCovers();
    final l10n = appLocalizationsFor(settings.locale);
    runtime.updateStrings(
      unknownTitle: l10n.unknownTitle,
      unknownArtist: l10n.unknownArtist,
    );
    final dependencies = runtime.dependencies;
    runtime.configureBackgroundNotification(
      presentation: PlaybackNotification(
        mornye: loadBootstrapThemeSettings(prefs).style == AppThemeStyle.mornye,
        favoriteLabel: l10n.trackOptionAddToLoved,
        unfavoriteLabel: l10n.trackOptionRemoveFromLoved,
        shuffleOnLabel: l10n.nowPlayingShuffleOn,
        shuffleOffLabel: l10n.nowPlayingPlayInOrder,
      ),
      favorites: BackgroundFavorites(
        library: dependencies.libraryDatabase,
        history: dependencies.historyDatabase,
        collections: dependencies.collectionsDatabase,
        covers: dependencies.coverStore,
      ),
    );
    await runtime.restoreSession();
    await runtime.initialize();
  } catch (error, stack) {
    _log.e('Failed to start playback without the app open', error, stack);
  }
}

/// Resolves Android TV, then the orientation, alongside the other startup
/// calls.
Future<void> _initializeOrientation() async {
  await initializeAndroidTv();
  // MainActivity.onCreate already asks phones for portrait, the request
  // below, and the router observer repeats it on the first page. TV gets
  // fixed landscape there and the user landscape here.
  if (Platform.isAndroid && !isAndroidTv) return;
  await setAppOrientation();
}

const _runtimeProfileTierKey = 'runtime_profile_tier_v1';

/// Returns whether a restored-installation reset started, which may have
/// rewritten the stored settings.
Future<bool> _prepareAndroidInstallationState(SharedPreferences prefs) async {
  if (!Platform.isAndroid) return false;

  var resetStarted = false;
  try {
    final hasPersistedSettings = hasPersistedAppSettings(prefs);
    final installState = await PlatformBridge.ensureInstallMarker();
    final shouldReset = shouldResetRestoredInstallation(
      hasPersistedSettings: hasPersistedSettings,
      installState: installState,
    );
    if (!shouldReset) return false;

    resetStarted = true;
    _log.w(
      'Android restored state into a fresh installation; resetting '
      'installation-bound settings',
    );
    await resetRestoredInstallationSettings(prefs);
    await prefs.remove(_runtimeProfileTierKey);
    await prefs.remove(localLibraryLastScannedAtKey);
    await AppStateDatabase.instance.clearPendingQueueAfterInstallationRestore();
  } catch (e) {
    // Startup SAF validation remains the second line of defense if an OEM or
    // bridge implementation prevents install-marker inspection.
    _log.w('Failed to inspect restored installation state: $e');
  }
  return resetStarted;
}

/// Starts the startup SAF grant check for [settings]. A failure is captured
/// with the result, so a check that is replaced never reports an error.
Future<(bool, Object?)>? _startSafTreeValidation(AppSettings settings) {
  if (!Platform.isAndroid ||
      settings.isFirstLaunch ||
      settings.storageMode != 'saf' ||
      settings.downloadTreeUri.isEmpty) {
    return null;
  }

  return PlatformBridge.validateSafTreeAccess(settings.downloadTreeUri)
      .timeout(const Duration(seconds: 2))
      .then<(bool, Object?)>(
        (accessible) => (accessible, null),
        onError: (Object error) => (true, error),
      );
}

Future<bool> _detectInitialSafAccessLoss(
  Future<(bool, Object?)>? validation,
) async {
  if (validation == null) return false;
  final (accessible, error) = await validation;
  if (error != null) {
    // A transient bridge failure must not trap the user at launch. Download
    // preflight validates strictly again before any write starts.
    _log.w('Failed to validate SAF access during startup: $error');
  }
  return !accessible;
}

Future<_RuntimeProfile> _resolveRuntimeProfile(SharedPreferences prefs) async {
  final cachedTier = prefs.getString(_runtimeProfileTierKey);
  if (cachedTier != null) {
    final cached = _RuntimeProfile.fromTier(cachedTier);
    if (cached != null) return cached;
  }

  const defaults = _RuntimeProfile.standard();

  if (!Platform.isAndroid) {
    await prefs.setString(_runtimeProfileTierKey, defaults.tier);
    return defaults;
  }

  try {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final isArm32Only = androidInfo.supported64BitAbis.isEmpty;
    final isLowRamDevice =
        androidInfo.isLowRamDevice || androidInfo.physicalRamSize <= 2500;

    final profile = (isArm32Only || isLowRamDevice)
        ? const _RuntimeProfile.low()
        : androidInfo.physicalRamSize >= 6000
        ? const _RuntimeProfile.high()
        : defaults;
    await prefs.setString(_runtimeProfileTierKey, profile.tier);
    return profile;
  } catch (e) {
    debugPrint('Failed to resolve runtime profile: $e');
    return defaults;
  }
}

void _configureImageCache(_RuntimeProfile runtimeProfile) {
  final imageCache = PaintingBinding.instance.imageCache;
  // Keep memory cache bounded so cover-heavy pages don't retain too many
  // full-resolution images simultaneously.
  imageCache.maximumSize = runtimeProfile.imageCacheMaximumSize;
  imageCache.maximumSizeBytes = runtimeProfile.imageCacheMaximumSizeBytes;
}

class _RuntimeProfile {
  final String tier;
  final int imageCacheMaximumSize;
  final int imageCacheMaximumSizeBytes;
  final bool disableOverscrollEffects;
  final bool enableBackdropBlur;

  const _RuntimeProfile._({
    required this.tier,
    required this.imageCacheMaximumSize,
    required this.imageCacheMaximumSizeBytes,
    required this.disableOverscrollEffects,
    required this.enableBackdropBlur,
  });

  const _RuntimeProfile.low()
    : this._(
        tier: 'low',
        imageCacheMaximumSize: 120,
        imageCacheMaximumSizeBytes: 24 << 20,
        disableOverscrollEffects: true,
        enableBackdropBlur: false,
      );

  const _RuntimeProfile.standard()
    : this._(
        tier: 'standard',
        imageCacheMaximumSize: 240,
        imageCacheMaximumSizeBytes: 60 << 20,
        disableOverscrollEffects: false,
        enableBackdropBlur: false,
      );

  const _RuntimeProfile.high()
    : this._(
        tier: 'high',
        imageCacheMaximumSize: 320,
        imageCacheMaximumSizeBytes: 80 << 20,
        disableOverscrollEffects: false,
        enableBackdropBlur: true,
      );

  static _RuntimeProfile? fromTier(String tier) => switch (tier) {
    'low' => const _RuntimeProfile.low(),
    'standard' => const _RuntimeProfile.standard(),
    'high' => const _RuntimeProfile.high(),
    _ => null,
  };
}

class EagerInitialization extends ConsumerStatefulWidget {
  const EagerInitialization({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<EagerInitialization> createState() =>
      _EagerInitializationState();
}

class _EagerInitializationState extends ConsumerState<EagerInitialization>
    with WidgetsBindingObserver {
  ProviderSubscription<bool>? _localLibraryEnabledSub;
  Timer? _downloadHistoryWarmupTimer;
  Timer? _localLibraryWarmupTimer;
  bool _localLibraryWarmupScheduled = false;
  bool _autoScanTriggeredOnLaunch = false;
  StreamSubscription<void>? _verificationNotificationSubscription;
  StreamSubscription<void>? _extensionAuthCallbackSubscription;
  DesktopDeepLinks? _desktopDeepLinks;
  DesktopLibraryWatcher? _desktopLibraryWatcher;
  ProviderSubscription<bool>? _desktopLibraryWatchSub;
  ProviderSubscription<List<LocalLibrarySource>>? _desktopLibrarySourcesSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _verificationNotificationSubscription =
          PlatformBridge.verificationNotificationEvents().listen(
            (_) => unawaited(_consumeVerificationNotification()),
          );
      _extensionAuthCallbackSubscription =
          PlatformBridge.extensionAuthCallbackEvents().listen(
            (_) => unawaited(_completeExtensionCallback()),
          );
      // After the callback subscription, so a launch URL is not missed.
      if (isDesktopPlatform) {
        _desktopDeepLinks = DesktopDeepLinks()..start();
        listenDesktopWindowFullScreen();
        bindDesktopFullScreenLyrics();
        // Starts the Mornye Link server when the owner turned it on.
        ref.read(linkDesktopHostProvider);
      }
      _initializeAppServices();
      _initializeExtensions();
      _initializeDeferredProviders();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CoverCacheManager.stopMaintenance();
    _localLibraryEnabledSub?.close();
    _downloadHistoryWarmupTimer?.cancel();
    _localLibraryWarmupTimer?.cancel();
    _verificationNotificationSubscription?.cancel();
    _extensionAuthCallbackSubscription?.cancel();
    unawaited(_desktopDeepLinks?.dispose());
    _desktopLibraryWatchSub?.close();
    _stopDesktopLibraryWatcher();
    NotificationService().verificationNotifications.setHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_consumeVerificationNotification());
      CoverCacheManager.scheduleMaintenance();
      // Native downloads can finish while Flutter is suspended. Refresh the
      // persisted history even when no queued item remains to reconcile.
      if (ref.exists(downloadHistoryProvider)) {
        unawaited(
          ref.read(downloadHistoryProvider.notifier).refreshFromStorage(),
        );
      }
      _maybeAutoScanLocalLibrary();
      if (ref.exists(localLibraryProvider)) {
        unawaited(
          ref
              .read(localLibraryProvider.notifier)
              .refreshSourceAvailability(scanReconnected: true),
        );
      }
      if (ref.exists(downloadQueueProvider)) {
        ref
            .read(downloadQueueProvider.notifier)
            .resumePendingDownloadsOnForeground();
      }
    } else if (state == AppLifecycleState.paused) {
      CoverCacheManager.stopMaintenance();
      // Last reliable moment before the OS may kill the process: make sure
      // any debounced download-queue persistence reaches disk.
      if (ref.exists(downloadQueueProvider)) {
        unawaited(
          ref
              .read(downloadQueueProvider.notifier)
              .flushQueuePersistence()
              .catchError((Object error) {
                _log.e('Failed to flush background download queue: $error');
              }),
        );
      }
      // Backgrounded: release idle native runtimes and connections.
      unawaited(PlatformBridge.releaseNativeMemory());
    }
  }

  @override
  void didHaveMemoryPressure() {
    // OS memory pressure: drop decoded bitmaps (disk caches stay intact) and
    // ask the native backend to release disposable runtimes and caches.
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    if (CoverCacheManager.isInitialized) {
      CoverCacheManager.instance.store.emptyMemoryCache();
    }
    unawaited(PlatformBridge.releaseNativeMemory(underPressure: true));
  }

  void _initializeDeferredProviders() {
    _downloadHistoryWarmupTimer = _scheduleProviderWarmup(
      const Duration(milliseconds: 400),
      () => ref.read(downloadHistoryProvider),
    );
    _maybeScheduleLocalLibraryWarmup(
      ref.read(
        settingsProvider.select((settings) => settings.localLibraryEnabled),
      ),
    );

    _localLibraryEnabledSub = ref.listenManual<bool>(
      settingsProvider.select((settings) => settings.localLibraryEnabled),
      (previous, next) {
        if (next == true) {
          _maybeScheduleLocalLibraryWarmup(true);
        }
      },
    );

    if (isDesktopPlatform) {
      _desktopLibraryWatchSub = ref.listenManual<bool>(
        settingsProvider.select(_desktopLibraryWatchEnabled),
        (_, _) => _updateDesktopLibraryWatcher(),
      );
    }
  }

  /// Desktop watches library folders unless automatic scans are off.
  static bool _desktopLibraryWatchEnabled(AppSettings settings) =>
      settings.localLibraryEnabled && settings.localLibraryAutoScan != 'off';

  /// Starts or stops the desktop folder watcher. Starts only once the
  /// library provider is warm, so watching never delays startup.
  void _updateDesktopLibraryWatcher() {
    if (!isDesktopPlatform || !mounted) return;
    if (!_desktopLibraryWatchEnabled(ref.read(settingsProvider)) ||
        !ref.exists(localLibraryProvider)) {
      _stopDesktopLibraryWatcher();
      return;
    }
    if (_desktopLibraryWatcher != null) return;
    final watcher = _desktopLibraryWatcher = DesktopLibraryWatcher(
      scanSource: (sourceId) => ref
          .read(localLibraryProvider.notifier)
          .startSourceScan(sourceId, notify: false, waitForCurrentScan: true),
      isScanning: () => ref.read(localLibraryProvider).isScanning,
    );
    _desktopLibrarySourcesSub = ref.listenManual<List<LocalLibrarySource>>(
      localLibraryProvider.select((state) => state.sources),
      (_, sources) => unawaited(watcher.updateSources(sources)),
      fireImmediately: true,
    );
  }

  void _stopDesktopLibraryWatcher() {
    _desktopLibrarySourcesSub?.close();
    _desktopLibrarySourcesSub = null;
    unawaited(_desktopLibraryWatcher?.dispose());
    _desktopLibraryWatcher = null;
  }

  Timer _scheduleProviderWarmup(Duration delay, VoidCallback action) {
    return Timer(delay, () {
      if (!mounted) return;
      action();
    });
  }

  void _maybeScheduleLocalLibraryWarmup(bool enabled) {
    if (!enabled || _localLibraryWarmupScheduled) return;
    _localLibraryWarmupScheduled = true;
    _localLibraryWarmupTimer = _scheduleProviderWarmup(
      const Duration(milliseconds: 1600),
      () {
        if (!ref.read(settingsProvider).localLibraryEnabled) {
          _localLibraryWarmupScheduled = false;
          return;
        }
        ref.read(localLibraryProvider);
        _updateDesktopLibraryWatcher();
        if (!_autoScanTriggeredOnLaunch) {
          _autoScanTriggeredOnLaunch = true;
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _maybeAutoScanLocalLibrary();
          });
        }
      },
    );
  }

  Future<void> _maybeAutoScanLocalLibrary() async {
    if (!mounted) return;

    final settings = ref.read(settingsProvider);
    if (!settings.localLibraryEnabled) return;
    if (settings.localLibraryAutoScan == 'off') return;

    final libraryState = ref.read(localLibraryProvider);
    if (libraryState.isScanning) return;

    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final pendingSourceId = prefs.getString(localLibraryActiveScanSourceKey);
    if (pendingSourceId != null && pendingSourceId.trim().isNotEmpty) {
      await ref
          .read(localLibraryProvider.notifier)
          .startSourceScan(
            pendingSourceId.trim(),
            notify: prefs.getBool(localLibraryActiveScanNotifyKey) ?? true,
          );
      return;
    }
    final lastScanned = readLocalLibraryLastScannedAt(prefs);

    if (lastScanned != null) {
      final elapsed = now.difference(lastScanned);

      switch (settings.localLibraryAutoScan) {
        case 'on_open':
          if (elapsed.inMinutes < 10) return;
          break;
        case 'daily':
          if (elapsed.inHours < 24) return;
          break;
        case 'weekly':
          if (elapsed.inDays < 7) return;
          break;
        default:
          return;
      }
    }

    await ref.read(localLibraryProvider.notifier).scanAllSources(notify: false);
  }

  Future<void> _initializeAppServices() async {
    try {
      await CoverCacheManager.initialize();
      CoverCacheManager.scheduleMaintenance();
      await Future.wait([
        NotificationService().initialize(),
        ShareIntentService().initialize(),
      ]);
    } catch (e) {
      debugPrint('Failed to initialize app services: $e');
    }
  }

  Future<void> _initializeExtensions() async {
    try {
      await ref.read(extensionProvider.notifier).ensureInitialized();
      _startupBenchmark?.extensionsReady(
        ref.read(extensionProvider),
        ref.read(settingsProvider),
      );
      if (!mounted) return;
      NotificationService().verificationNotifications.setHandler((
        target,
      ) async {
        if (!mounted) return;
        try {
          await ref
              .read(downloadQueueProvider.notifier)
              .handleVerificationNotificationTap(target);
        } catch (error) {
          _log.w('Could not open verification notification: $error');
          if (mounted) showExtensionVerificationUnavailable(target.extensionId);
        }
      });
      await _consumeVerificationNotification();
    } catch (e) {
      debugPrint('Failed to initialize extensions: $e');
    }
  }

  Future<void> _consumeVerificationNotification() async {
    if (!mounted || !Platform.isAndroid) return;
    try {
      final payload = await PlatformBridge.consumeVerificationNotification();
      if (mounted) {
        NotificationService().verificationNotifications.receive(payload);
      }
    } catch (error) {
      _log.w('Could not read pending verification notification: $error');
    }
  }

  Future<void> _completeExtensionCallback() async {
    try {
      await ref.read(extensionProvider.notifier).ensureInitialized();
      await PlatformBridge.processPendingExtensionCallbacks();
    } catch (error) {
      _log.w('Could not complete extension verification: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
