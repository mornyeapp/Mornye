import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/autoplay_taste_fixture.dart';

Map<String, Object?> _model(AutoplayTasteModel model) => {
  'tokens': model.tokens,
  'vectors': model.vectors.toList(),
  'positives': model.positives,
  'through': model.through,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native training forwards history and preserves stored model shape',
    () async {
      final plays = autoplayTasteFixture(12);
      final expected = trainAutoplayTaste(plays);
      var called = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final arguments = call.arguments as Map;
        expect(
          jsonDecode(arguments['request_json'] as String),
          autoplayTasteFixtureRequest(plays),
        );
        called = true;
        return jsonEncode(_model(expected));
      });
      expect(
        _model(await trainAutoplayTasteInBackground(plays)),
        _model(expected),
      );
      expect(called, isTrue);
    },
  );

  test('missing native host retains isolated compatibility trainer', () async {
    final plays = autoplayTasteFixture(12);
    expect(
      _model(await trainAutoplayTasteInBackground(plays)),
      _model(trainAutoplayTaste(plays)),
    );
  });

  test('native errors are not silently retrained by Dart', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'data_job_error', message: 'cancelled');
    });
    await expectLater(
      trainAutoplayTasteInBackground([]),
      throwsA(isA<PlatformException>()),
    );
  });

  test('invalid native vectors are rejected', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => jsonEncode({
        'tokens': ['artist:a'],
        'vectors': [0.0],
        'positives': 1,
        'through': 1,
      }),
    );
    await expectLater(
      trainAutoplayTasteInBackground([]),
      throwsA(isA<FormatException>()),
    );
  });

  final enabled =
      Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
      false;
  group('actual native autoplay taste', () {
    late Directory directory;
    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('mornye-taste-ffi-');
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: FfiBackendTransport.open,
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: directory.path,
          documentsDir: directory.path,
          tempDir: directory.path,
        ),
      );
    });
    tearDownAll(() async {
      RustFfiBackend.debugShared = null;
      debugDesktopPlatformOverride = null;
      await directory.delete(recursive: true);
    });
    for (final count in [-1, 0, 12, 500]) {
      test('training fixture $count matches Dart baseline', () async {
        final plays = count < 0
            ? autoplayTasteEdgeFixture()
            : autoplayTasteFixture(count);
        final baseline = trainAutoplayTaste(plays);
        final raw = await PlatformBridge.runNativeDataJob(
          autoplayTasteFixtureRequest(plays),
        );
        expect(raw['tokens'], baseline.tokens);
        final actual = await trainAutoplayTasteInBackground(plays);
        expect(actual.tokens, baseline.tokens);
        expect(actual.positives, baseline.positives);
        expect(actual.through, baseline.through);
        expect(actual.vectors.length, baseline.vectors.length);
        for (var i = 0; i < actual.vectors.length; i++) {
          expect(
            actual.vectors[i],
            closeTo(baseline.vectors[i], 1e-6),
            reason: 'vector $i',
          );
        }
      });
    }
  }, skip: !enabled);
}
