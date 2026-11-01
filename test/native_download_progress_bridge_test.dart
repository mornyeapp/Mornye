import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  const events = MethodChannel('com.zarz.mornye/download_progress_stream');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  final snapshot = <String, dynamic>{
    'seq': 19,
    'reset': true,
    'run_id': 'example-run',
    'state_serial': 8,
    'compact_items': [
      for (var i = 0; i < 2000; i++)
        {
          'item_id': '$i',
          'name': 'Example song $i',
          'progress': 0.5,
          'error': null,
        },
    ],
    'item_ids': [for (var i = 0; i < 2000; i++) '$i'],
  };
  final largeJson = jsonEncode(snapshot);

  test('large snapshots yield while decoding and retain all fields', () async {
    expect(largeJson.length, greaterThanOrEqualTo(128 * 1024));
    final timer = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getNativeDownloadWorkerSnapshot');
      expect(call.arguments, {'since_state_serial': 7});
      Timer.run(timer.complete);
      return largeJson;
    });
    final result = await PlatformBridge.getNativeDownloadWorkerSnapshot(
      sinceStateSerial: 7,
    );
    expect(timer.isCompleted, isTrue);
    expect(result, snapshot);
    await timer.future;
  });

  test(
    'snapshot maps, empty payloads and decode errors keep their contract',
    () async {
      for (final value in [snapshot, '', null, '[]', 'null', '{}']) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        expect(
          await PlatformBridge.getNativeDownloadWorkerSnapshot(),
          value is Map ? snapshot : isEmpty,
        );
      }
      messenger.setMockMethodCallHandler(channel, (_) async => '{broken');
      await expectLater(
        PlatformBridge.getNativeDownloadWorkerSnapshot(),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'progress JSON stays ordered across large payloads and errors',
    () async {
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      messenger.setMockMethodCallHandler(events, (call) async {
        if (call.method == 'listen') listening.complete();
        if (call.method == 'cancel') cancelled.complete();
        return null;
      });
      final seen = <Object>[];
      final done = Completer<void>();
      final subscription = PlatformBridge.downloadProgressStream().listen((
        value,
      ) {
        seen.add(value);
        if (seen.length == 4) done.complete();
      }, onError: (Object error) => seen.add(error));
      await listening.future;
      for (final value in [
        largeJson,
        {'seq': 20},
        '{broken',
        '{"seq":21}',
      ]) {
        await messenger.handlePlatformMessage(
          events.name,
          codec.encodeSuccessEnvelope(value),
          (_) {},
        );
      }
      await done.future;
      expect(seen[0], snapshot);
      expect(seen[1], {'seq': 20});
      expect(seen[2], isA<FormatException>());
      expect(seen[3], {'seq': 21});
      await subscription.cancel();
      await cancelled.future;
    },
  );

  test(
    'cancelling a large progress decode retires the native stream',
    () async {
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      messenger.setMockMethodCallHandler(events, (call) async {
        if (call.method == 'listen') listening.complete();
        if (call.method == 'cancel') cancelled.complete();
        return null;
      });
      final seen = <Map<String, dynamic>>[];
      final subscription = PlatformBridge.downloadProgressStream().listen(
        seen.add,
      );
      await listening.future;
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(largeJson),
        (_) {},
      );
      await subscription.cancel();
      await cancelled.future;
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
    },
  );
}
