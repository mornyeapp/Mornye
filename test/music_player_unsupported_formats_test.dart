import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/music_player_automix_harness.dart';

/// A player with native source failures and an optional FFmpeg stand-in.
class _Player {
  _Player({
    required Future<bool> Function(List<String>) convert,
    required Directory copies,
    bool gapless = false,
    bool avPlayer = true,
    bool android = false,
    Future<String?> Function(String)? recoverMissingFile,
  }) : this._(
         convert,
         copies,
         gapless,
         avPlayer,
         android,
         recoverMissingFile,
         [],
       );

  _Player._(
    Future<bool> Function(List<String>) convert,
    Directory copies,
    bool gapless,
    bool avPlayer,
    bool android,
    Future<String?> Function(String)? recoverMissingFile,
    this.conversions,
  ) : runtime = MusicPlayerRuntime(
        settings: const AppSettings().copyWith(
          musicHaptics: false,
          autoMix: false,
          gaplessPlayback: gapless,
          pauseOnMute: false,
          autoplay: false,
        ),
        dependencies: PlaybackDependencies(
          isMacOS: avPlayer,
          isAndroid: android,
          synchronizePlaybackState: () async {},
          recoverMissingFile: recoverMissingFile ?? (_) async => null,
          recoverMovedDownload: (_, _, _) async => null,
          convertAudio: (arguments) {
            conversions.add(arguments);
            return convert(arguments);
          },
          playbackCopies: copies,
        ),
      ) {
    handler = MusicPlayerHandler(
      runtime: runtime,
      autoMixAnalyzer: FakeAutoMixAnalyzer(),
      autoMixEffectRenderer: FakeEffectRenderer(),
      hapticsAnalyzer: FakeHapticsAnalyzer(),
      hapticPulse: (_, _) async {},
    );
    _subscription = runtime.unplayableSongs.listen(notices.add);
  }

  final MusicPlayerRuntime runtime;
  late final MusicPlayerHandler handler;
  final List<List<String>> conversions;
  final notices = <UnplayableSong>[];
  late final StreamSubscription<UnplayableSong> _subscription;

  Future<void> dispose() async {
    await handler.dispose();
    await _subscription.cancel();
    await runtime.dispose();
  }
}

/// Writes FFmpeg's output file, the argument before the trailing `-y`.
Future<bool> _convert(List<String> arguments) async {
  await File(arguments[arguments.length - 2]).writeAsBytes([1, 2, 3]);
  return true;
}

