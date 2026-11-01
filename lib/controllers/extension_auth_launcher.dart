import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/extension_session_callback.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = AppLogger('ExtensionAuthLauncher');

const extensionVerificationGrantTimeout = Duration(minutes: 3);

bool isExtensionVerificationRequired(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('verify_required') ||
      message.contains('verification_required') ||
      message.contains('verification required') ||
      message.contains('needsverification') ||
      message.contains('needs verification') ||
      message.contains('session is not authenticated') ||
      message.contains('signed session expired');
}

Future<T> runExtensionOperationWithVerificationRetry<T>({
  required String extensionId,
  required String browserMode,
  required Future<T> Function() operation,
  Future<bool> Function()? verify,
}) async {
  try {
    return await operation();
  } catch (error) {
    if (!isExtensionVerificationRequired(error)) rethrow;

    final verified =
        await (verify ??
            () => openVerificationAndAwaitGrant(
              extensionId,
              browserMode: browserMode,
            ))();
    if (!verified) rethrow;

    return operation();
  }
}

String? extensionIdFromVerificationError(
  Object error,
  Iterable<String> knownExtensionIds,
) {
  final idsByNormalized = <String, String>{
    for (final id in knownExtensionIds)
      if (id.trim().isNotEmpty) id.trim().toLowerCase(): id.trim(),
  };
  if (idsByNormalized.isEmpty) return null;

  final message = error.toString();
  final canonicalMatch = RegExp(
    r'''extension\s+['"]([^'"]+)['"]''',
    caseSensitive: false,
  ).firstMatch(message);
  final canonicalId = canonicalMatch?.group(1)?.trim().toLowerCase();
  if (canonicalId != null && idsByNormalized.containsKey(canonicalId)) {
    return idsByNormalized[canonicalId];
  }

  final lowerMessage = message.toLowerCase();
  final orderedIds = idsByNormalized.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final normalizedId in orderedIds) {
    if (lowerMessage.contains(normalizedId)) {
      return idsByNormalized[normalizedId];
    }
  }
  return null;
}

Future<bool> openPendingExtensionVerification(
  String extensionId, {
  String browserMode = 'in_app_first',
  void Function(Uri authUri)? onAuthUri,
  Future<void>? cancellationSignal,
}) async {
  final normalizedExtensionId = extensionId.trim();
  if (normalizedExtensionId.isEmpty) return false;

  var cancelled = false;
  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => cancelled = true));
  }
  try {
    final pending = await _awaitVerificationStepOrCancellation(
      PlatformBridge.getExtensionPendingAuth(normalizedExtensionId),
      cancellationSignal,
    );
    if (cancelled) return false;
    final authUrl = pending?['auth_url']?.toString().trim() ?? '';
    if (authUrl.isEmpty) {
      _log.w('No pending verification challenge for $normalizedExtensionId');
      showExtensionVerificationUnavailable(normalizedExtensionId);
      return false;
    }

    final uri = Uri.tryParse(authUrl);
    if (uri == null) return false;
    onAuthUri?.call(uri);

    final launched = await _awaitVerificationStepOrCancellation(
      _launchVerificationUrl(
        uri,
        browserMode,
        cancellationSignal: cancellationSignal,
      ),
      cancellationSignal,
    );

    if (launched == null) return false;

    if (launched) {
      _log.i('Opened verification challenge for $normalizedExtensionId');
    } else {
      _log.w(
        'Could not open verification challenge for $normalizedExtensionId',
      );
      return await showExtensionVerificationHelpDialog(
        normalizedExtensionId,
        uri,
        browserMode: browserMode,
        immediateFailure: true,
        cancellationSignal: cancellationSignal,
      );
    }
    return launched;
  } catch (e) {
    _log.w(
      'Failed to open verification challenge for $normalizedExtensionId: $e',
    );
    if (!cancelled) showExtensionVerificationUnavailable(normalizedExtensionId);
    return false;
  }
}

void showExtensionVerificationUnavailable(String extensionId) {
  final context = AppNavigationService.rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(context.l10n.extensionVerificationUnavailable(extensionId)),
      duration: const Duration(seconds: 8),
    ),
  );
}

Timer? scheduleExtensionVerificationHelpDialog(
  String extensionId,
  Uri? authUri, {
  String browserMode = 'in_app_first',
  Duration delay = const Duration(seconds: 20),
  Future<void>? cancellationSignal,
}) {
  final normalizedExtensionId = extensionId.trim();
  if (normalizedExtensionId.isEmpty || authUri == null) return null;

  return Timer(delay, () {
    unawaited(
      showExtensionVerificationHelpDialog(
        normalizedExtensionId,
        authUri,
        browserMode: browserMode,
        cancellationSignal: cancellationSignal,
      ),
    );
  });
}

