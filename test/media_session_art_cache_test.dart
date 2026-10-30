import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/media_session_art_cache.dart';

class _CacheBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

/// The OS end of the session, passing on the media items it is sent.
class _Os extends AudioServicePlatform {
  final items = StreamController<MediaItemMessage>.broadcast(sync: true);

  @override
  Future<void> configure(ConfigureRequest request) async {}

  @override
  Future<void> setState(SetStateRequest request) async {}

  @override
  Future<void> setQueue(SetQueueRequest request) async {}

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async =>
      items.add(request.mediaItem);

  @override
  Future<void> setAndroidPlaybackInfo(
    SetAndroidPlaybackInfoRequest request,
  ) async {}

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {}
}

void main() {
  _CacheBinding();

  test('the media session takes web covers from the app cover cache', () async {
    final directory = await Directory.systemTemp.createTemp('session-art-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final os = _Os();
    final original = AudioServicePlatform.instance;
    BaseAudioHandler? handler;
    addTearDown(() async {
      AudioServicePlatform.instance = original;
      await handler?.playbackState.close();
      await handler?.queue.close();
      await handler?.mediaItem.close();
      await os.items.close();
      await server.close(force: true);
      await CoverCacheManager.instance.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });
    final cover = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6qVQAAAAASUVORK5CYII=',
    );
    var downloads = 0;
    server.listen((request) async {
      downloads++;
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600')
        ..add(cover);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/cover.png';
    await CoverCacheManager.initialize();
    // The app shows the cover first, from its cover cache.
    final shown = await CoverCacheManager.instance.getSingleFile(url);
    expect(downloads, 1);

    AudioServicePlatform.instance = os;
    handler = await AudioService.init(
      builder: BaseAudioHandler.new,
      cacheManager: MediaSessionArtCache(),
    );
    Future<MediaItemMessage> artwork(String id) => os.items.stream
        .firstWhere(
          (item) => item.id == id && item.extras?['artCacheFile'] != null,
        )
        .timeout(const Duration(seconds: 10));

    final first = artwork('one');
    handler.mediaItem.add(
      MediaItem(id: 'one', title: 'One', artUri: Uri.parse(url)),
    );
    expect((await first).extras!['artCacheFile'], shown.path);
    expect(downloads, 1);

    // The cover cache's byte budget deleted the file; its memory still
    // lists it, so the session fetches it again rather than lose it.
    await shown.delete();
    final second = artwork('two');
    handler.mediaItem.add(
      MediaItem(id: 'two', title: 'Two', artUri: Uri.parse(url)),
    );
    final path = (await second).extras!['artCacheFile'] as String;
    expect(File(path).existsSync(), isTrue);
    expect(downloads, 2);
  });
}
