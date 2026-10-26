import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/music_player_automix_harness.dart';

const _tracks = testTracks;
const _until = waitUntil;

Iterable<String> get _gaplessDecks =>
    native.live.where((id) => id.startsWith('music-gapless-'));

class _CachedPhoneSongs implements NetworkVirtualSources {
  @override
  bool owns(String id) => id == 'example-phone';
  @override
  bool reachable(String id) => true;
  @override
  Stream<NetworkVirtualSong> songs(String id) => const Stream.empty();
  @override
  Future<String> resolve(String id, String path) async => '/received/two.flac';
  @override
  Future<Map<String, dynamic>> metadata(String id, String path) async => {};
}

/// Plays [_tracks] from 45 of 60 seconds, inside the preparation lead.
Future<void> _playNearTheEnd() async {
  await handler.setQueueAndPlay(_tracks);
  await _until(() => handler.mediaItem.value?.duration != null);
  await handler.seek(const Duration(seconds: 45));
}

void main() {
  setUpMusicPlayerHarness();
  tearDown(() => AudioplayersPlaybackDeck.debugChainsPlayers = null);

  test('Gapless playback is on by default and persists when turned off', () {
    expect(const AppSettings().gaplessPlayback, isTrue);
    expect(AppSettings.fromJson({}).gaplessPlayback, isTrue);
    final off = const AppSettings().copyWith(gaplessPlayback: false);
    expect(AppSettings.fromJson(off.toJson()).gaplessPlayback, isFalse);
  });

  test('the next song loads before the end and starts on completion', () async {
    setGaplessEnabled(true);
    await _playNearTheEnd();
    await _until(() => _gaplessDecks.length == 1);
    final next = _gaplessDecks.single;
    await _until(() => native.sources[next] == '/two.flac');
    expect(native.playing, {'music-player'});

    await native.complete('music-player');
    await _until(() => handler.mediaItem.value?.id == 'two');
    expect(native.playing, {next});
    expect(native.live, {next});
    // The prepared deck played; nothing loaded the song again.
    expect(native.calls.where((call) => call.$2 == 'setSourceUrl').length, 2);
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.queue.value.map((item) => item.id), ['one', 'two', 'three']);
  });

  test(
    'a cached phone song prepares as a local file for gapless playback',
    () async {
      final storage = NetworkStorageService.instance;
      final previous = storage.virtualSources;
      storage.virtualSources = _CachedPhoneSongs();
      addTearDown(() => storage.virtualSources = previous);
      setGaplessEnabled(true);
      await handler.setQueueAndPlay([
        _tracks.first,
        const PlayableMedia(
          id: 'two',
          source: 'network://example-phone/two.flac',
          title: 'Two',
          artist: 'Artist',
        ),
      ]);
      await _until(() => handler.mediaItem.value?.duration != null);
      await handler.seek(const Duration(seconds: 45));
      await _until(() => _gaplessDecks.length == 1);
      final next = _gaplessDecks.single;
      await _until(() => native.sources[next] == '/received/two.flac');
      final prepare = native.calls.singleWhere(
        (call) => call.$1 == next && call.$2 == 'setSourceUrl',
      );
      expect(prepare.$3['isLocal'], isTrue);
      await native.complete('music-player');
      await _until(() => handler.mediaItem.value?.id == 'two');
      expect(native.playing, {next});
    },
  );

  test('chained players hand over natively', () async {
    AudioplayersPlaybackDeck.debugChainsPlayers = true;
    setGaplessEnabled(true);
    await _playNearTheEnd();
    await _until(() => native.nextPlayers['music-player'] != null);
    final next = native.nextPlayers['music-player']!;
    expect(native.playing, {'music-player'});

    await native.complete('music-player');
    await _until(() => handler.mediaItem.value?.id == 'two');
    expect(native.playing, {next});
    expect(native.live, {next});
  });

  test('repeat all joins the last song to the first', () async {
    setGaplessEnabled(true);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    await handler.setQueueAndPlay(_tracks, initialIndex: 2);
    await _until(() => handler.mediaItem.value?.duration != null);
    await handler.seek(const Duration(seconds: 45));
    await _until(() => _gaplessDecks.length == 1);
    final next = _gaplessDecks.single;
    await _until(() => native.sources[next] == '/one.flac');

    await native.complete('music-player');
    await _until(() => handler.mediaItem.value?.id == 'one');
    expect(native.playing, {next});
  });

  test('a queue change drops the prepared song and its link', () async {
    AudioplayersPlaybackDeck.debugChainsPlayers = true;
    setGaplessEnabled(true);
    await _playNearTheEnd();
    await _until(() => native.nextPlayers['music-player'] != null);
    final next = native.nextPlayers['music-player']!;

    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    await _until(() => !native.live.contains(next));
    expect(native.nextPlayers, isEmpty);

    // Repeat one keeps the ordinary transition.
    await native.complete('music-player');
    await _until(
      () =>
          native.resumedSources
              .where((source) => source == '/one.flac')
              .length ==
          2,
    );
    expect(handler.mediaItem.value?.id, 'one');
    expect(_gaplessDecks, isEmpty);
  });

  test('turning gapless off drops the prepared song', () async {
    setGaplessEnabled(true);
    await _playNearTheEnd();
    await _until(() => _gaplessDecks.length == 1);

    setGaplessEnabled(false);
    await _until(() => _gaplessDecks.isEmpty);
    await native.complete('music-player');
    await _until(() => handler.mediaItem.value?.id == 'two');
    expect(native.sources['music-player'], '/two.flac');
  });

  test('AutoMix replaces gapless playback', () async {
    setGaplessEnabled(true);
    setAutoMixEnabled(true);
    await _playNearTheEnd();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(_gaplessDecks, isEmpty);
  });

  test('a song far from its end does not load the next one', () async {
    setGaplessEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(_gaplessDecks, isEmpty);
  });
}
