import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_playback_deck.dart';

import 'support/music_player_automix_harness.dart';

void main() {
  setUpMusicPlayerHarness();
  const url = 'http://127.0.0.1:1234/transcoded.opus';
  late AudioplayersPlaybackDeck deck;
  setUp(() {
    deck = AudioplayersPlaybackDeck(
      playerId: 'network-output',
      nativeAvailable: false,
      equalizerAvailable: false,
    );
    native.durations[url] = 0;
  });
  tearDown(() => deck.dispose());

  test('Pause can abandon a native seek that never completes', () async {
    final originalTimeout = AudioPlayer.seekingTimeout;
    AudioPlayer.seekingTimeout = const Duration(milliseconds: 200);
    addTearDown(() => AudioPlayer.seekingTimeout = originalTimeout);
    await deck.setNetworkSource(url);
    await deck.resume();
    native.withheldSeekCompletions.add('network-output');
    final seeking = deck.seek(const Duration(seconds: 10));
    await waitUntil(() => native.calls.any((call) => call.$2 == 'seek'));
    await deck.cancelPreparation();
    await seeking.timeout(const Duration(milliseconds: 50));
    await deck.pause();
    expect(native.playing, isNot(contains('network-output')));
    // A late timeout from the abandoned platform future stays handled.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });

  test(
    'Next can replace a source while a native seek never completes',
    () async {
      final originalTimeout = AudioPlayer.seekingTimeout;
      AudioPlayer.seekingTimeout = const Duration(milliseconds: 200);
      addTearDown(() => AudioPlayer.seekingTimeout = originalTimeout);
      await deck.setNetworkSource(url);
      await deck.resume();
      native.withheldSeekCompletions.add('network-output');
      final seeking = deck.seek(const Duration(seconds: 10));
      await waitUntil(() => native.calls.any((call) => call.$2 == 'seek'));
      await deck.cancelPreparation();
      await seeking.timeout(const Duration(milliseconds: 50));
      const next = 'http://127.0.0.1:1234/next.opus';
      await deck.setNetworkSource(next);
      await deck.resume();
      expect(native.sources['network-output'], next);
      expect(native.playing, contains('network-output'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    },
  );

  String? modeBefore(int index) =>
      native.calls
              .take(index)
              .where(
                (call) =>
                    call.$1 == 'network-output' && call.$2 == 'setReleaseMode',
              )
              .lastOrNull
              ?.$3['releaseMode']
          as String?;

  test(
    'unknown-duration network stops release instead of re-preparing',
    () async {
      await deck.configureOutput();
      await deck.setNetworkSource(url);
      await deck.resume();
      // The handler configures output again before stopping the previous song.
      await deck.configureOutput();
      await deck.stop();
      final stop = native.calls.lastIndexWhere((call) => call.$2 == 'stop');
      expect(modeBefore(stop), 'ReleaseMode.release');
    },
  );

  test('pausing a network stream retains its source for resume', () async {
    await deck.setNetworkSource(url);
    await deck.resume();
    final before = native.calls
        .where((call) => call.$2 == 'setSourceUrl')
        .length;
    await deck.pause();
    await deck.resume();
    expect(
      native.calls.where((call) => call.$2 == 'setSourceUrl'),
      hasLength(before),
    );
    expect(native.playing, contains('network-output'));
  });

  test(
    'switching to a file retires HTTP before restoring file stop mode',
    () async {
      await deck.setNetworkSource(url);
      await deck.resume();
      final before = native.calls.length;
      await deck.setFileSource('/music/song.flac');
      final firstStop = native.calls.indexWhere(
        (call) => call.$2 == 'stop',
        before,
      );
      expect(modeBefore(firstStop), 'ReleaseMode.release');
      await deck.configureOutput();
      expect(modeBefore(native.calls.length), 'ReleaseMode.stop');
    },
  );
}