/// Opens a pending extension verification challenge and waits (up to 3
/// minutes, including pending lookup and browser launch) for its grant result,
/// returning whether it succeeded. When
/// [cancellationSignal] completes, all local waiting resources are released
/// and the method returns false without waiting for the timeout.
///
/// [awaitForeground], if given, is awaited first — passed the trimmed
/// [extensionId] — before opening the challenge; used by callers that must
/// defer verification until the app is foregrounded (launching a browser
/// from the background is blocked by the OS).
Future<bool> openVerificationAndAwaitGrant(
  String extensionId, {
  required String browserMode,
  Future<void> Function(String extensionId)? awaitForeground,
  Future<void>? cancellationSignal,
}) async {
  final normalizedExtensionId = extensionId.trim();
  if (normalizedExtensionId.isEmpty) return false;

  if (awaitForeground != null) {
    final reachedForeground = await _awaitVerificationStepOrCancellation(
      awaitForeground(normalizedExtensionId).then((_) => true),
      cancellationSignal,
    );
    if (reachedForeground != true) return false;
  }

  final grantCompleter = Completer<ExtensionSessionGrantEvent>();
  late final StreamSubscription<ExtensionSessionGrantEvent> grantSub;
  grantSub = PlatformBridge.extensionSessionGrantEvents()
      .where((event) => event.extensionId.trim() == normalizedExtensionId)
      .listen((event) {
        if (!grantCompleter.isCompleted) {
          grantCompleter.complete(event);
        }
      });

  Uri? authUri;
  Timer? helpDialogTimer;
  final stopped = Completer<void>();
  void stop() {
    if (!stopped.isCompleted) stopped.complete();
  }

  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => stop()));
  }
  // The browser or manual-help dialog may never return. Bound the complete
  // foreground flow, not only the grant wait reached after opening the page.
  final deadline = Timer(extensionVerificationGrantTimeout, () {
    _log.w('Timed out waiting for verification grant: $normalizedExtensionId');
    stop();
  });

  try {
    final opened = await _awaitVerificationStepOrCancellation(
      openPendingExtensionVerification(
        normalizedExtensionId,
        browserMode: browserMode,
        onAuthUri: (uri) => authUri = uri,
        cancellationSignal: stopped.future,
      ),
      stopped.future,
    );
    if (opened != true) return false;

    helpDialogTimer = scheduleExtensionVerificationHelpDialog(
      normalizedExtensionId,
      authUri,
      browserMode: browserMode,
      cancellationSignal: stopped.future,
    );

    final event = await _awaitVerificationStepOrCancellation(
      grantCompleter.future,
      stopped.future,
    );
    if (event == null) {
      _log.i('Stopped waiting for verification grant: $normalizedExtensionId');
      return false;
    }
    return event.success;
  } on TimeoutException {
    _log.w('Timed out waiting for verification grant: $normalizedExtensionId');
    return false;
  } finally {
    deadline.cancel();
    helpDialogTimer?.cancel();
    stop();
    await grantSub.cancel();
  }
}

Future<T?> _awaitVerificationStepOrCancellation<T>(
  Future<T> operation,
  Future<void>? cancellationSignal,
) {
  if (cancellationSignal == null) {
    return operation.then<T?>((value) => value);
  }
  return Future.any<T?>([
    operation.then<T?>((value) => value),
    cancellationSignal.then<T?>((_) => null),
  ]);
}

