import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/extension_link_resolver.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('com.zarz.mornye/backend');

  setUp(() async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await PlatformBridge.clearTrackCache();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await PlatformBridge.clearTrackCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a link no extension handles is not asked for', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return call.method == 'findURLHandler' ? '' : null;
    });

    expect(
      await ExtensionLinkResolver.resolveTracks('https://example.com/x/1'),
      isNull,
    );
    expect(methods, ['findURLHandler']);
  });

  test('an incomplete answer is asked again at most three times', () async {
    var handled = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'findURLHandler') return 'generic-extension';
      if (call.method == 'handleURLWithExtension') {
        handled++;
        return {
          'type': 'track',
          'extension_id': 'generic-extension',
          'track': {'id': 't1', 'name': ''},
        };
      }
      return null;
    });

    expect(
      await ExtensionLinkResolver.resolveTracks('https://example.com/track/1'),
      isEmpty,
    );
    expect(handled, ExtensionLinkResolver.attempts);
  });

  test('a playlist link yields its tracks in order with the source', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'findURLHandler') return 'generic-extension';
      if (call.method == 'handleURLWithExtension') {
        return {
          'type': 'playlist',
          'extension_id': 'generic-extension',
          'name': 'Mix',
          'tracks': [
            {'id': 'p1', 'name': 'First', 'artists': 'A', 'album_name': 'Mix'},
            {'id': 'p2', 'name': 'Second', 'artists': 'B', 'album_name': 'LP'},
          ],
        };
      }
      return null;
    });

    final tracks = await ExtensionLinkResolver.resolveTracks(
      'https://example.com/playlist/1',
    );
    expect(tracks!.map((track) => track.id), ['p1', 'p2']);
    expect(
      tracks.every((track) => track.source == 'generic-extension'),
      isTrue,
    );
    // An album named like the playlist is the playlist's own name.
    expect(tracks.first.albumName, '');
    expect(tracks.last.albumName, 'LP');
  });
}
