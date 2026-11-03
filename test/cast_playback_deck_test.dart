import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/cast_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cast-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late CastOutput output;
  late CastPlaybackDeck deck;
  late StreamController<Object?> events;
  late List<MethodCall> calls;
  late Map<Object?, Object?> load;
  late List<Map<Object?, Object?>> registered;
  Completer<void>? pendingLoad;

  setUp(() async {
    events = StreamController<Object?>.broadcast(sync: true);
    calls = [];
    registered = [];
    pendingLoad = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'state':
          return {'connected': false};
        case 'register':
          registered.add(call.arguments as Map<Object?, Object?>);
          return {'url': 'http://192.0.2.2:4000/media/${registered.length}'};
        case 'load':
          load = call.arguments as Map<Object?, Object?>;
          await pendingLoad?.future;
      }
      return null;
    });
    output = CastOutput(channel: channel, events: events.stream);
    await output.initialize();
    events.add({'connected': true, 'deviceId': 'tv', 'host': '192.0.2.10'});
    deck = CastPlaybackDeck(
      output: output,
      metadata: () => MediaItem(
        id: 'song',
        title: 'A song',
        artist: 'An artist',
        duration: const Duration(minutes: 3),
        artUri: Uri.file('/private/covers/song.jpg'),
        extras: const {'format': 'flac'},
      ),
    );
  });
  tearDown(() async {
    await deck.dispose();
    output.dispose();
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'uses an audio MIME type and original metadata, and controls the receiver',
    () async {
      await deck.setFileSource('/private/music/song.flac');
      expect(load['mime'], 'audio/flac');
      expect(load['title'], 'A song');
      expect(load['artist'], 'An artist');
      expect(load['duration'], 180000);
      // Paths stay on the phone: the receiver gets server URLs only.
      expect(load['url'], 'http://192.0.2.2:4000/media/1');
      expect(load['artwork'], 'http://192.0.2.2:4000/media/2');
      expect(registered, [
        {'source': '/private/music/song.flac', 'mime': 'audio/flac'},
        {'source': '/private/covers/song.jpg', 'mime': 'image/jpeg'},
      ]);
      final serve = calls.firstWhere((call) => call.method == 'serve');
      expect(serve.arguments, {'host': '192.0.2.10'});
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(['serve', 'clearMedia', 'register', 'load']),
      );
      await deck.seek(const Duration(seconds: 12));
      await deck.resume();
      // The handler cancels preparation before every pause, including loaded sources.
      await deck.cancelPreparation();
      await deck.pause();
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(['load', 'seek', 'play', 'pause']),
      );
      expect(deck.state, PlaybackDeckState.paused);
    },
  );

  test(
    'only current media status can complete a track, and completion is emitted once',
    () async {
      var completed = 0;
      final subscription = deck.onPlayerComplete.listen((_) => completed++);
      addTearDown(subscription.cancel);
      await deck.setFileSource('/song.flac');
      await deck.resume();
      events.add({'token': -1, 'finished': true});
      expect(completed, 0);
      events.add({'token': load['token'], 'state': 2, 'position': 17000});
      expect(await deck.getCurrentPosition(), const Duration(seconds: 17));
      events.add({'token': load['token'], 'finished': true});
      events.add({'token': load['token'], 'finished': true});
      expect(completed, 1);
    },
  );

  test('closing the deck closes the media server it started', () async {
    await deck.setFileSource('/song.flac');
    await deck.dispose();
    expect(calls.last.method, 'closeMedia');
  });

  test('a TV the server cannot reach fails the load and can retry', () async {
    var refused = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'serve' && refused) {
        refused = false;
        throw PlatformException(code: 'CAST_MEDIA');
      }
      if (call.method == 'register') return {'url': 'http://192.0.2.2/m/1'};
      return null;
    });
    await expectLater(
      deck.setFileSource('/song.flac'),
      throwsA(isA<PlatformException>()),
    );
    await deck.setFileSource('/song.flac');
    expect(calls.where((call) => call.method == 'serve'), hasLength(2));
    expect(calls.last.method, 'load');
  });

  test('a cancelled load cannot become ready or resume', () async {
    pendingLoad = Completer<void>();
    final preparing = deck.setFileSource('/song.flac');
    while (!calls.any((call) => call.method == 'load')) {
      await Future<void>.delayed(Duration.zero);
    }
    await deck.cancelPreparation();
    pendingLoad!.complete();
    await preparing;
    await expectLater(deck.resume(), throwsStateError);
    expect(calls.where((call) => call.method == 'play'), isEmpty);
  });

  test(
    'receiver errors do not advance the queue and suspension pauses its clock',
    () async {
      final errors = <Object>[];
      final subscription = deck.onPlayerStateChanged.listen(
        (_) {},
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      await deck.setFileSource('/song.flac');
      await deck.resume();
      events.add({'token': load['token'], 'state': 2, 'suspended': true});
      expect(deck.state, PlaybackDeckState.paused);
      events.add({'token': load['token'], 'failed': true});
      expect(errors, hasLength(1));
      expect(deck.state, isNot(PlaybackDeckState.completed));
    },
  );
}
