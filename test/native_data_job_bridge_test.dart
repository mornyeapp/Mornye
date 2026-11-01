import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

class _EncodingLocationMap extends MapBase<String, dynamic> {
  _EncodingLocationMap(this._values);

  final Map<String, dynamic> _values;

  @override
  Iterable<String> get keys => [..._values.keys, 'encoding_isolate'];

  @override
  dynamic operator [](Object? key) =>
      key == 'encoding_isolate' ? Isolate.current.debugName : _values[key];

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('read only');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'runNativeDataJob' ? '{"value":1}' : null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final scenario in [
    (
      name: 'small scalars',
      values: <String, dynamic>{'path': '/song.flac'},
      background: false,
    ),
    (
      name: 'bounded list',
      values: <String, dynamic>{'items': List.filled(64, 1)},
      background: false,
    ),
    (
      name: 'long list',
      values: <String, dynamic>{'items': List.filled(65, 1)},
      background: true,
    ),
    (
      name: 'long string',
      values: <String, dynamic>{'text': 'x' * (16 * 1024)},
      background: true,
    ),
    (
      name: 'wide map',
      values: <String, dynamic>{for (var i = 0; i < 65; i++) '$i': i},
      background: true,
    ),
    (
      name: 'aggregate nodes',
      values: <String, dynamic>{
        'items': List.generate(8, (_) => List.filled(64, 1)),
      },
      background: true,
    ),
    (
      name: 'aggregate text',
      values: <String, dynamic>{'items': List.filled(32, 'x' * 1024)},
      background: true,
    ),
  ]) {
    test('encodes ${scenario.name} on the expected isolate', () async {
      late Map<String, dynamic> encoded;
      messenger.setMockMethodCallHandler(channel, (call) async {
        encoded =
            jsonDecode((call.arguments as Map)['request_json'] as String)
                as Map<String, dynamic>;
        return '{}';
      });
      await PlatformBridge.runNativeDataJob(
        _EncodingLocationMap(scenario.values),
      );
      expect(
        encoded.remove('encoding_isolate'),
        scenario.background
            ? isNot(Isolate.current.debugName)
            : Isolate.current.debugName,
      );
      expect(encoded, scenario.values);
    });
  }

  test(
    'inline encoding preserves JSON and separate binary arguments',
    () async {
      final request = <String, dynamic>{
        'operation': 'palette',
        'path': '/Music/Example ♫/song.flac',
        'options': {
          'enabled': true,
          'missing': null,
          'values': [1, 2.5, 'a\nb'],
        },
      };
      final bytes = Uint8List.fromList([0, 127, 255]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        expect(args['request_json'], jsonEncode(request));
        expect(args['bytes'], bytes);
        return '{}';
      });
      await PlatformBridge.runNativeDataJob(request, bytes: bytes);
    },
  );

  test(
    'cancel before encoding completes never dispatches an idle job',
    () async {
      final expectation = expectLater(
        PlatformBridge.runNativeDataJob({
          'operation': 'hash_file',
          'path': '/unused',
        }, requestId: 'encoding'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      await PlatformBridge.cancelNativeDataJob('encoding');
      await expectation;
      expect(calls, isEmpty);
      expect(
        await PlatformBridge.runNativeDataJob({
          'operation': 'hash_file',
          'path': '/unused',
        }, requestId: 'encoding'),
        {'value': 1},
      );
    },
  );

  test(
    'active cancellation reaches native and preserves committed results',
    () async {
      final started = Completer<void>();
      final finished = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'runNativeDataJob') {
          started.complete();
          return finished.future;
        }
        return null;
      });
      final job = PlatformBridge.runNativeDataJob({
        'operation': 'library_import',
      }, requestId: 'active');
      await started.future;
      await PlatformBridge.cancelNativeDataJob('active');
      finished.complete('{"committed":true}');
      expect(await job, {'committed': true});
      expect(calls, ['runNativeDataJob', 'cancelNativeDataJob']);
      await PlatformBridge.cancelNativeDataJob('active');
      await PlatformBridge.cancelNativeDataJob('unknown');
      expect(calls, ['runNativeDataJob', 'cancelNativeDataJob']);
    },
  );

  test('failed encoding releases its request identity', () async {
    await expectLater(
      PlatformBridge.runNativeDataJob({
        'operation': Object(),
      }, requestId: 'invalid'),
      throwsA(isA<Object>()),
    );
    await PlatformBridge.cancelNativeDataJob('invalid');
    expect(calls, isEmpty);
    expect(
      await PlatformBridge.runNativeDataJob({
        'operation': 'palette',
      }, requestId: 'invalid'),
      {'value': 1},
    );
  });
}
