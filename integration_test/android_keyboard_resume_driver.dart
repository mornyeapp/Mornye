import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';

/// Set ADB_PATH and ANDROID_SERIAL. Only use a disposable emulator.
Future<void> main() async {
  final adb = Platform.environment['ADB_PATH'] ?? 'adb';
  final serial = Platform.environment['ANDROID_SERIAL'];
  final package =
      Platform.environment['MORNYE_TEST_PACKAGE'] ?? 'com.zarz.mornye.debug';
  Future<String> runAdb(List<String> args) async {
    final result = await Process.run(adb, [
      if (serial != null) ...['-s', serial],
      ...args,
    ]);
    if (result.exitCode != 0) throw StateError('adb failed: ${result.stderr}');
    return result.stdout as String;
  }

  const keyboardSetting = 'show_ime_with_hard_keyboard';
  final previousKeyboardSetting = (await runAdb([
    'shell',
    'settings',
    'get',
    'secure',
    keyboardSetting,
  ])).trim();
  final driver = await FlutterDriver.connect();
  try {
    await runAdb(['shell', 'settings', 'put', 'secure', keyboardSetting, '1']);
    final pid = (await runAdb(['shell', 'pidof', package])).trim();
    Future<String> waitForMarker(String marker) async {
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (true) {
        final log = await runAdb([
          'logcat',
          '-d',
          '--pid=$pid',
          '-s',
          'flutter:I',
        ]);
        final lines = log.split('\n').where((line) => line.contains(marker));
        if (lines.isNotEmpty) return lines.last.split(marker).last.trim();
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Timed out waiting for $marker');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    for (var cycle = 0; cycle < 4; cycle++) {
      if (cycle.isOdd) {
        final open = (await waitForMarker(
          'KEYBOARD_RESUME_OPEN_$cycle',
        )).split(' ');
        await runAdb(['shell', 'input', 'tap', ...open]);
      }
      final editor = (await waitForMarker(
        'KEYBOARD_RESUME_EDIT_$cycle',
      )).split(' ');
      await runAdb(['shell', 'input', 'tap', ...editor]);
      await waitForMarker('KEYBOARD_RESUME_READY_$cycle');
      await runAdb(['shell', 'input', 'keyevent', 'KEYCODE_HOME']);
      await Future<void>.delayed(const Duration(seconds: 2));
      await runAdb([
        'shell',
        'am',
        'start',
        '-n',
        '$package/com.zarz.mornye.MainActivity',
      ]);
      final coordinates = (await waitForMarker(
        'KEYBOARD_RESUME_TAP_$cycle',
      )).split(' ');
      await runAdb(['shell', 'input', 'tap', ...coordinates]);
      stdout.writeln('Cycle $cycle: resumed and tapped bottom control.');
    }
    final response = Response.fromJson(await driver.requestData(null));
    if (!response.allTestsPassed) {
      throw StateError(response.formattedFailureDetails);
    }
    stdout.writeln('Keyboard resume passed: ${response.data}');
  } finally {
    await driver.close();
    await runAdb([
      'shell',
      'settings',
      previousKeyboardSetting == 'null' ? 'delete' : 'put',
      'secure',
      keyboardSetting,
      if (previousKeyboardSetting != 'null') previousKeyboardSetting,
    ]);
  }
}
