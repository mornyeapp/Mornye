import 'dart:io' show Platform;

import 'package:flutter/services.dart';

bool? debugAndroidTvOverride;
bool _isAndroidTv = false;

bool get isAndroidTv => debugAndroidTvOverride ?? _isAndroidTv;

/// Resolve before the first frame so TV never mounts the portrait phone UI.
Future<void> initializeAndroidTv() async {
  if (!Platform.isAndroid) return;
  _isAndroidTv =
      await const MethodChannel(
        'com.zarz.mornye/backend',
      ).invokeMethod<bool>('isAndroidTv') ??
      false;
}
