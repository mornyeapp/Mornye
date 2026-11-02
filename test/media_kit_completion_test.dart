import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';

// Runs the desktop engine on the host, using the same framework folder as
// integration_test/media_kit_playback_deck_test.dart. A null audio output
// simulates a device with 700 ms of queued audio, without playing sound.
const _libmpvFolder = String.fromEnvironment('MORNYE_TEST_LIBMPV');

Uint8List _toneWav() {
  const rate = 48000;
  const frames = rate * 3;
  final data = ByteData(44 + frames * 4);
  void text(int offset, String value) {
    data.buffer.asUint8List().setRange(
      offset,
      offset + value.length,
      value.codeUnits,
    );
  }

  text(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    final sample = (math.sin(2 * math.pi * 440 * frame / rate) * 3000).round();
    data.setInt16(44 + frame * 4, sample, Endian.little);
    data.setInt16(46 + frame * 4, sample, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (_libmpvFolder.isEmpty || !Platform.isMacOS) return;
    for (final name in [
      'Avutil',
      'Swresample',
      'Swscale',
      'Mbedcrypto',
      'Mbedx509',
      'Mbedtls',
      'Avcodec',
      'Avformat',
      'Avfilter',
      'Mpv',
    ]) {
      final path =
          '$_libmpvFolder/$name.xcframework/macos-arm64_x86_64/'
          '$name.framework/Versions/A/$name';
      DynamicLibrary.open(path);
      if (name == 'Mpv') MediaKit.ensureInitialized(libmpv: path);
    }
  });

  for (final rate in [1.0, 2.0]) {
    test(
      'completion waits for the audio output buffer at ${rate}x speed',
      () async {
        final directory = await Directory.systemTemp.createTemp('mpv-tail-');
        final source = File('${directory.path}/tone.wav');
        await source.writeAsBytes(_toneWav());
        final engine = MediaKitEngine();
        final deck = MediaKitPlaybackDeck(
          playerId: 'tail-test',
          engine: engine,
        );
        final completed = Completer<void>();
        final clock = Stopwatch();
        Duration? finishedAt;
        final subscription = deck.onPlayerComplete.listen((_) {
          finishedAt ??= clock.elapsed;
          if (!completed.isCompleted) completed.complete();
        });
        try {
          for (final (name, value) in [
            ('ao', 'null'),
            ('ao-null-buffer', '0.7'),
          ]) {
            expect(
              await engine.setProperty(name, value),
              greaterThanOrEqualTo(0),
            );
          }
          await deck.setFileSource(source.path);
          await deck.setPlaybackRate(rate);
          clock.start();
          await deck.resume();
          await completed.future.timeout(const Duration(seconds: 8));
          expect(
            finishedAt!.inMilliseconds,
            greaterThanOrEqualTo((3000 / rate).round() - 100),
            reason:
                'EOF must follow audible playback, including the queued tail',
          );
        } finally {
          await subscription.cancel();
          await deck.dispose();
          await directory.delete(recursive: true);
        }
      },
      skip: _libmpvFolder.isEmpty || !Platform.isMacOS
          ? 'Requires MORNYE_TEST_LIBMPV with the signed macOS audio frameworks'
          : false,
    );
  }

  test(
    'native playlist joins tracks without cutting the buffered tail',
    () async {
      final directory = await Directory.systemTemp.createTemp('mpv-gapless-');
      final first = File('${directory.path}/first.wav');
      final second = File('${directory.path}/second.wav');
      final third = File('${directory.path}/third.wav');
      await first.writeAsBytes(_toneWav());
      await second.writeAsBytes(_toneWav());
      await third.writeAsBytes(_toneWav());
      final engine = MediaKitEngine();
      final deck = MediaKitPlaybackDeck(
        playerId: 'gapless-test',
        engine: engine,
      );
      final next = Completer<void>();
      final last = Completer<void>();
      final done = Completer<void>();
      final subscriptions = [
        deck.onPlayerComplete.listen((_) {
          if (!done.isCompleted) done.complete();
        }),
      ];
      final clock = Stopwatch();
      try {
        expect(await engine.setProperty('ao', 'null'), greaterThanOrEqualTo(0));
        expect(
          await engine.setProperty('ao-null-buffer', '0.7'),
          greaterThanOrEqualTo(0),
        );
        await deck.setFileSource(first.path);
        expect(
          await deck.queueNextSource(
            second.path,
            volume: 1,
            onStarted: () {
              if (!next.isCompleted) next.complete();
            },
          ),
          isTrue,
        );
        clock.start();
        await deck.resume();
        await next.future.timeout(const Duration(seconds: 5));
        expect(done.isCompleted, isFalse);
        expect(deck.state, PlaybackDeckState.playing);
        expect(await engine.getProperty('path'), second.path);
        expect(
          await deck.queueNextSource(
            third.path,
            volume: 0.5,
            onStarted: () {
              if (!last.isCompleted) last.complete();
            },
          ),
          isTrue,
        );
        await last.future.timeout(const Duration(seconds: 5));
        expect(await engine.getProperty('path'), third.path);
        expect(await engine.getProperty('playlist-count'), '2');
        await done.future.timeout(const Duration(seconds: 5));
        expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(8900));
        expect(clock.elapsedMilliseconds, lessThan(9800));
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await deck.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: _libmpvFolder.isEmpty || !Platform.isMacOS,
  );

  test(
    'unreadable LRC sidecars cannot prevent their audio from playing',
    () async {
      final directory = await Directory.systemTemp.createTemp('mpv-sidecar-');
      final engine = MediaKitEngine();
      final deck = MediaKitPlaybackDeck(
        playerId: 'sidecar-test',
        engine: engine,
      );
      final diagnostics = <MpvLogError>[];
      final subscription = engine.errors.listen(diagnostics.add);
      try {
        expect(await engine.setProperty('ao', 'null'), greaterThanOrEqualTo(0));
        for (final name in ['Song', '100% Song']) {
          final source = File('${directory.path}/$name.wav');
          final lyrics = File('${directory.path}/$name.lrc');
          await source.writeAsBytes(_toneWav());
          await lyrics.writeAsString('This is not a supported subtitle stream');
          await deck.setFileSource(source.path);
          await deck.resume();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(
            (await deck.getCurrentPosition())!.inMilliseconds,
            greaterThan(100),
          );
          await deck.pause();
          expect(
            await lyrics.readAsString(),
            'This is not a supported subtitle stream',
          );
        }
        expect(
          diagnostics.where((error) => error.text.contains('.lrc')),
          isEmpty,
        );
      } finally {
        await subscription.cancel();
        await deck.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: _libmpvFolder.isEmpty || !Platform.isMacOS
        ? 'Requires MORNYE_TEST_LIBMPV with the signed macOS audio frameworks'
        : false,
  );
}
