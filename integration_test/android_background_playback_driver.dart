import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';

/// Set ADB_PATH and ANDROID_SERIAL when adb is not on PATH or several devices
/// are attached. Use a dedicated emulator; this controls its screen and app.
Future<void> main() async {
  final adb = Platform.environment['ADB_PATH'] ?? 'adb';
  final serial = Platform.environment['ANDROID_SERIAL'];
  final package =
      Platform.environment['MORNYE_TEST_PACKAGE'] ?? 'com.zarz.mornye.debug';
  Future<String> shell(List<String> arguments) async {
    final result = await Process.run(adb, [
      if (serial != null) ...['-s', serial],
      'shell',
      ...arguments,
    ]);
    if (result.exitCode != 0) {
      throw StateError('adb failed: ${result.stderr}');
    }
    return result.stdout as String;
  }

  final driver = await FlutterDriver.connect();
  try {
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (true) {
        final sessions = await shell(['dumpsys', 'media_session']);
        final start = sessions.indexOf('package=$package');
        final session = start < 0
            ? ''
            : sessions.substring(start).split('queueTitle=').first;
        if (session.contains('PLAYING(3)') &&
            sessions.contains('Background playback test')) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Test playback did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await shell(['input', 'keyevent', 'KEYCODE_HOME']);
      await shell(['input', 'keyevent', 'KEYCODE_SLEEP']);
      final power = await shell(['dumpsys', 'power']);
      if (!RegExp(r'mWakefulness=(Asleep|Dozing)').hasMatch(power)) {
        throw StateError('The emulator screen did not turn off');
      }
      stdout.writeln(
        power
            .split('\n')
            .where(
              (line) =>
                  line.contains('MediaPlayer') || line.contains('AudioService'),
            )
            .join('\n'),
      );
      final pauseDeadline = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        final sessions = await shell(['dumpsys', 'media_session']);
        final start = sessions.indexOf('package=$package');
        if (start >= 0 &&
            sessions
                .substring(start)
                .split('queueTitle=')
                .first
                .contains('PAUSED(2)')) {
          break;
        }
        if (DateTime.now().isAfter(pauseDeadline)) {
          throw StateError('Test playback did not pause');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final pid = (await shell(['pidof', package])).trim();
      final pausedPower = await shell(['dumpsys', 'power']);
      final heldLocks = pausedPower
          .split('\n')
          .where(
            (line) =>
                line.contains('PARTIAL_WAKE_LOCK') &&
                line.contains('pid=$pid ') &&
                (line.contains('MediaPlayer') || line.contains('AudioService')),
          );
      if (heldLocks.isNotEmpty) {
        throw StateError('Paused playback still holds a CPU wake lock');
      }
      final service = await shell(['dumpsys', 'activity', 'services', package]);
      if (!service.contains('isForeground=true')) {
        throw StateError('Paused playback lost its foreground service');
      }
      stdout.writeln(
        'Paused: foreground service active, CPU wake locks released.',
      );
      await Future<void>.delayed(const Duration(seconds: 15));
    } finally {
      await shell(['input', 'keyevent', 'KEYCODE_WAKEUP']);
      await shell([
        'am',
        'start',
        '-n',
        '$package/com.zarz.mornye.MainActivity',
      ]);
    }
    final response = Response.fromJson(
      await driver.requestData(null, timeout: const Duration(minutes: 2)),
    );
    if (!response.allTestsPassed) {
      throw StateError(response.formattedFailureDetails);
    }
    final stoppedService = await shell([
      'dumpsys',
      'activity',
      'services',
      '$package/com.ryanheise.audioservice.AudioService',
    ]);
    if (stoppedService.contains('isForeground=true')) {
      throw StateError('Stopping playback left the foreground service active');
    }
    final output = File(
      Platform.environment['MORNYE_BACKGROUND_REPORT'] ??
          '/tmp/mornye-background-playback.json',
    );
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(response.data),
    );
    stdout.writeln('Background playback passed: ${output.path}');
  } finally {
    await driver.close();
  }
}
