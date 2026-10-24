import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/preview_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/playback_deck.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer previews(MusicPlayerRuntime runtime) => ProviderContainer(
    overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
  );

  test('preview ownership stays within its playback runtime', () async {
    final firstRuntime = MusicPlayerRuntime();
    final secondRuntime = MusicPlayerRuntime();
    final first = previews(firstRuntime);
    final second = previews(secondRuntime);
    first.read(previewPlayerProvider);
    second.read(previewPlayerProvider);
    final secondHook = secondRuntime.exclusiveAudioHook;

    expect(firstRuntime.exclusiveAudioHook, isNotNull);
    expect(secondHook, isNotNull);
    expect(firstRuntime.exclusiveAudioHook, isNot(same(secondHook)));
    first.dispose();
    expect(firstRuntime.exclusiveAudioHook, isNull);
    expect(secondRuntime.exclusiveAudioHook, same(secondHook));
    second.dispose();
    expect(secondRuntime.exclusiveAudioHook, isNull);
    await firstRuntime.dispose();
    await secondRuntime.dispose();
  });

  test('disposing an old preview preserves the new audio owner', () async {
    final runtime = MusicPlayerRuntime();
    final first = previews(runtime);
    final second = previews(runtime);
    first.read(previewPlayerProvider);
    final firstHook = runtime.exclusiveAudioHook;
    second.read(previewPlayerProvider);
    final secondHook = runtime.exclusiveAudioHook;

    expect(firstHook, isNot(same(secondHook)));
    first.dispose();
    expect(runtime.exclusiveAudioHook, same(secondHook));
    second.dispose();
    expect(runtime.exclusiveAudioHook, isNull);
    await runtime.dispose();
  });

  test('previews play through the runtime preview deck', () async {
    final decks = <_PreviewDeck>[];
    final runtime = MusicPlayerRuntime(
      dependencies: PlaybackDependencies(
        createPreviewDeck: (id) {
          expect(id, 'preview-player');
          final deck = _PreviewDeck();
          decks.add(deck);
          return deck;
        },
      ),
    );
    final container = previews(runtime);
    final controller = container.read(previewPlayerProvider.notifier);

    await controller.play('https://example.com/preview.mp3');
    final deck = decks.single;
    expect(deck.calls, [
      'positions',
      'volume 1.0',
      'network https://example.com/preview.mp3',
      'resume',
    ]);
    deck.states.add(PlaybackDeckState.playing);
    deck.positions.add(const Duration(seconds: 4));
    deck.durations.add(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);
    var state = container.read(previewPlayerProvider);
    expect(state.status, PreviewStatus.playing);
    expect(state.position, const Duration(seconds: 4));
    expect(state.duration, const Duration(seconds: 30));

    await controller.toggle('https://example.com/preview.mp3');
    expect(deck.calls.last, 'pause');
    expect(container.read(previewPlayerProvider).status, PreviewStatus.paused);

    deck.completions.add(null);
    await Future<void>.delayed(Duration.zero);
    state = container.read(previewPlayerProvider);
    expect(state.isActive, isFalse);

    container.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(deck.calls.last, 'dispose');
    await runtime.dispose();
  });

  group('deferred preview links', () {
    const backend = MethodChannel('com.zarz.mornye/backend');
    const link = 'mornye-preview:example-provider/track%2F1';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(backend, null));

    test('resolve through their extension before playback', () async {
      final actions = <MethodCall>[];
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'invokeExtensionAction') return null;
        actions.add(call);
        return '{"preview_url":"https://example.com/sample.mp3"}';
      });
      final deck = _PreviewDeck();
      final runtime = MusicPlayerRuntime(
        dependencies: PlaybackDependencies(createPreviewDeck: (_) => deck),
      );
      final container = previews(runtime);

      await container.read(previewPlayerProvider.notifier).play(link);
      final arguments = actions.single.arguments as Map;
      expect(arguments['extension_id'], 'example-provider');
      expect(arguments['action'], 'resolvePreview');
      expect(jsonDecode(arguments['arguments_json'] as String), [
        {'id': 'track/1'},
      ]);
      expect(deck.calls, contains('network https://example.com/sample.mp3'));
      expect(container.read(previewPlayerProvider).isActiveUrl(link), isTrue);

      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await runtime.dispose();
    });

    test('fail before playback without a playable URL', () async {
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'invokeExtensionAction') return null;
        return '{"preview_url":""}';
      });
      final decks = <_PreviewDeck>[];
      final runtime = MusicPlayerRuntime(
        dependencies: PlaybackDependencies(
          createPreviewDeck: (_) {
            final deck = _PreviewDeck();
            decks.add(deck);
            return deck;
          },
        ),
      );
      final container = previews(runtime);

      await expectLater(
        container.read(previewPlayerProvider.notifier).play(link),
        throwsStateError,
      );
      expect(decks, isEmpty);
      expect(container.read(previewPlayerProvider).isActive, isFalse);

      container.dispose();
      await runtime.dispose();
    });
  });
}

class _PreviewDeck implements PlaybackDeck {
  final calls = <String>[];
  final states = StreamController<PlaybackDeckState>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final completions = StreamController<void>.broadcast();

  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => states.stream;
  @override
  Stream<Duration> get onDurationChanged => durations.stream;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<void> get onPlayerComplete => completions.stream;
  @override
  void startPositionUpdates(Duration interval) => calls.add('positions');
  @override
  Future<void> configureOutput() async => calls.add('configure');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> setPlaybackRate(double rate) async => calls.add('rate $rate');
  @override
  Future<void> setNetworkSource(String url) async => calls.add('network $url');
  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async => calls.add('file $path');
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration position) async => calls.add('seek');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override
  Future<Duration?> getDuration() async => null;
  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await states.close();
    await durations.close();
    await positions.close();
    await completions.close();
  }
}