String _output(List<String> arguments) => arguments[arguments.length - 2];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late AudioNative native;
  late Directory folder;
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    native = AudioNative()..install();
    folder = await Directory.systemTemp.createTemp('unsupported-formats-');
    addTearDown(() => folder.delete(recursive: true));
    addTearDown(() => messenger.setMockMethodCallHandler(backend, null));
  });

  Future<PlayableMedia> song(String name, {String? format}) async {
    final path = '${folder.path}/$name';
    await File(path).writeAsBytes([0]);
    return PlayableMedia(
      id: name,
      source: path,
      title: name,
      artist: 'Artist',
      format: format,
    );
  }

  Future<_Player> player({
    Future<bool> Function(List<String>) convert = _convert,
    bool gapless = false,
    bool avPlayer = true,
    bool android = false,
    Future<String?> Function(String)? recoverMissingFile,
  }) async {
    if (android) {
      const channel = MethodChannel(
        'com.ryanheise.audio_service.handler.methods',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final player = _Player(
      convert: convert,
      copies: Directory('${folder.path}/copies'),
      gapless: gapless,
      avPlayer: avPlayer,
      android: android,
      recoverMissingFile: recoverMissingFile,
    );
    addTearDown(() async {
      await player.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(native.live, isEmpty);
    });
    return player;
  }

  test('an APE song plays from a FLAC copy', () async {
    final ape = await song('one.ape');
    native.sourceFailures.add(ape.source);
    final p = await player();
    await p.handler.setQueueAndPlay([ape, await song('two.flac')]);

    expect(p.conversions, hasLength(1));
    expect(p.conversions.single, containsAllInOrder(['-i', ape.source]));
    final copy = _output(p.conversions.single);
    expect(native.resumedSources, [copy]);
    expect(p.handler.playbackState.value.playing, isTrue);
    expect(p.handler.mediaItem.value?.id, 'one.ape');
    expect(p.notices, isEmpty);
  });

  test('a song AVPlayer refuses plays from a copy made after', () async {
    // AVPlayer needs an extension to open a local file.
    final odd = await song('one', format: 'flac');
    native.sourceFailures.add(odd.source);
    final p = await player();
    await p.handler.setQueueAndPlay([odd]);

    expect(p.conversions, hasLength(1));
    expect(native.resumedSources, [_output(p.conversions.single)]);
    expect(p.handler.playbackState.value.errorMessage, isNull);

    // Playing it again uses the same copy at once.
    await p.handler.skipToQueueItem(0);
    expect(p.conversions, hasLength(1));
    expect(native.resumedSources.last, _output(p.conversions.single));
  });

  test('unplayable songs name their format and give way', () async {
    final ape = await song('one.ape');
    final wavPack = await song('two.wv');
    final flac = await song('three.flac');
    native.sourceFailures.addAll([ape.source, wavPack.source]);
    final p = await player(convert: (_) async => false);
    await p.handler.setQueueAndPlay([ape, wavPack, flac]);
    await waitUntil(() => p.handler.mediaItem.value?.id == 'three.flac');
    await waitUntil(() => native.resumedSources.isNotEmpty);

    expect(p.notices, [
      (format: 'APE', skipped: true),
      (format: 'WavPack', skipped: true),
    ]);
    expect(native.resumedSources, [flac.source]);
    expect(p.handler.playbackState.value.playing, isTrue);
    expect(p.handler.playbackState.value.errorMessage, isNull);
  });

  test('a queue of unplayable songs stops after one pass', () async {
    final songs = [
      await song('one.ape'),
      await song('two.dsf'),
      await song('three.wv'),
    ];
    native.sourceFailures.addAll(songs.map((song) => song.source));
    final p = await player(convert: (_) async => false);
    await p.handler.setRepeatMode(AudioServiceRepeatMode.all);
    await p.handler.setQueueAndPlay(songs);
    await waitUntil(
      () =>
          p.handler.playbackState.value.processingState ==
          AudioProcessingState.error,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(p.notices, [
      (format: 'APE', skipped: true),
      (format: 'DSF', skipped: true),
      (format: 'WavPack', skipped: false),
    ]);
    expect(p.handler.mediaItem.value?.id, 'three.wv');
    expect(p.handler.playbackState.value.playing, isFalse);
    expect(native.resumedSources, isEmpty);

    // Choosing a song again starts a new run.
    await p.handler.skipToQueueItem(0);
    await waitUntil(() => p.notices.length == 6);
  });

  test('the last unplayable song stops with its format named', () async {
    final ape = await song('one.ape');
    native.sourceFailures.add(ape.source);
    final p = await player(convert: (_) async => false);
    await p.handler.setQueueAndPlay([ape]);
    await waitUntil(() => p.notices.isNotEmpty);

    expect(p.notices, [(format: 'APE', skipped: false)]);
    expect(
      p.handler.playbackState.value.processingState,
      AudioProcessingState.error,
    );
  });

  test('a missing file skips without an unsupported format notice', () async {
    final gone = await song('one.ape');
    await File(gone.source).delete();
    native.sourceFailures.add(gone.source);
    final p = await player(convert: (_) async => false);
    await p.handler.setQueueAndPlay([gone, await song('two.flac')]);
    await waitUntil(() => native.resumedSources.isNotEmpty);

    expect(p.notices, isEmpty);
    expect(p.handler.mediaItem.value?.id, 'two.flac');
    expect(p.handler.playbackState.value.errorMessage, isNull);
  });

  test(
    'Android advances past a deleted song after the previous one ends',
    () async {
      final first = await song('first.flac');
      final gone = await song('gone.flac');
      final last = await song('last.flac');
      await File(gone.source).delete();
      native.sourceFailures.add(gone.source);
      final p = await player(android: true, avPlayer: false);
      await p.handler.setQueueAndPlay([first, gone, last]);
      await native.complete('music-player');
      await waitUntil(() => native.resumedSources.length == 2);

      expect(native.resumedSources, [first.source, last.source]);
      expect(p.handler.mediaItem.value?.id, last.id);
      expect(p.handler.playbackState.value.errorMessage, isNull);
      expect(p.handler.queue.value.map((item) => item.id), [
        first.id,
        gone.id,
        last.id,
      ]);
      expect(p.notices, isEmpty);
    },
  );

  test(
    'confirmed missing songs do not use the format conversion limit',
    () async {
      final missing = <PlayableMedia>[];
      for (var i = 0; i < 12; i++) {
        final gone = await song('gone-$i.flac');
        await File(gone.source).delete();
        missing.add(gone);
      }
      native.sourceFailures.addAll(missing.map((song) => song.source));
      final last = await song('last.flac');
      final p = await player(avPlayer: false);
      await p.handler.setQueueAndPlay([...missing, last]);
      await waitUntil(() => native.resumedSources.isNotEmpty);

      expect(native.resumedSources, [last.source]);
      expect(p.handler.playbackState.value.errorMessage, isNull);
    },
  );

  test(
    'an entirely missing queue stops after one pass in repeat all',
    () async {
      final missing = [await song('one.flac'), await song('two.flac')];
      for (final media in missing) {
        await File(media.source).delete();
        native.sourceFailures.add(media.source);
      }
      final p = await player(avPlayer: false);
      await p.handler.setRepeatMode(AudioServiceRepeatMode.all);
      await p.handler.setQueueAndPlay(missing, initialIndex: 1);
      await waitUntil(
        () =>
            p.handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final opened = native.calls
          .where((call) => call.$2 == 'setSourceUrl')
          .map((call) => call.$3['url']);
      expect(opened, [missing[1].source, missing[0].source]);
      expect(p.handler.playbackState.value.playing, isFalse);
      expect(native.resumedSources, isEmpty);

      // A repaired file is playable on the next explicit attempt.
      await File(missing[0].source).writeAsBytes([0]);
      native.sourceFailures.remove(missing[0].source);
      await p.handler.play();
      expect(native.resumedSources, [missing[0].source]);
    },
  );

  test('repeat one does not advance or retry a missing song forever', () async {
    final gone = await song('gone.flac');
    await File(gone.source).delete();
    native.sourceFailures.add(gone.source);
    final p = await player(avPlayer: false);
    await p.handler.setRepeatMode(AudioServiceRepeatMode.one);
    await p.handler.setQueueAndPlay([gone, await song('next.flac')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(p.handler.mediaItem.value?.id, gone.id);
    expect(
      p.handler.playbackState.value.processingState,
      AudioProcessingState.error,
    );
    expect(native.resumedSources, isEmpty);
    expect(
      native.calls.where((call) => call.$2 == 'setSourceUrl'),
      hasLength(1),
    );
  });

  test(
    'a recovered local file plays before considering a missing skip',
    () async {
      final gone = await song('gone.flac');
      final recovered = await song('recovered.flac');
      await File(gone.source).delete();
      native.sourceFailures.add(gone.source);
      final p = await player(
        avPlayer: false,
        recoverMissingFile: (path) async =>
            path == gone.source ? recovered.source : null,
      );
      await p.handler.setQueueAndPlay([gone, await song('next.flac')]);

      expect(p.handler.mediaItem.value?.id, gone.id);
      expect(native.resumedSources, [recovered.source]);
      expect(p.handler.playbackState.value.errorMessage, isNull);
    },
  );

  for (final status in [
    'missing',
    'found',
    'permission_denied',
    'provider_unavailable',
  ]) {
    test('Android SAF skips only confirmed absence: $status', () async {
      const source = 'content://example.documents/document/track.flac';
      final probes = <String>[];
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'safStat') return null;
        final arguments = call.arguments as Map<Object?, Object?>;
        probes.add(arguments['uri']! as String);
        if (status == 'missing') return '{"exists":false}';
        if (status == 'found') return '{"exists":true}';
        throw PlatformException(code: status);
      });
      final p = await player(android: true, avPlayer: false);
      final next = await song('next.flac');
      await p.handler.setQueueAndPlay([
        PlayableMedia(
          id: 'saf-song',
          source: source,
          title: 'Song',
          artist: 'Artist',
        ),
        next,
      ]);
      if (status == 'missing') {
        await waitUntil(() => native.resumedSources.isNotEmpty);
        expect(native.resumedSources, [next.source]);
        expect(p.handler.playbackState.value.errorMessage, isNull);
      } else {
        expect(native.resumedSources, isEmpty);
        expect(p.handler.mediaItem.value?.id, 'saf-song');
        expect(
          p.handler.playbackState.value.processingState,
          AudioProcessingState.error,
        );
      }
      expect(probes, contains(source));
    });
  }

  test(
    'pausing during a missing-file check cancels automatic advancement',
    () async {
      final probing = Completer<void>();
      final result = Completer<String>();
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'safStat') return null;
        if (!probing.isCompleted) probing.complete();
        return result.future;
      });
      final p = await player(android: true, avPlayer: false);
      final next = await song('next.flac');
      final opening = p.handler.setQueueAndPlay([
        PlayableMedia(
          id: 'saf-song',
          source: 'content://example.documents/document/gone.flac',
          title: 'Song',
          artist: 'Artist',
        ),
        next,
      ]);
      await probing.future;
      final pausing = p.handler.pause();
      result.complete('{"exists":false}');
      await Future.wait([opening, pausing]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(p.handler.mediaItem.value?.id, 'saf-song');
      expect(p.handler.playbackState.value.playing, isFalse);
      expect(p.handler.playbackState.value.errorMessage, isNull);
      expect(native.resumedSources, isEmpty);
    },
  );

  test(
    'mixed missing and unplayable songs share one failing repeat pass',
    () async {
      final songs = [
        await song('one.ape'),
        await song('missing.flac'),
        await song('three.wv'),
      ];
      await File(songs[1].source).delete();
      native.sourceFailures.addAll(songs.map((song) => song.source));
      final p = await player(convert: (_) async => false);
      await p.handler.setRepeatMode(AudioServiceRepeatMode.all);
      await p.handler.setQueueAndPlay(songs);
      await waitUntil(
        () =>
            p.handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(p.notices, [
        (format: 'APE', skipped: true),
        (format: 'WavPack', skipped: false),
      ]);
      expect(p.handler.mediaItem.value?.id, 'three.wv');
      expect(native.resumedSources, isEmpty);
    },
  );

  test(
    'other engines do not copy or skip an existing unplayable file',
    () async {
      final ape = await song('one.ape');
      native.sourceFailures.add(ape.source);
      final p = await player(avPlayer: false);
      await p.handler.setQueueAndPlay([ape, await song('two.flac')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(p.conversions, isEmpty);
      expect(p.notices, isEmpty);
      expect(p.handler.mediaItem.value?.id, 'one.ape');
      expect(
        p.handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
    },
  );

  test('gapless playback prepares the next song from its copy', () async {
    final flac = await song('one.flac');
    final ape = await song('two.ape');
    native.sourceFailures.add(ape.source);
    final p = await player(gapless: true);
    await p.handler.setQueueAndPlay([flac, ape]);
    await waitUntil(() => p.handler.mediaItem.value?.duration != null);
    await p.handler.seek(const Duration(seconds: 45));
    await waitUntil(() => p.conversions.length == 1);
    final copy = _output(p.conversions.single);
    await waitUntil(
      () => native.live.any(
        (id) => id.startsWith('music-gapless-') && native.sources[id] == copy,
      ),
    );

    await native.complete('music-player');
    await waitUntil(() => p.handler.mediaItem.value?.id == 'two.ape');
    expect(native.resumedSources, [flac.source, copy]);
    expect(await File(copy).exists(), isTrue);
  });
}
