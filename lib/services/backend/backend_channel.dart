import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/backend/method_channel_backend.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Handles a host to Dart call, like [MethodChannel.setMethodCallHandler].
typedef BackendCallHandler = Future<dynamic> Function(MethodCall call);

/// Transport between Dart and the Rust backend.
///
/// Android and iOS keep the platform channels ([MethodChannelBackend]);
/// desktop builds call the Rust library directly ([RustFfiBackend]).
abstract class BackendChannel {
  const BackendChannel();

  /// Same contract as [MethodChannel.invokeMethod]. Methods the backend does
  /// not implement throw [MissingPluginException].
  @optionalTypeArgs
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]);

  /// Same contract as [MethodChannel.invokeMapMethod].
  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) async {
    final result = await invokeMethod<Map<dynamic, dynamic>>(method, arguments);
    return result?.cast<K, V>();
  }

  /// Receives host to Dart calls such as `extensionAuthCallbackReceived`.
  /// Replaces any previous handler; null removes it.
  void setMethodCallHandler(BackendCallHandler? handler);

  /// Download progress events, in the payload format of the mobile
  /// `download_progress_stream` EventChannel.
  Stream<dynamic> downloadProgressEvents();

  /// Library scan progress events, in the payload format of the mobile
  /// `library_scan_progress_stream` EventChannel.
  Stream<dynamic> libraryScanProgressEvents();
}

BackendChannel get backendChannel =>
    isDesktopPlatform ? RustFfiBackend.shared : MethodChannelBackend.shared;
