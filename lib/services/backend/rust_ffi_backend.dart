import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/backend/backend_channel.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:path_provider/path_provider.dart';

/// Error code of calls made while the desktop library cannot be loaded.
const desktopBackendUnavailableCode = 'backend_unavailable';

/// Key the native side uses to restore a binary argument (see
/// [encodeBackendArguments]).
const backendBytesKey = r'$bytes_key';

/// Results at least this large decode on a background isolate, matching the
/// platform bridge's threshold for JSON string results.
const _backgroundDecodeThresholdBytes = 128 * 1024;

final _jsonBytesDecoder = const Utf8Decoder().fuse(const JsonDecoder());

Object? _decodeJsonBytes(Uint8List data) =>
    data.isEmpty ? null : _jsonBytesDecoder.convert(data);

/// The JSON config passed once to `mornye_init`.
@immutable
class DesktopBackendConfig {
  const DesktopBackendConfig({
    required this.appSupportDir,
    required this.documentsDir,
    required this.tempDir,
    this.ffmpegPath,
    this.ffprobePath,
    this.appVersion = AppInfo.version,
  });

  final String appSupportDir;
  final String documentsDir;
  final String tempDir;

  /// Host version extensions check `minAppVersion` against, as the mobile
  /// hosts pass their bundle version.
  final String appVersion;

  /// Bundled FFmpeg tools; null leaves FFmpeg work unavailable on desktop.
  final String? ffmpegPath;
  final String? ffprobePath;

  /// Directories from path_provider. The FFmpeg tool locations default to
  /// those [DesktopFFmpegTools] resolves, so Rust and Dart run one binary.
  ///
  /// Windows fails the Documents lookup when that known folder points at a
  /// folder that no longer exists, such as a removed OneDrive folder. The
  /// backend does not depend on it, so application support stands in.
  static Future<DesktopBackendConfig> resolve({
    String? ffmpegPath,
    String? ffprobePath,
    Future<DesktopFFmpegTools> Function()? locateTools,
    @visibleForTesting
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    @visibleForTesting
    Future<Directory> Function() documentsDirectory =
        getApplicationDocumentsDirectory,
    @visibleForTesting
    Future<Directory> Function() temporaryDirectory = getTemporaryDirectory,
  }) async {
    final directories = await Future.wait([
      supportDirectory(),
      temporaryDirectory(),
    ]);
    final appSupportDir = directories[0].path;
    String documentsDir;
    try {
      documentsDir = (await documentsDirectory()).path;
    } on Object catch (error) {
      debugPrint('Documents folder unavailable, using app support: $error');
      documentsDir = appSupportDir;
    }
    final tools = ffmpegPath != null && ffprobePath != null
        ? null
        : await (locateTools ?? () => DesktopFFmpegTools.shared)();
    return DesktopBackendConfig(
      appSupportDir: appSupportDir,
      documentsDir: documentsDir,
      tempDir: directories[1].path,
      ffmpegPath: ffmpegPath ?? tools?.ffmpegPath,
      ffprobePath: ffprobePath ?? tools?.ffprobePath,
    );
  }

  Map<String, Object?> toJson() => {
    'app_support_dir': appSupportDir,
    'documents_dir': documentsDir,
    'temp_dir': tempDir,
    'ffmpeg_path': ffmpegPath,
    'ffprobe_path': ffprobePath,
    'app_version': appVersion,
  };
}

