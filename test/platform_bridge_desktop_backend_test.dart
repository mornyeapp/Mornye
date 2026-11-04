import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/native_log_source.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _FakeTransport implements NativeBackendTransport {
  final methods = <String>[];
  final calls = <(String, Map<String, dynamic>)>[];
  final subscriptions = <int>[];
  final results = <String, Object?>{};
  String? failingMethod;
  late NativeMessageListener listener;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    methods.add(method);
    final arguments =
        jsonDecode(utf8.decode(argsJson)) as Map<String, dynamic>? ?? {};
    calls.add((method, arguments));
    scheduleMicrotask(
      () => listener(
        id,
        method == failingMethod
            ? NativeMessageKind.error
            : NativeMessageKind.result,
        utf8.encode(
          jsonEncode(
            method == failingMethod
                ? {'code': 'ERROR', 'message': 'Metadata write failed'}
                : method == 'acquireDownloadDirectory'
                ? 'grant:${arguments['path']}'
                : results[method],
          ),
        ),
      ),
    );
  }

  @override
  void subscribe(int kind) => subscriptions.add(kind);

  @override
  void unsubscribe(int kind) => subscriptions.remove(kind);

  void push(int kind, Object? value) =>
      listener(0, kind, utf8.encode(jsonEncode(value)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final transport = _FakeTransport();

  setUpAll(() {
    debugDesktopPlatformOverride = true;
    RustFfiBackend.debugShared = RustFfiBackend(
      openTransport: () => transport,
      loadConfig: () async => const DesktopBackendConfig(
        appSupportDir: '/support',
        documentsDir: '/documents',
        tempDir: '/tmp',
      ),
    );
  });

  tearDownAll(() {
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
  });

  test('bridge calls reach the Rust backend on desktop', () async {
    transport.results['getAllDownloadProgress'] = {
      'items': {'a': 1},
    };
    expect(await PlatformBridge.getAllDownloadProgress(), {
      'items': {'a': 1},
    });
    await const NativeLogSource().clear();
    expect(transport.methods, ['getAllDownloadProgress', 'clearLogs']);
  });

  test('progress streams come from native events', () async {
    final events = <Map<String, dynamic>>[];
    final subscription = PlatformBridge.downloadProgressStream().listen(
      events.add,
    );
    await pumpEventQueue();
    expect(transport.subscriptions, [NativeMessageKind.downloadProgress]);
    transport.push(NativeMessageKind.downloadProgress, {
      'items': {'a': 0.25},
    });
    await pumpEventQueue();
    await subscription.cancel();
    expect(events, [
      {
        'items': {'a': 0.25},
      },
    ]);
    expect(transport.subscriptions, isEmpty);
  });

  test('inbound calls reach the bridge handler', () async {
    final grants = <ExtensionSessionGrantEvent>[];
    final subscription = PlatformBridge.extensionSessionGrantEvents().listen(
      grants.add,
    );
    final taps = PlatformBridge.verificationNotificationEvents().first;
    transport.push(NativeMessageKind.inboundCall, {
      'method': 'extensionSessionGrantCompleted',
      'arguments': {'extension_id': 'example', 'success': false},
    });
    transport.push(NativeMessageKind.inboundCall, {
      'method': 'extensionVerificationNotificationTapped',
      'arguments': null,
    });
    await taps;
    await pumpEventQueue();
    await subscription.cancel();
    expect(grants.single.extensionId, 'example');
    expect(grants.single.success, isFalse);
  });

  for (final (file, directory) in [
    (
      r'C:\Users\Example User\Temp\metadata_cover_1\cover.jpg',
      r'C:\Users\Example User\Temp\metadata_cover_1',
    ),
    ('D:/Music/春の歌/cover.jpg', 'D:/Music/春の歌'),
    (r'\\server\share\Music\cover.jpg', r'\\server\share\Music'),
    (r'\\?\C:\Music\cover.jpg', r'\\?\C:\Music'),
    (r'\\?\UNC\server\share\Music\cover.jpg', r'\\?\UNC\server\share\Music'),
    ('/tmp/metadata_cover_1/cover.jpg', '/tmp/metadata_cover_1'),
  ]) {
    test('cover download holds a directory grant for $file', () async {
      transport.calls.clear();
      transport.results['downloadCoverToFile'] = {'success': true};

      final result = await PlatformBridge.downloadCoverToFile(
        'https://example.invalid/cover.jpg',
        file,
      );

      expect(result['success'], isTrue);
      expect(transport.calls.map((call) => [call.$1, call.$2]), [
        [
          'acquireDownloadDirectory',
          {'path': directory},
        ],
        [
          'downloadCoverToFile',
          {
            'cover_url': 'https://example.invalid/cover.jpg',
            'output_path': file,
            'max_dimension': 0,
          },
        ],
        [
          'releaseDownloadDirectory',
          {'token': 'grant:$directory'},
        ],
      ]);
    });
  }

  test(
    'cover extraction shares one grant for audio and artwork siblings',
    () async {
      transport.calls.clear();
      transport.results['extractCoverToFile'] = {'success': true};

      await PlatformBridge.extractCoverToFile(
        r'C:\Music\song.flac',
        r'C:\Music\cover.jpg',
      );

      expect(transport.calls.map((call) => call.$1), [
        'acquireDownloadDirectory',
        'extractCoverToFile',
        'releaseDownloadDirectory',
      ]);
      expect(transport.calls.first.$2, {'path': r'C:\Music'});
    },
  );

  test('failed metadata writes release audio and artwork grants', () async {
    transport.calls.clear();
    transport.failingMethod = 'editFileMetadata';
    addTearDown(() => transport.failingMethod = null);

    await expectLater(
      PlatformBridge.editFileMetadata(r'C:\Music\song.flac', {
        'cover_path': r'C:\Temp\metadata_cover_1\cover.jpg',
        'title': 'Song',
      }),
      throwsA(isA<PlatformException>()),
    );

    expect(transport.calls.map((call) => call.$1), [
      'acquireDownloadDirectory',
      'acquireDownloadDirectory',
      'editFileMetadata',
      'releaseDownloadDirectory',
      'releaseDownloadDirectory',
    ]);
    expect(transport.calls[0].$2, {'path': r'C:\Music'});
    expect(transport.calls[1].$2, {'path': r'C:\Temp\metadata_cover_1'});
    expect(transport.calls[3].$2, {'token': r'grant:C:\Temp\metadata_cover_1'});
    expect(transport.calls[4].$2, {'token': r'grant:C:\Music'});
  });

  test(
    'URI, relative and backend-owned outputs do not acquire folder grants',
    () async {
      for (final path in [
        '',
        'cover.jpg',
        r'C:cover.jpg',
        r'\Temp\cover.jpg',
        'content://example/document/cover',
        'network://example/cover.jpg',
        'https://example.invalid/cover.jpg',
      ]) {
        transport.calls.clear();
        await PlatformBridge.downloadCoverToFile(
          'https://example.invalid/cover.jpg',
          path,
        );
        expect(transport.calls.map((call) => call.$1), ['downloadCoverToFile']);
      }
    },
  );
}
