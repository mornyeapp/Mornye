import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class PreferenceBlobFixture {
  PreferenceBlobFixture._(this.root);

  final Directory root;
  static const _paths = MethodChannel('plugins.flutter.io/path_provider');

  static Future<PreferenceBlobFixture> create() async {
    final fixture = PreferenceBlobFixture._(
      await Directory.systemTemp.createTemp('preference-blob-consumer-'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_paths, (_) async => fixture.root.path);
    return fixture;
  }

  Future<void> close() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_paths, null);
    await root.delete(recursive: true);
  }
}
