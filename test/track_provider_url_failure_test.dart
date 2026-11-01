import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('com.zarz.mornye/backend');
  const url = 'https://example.invalid/playlist/large';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await PlatformBridge.clearTrackCache();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await PlatformBridge.clearTrackCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final reason in [
    'handleUrl timeout: extension took too long to respond',
    'handleUrl failed: out of memory',
  ]) {
    test('recognized URL metadata failure preserves $reason', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'findURLHandler') return 'example.metadata';
        if (call.method == 'handleURLWithExtension') {
          calls++;
          throw PlatformException(code: 'ERROR', message: reason);
        }
        return null;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(trackProvider.notifier).fetchFromUrl(url);
      final state = container.read(trackProvider);
      expect(state.isLoading, isFalse);
      expect(state.error, contains(reason));
      expect(state.error, isNot('url_not_recognized'));
      expect(calls, 1);
    });
  }

  test('failed URL lookups can be retried without a cached error', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (++calls == 1) {
        throw PlatformException(code: 'ERROR', message: 'metadata timeout');
      }
      return {'type': 'playlist', 'name': 'Playlist', 'tracks': <Object?>[]};
    });
    await expectLater(
      PlatformBridge.handleURLWithExtension(url),
      throwsA(isA<PlatformException>()),
    );
    expect(
      (await PlatformBridge.handleURLWithExtension(url))?['type'],
      'playlist',
    );
    expect(calls, 2);
  });
}
