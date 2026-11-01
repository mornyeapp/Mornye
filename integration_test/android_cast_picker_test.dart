import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/cast_output.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Android bridge opens the real Google Cast device picker', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Cast picker smoke test'))),
    );
    await tester.pumpAndSettle();
    final output = CastOutput();
    await output.initialize();
    expect(await output.showPicker(), isTrue);
    // The native picker stays above Flutter until the user chooses or cancels.
    output.dispose();
    await const MethodChannel(
      'com.zarz.mornye/cast',
    ).invokeMethod<void>('disconnect');
  });
}
