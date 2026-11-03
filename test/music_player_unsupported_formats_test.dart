import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/music_player_automix_harness.dart';

/// A macOS player (AVPlayer, like iOS) whose FFmpeg [convert] stands in.
class _Player {
  _Player({
    required Future<bool> Function(List<String>) convert,
    required Directory copies,
    bool gapless = false,
    bool avPlayer = true,
  }) : this._(convert, copies, gapless, avPlayer, []);

  _Player._(
    Future<bool> Function(List<String>) convert,
    Directory copies,
    bool gapless,
    bool avPlayer,
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

  setUp(() async {
    native = AudioNative()..install();
    folder = await Directory.systemTemp.createTemp('unsupported-formats-');
    addTearDown(() => folder.delete(recursive: true));
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
  }) async {
    final player = _Player(
      convert: convert,
      copies: Directory('${folder.path}/copies'),
      gapless: gapless,
      avPlayer: avPlayer,
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

  test('a missing file keeps the ordinary failure', () async {
    final gone = await song('one.ape');
    await File(gone.source).delete();
    native.sourceFailures.add(gone.source);
    final p = await player(convert: (_) async => false);
    await p.handler.setQueueAndPlay([gone, await song('two.flac')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(p.notices, isEmpty);
    expect(p.handler.mediaItem.value?.id, 'one.ape');
    expect(
      p.handler.playbackState.value.processingState,
      AudioProcessingState.error,
    );
  });

  test('other engines neither copy nor skip', () async {
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
  });

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
