import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';

class _Call {
  _Call(this.id, this.method, this.args, this.bytes);

  final int id;
  final String method;
  final Object? args;
  final Uint8List? bytes;
}

/// Stands in for the native library: records calls and lets the test answer
/// through the registered callback, as the Rust worker threads would.
class _FakeTransport implements NativeBackendTransport {
  final calls = <_Call>[];
  final configs = <Object?>[];
  final subscriptions = <String>[];
  NativeMessageListener? _listener;

  /// Answers each call; null leaves it pending.
  void Function(_Call call)? responder;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) {
    configs.add(jsonDecode(utf8.decode(configJson)));
    _listener = listener;
  }

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    final call = _Call(id, method, jsonDecode(utf8.decode(argsJson)), bytes);
    calls.add(call);
    final respond = responder;
    if (respond != null) scheduleMicrotask(() => respond(call));
  }

  @override
  void subscribe(int kind) => subscriptions.add('+$kind');

  @override
  void unsubscribe(int kind) => subscriptions.add('-$kind');

  void send(int id, int kind, Uint8List data) => _listener!(id, kind, data);

  void sendJson(int id, int kind, Object? value) =>
      send(id, kind, utf8.encode(jsonEncode(value)));
}

const _config = DesktopBackendConfig(
  appSupportDir: '/support',
  documentsDir: '/documents',
  tempDir: '/tmp',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTransport transport;
  late int opened;
  late RustFfiBackend backend;

  setUp(() {
    transport = _FakeTransport();
    opened = 0;
    backend = RustFfiBackend(
      openTransport: () {
        opened++;
        return transport;
      },
      loadConfig: () async => _config,
    );
  });

  test('initializes once with the config JSON on first use', () async {
    transport.responder = (call) =>
        transport.sendJson(call.id, NativeMessageKind.result, null);
    await backend.invokeMethod<void>('a');
    await backend.invokeMethod<void>('b');
    expect(opened, 1);
    expect(transport.configs, [
      {
        'app_support_dir': '/support',
        'documents_dir': '/documents',
        'temp_dir': '/tmp',
        'ffmpeg_path': null,
        'ffprobe_path': null,
        'app_version': AppInfo.version,
      },
    ]);
    expect(transport.calls.map((call) => call.id).toSet(), hasLength(2));
  });

  test('decodes JSON results and passes JSON arguments', () async {
    final results = <String, Object?>{
      'map': {
        'value': 1,
        'nested': [true, 'x'],
      },
      'list': [1, 2],
      'string': '{"kept":"as text"}',
      'none': null,
    };
    transport.responder = (call) => transport.sendJson(
      call.id,
      NativeMessageKind.result,
      results[call.method],
    );
    expect(await backend.invokeMethod<Object?>('map', {'item_id': 'a'}), {
      'value': 1,
      'nested': [true, 'x'],
    });
    expect(transport.calls.single.args, {'item_id': 'a'});
    expect(await backend.invokeMethod<List<Object?>>('list'), [1, 2]);
    expect(await backend.invokeMethod<String>('string'), '{"kept":"as text"}');
    expect(await backend.invokeMethod<Object?>('none'), isNull);
    expect(transport.calls.last.args, isNull);
    expect(
      await backend.invokeMapMethod<String, Object?>('map'),
      isA<Map<String, Object?>>(),
    );
  });

  test('decodes large results off the UI isolate', () async {
    final large = List<String>.generate(20000, (index) => 'track_$index');
    transport.responder = (call) =>
        transport.sendJson(call.id, NativeMessageKind.result, large);
    final result = await backend.invokeMethod<List<Object?>>('big');
    expect(result, large);
  });

  test('matches results to calls by id', () async {
    final first = backend.invokeMethod<String>('first');
    final second = backend.invokeMethod<String>('second');
    await pumpEventQueue();
    final ids = transport.calls.map((call) => call.id).toList();
    transport.sendJson(ids[1], NativeMessageKind.result, 'two');
    transport.sendJson(ids[0], NativeMessageKind.result, 'one');
    expect(await first, 'one');
    expect(await second, 'two');
  });

  test('maps errors to PlatformException', () async {
    transport.responder = (call) =>
        transport.sendJson(call.id, NativeMessageKind.error, {
          'code': 'download_failed',
          'message': 'No route',
          'details': {'attempt': 2},
        });
    await expectLater(
      backend.invokeMethod<void>('downloadByStrategy'),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'download_failed')
            .having((e) => e.message, 'message', 'No route')
            .having((e) => e.details, 'details', {'attempt': 2}),
      ),
    );
  });

  test('maps unimplemented to MissingPluginException', () async {
    transport.responder = (call) => transport.sendJson(
      call.id,
      NativeMessageKind.error,
      {'code': 'unimplemented', 'message': 'not on desktop', 'details': null},
    );
    await expectLater(
      backend.invokeMethod<void>('openSafTree'),
      throwsA(
        isA<MissingPluginException>().having(
          (e) => e.message,
          'message',
          contains('openSafTree'),
        ),
      ),
    );
  });

  test('returns binary results as bytes', () async {
    final payload = Uint8List.fromList([0, 255, 7, 128]);
    transport.responder = (call) =>
        transport.send(call.id, NativeMessageKind.binaryResult, payload);
    final result = await backend.invokeMethod<Uint8List>('readCover');
    expect(result, isA<Uint8List>());
    expect(result, payload);
  });

  group('binary arguments', () {
    test('move one top-level Uint8List into the bytes buffer', () async {
      transport.responder = (call) =>
          transport.sendJson(call.id, NativeMessageKind.result, null);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await backend.invokeMethod<void>('runNativeDataJob', {
        'request_json': '{}',
        'request_id': 'job',
        'bytes': bytes,
      });
      final call = transport.calls.single;
      expect(call.args, {
        'request_json': '{}',
        'request_id': 'job',
        r'$bytes_key': 'bytes',
      });
      expect(call.bytes, bytes);
    });

    test('leave arguments without binary values untouched', () {
      final encoded = encodeBackendArguments({'request_id': 'job'});
      expect(jsonDecode(utf8.decode(encoded.json)), {'request_id': 'job'});
      expect(encoded.bytes, isNull);
      expect(utf8.decode(encodeBackendArguments(null).json), 'null');
    });

    test('reject a second binary value', () async {
      await expectLater(
        backend.invokeMethod<void>('x', {'a': Uint8List(1), 'b': Uint8List(2)}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_arguments',
          ),
        ),
      );
      expect(transport.calls, isEmpty);
    });

    test('reject values JSON cannot carry', () {
      expect(
        () => encodeBackendArguments({'when': DateTime(2026)}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_arguments',
          ),
        ),
      );
    });
  });

  group('progress events', () {
    test('fan out to every listener and subscribe once', () async {
      final first = <Object?>[];
      final second = <Object?>[];
      final a = backend.downloadProgressEvents().listen(first.add);
      final b = backend.downloadProgressEvents().listen(second.add);
      await pumpEventQueue();
      expect(transport.subscriptions, [
        '+${NativeMessageKind.downloadProgress}',
      ]);

      transport.sendJson(0, NativeMessageKind.downloadProgress, {
        'items': {'a': 0.5},
      });
      transport.sendJson(0, NativeMessageKind.libraryScanProgress, {
        'scanned': 1,
      });
      await pumpEventQueue();
      expect(first, [
        {
          'items': {'a': 0.5},
        },
      ]);
      expect(second, first);

      await a.cancel();
      expect(transport.subscriptions, hasLength(1));
      await b.cancel();
      expect(transport.subscriptions, [
        '+${NativeMessageKind.downloadProgress}',
        '-${NativeMessageKind.downloadProgress}',
      ]);
    });

    test('resubscribe after the last listener returns', () async {
      final events = <Object?>[];
      final first = backend.libraryScanProgressEvents().listen(events.add);
      await pumpEventQueue();
      await first.cancel();
      final second = backend.libraryScanProgressEvents().listen(events.add);
      await pumpEventQueue();
      transport.sendJson(0, NativeMessageKind.libraryScanProgress, {
        'scanned': 3,
      });
      await pumpEventQueue();
      await second.cancel();
      const kind = NativeMessageKind.libraryScanProgress;
      expect(transport.subscriptions, ['+$kind', '-$kind', '+$kind', '-$kind']);
      expect(events, [
        {'scanned': 3},
      ]);
    });

    test(
      'never subscribe when cancelled before the library is ready',
      () async {
        final subscription = backend.downloadProgressEvents().listen((_) {});
        await subscription.cancel();
        await pumpEventQueue();
        expect(transport.subscriptions, isEmpty);
      },
    );
  });

  test('routes inbound calls to the handler', () async {
    final received = <MethodCall>[];
    backend.setMethodCallHandler((call) async => received.add(call));
    transport.responder = (call) =>
        transport.sendJson(call.id, NativeMessageKind.result, null);
    await backend.invokeMethod<void>('init');

    transport.sendJson(0, NativeMessageKind.inboundCall, {
      'method': 'extensionSessionGrantCompleted',
      'arguments': {'extension_id': 'example', 'success': true},
    });
    transport.sendJson(0, NativeMessageKind.inboundCall, {
      'method': 'libraryStorageChanged',
      'arguments': null,
    });
    await pumpEventQueue();
    expect(received.map((call) => call.method), [
      'extensionSessionGrantCompleted',
      'libraryStorageChanged',
    ]);
    expect(received.first.arguments, {
      'extension_id': 'example',
      'success': true,
    });
  });

  test('forwards pushed log records', () async {
    final logs = <Object?>[];
    final subscription = backend.logRecords.listen(logs.add);
    transport.responder = (call) =>
        transport.sendJson(call.id, NativeMessageKind.result, null);
    await backend.invokeMethod<void>('init');
    transport.sendJson(0, NativeMessageKind.log, {
      'level': 'INFO',
      'message': 'ready',
    });
    await pumpEventQueue();
    await subscription.cancel();
    expect(logs, [
      {'level': 'INFO', 'message': 'ready'},
    ]);
  });

  test('reports a missing library as a PlatformException', () async {
    final missing = RustFfiBackend(
      openTransport: () => throw ArgumentError('dlopen failed'),
      loadConfig: () async => _config,
    );
    await expectLater(
      missing.invokeMethod<void>('getAllDownloadProgress'),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', desktopBackendUnavailableCode)
            .having((e) => e.details, 'details', contains('dlopen failed')),
      ),
    );
    await expectLater(
      missing.downloadProgressEvents().first,
      throwsA(isA<PlatformException>()),
    );
  });

  test('starts again after a failed start', () async {
    var attempts = 0;
    final retrying = RustFfiBackend(
      openTransport: () => transport,
      loadConfig: () async {
        if (++attempts == 1) throw StateError('folder unavailable');
        return _config;
      },
    );
    transport.responder = (call) =>
        transport.sendJson(call.id, NativeMessageKind.result, 'ok');
    await expectLater(
      retrying.invokeMethod<String>('first'),
      throwsA(isA<StateError>()),
    );
    expect(await retrying.invokeMethod<String>('second'), 'ok');
    expect(attempts, 2);
    expect(transport.configs, hasLength(1));
  });

  test('config falls back to app support without a Documents folder', () async {
    final config = await DesktopBackendConfig.resolve(
      ffmpegPath: '/bin/ffmpeg',
      ffprobePath: '/bin/ffprobe',
      supportDirectory: () async => Directory('/support'),
      documentsDirectory: () async =>
          throw const FileSystemException('Unable to get documents directory'),
      temporaryDirectory: () async => Directory('/tmp'),
    );
    expect(config.appSupportDir, '/support');
    expect(config.documentsDir, '/support');
    expect(config.tempDir, '/tmp');
  });

  group('library location', () {
    test('prefers the environment override', () {
      expect(
        desktopBackendLibraryCandidates(
          environment: {'MORNYE_DESKTOP_LIB': '/dev/libmornye_desktop.dylib'},
          operatingSystem: 'macos',
          executable: '/Applications/Mornye.app/Contents/MacOS/Mornye',
        ),
        [
          '/dev/libmornye_desktop.dylib',
          '/Applications/Mornye.app/Contents/Frameworks/libmornye_desktop.dylib',
        ],
      );
    });

    test('uses the bundled location per platform', () {
      expect(
        desktopBackendLibraryCandidates(
          environment: const {},
          operatingSystem: 'windows',
          executable: r'C:\Program Files\Mornye\mornye.exe',
        ),
        [r'C:\Program Files\Mornye\mornye_desktop.dll'],
      );
      expect(
        desktopBackendLibraryCandidates(
          environment: const {},
          operatingSystem: 'linux',
          executable: '/opt/mornye/mornye',
        ),
        ['/opt/mornye/lib/libmornye_desktop.so'],
      );
    });
  });
}