/// Encodes MethodChannel arguments for `mornye_call`.
///
/// A top-level [Uint8List] map value travels as raw bytes: it is removed from
/// the map and its key is recorded under [backendBytesKey]. More than one such
/// value, or anything JSON cannot encode, is an `invalid_arguments` error.
@visibleForTesting
({Uint8List json, Uint8List? bytes}) encodeBackendArguments(Object? arguments) {
  var payload = arguments;
  Uint8List? bytes;
  if (arguments is Map) {
    Object? bytesKey;
    for (final entry in arguments.entries) {
      final value = entry.value;
      if (value is! Uint8List) continue;
      if (bytes != null) {
        throw PlatformException(
          code: 'invalid_arguments',
          message: 'Only one binary argument is supported per call',
        );
      }
      bytesKey = entry.key;
      bytes = value;
    }
    if (bytes != null) {
      payload = <Object?, Object?>{
        for (final entry in arguments.entries)
          if (entry.value is! Uint8List) entry.key: entry.value,
        backendBytesKey: bytesKey.toString(),
      };
    }
  }
  try {
    return (json: utf8.encode(jsonEncode(payload)), bytes: bytes);
  } on JsonUnsupportedObjectError catch (error) {
    throw PlatformException(
      code: 'invalid_arguments',
      message: 'Arguments cannot be sent to the desktop backend',
      details: error.toString(),
    );
  }
}

class _PendingCall {
  _PendingCall(this.method);

  final String method;
  final completer = Completer<Object?>();
}

/// One broadcast stream per event kind. The native side pushes the kind while
/// at least one listener is attached.
class _EventStream {
  _EventStream(this._backend, this._kind) {
    controller = StreamController<dynamic>.broadcast(
      onListen: _onListen,
      onCancel: _onCancel,
    );
  }

  final RustFfiBackend _backend;
  final int _kind;
  late final StreamController<dynamic> controller;
  bool _listening = false;
  bool _subscribed = false;

  void _onListen() {
    _listening = true;
    _backend._ensureReady().then(
      (transport) {
        if (!_listening || _subscribed) return;
        transport.subscribe(_kind);
        _subscribed = true;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_listening) controller.addError(error, stackTrace);
      },
    );
  }

  void push(Uint8List data) {
    if (!controller.hasListener) return;
    try {
      controller.add(_decodeJsonBytes(data));
    } on FormatException catch (error, stackTrace) {
      controller.addError(error, stackTrace);
    }
  }

  void _onCancel() {
    _listening = false;
    if (!_subscribed) return;
    _subscribed = false;
    _backend._transport?.unsubscribe(_kind);
  }
}

/// The desktop backend: the Rust library called through dart:ffi.
///
/// The library loads and initializes on first use, so a missing library makes
/// calls fail with [desktopBackendUnavailableCode] instead of failing at
/// startup.
class RustFfiBackend extends BackendChannel {
  RustFfiBackend({
    NativeBackendTransport Function()? openTransport,
    Future<DesktopBackendConfig> Function()? loadConfig,
  }) : _openTransport = openTransport ?? FfiBackendTransport.open,
       _loadConfig = loadConfig ?? DesktopBackendConfig.resolve;

  static RustFfiBackend? _shared;

  static RustFfiBackend get shared => _shared ??= RustFfiBackend();

  @visibleForTesting
  static set debugShared(RustFfiBackend? backend) => _shared = backend;

  final NativeBackendTransport Function() _openTransport;
  final Future<DesktopBackendConfig> Function() _loadConfig;

  Future<NativeBackendTransport>? _ready;
  NativeBackendTransport? _transport;
  int _nextCallId = 1;
  final _pending = <int, _PendingCall>{};
  BackendCallHandler? _handler;
  final _eventStreams = <int, _EventStream>{};
  final _logRecords = StreamController<Object?>.broadcast();

  /// Log records the library pushes (callback kind 13).
  Stream<Object?> get logRecords => _logRecords.stream;

