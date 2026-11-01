import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/utils/android_tv.dart';

import '../test/tv_navigation_test.dart' as remote_tests;

/// Run on an Android TV emulator, never on a phone or the user's main app.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native host detects TV and keeps the Flutter surface landscape',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      debugAndroidTvOverride = null;
      await tester.runAsync(initializeAndroidTv);
      expect(isAndroidTv, isTrue);
      await tester.runAsync(setAppOrientation);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.view.physicalSize.width,
        greaterThan(tester.view.physicalSize.height),
      );
    },
  );

  remote_tests.main();
}
