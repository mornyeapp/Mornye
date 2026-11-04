import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/desktop_platform.dart';

// Run on a Windows device with an output that supports exclusive mode:
// flutter test integration_test/wasapi_exclusive_playback_test.dart -d windows
// Keep the actual WASAPI driver and endpoint, with the test tone muted.
Uint8List _toneWav(int sampleRate) {
  const channels = 2;
  final frames = sampleRate * 12;
  final dataBytes = frames * channels * 2;
  final bytes = ByteData(44 + dataBytes);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < frames; i++) {
    final value = (math.sin(2 * math.pi * 440 * i / sampleRate) * 3276).round();
    for (var channel = 0; channel < channels; channel++) {
      bytes.setInt16(44 + (i * channels + channel) * 2, value, Endian.little);
    }
  }
  return bytes.buffer.asUint8List();
}

Future<void> _expectNormalSpeed(MediaKitPlaybackDeck deck) async {
  final before = (await deck.getCurrentPosition())!;
  final elapsed = Stopwatch()..start();
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  final after = (await deck.getCurrentPosition())!;
  elapsed.stop();
  expect(
    (after - before).inMicroseconds / elapsed.elapsedMicroseconds,
    closeTo(1, 0.15),
    reason: 'The audio clock must advance at normal speed',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (!Platform.isWindows) return;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    debugDesktopPlatformOverride = true;
    MediaKit.ensureInitialized();
  });
  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
  });

  for (final sampleRate in [44100, 48000]) {
    testWidgets(
      'WASAPI exclusive plays at normal speed after resets ($sampleRate Hz)',
      (tester) async {
        final directory = await Directory.systemTemp.createTemp('wasapi-');
        final source = File('${directory.path}/tone.wav');
        await source.writeAsBytes(_toneWav(sampleRate));
        playbackExclusiveOutput.value = true;
        final deck = MediaKitPlaybackDeck(playerId: 'wasapi-$sampleRate');
        final failures = <Object>[];
        final subscription = deck.onPlayerStateChanged.listen(
          (_) {},
          onError: failures.add,
        );
        try {
          await deck.configureOutput();
          await deck.setVolume(0);
          await deck.setFileSource(source.path);
          await deck.resume();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(await deck.debugProperty('current-ao'), 'wasapi');
          expect(await deck.debugProperty('wasapi-exclusive-buffer'), 'min');
          expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.active);
          await _expectNormalSpeed(deck);

          for (var attempt = 0; attempt < 3; attempt++) {
            await deck.pause();
            final paused = (await deck.getCurrentPosition())!;
            await Future<void>.delayed(const Duration(milliseconds: 250));
            expect(
              ((await deck.getCurrentPosition())! - paused).inMilliseconds
                  .abs(),
              lessThan(150),
            );
            await deck.resume();
            await deck.seek(const Duration(seconds: 2));
            await Future<void>.delayed(const Duration(milliseconds: 150));
            await _expectNormalSpeed(deck);
            expect(playbackExclusiveStatus.value, ExclusiveOutputStatus.active);
          }
          expect(failures, isEmpty);
        } finally {
          await subscription.cancel();
          await deck.dispose();
          playbackExclusiveOutput.value = false;
          playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;
          await directory.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
