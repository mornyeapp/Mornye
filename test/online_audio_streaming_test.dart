import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/fake_mpv_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayableMedia Online Streaming', () {
    test(
      'playableFromOnlineTrack constructs valid online media with headers',
      () {
      final track = Track(
        id: 'track-123',
        name: 'Online Song',
        artistName: 'Online Artist',
        albumName: 'Online Album',
        duration: 210,
        source: 'jiosaavn',
        coverUrl: 'https://example.com/cover.jpg',
      );

      final headers = {
        'User-Agent': 'Mornye-Audio/1.0',
        'Authorization': 'Bearer test-token',
      };

      final media = playableFromOnlineTrack(
        track: track,
        streamUrl: 'https://audio.example.com/stream.mp4',
        headers: headers,
        durationMs: 210000,
        bitrate: 320000,
        format: 'm4a',
      );

      expect(media.id, 'stream://jiosaavn/track-123');
      expect(media.source, 'https://audio.example.com/stream.mp4');
      expect(media.isNetwork, isTrue);
      expect(media.title, 'Online Song');
      expect(media.artist, 'Online Artist');
      expect(media.album, 'Online Album');
      expect(media.duration, const Duration(milliseconds: 210000));
      expect(media.bitrate, 320000);
      expect(media.format, 'm4a');
      expect(media.httpHeaders, headers);

      // JSON serialization round-trip preserves headers
      final json = media.toJson();
      expect(json['httpHeaders'], headers);

      final restored = PlayableMedia.fromJson(json);
      expect(restored, isNotNull);
      expect(restored!.id, media.id);
      expect(restored.source, media.source);
      expect(restored.isNetwork, isTrue);
      expect(restored.httpHeaders, headers);
    });

    test('toMediaItem preserves stream metadata and headers', () {
      final track = Track(
        id: 'track-456',
        name: 'Stream Song',
        artistName: 'Stream Artist',
        albumName: 'Stream Album',
        duration: 180,
      );

      final media = playableFromOnlineTrack(
        track: track,
        streamUrl: 'https://cdn.example.com/stream.mp3',
        headers: {'User-Agent': 'Custom-Agent'},
        format: 'mp3',
      );

      final item = media.toMediaItem();
      expect(item.id, media.id);
      expect(item.title, 'Stream Song');
      expect(item.extras?['source'], 'https://cdn.example.com/stream.mp3');
      expect(item.extras?['httpHeaders'], {'User-Agent': 'Custom-Agent'});
      expect(item.extras?['format'], 'mp3');
    });
  });

  group('MediaKitPlaybackDeck Network Streaming', () {
    late FakeMpvEngine engine;
    late MediaKitPlaybackDeck deck;

    setUp(() {
      playbackOutputVolume.value = 1;
      engine = FakeMpvEngine();
      deck = MediaKitPlaybackDeck(playerId: 'network-test', engine: engine);
    });

    tearDown(() async {
      await deck.dispose();
      playbackOutputVolume.value = 1;
    });

    test('loads remote HTTP stream with custom request headers', () async {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        'Range': 'bytes=0-',
      };

      await deck.setNetworkSource(
        'https://stream.example.com/audio.m4a',
        headers: headers,
      );

      expect(
        engine.calls,
        containsAllInOrder([
          ['stop'],
          ['open', 'https://stream.example.com/audio.m4a', headers.toString()],
        ]),
      );

      expect(deck.state, PlaybackDeckState.stopped);

      // Resume starts playback of the progressive network stream
      await deck.resume();
      expect(deck.state, PlaybackDeckState.playing);
      expect(engine.calls, contains(['play']));

      // Range seeking works directly on network stream
      await deck.seek(const Duration(seconds: 45));
      expect(engine.calls, contains(['seek', '0:00:45.000000']));
    });

    test(
      'loads remote HTTP stream without headers when not required',
      () async {
      await deck.setNetworkSource('https://stream.example.com/direct.mp3');

      expect(
        engine.calls,
        containsAllInOrder([
          ['stop'],
          ['open', 'https://stream.example.com/direct.mp3'],
        ]),
      );

      await deck.resume();
      expect(deck.state, PlaybackDeckState.playing);
    });

    test('local file playback remains functional and unmodified', () async {
      await deck.setFileSource('/path/to/local/downloaded_song.flac');

      expect(
        engine.calls,
        containsAllInOrder([
          ['stop'],
          ['open', '/path/to/local/downloaded_song.flac'],
        ]),
      );

      await deck.resume();
      expect(deck.state, PlaybackDeckState.playing);
    });
  });
}
