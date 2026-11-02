import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/verification_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final methodCalls = <MethodCall>[];
  const coldTarget = VerificationNotification(
    extensionId: 'provider-a',
    itemId: 'cold-source-item',
    tapId: 'dart:cold-tap',
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NotificationService().updateStrings(
      await AppLocalizations.delegate.load(const Locale('en')),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodCalls.add(call);
          if (call.method == 'initialize') return true;
          if (call.method == 'getNotificationAppLaunchDetails') {
            return {
              'notificationLaunchedApp': true,
              'notificationResponse': {
                'notificationId': 4,
                'notificationResponseType': 0,
                'payload': coldTarget.encode(),
              },
            };
          }
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('verification uses a distinct audible Android alert channel', () async {
    final notificationService = NotificationService();
    await notificationService.showVerificationRequired(
      extensionId: 'provider-b',
      itemId: 'source-item',
    );

    final alertChannelCall = methodCalls.firstWhere(
      (call) =>
          call.method == 'createNotificationChannel' &&
          (call.arguments as Map<Object?, Object?>)['id'] ==
              NotificationService.alertChannelId,
    );
    final alertChannel = alertChannelCall.arguments as Map<Object?, Object?>;

    expect(alertChannel['importance'], Importance.defaultImportance.value);
    expect(alertChannel['playSound'], isTrue);
    expect(alertChannel['enableVibration'], isTrue);

    final showCall = methodCalls.lastWhere((call) => call.method == 'show');
    final showArguments = showCall.arguments as Map<Object?, Object?>;
    final androidDetails =
        showArguments['platformSpecifics'] as Map<Object?, Object?>;

    final initialization =
        methodCalls.firstWhere((call) => call.method == 'initialize').arguments
            as Map<Object?, Object?>;
    expect(initialization['defaultIcon'], '@drawable/ic_notification_mornye');
    expect(androidDetails['icon'], '@drawable/ic_notification_mornye');

    expect(
      NotificationService.verificationRequiredId,
      isNot(NotificationService.downloadProgressId),
    );
    expect(showArguments['id'], NotificationService.verificationRequiredId);
    expect(androidDetails['channelId'], NotificationService.alertChannelId);
    expect(androidDetails['importance'], Importance.defaultImportance.value);
    expect(androidDetails['playSound'], isTrue);
    expect(androidDetails['enableVibration'], isTrue);
    final target = VerificationNotification.parse(showArguments['payload']);
    expect(target?.extensionId, 'provider-b');
    expect(target?.itemId, 'source-item');

    final tapped = <VerificationNotification>[];
    notificationService.verificationNotifications.setHandler((target) async {
      tapped.add(target);
    });
    expect(tapped.single.extensionId, 'provider-a');
    expect(tapped.single.itemId, 'cold-source-item');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('didReceiveNotificationResponse', {
              'notificationResponseType': 0,
              'id': 4,
              'payload': showArguments['payload'],
            }),
          ),
          (_) {},
        );
    expect(tapped.map((target) => target.extensionId), [
      'provider-a',
      'provider-b',
    ]);
    notificationService.verificationNotifications.setHandler(null);

    await notificationService.cancelVerificationRequired();
    expect(
      methodCalls.last,
      isMethodCall(
        'cancel',
        arguments: <String, Object?>{
          'id': NotificationService.verificationRequiredId,
          'tag': null,
        },
      ),
    );
  });

  test(
    'scan with unknown total shows count and indeterminate progress',
    () async {
      final service = NotificationService();
      for (final count in [0, 1566]) {
        await service.showLibraryScanProgress(
          progress: 0,
          scannedFiles: count,
          totalFiles: 0,
          currentFile: 'track.flac',
        );

        final arguments =
            methodCalls.lastWhere((call) => call.method == 'show').arguments
                as Map<Object?, Object?>;
        final details = arguments['platformSpecifics'] as Map<Object?, Object?>;

        expect(arguments['id'], NotificationService.libraryScanId);
        expect(arguments['body'], '$count files scanned\ntrack.flac');
        expect(details['showProgress'], isTrue);
        expect(details['indeterminate'], isTrue);
        expect(details['progress'], 0);
        expect(details['ongoing'], isTrue);
        expect(details['autoCancel'], isFalse);
        expect(details['playSound'], isFalse);
      }
    },
  );

  test('scan switches to percentage when total becomes known', () async {
    final service = NotificationService();
    await service.showLibraryScanProgress(
      progress: 0,
      scannedFiles: 1566,
      totalFiles: 0,
    );
    await service.showLibraryScanProgress(
      progress: 78.3,
      scannedFiles: 1566,
      totalFiles: 2000,
      currentFile: 'track.flac',
    );

    final progressArguments =
        methodCalls.lastWhere((call) => call.method == 'show').arguments
            as Map<Object?, Object?>;
    final progressDetails =
        progressArguments['platformSpecifics'] as Map<Object?, Object?>;
    expect(progressArguments['body'], '1566/2000 files • 78%\ntrack.flac');
    expect(progressDetails['showProgress'], isTrue);
    expect(progressDetails['indeterminate'], isFalse);
    expect(progressDetails['progress'], 78);

    await service.showLibraryScanComplete(totalTracks: 2000);
    final completeArguments =
        methodCalls.lastWhere((call) => call.method == 'show').arguments
            as Map<Object?, Object?>;
    final completeDetails =
        completeArguments['platformSpecifics'] as Map<Object?, Object?>;
    expect(completeArguments['body'], '2000 tracks indexed');
    expect(completeDetails['showProgress'], isFalse);
    expect(completeDetails['ongoing'], isFalse);
    expect(completeDetails['autoCancel'], isTrue);
  });

  test('unknown-total scan never displays percentage in any locale', () async {
    final service = NotificationService();
    for (final locale in AppLocalizations.supportedLocales) {
      service.updateStrings(await AppLocalizations.delegate.load(locale));
      await service.showLibraryScanProgress(
        progress: 0,
        scannedFiles: 1566,
        totalFiles: 0,
      );
      final arguments =
          methodCalls.lastWhere((call) => call.method == 'show').arguments
              as Map<Object?, Object?>;
      final body = arguments['body'] as String;
      expect(body, contains('1566'), reason: '$locale');
      expect(body, isNot(contains('%')), reason: '$locale');
    }
  });
}
