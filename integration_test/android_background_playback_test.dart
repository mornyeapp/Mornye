import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/playback_deck.dart';

class _SessionStore implements AppStateDatabase {
  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {}

  @override
  Future<void> clearPlaybackSession() async {}

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _silentWav() {
  final wav = Uint8List(44 + 44100 * 2 * 90);
  final data = ByteData.sublistView(wav);
  wav.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, wav.length - 8, Endian.little);
  wav.setRange(8, 16, 'WAVEfmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 88200, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  wav.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, wav.length - 44, Endian.little);
  return wav;
}

/// Run with android_background_playback_driver.dart on a dedicated emulator.
/// The driver backgrounds the activity and turns off the screen using adb.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local playback survives screen off and background resume', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final directory = await Directory.systemTemp.createTemp(
      'background-audio-',
    );
    final file = await File(
      '${directory.path}/silence.wav',
    ).writeAsBytes(_silentWav());
    late PlaybackDeck deck;
    final runtime = MusicPlayerRuntime(
      settings: const AppSettings(
        pauseOnMute: false,
        autoplayPersonalization: false,
      ),
      dependencies: PlaybackDependencies(
        createDeck: (id) => deck = const PlaybackDependencies().createDeck(id),
        sessionDatabase: _SessionStore(),
        recorder: ListeningRecorder(
          write: (_) async {},
          elapsed: () => Duration.zero,
          now: DateTime.now,
        ),
      ),
    );
    try {
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([
        PlayableMedia(
          id: 'background-audio',
          source: file.path,
          title: 'Background playback test',
          artist: 'Test fixture',
          duration: const Duration(seconds: 90),
        ),
      ]);
      await Future<void>.delayed(const Duration(seconds: 2));
      final before = (await deck.getCurrentPosition())!;
      expect(before, greaterThan(const Duration(milliseconds: 500)));
      // ignore: avoid_print
      print('BACKGROUND_READY');
      await Future<void>.delayed(const Duration(seconds: 15));
      expect(binding.lifecycleState, AppLifecycleState.paused);
      final background = (await deck.getCurrentPosition())!;
      expect(background - before, greaterThan(const Duration(seconds: 12)));
      expect(handler.playbackState.value.playing, isTrue);

      await handler.pause();
      await AudioService.synchronizePlaybackState();
      final paused = (await deck.getCurrentPosition())!;
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(
        ((await deck.getCurrentPosition())! - paused).abs(),
        lessThan(const Duration(milliseconds: 100)),
      );
      // ignore: avoid_print
      print('BACKGROUND_RESUMING');
      await handler.play();
      await Future<void>.delayed(const Duration(seconds: 8));
      final resumed = (await deck.getCurrentPosition())!;
      expect(resumed - paused, greaterThan(const Duration(seconds: 6)));
      expect(handler.playbackState.value.playing, isTrue);
      binding.reportData = {
        'before_ms': before.inMilliseconds,
        'background_ms': background.inMilliseconds,
        'paused_ms': paused.inMilliseconds,
        'resumed_ms': resumed.inMilliseconds,
      };
    } finally {
      final handler = runtime.handler;
      if (handler != null) {
        await handler.stop();
        await AudioService.synchronizePlaybackState();
      }
      await runtime.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isAndroid);
}
