import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/verification_notification.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/string_utils.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal()
    : _notifications = FlutterLocalNotificationsPlugin();

  @visibleForTesting
  NotificationService.forTesting(FlutterLocalNotificationsPlugin notifications)
    : _notifications = notifications;

  final FlutterLocalNotificationsPlugin _notifications;
  bool _isInitialized = false;
  Future<void>? _initialization;
  final verificationNotifications = VerificationNotificationRouter();
  bool _notificationPermissionRequested = false;
  AppLocalizations? _l10n;

  /// Call this from the widget tree (e.g. didChangeDependencies) whenever the
  /// app locale changes so that notification strings stay in sync.
  void updateStrings(AppLocalizations l10n) {
    _l10n = l10n;
  }

  String get embeddingMetadataLabel =>
      _l10n?.notifEmbeddingMetadata ?? 'Embedding metadata...';

  String get libraryScanInterruptedMessage =>
      _l10n?.notifLibraryScanInterruptedBody ??
      'The previous library scan was interrupted. Scan the folder again to continue. Your indexed tracks are still available.';

  static const String libraryScanWorkKind = 'library_scan';
  static const String updateDownloadWorkKind = 'app_update';
  int _linkTransferSequence = 0;

  // Kinds whose progress the Android foreground-service notification shows,
  // replacing the plugin's progress notification so only one is visible.
  final Set<String> _serviceNotificationKinds = {};

  /// Keeps user-started work running when the screen turns off (Android
  /// foreground service, iOS background task). Pair with [endBackgroundWork].
  Future<void> beginBackgroundWork(String kind, {required String title}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final started = await PlatformBridge.startBackgroundWork(
        kind,
        title: title,
      );
      if (started && Platform.isAndroid) _serviceNotificationKinds.add(kind);
    } catch (e) {
      debugPrint('Background work $kind could not start: $e');
    }
  }

  Future<void> endBackgroundWork(String kind) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _serviceNotificationKinds.remove(kind);
    try {
      await PlatformBridge.stopBackgroundWork(kind);
    } catch (e) {
      debugPrint('Background work $kind could not stop: $e');
    }
  }

  Future<void> beginLibraryScanWork() => beginBackgroundWork(
    libraryScanWorkKind,
    title: _l10n?.notifScanningLibrary ?? 'Scanning local library',
  );

  /// Each upload owns its lease, so finishing one cannot stop another.
  Future<Future<void> Function()> acquireLinkTransferWork(
    String desktopName,
  ) async {
    final kind = 'link_transfer_${_linkTransferSequence++}';
    await beginBackgroundWork(
      kind,
      title:
          _l10n?.linkHandoffSending(desktopName) ??
          'Sending this song to $desktopName...',
    );
    var released = false;
    return () async {
      if (released) return;
      released = true;
      await endBackgroundWork(kind);
    };
  }

  Future<void> beginUpdateDownloadWork({required String version}) =>
      beginBackgroundWork(
        updateDownloadWorkKind,
        title:
            _l10n?.notifDownloadingUpdate(version) ??
            'Downloading ${AppInfo.appName} v$version',
      );

  Future<bool> _showInBackgroundWork(
    String kind, {
    required String title,
    required String body,
    required int progress,
  }) async {
    if (!_serviceNotificationKinds.contains(kind)) return false;
    try {
      await PlatformBridge.updateBackgroundWork(
        kind,
        title: title,
        text: body,
        progress: progress,
      );
      return true;
    } catch (e) {
      debugPrint('Background work $kind notification failed: $e');
      return false;
    }
  }

  static const int downloadProgressId = 1;
  static const int updateDownloadId = 2;
  static const int libraryScanId = 3;
  static const int verificationRequiredId = 4;
  static const String channelId = 'download_progress';
  static const String channelName = 'Download Progress';
  static const String channelDescription = 'Shows download progress for tracks';
  static const String alertChannelId = 'download_alerts_v1';
  static const String alertChannelName = 'Download Alerts';
  static const String alertChannelDescription =
      'Important download status and actions that need attention';
  static const String libraryChannelId = 'library_scan';
  static const String libraryChannelName = 'Library Scan';
  static const String libraryChannelDescription =
      'Shows local library scan progress';

  /// Windows toast identity. Keep both values stable: Windows ties the
  /// notification settings and activation callback to them.
  static const String windowsAppUserModelId = 'com.zarz.mornye';
  static const String windowsNotificationGuid =
      '1a458cb1-f396-4430-8ee3-23d66b56e12f';

  /// Desktop windows already show live progress, and desktop notification
  /// servers pop a new banner for each update, so only results are posted.
  bool get _showsProgressNotifications => !isDesktopPlatform;
  bool? _macOSPermissionGranted;

  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    return _initialization ??= _initialize().whenComplete(() {
      _initialization = null;
    });
  }

  Future<void> _initialize() async {
    // System UI draws only the small icon's alpha, so use the brand mark
    // rather than the opaque launcher icon.
    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_launcher_monochrome',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );
    const windowsSettings = WindowsInitializationSettings(
      appName: AppInfo.appName,
      appUserModelId: windowsAppUserModelId,
      guid: windowsNotificationGuid,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    await _notifications.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (response) {
        verificationNotifications.receive(response.payload);
      },
    );
    // Linux delivers launch responses through initialize's callback and does
    // not implement the separate launch-details query.
    if (defaultTargetPlatform != TargetPlatform.linux) {
      final launch = await _notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        verificationNotifications.receive(
          launch?.notificationResponse?.payload,
        );
      }
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final androidImpl = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.low,
          showBadge: false,
          playSound: false,
          enableVibration: false,
        ),
      );
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          alertChannelId,
          alertChannelName,
          description: alertChannelDescription,
          importance: Importance.defaultImportance,
          playSound: true,
          enableVibration: true,
        ),
      );
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          libraryChannelId,
          libraryChannelName,
          description: libraryChannelDescription,
          importance: Importance.low,
          showBadge: false,
          playSound: false,
          enableVibration: false,
        ),
      );
    }

    _isInitialized = true;
  }

  Future<bool> _ensureNotificationPermission() async {
    if (isDesktopPlatform && Platform.isMacOS) {
      return _macOSPermissionGranted ??=
          await _notifications
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (!Platform.isIOS) return true;

    final status = await Permission.notification.status;
    if (status.isGranted || status.isProvisional) return true;

    if (_notificationPermissionRequested ||
        status.isPermanentlyDenied ||
        status.isRestricted) {
      return false;
    }

    _notificationPermissionRequested = true;
    final requested = await Permission.notification.request();
    return requested.isGranted || requested.isProvisional;
  }

  Future<void> _showSafely({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
    String? payload,
  }) async {
    if (!await _ensureNotificationPermission()) return;

    try {
      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
    } on PlatformException catch (e) {
      final isNotificationsNotAllowed =
          Platform.isIOS &&
          (e.code == 'Error 1' ||
              (e.message?.contains('UNErrorDomain error 1') ?? false) ||
              e.toString().contains('UNErrorDomain error 1'));

      if (isNotificationsNotAllowed) {
        debugPrint(
          'iOS notifications not allowed; skipping local notification',
        );
        return;
      }
      rethrow;
    }
  }

  /// Builds [NotificationDetails]. A non-null [progress] switches to the
  /// low-importance ongoing progress style; a negative value is indeterminate.
  /// Otherwise builds a dismissible alert.
  NotificationDetails _details({
    bool library = false,
    int? progress,
    bool playSound = false,
    bool presentBadge = false,
    bool presentSound = false,
  }) {
    assert(!library || !playSound);
    final inProgress = progress != null;
    assert(!inProgress || !playSound);
    final androidChannelId = library
        ? libraryChannelId
        : playSound
        ? alertChannelId
        : channelId;
    final androidChannelName = library
        ? libraryChannelName
        : playSound
        ? alertChannelName
        : channelName;
    final androidChannelDescription = library
        ? libraryChannelDescription
        : playSound
        ? alertChannelDescription
        : channelDescription;

    return NotificationDetails(
      android: AndroidNotificationDetails(
        androidChannelId,
        androidChannelName,
        channelDescription: androidChannelDescription,
        importance: inProgress ? Importance.low : Importance.defaultImportance,
        priority: inProgress ? Priority.low : Priority.defaultPriority,
        showProgress: inProgress,
        maxProgress: inProgress ? 100 : 0,
        progress: progress?.clamp(0, 100) ?? 0,
        indeterminate: (progress ?? 0) < 0,
        ongoing: inProgress,
        autoCancel: !inProgress,
        playSound: playSound,
        enableVibration: !inProgress,
        onlyAlertOnce: inProgress,
        icon: '@drawable/ic_launcher_monochrome',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: !inProgress,
        presentBadge: presentBadge,
        presentSound: presentSound,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: !inProgress,
        presentBadge: presentBadge,
        presentSound: presentSound,
      ),
    );
  }

  Future<void> showDownloadProgress({
    required String trackName,
    required String artistName,
    required int progress,
    required int total,
  }) async {
    if (!_showsProgressNotifications) return;
    if (!_isInitialized) await initialize();

    final percentage = total > 0 ? (progress * 100 ~/ total) : 0;

    await _showSafely(
      id: downloadProgressId,
      title:
          _l10n?.notifDownloadingTrack(trackName) ?? 'Downloading $trackName',
      body: '$artistName • $percentage%',
      details: _details(progress: percentage),
    );
  }

  Future<void> showDownloadFinalizing({
    required String trackName,
    required String artistName,
  }) async {
    if (!_showsProgressNotifications) return;
    if (!_isInitialized) await initialize();

    await _showSafely(
      id: downloadProgressId,
      title: _l10n?.notifFinalizingTrack(trackName) ?? 'Finalizing $trackName',
      body:
          '$artistName • ${_l10n?.notifEmbeddingMetadata ?? 'Embedding metadata...'}',
      details: _details(progress: 100),
    );
  }

  Future<void> showDownloadComplete({
    required String trackName,
    required String artistName,
    int? completedCount,
    int? totalCount,
    bool alreadyInLibrary = false,
  }) async {
    if (!_isInitialized) await initialize();
    unawaited(HapticFeedback.mediumImpact());

    String title;
    if (alreadyInLibrary) {
      title = completedCount != null && totalCount != null
          ? (_l10n?.notifAlreadyInLibraryCount(completedCount, totalCount) ??
                'Already in Library ($completedCount/$totalCount)')
          : (_l10n?.notifAlreadyInLibrary ?? 'Already in Library');
    } else {
      title = completedCount != null && totalCount != null
          ? (_l10n?.notifDownloadCompleteCount(completedCount, totalCount) ??
                'Download Complete ($completedCount/$totalCount)')
          : (_l10n?.notifDownloadComplete ?? 'Download Complete');
    }

    await _showSafely(
      id: downloadProgressId,
      title: title,
      body: '$trackName - $artistName',
      details: _details(presentBadge: true),
    );
  }

  Future<void> showQueueComplete({
    required int completedCount,
    required int failedCount,
  }) async {
    if (!_isInitialized) await initialize();
    if (completedCount <= 0 && failedCount <= 0) return;
    unawaited(
      failedCount > 0
          ? HapticFeedback.heavyImpact()
          : HapticFeedback.mediumImpact(),
    );

    final title = failedCount > 0
        ? (_l10n?.notifDownloadsFinished(completedCount, failedCount) ??
              'Downloads Finished ($completedCount done, $failedCount failed)')
        : (_l10n?.notifAllDownloadsComplete ?? 'All Downloads Complete');
    final body = failedCount > 0
        ? (_l10n?.notifDownloadsFinishedBody(completedCount, failedCount) ??
              '$completedCount downloaded, $failedCount failed')
        : (_l10n?.notifTracksDownloadedSuccess(completedCount) ??
              '$completedCount tracks downloaded successfully');

    await _showSafely(
      id: downloadProgressId,
      title: title,
      body: body,
      details: _details(
        playSound: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  Future<void> showVerificationRequired({
    required String extensionId,
    required String itemId,
  }) async {
    if (!_isInitialized) await initialize();
    unawaited(HapticFeedback.mediumImpact());

    final title =
        _l10n?.notifVerificationRequiredTitle ?? 'Verification required';
    final body =
        _l10n?.notifVerificationRequiredBody ??
        'Open the app to complete verification and resume downloads';

    await _showSafely(
      id: verificationRequiredId,
      title: title,
      body: body,
      payload: VerificationNotification(
        extensionId: extensionId,
        itemId: itemId,
        tapId: 'dart:${DateTime.now().microsecondsSinceEpoch}',
      ).encode(),
      details: _details(
        playSound: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  Future<void> cancelVerificationRequired() async {
    await _notifications.cancel(id: verificationRequiredId);
  }

  Future<void> showQueueCanceled({required int canceledCount}) async {
    if (!_isInitialized) await initialize();
    if (canceledCount <= 0) return;
    unawaited(HapticFeedback.lightImpact());

    final title = _l10n?.notifDownloadsCanceledTitle ?? 'Downloads canceled';
    final body =
        _l10n?.notifDownloadsCanceledBody(canceledCount) ??
        '$canceledCount downloads canceled by user';

    await _showSafely(
      id: downloadProgressId,
      title: title,
      body: body,
      details: _details(presentBadge: true),
    );
  }

  Future<void> cancelDownloadNotification() async {
    await _notifications.cancel(id: downloadProgressId);
  }

  Future<void> showLibraryScanProgress({
    required double progress,
    required int scannedFiles,
    required int totalFiles,
    String? currentFile,
  }) async {
    if (!_showsProgressNotifications) return;
    if (!_isInitialized) await initialize();

    // Network scans read tags while discovering folders, so their total is
    // unknown. Zero percent would falsely imply that no files were processed.
    // Use the same indeterminate value for the foreground service and plugin.
    final hasTotal = totalFiles > 0;
    final percentage = hasTotal ? progress.clamp(0.0, 100.0).round() : -1;
    final progressBody = hasTotal
        ? (_l10n?.notifLibraryScanProgressWithTotal(
                scannedFiles,
                totalFiles,
                percentage,
              ) ??
              '$scannedFiles/$totalFiles files • $percentage%')
        : (_l10n?.notifLibraryScanProgressNoTotal(scannedFiles) ??
              '$scannedFiles files scanned');
    final body = (currentFile != null && currentFile.isNotEmpty)
        ? '$progressBody\n$currentFile'
        : progressBody;
    final title = _l10n?.notifScanningLibrary ?? 'Scanning local library';
    if (await _showInBackgroundWork(
      libraryScanWorkKind,
      title: title,
      body: body,
      progress: percentage,
    )) {
      return;
    }

    await _showSafely(
      id: libraryScanId,
      title: title,
      body: body,
      details: _details(library: true, progress: percentage),
    );
  }

  Future<void> showLibraryScanComplete({
    required int totalTracks,
    int excludedDownloadedCount = 0,
    int errorCount = 0,
  }) async {
    if (!_isInitialized) await initialize();

    final extras = <String>[];
    if (excludedDownloadedCount > 0) {
      extras.add(
        _l10n?.notifLibraryScanExcluded(excludedDownloadedCount) ??
            '$excludedDownloadedCount excluded',
      );
    }
    if (errorCount > 0) {
      extras.add(
        _l10n?.notifLibraryScanErrors(errorCount) ?? '$errorCount errors',
      );
    }
    final suffix = extras.isEmpty ? '' : ' (${extras.join(', ')})';

    await _showSafely(
      id: libraryScanId,
      title: _l10n?.notifLibraryScanComplete ?? 'Library scan complete',
      body:
          '${_l10n?.notifLibraryScanCompleteBody(totalTracks) ?? '$totalTracks tracks indexed'}$suffix',
      details: _details(library: true),
    );
  }

  Future<void> showLibraryScanFailed(String message) async {
    if (!_isInitialized) await initialize();

    await _showSafely(
      id: libraryScanId,
      title: _l10n?.notifLibraryScanFailed ?? 'Library scan failed',
      body: message,
      details: _details(library: true),
    );
  }

  Future<void> showLibraryScanCancelled() async {
    if (!_isInitialized) await initialize();

    await _showSafely(
      id: libraryScanId,
      title: _l10n?.notifLibraryScanCancelled ?? 'Library scan cancelled',
      body: _l10n?.notifLibraryScanStopped ?? 'Scan stopped before completion.',
      details: _details(library: true),
    );
  }

  Future<void> showLibraryScanPaused({required int scannedFiles}) async {
    if (!_isInitialized) await initialize();

    await _showSafely(
      id: libraryScanId,
      title: _l10n?.notifLibraryScanPaused ?? 'Library scan paused',
      body:
          _l10n?.notifLibraryScanPausedBody(scannedFiles) ??
          '$scannedFiles files scanned. Resume in Local Library settings to '
              'continue from here.',
      details: _details(library: true),
    );
  }

  /// Clears a paused-scan notice once the foreground service shows progress.
  Future<void> cancelLibraryScanNotification() async {
    await _notifications.cancel(id: libraryScanId);
  }

  Future<void> showUpdateDownloadProgress({
    required String version,
    required int received,
    required int total,
  }) async {
    if (!_showsProgressNotifications) return;
    if (!_isInitialized) await initialize();

    final percentage = total > 0 ? (received * 100 ~/ total) : 0;
    final receivedMB = formatMegabytes(received);
    final totalMB = formatMegabytes(total);
    final title =
        _l10n?.notifDownloadingUpdate(version) ??
        'Downloading ${AppInfo.appName} v$version';
    final body =
        _l10n?.notifUpdateProgress(receivedMB, totalMB, percentage) ??
        '$receivedMB / $totalMB MB • $percentage%';
    if (await _showInBackgroundWork(
      updateDownloadWorkKind,
      title: title,
      body: body,
      progress: total > 0 ? percentage : -1,
    )) {
      return;
    }

    await _showSafely(
      id: updateDownloadId,
      title: title,
      body: body,
      details: _details(progress: percentage),
    );
  }

  Future<void> showUpdateDownloadComplete({required String version}) async {
    if (!_isInitialized) await initialize();

    await _showSafely(
      id: updateDownloadId,
      title: _l10n?.notifUpdateReady ?? 'Update Ready',
      body:
          _l10n?.notifUpdateReadyBody(version) ??
          '${AppInfo.appName} v$version downloaded. Tap to install.',
      details: _details(
        playSound: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  Future<void> showUpdateDownloadFailed() async {
    if (!_isInitialized) await initialize();

    await _showSafely(
      id: updateDownloadId,
      title: _l10n?.notifUpdateFailed ?? 'Update Failed',
      body:
          _l10n?.notifUpdateFailedBody ??
          'Could not download update. Try again later.',
      details: _details(playSound: true),
    );
  }

  Future<void> cancelUpdateNotification() async {
    await _notifications.cancel(id: updateDownloadId);
  }
}