Future<bool> showExtensionVerificationHelpDialog(
  String extensionId,
  Uri authUri, {
  String browserMode = 'in_app_first',
  bool immediateFailure = false,
  Future<void>? cancellationSignal,
}) async {
  final context = AppNavigationService.rootNavigatorKey.currentContext;
  if (context == null) {
    _log.w('Cannot show verification help dialog without root context');
    return false;
  }

  final l10n = context.l10n;
  final title = immediateFailure
      ? l10n.extensionVerificationHelpTitleManual
      : l10n.extensionVerificationHelpTitleWaiting;
  final message = immediateFailure
      ? l10n.extensionVerificationHelpMessageManual
      : l10n.extensionVerificationHelpMessageWaiting;
  final normalizedExtensionId = extensionId.trim();
  BuildContext? activeDialogContext;
  var closeRequested = false;
  void closeDialog() {
    closeRequested = true;
    final dialogContext = activeDialogContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final route = ModalRoute.of(dialogContext);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(dialogContext, rootNavigator: true);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      // A newer dialog may be above this one; dismiss only our own route.
      navigator.removeRoute(route);
    }
  }

  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => closeDialog()));
  }
  var clipboardGrantInFlight = false;
  late final StreamSubscription<ExtensionSessionGrantEvent> grantSub;
  grantSub = PlatformBridge.extensionSessionGrantEvents()
      .where(
        (event) =>
            event.success && event.extensionId.trim() == normalizedExtensionId,
      )
      .listen((_) {
        _log.i(
          'Closing verification help dialog after $normalizedExtensionId grant',
        );
        closeDialog();
      });

  try {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        activeDialogContext = dialogContext;
        if (closeRequested) {
          WidgetsBinding.instance.addPostFrameCallback((_) => closeDialog());
        }
        final dialogL10n = dialogContext.l10n;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AppAlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      authUri.toString(),
                      maxLines: 4,
                      minLines: 1,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              ExpressiveButton(
                text: true,
                onPressed: clipboardGrantInFlight
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: Text(dialogL10n.extensionVerificationClose),
              ),
              ExpressiveButton(
                text: true,
                icon: const Icon(Icons.copy),
                onPressed: clipboardGrantInFlight
                    ? null
                    : () {
                        Clipboard.setData(
                          ClipboardData(text: authUri.toString()),
                        );
                        ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                          SnackBar(
                            content: Text(
                              dialogL10n.extensionVerificationLinkCopied,
                            ),
                          ),
                        );
                      },
                child: Text(dialogL10n.extensionVerificationCopyLink),
              ),
              ExpressiveButton(
                text: true,
                icon: clipboardGrantInFlight
                    ? const AppLoadingIndicator(size: 18, strokeWidth: 2)
                    : const Icon(Icons.content_paste),
                onPressed: clipboardGrantInFlight
                    ? null
                    : () async {
                        setDialogState(() => clipboardGrantInFlight = true);
                        await _completeSessionGrantFromClipboard(
                          dialogContext,
                          extensionId,
                          authUri,
                        );
                        if (dialogContext.mounted) {
                          setDialogState(() => clipboardGrantInFlight = false);
                        }
                      },
                child: Text(dialogL10n.extensionVerificationPasteCallback),
              ),
              ExpressiveButton(
                icon: const Icon(Icons.open_in_browser),
                onPressed: clipboardGrantInFlight
                    ? null
                    : () {
                        unawaited(
                          _launchVerificationUrl(
                            authUri,
                            browserMode,
                            cancellationSignal: cancellationSignal,
                          ),
                        );
                      },
                child: Text(dialogL10n.extensionVerificationOpenBrowser),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    activeDialogContext = null;
    await grantSub.cancel();
  }
  return true;
}

Future<void> _completeSessionGrantFromClipboard(
  BuildContext context,
  String extensionId,
  Uri verificationUri,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    final parsed = parseExtensionSessionGrantCallback(text);
    if (parsed == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('No verification callback found')),
      );
      return;
    }

    final expectedState = extensionCallbackStateFromVerificationUri(
      verificationUri,
    );
    if (expectedState == null || parsed.state != expectedState) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('This callback does not match the active verification'),
        ),
      );
      return;
    }

    final success = await PlatformBridge.completeExtensionSessionGrant(
      extensionId.trim(),
      parsed.grant,
    );
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Verification completed' : 'Verification failed',
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Verification callback failed: ${context.friendlyError(e)}',
        ),
      ),
    );
  }
}

/// Opens an extension auth/verification page using the browser preference.
/// In-app HTTPS verification on iOS uses ASWebAuthenticationSession to capture
/// the mornye:// callback even when the app's URL scheme is not registered
/// with the OS (sideload containers like LiveContainer).
Future<bool> launchExtensionAuthUrl(Uri uri, {required String browserMode}) {
  return _launchVerificationUrl(uri, browserMode);
}

Future<bool> _launchVerificationUrl(
  Uri uri,
  String browserMode, {
  Future<void>? cancellationSignal,
}) async {
  var cancelled = false;
  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => cancelled = true));
  }
  // Desktop has no in-app browser or web auth session: the system browser
  // opens the page and returns through the registered mornye:// scheme
  // (DesktopDeepLinks hands the callback to the backend).
  if (isDesktopPlatform) {
    if (cancelled) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException catch (error) {
      _log.w('Verification browser launch failed: ${error.code}');
      return false;
    }
  }

  final preferInApp = browserMode.trim().toLowerCase() == 'in_app_first';
  final firstMode = preferInApp
      ? LaunchMode.inAppBrowserView
      : LaunchMode.externalApplication;
  final fallbackMode = preferInApp
      ? LaunchMode.externalApplication
      : LaunchMode.inAppBrowserView;

  for (final mode in [firstMode, fallbackMode]) {
    if (cancelled) return false;
    if (mode == LaunchMode.inAppBrowserView &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        uri.scheme == 'https') {
      try {
        if (await PlatformBridge.startIosWebAuthSession(uri.toString())) {
          return true;
        }
        _log.w('Web auth session did not start, falling back to browser');
      } catch (e) {
        _log.w('Web auth session failed, falling back to browser: $e');
      }
      if (cancelled) return false;
    }
    try {
      if (await launchUrl(uri, mode: mode)) return true;
    } on PlatformException catch (error) {
      // Android reports some launch failures as exceptions rather than false.
      // Keep the other mode and manual verification help available in both cases.
      _log.w(
        'Verification browser launch failed (${mode.name}): ${error.code}',
      );
    }
  }
  return false;
}