  Future<NativeBackendTransport> _ensureReady() {
    final ready = _ready ??= _start();
    // A failed start is not kept for the whole session: the next call
    // starts again, for example once a missing folder is reachable.
    unawaited(
      ready.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_ready, ready)) _ready = null;
        },
      ),
    );
    return ready;
  }

  Future<NativeBackendTransport> _start() async {
    final NativeBackendTransport transport;
    try {
      transport = _openTransport();
    } on Object catch (error) {
      throw PlatformException(
        code: desktopBackendUnavailableCode,
        message: 'The Mornye desktop backend library could not be loaded',
        details: error.toString(),
      );
    }
    final config = await _loadConfig();
    transport.init(utf8.encode(jsonEncode(config.toJson())), _onMessage);
    return _transport = transport;
  }

  @override
  @optionalTypeArgs
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final encoded = encodeBackendArguments(arguments);
    final transport = await _ensureReady();
    final id = _nextCallId++;
    final pending = _PendingCall(method);
    _pending[id] = pending;
    try {
      transport.call(id, method, encoded.json, encoded.bytes);
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    return await pending.completer.future as T?;
  }

  @override
  void setMethodCallHandler(BackendCallHandler? handler) => _handler = handler;

  @override
  Stream<dynamic> downloadProgressEvents() =>
      _events(NativeMessageKind.downloadProgress);

  @override
  Stream<dynamic> libraryScanProgressEvents() =>
      _events(NativeMessageKind.libraryScanProgress);

  Stream<dynamic> _events(int kind) => _eventStreams
      .putIfAbsent(kind, () => _EventStream(this, kind))
      .controller
      .stream;

  void _onMessage(int id, int kind, Uint8List data) {
    switch (kind) {
      case NativeMessageKind.result:
        final pending = _pending.remove(id);
        if (pending != null) _completeWithJson(pending, data);
      case NativeMessageKind.error:
        final pending = _pending.remove(id);
        if (pending != null) {
          pending.completer.completeError(_callError(pending.method, data));
        }
      case NativeMessageKind.binaryResult:
        _pending.remove(id)?.completer.complete(data);
      case NativeMessageKind.downloadProgress:
      case NativeMessageKind.libraryScanProgress:
        _eventStreams[kind]?.push(data);
      case NativeMessageKind.inboundCall:
        _dispatchInboundCall(data);
      case NativeMessageKind.log:
        if (!_logRecords.hasListener) return;
        try {
          _logRecords.add(_decodeJsonBytes(data));
        } on FormatException {
          // A malformed record must not break the log stream.
        }
    }
  }

  void _completeWithJson(_PendingCall pending, Uint8List data) {
    final Future<Object?> decoded =
        data.length >= _backgroundDecodeThresholdBytes
        ? compute(_decodeJsonBytes, data)
        : Future<Object?>.sync(() => _decodeJsonBytes(data));
    decoded.then(
      pending.completer.complete,
      onError: (Object error) => pending.completer.completeError(
        PlatformException(
          code: 'invalid_result',
          message: 'Malformed result for ${pending.method}',
          details: error.toString(),
        ),
      ),
    );
  }

  static Exception _callError(String method, Uint8List data) {
    Object? decoded;
    try {
      decoded = _decodeJsonBytes(data);
    } on FormatException {
      decoded = null;
    }
    final error = decoded is Map ? decoded : const <String, Object?>{};
    final code = error['code']?.toString() ?? 'error';
    if (code == 'unimplemented') {
      return MissingPluginException(
        'No implementation found for method $method on the desktop backend',
      );
    }
    return PlatformException(
      code: code,
      message: error['message']?.toString(),
      details: error['details'],
    );
  }

  void _dispatchInboundCall(Uint8List data) {
    final handler = _handler;
    if (handler == null) return;
    final Object? decoded;
    try {
      decoded = _decodeJsonBytes(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final method = decoded['method'];
    if (method is! String) return;
    final call = MethodCall(method, decoded['arguments']);
    Future<dynamic>.sync(() => handler(call)).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        // Same handling as a MethodChannel handler: platform errors are
        // answers, anything else is a bug worth reporting.
        if (error is PlatformException || error is MissingPluginException) {
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'services library',
            context: ErrorDescription(
              'during a desktop backend call to ${call.method}',
            ),
          ),
        );
      },
    );
  }
}
