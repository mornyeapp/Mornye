import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
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
      // The extension has no preview for it: the button is not offered again.
      expect(container.read(previewUnavailableLinksProvider), {link});

      container.dispose();
      await runtime.dispose();
    });
  });

  group('a link that expired', () {
    const old = 'https://example.com/old.mp3';
    const current = 'https://example.com/current.mp3';

    (ProviderContainer, List<_PreviewDeck>, MusicPlayerRuntime) expired() {
      final decks = <_PreviewDeck>[];
      final runtime = MusicPlayerRuntime(
        dependencies: PlaybackDependencies(
          createPreviewDeck: (_) {
            final deck = _PreviewDeck(dead: {old});
            decks.add(deck);
            return deck;
          },
        ),
      );
      return (previews(runtime), decks, runtime);
    }

    test('plays the link its extension has now', () async {
      final (container, decks, runtime) = expired();
      final controller = container.read(previewPlayerProvider.notifier);
      var reads = 0;
      Future<String?> refresh() async {
        reads++;
        return current;
      }

      await controller.play(old, refresh: refresh);
      expect(reads, 1);
      expect(decks, hasLength(2));
      expect(decks.last.calls, contains('network $current'));
      // The button of the song still owns the preview.
      expect(container.read(previewPlayerProvider).isActiveUrl(old), isTrue);
      expect(container.read(previewUnavailableLinksProvider), isEmpty);

      // The next play starts from the link that works.
      await controller.stop();
      await controller.play(old, refresh: refresh);
      expect(reads, 1);
      expect(decks, hasLength(2));
      expect(decks.last.calls.where((call) => call == 'network $old'), isEmpty);

      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await runtime.dispose();
    });

    test('is not offered again when nothing newer plays', () async {
      final (container, decks, runtime) = expired();

      await expectLater(
        container
            .read(previewPlayerProvider.notifier)
            .play(old, refresh: () async => old),
        throwsStateError,
      );
      expect(decks, hasLength(2));
      expect(container.read(previewPlayerProvider).isActive, isFalse);
      expect(container.read(previewUnavailableLinksProvider), {old});

      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await runtime.dispose();
    });

    test('stays offered when its extension could not be asked', () async {
      final (container, _, runtime) = expired();

      await expectLater(
        container
            .read(previewPlayerProvider.notifier)
            .play(old, refresh: () async => throw Exception('offline')),
        throwsStateError,
      );
      expect(container.read(previewUnavailableLinksProvider), isEmpty);

      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await runtime.dispose();
    });
  });

  group('reading a preview link again', () {
    const backend = MethodChannel('com.zarz.mornye/backend');
    const old = 'https://e.test/old.mp3';
    const song = Track(
      id: 'song-1',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
      isrc: 'AA0000000001',
      source: 'example-provider',
      previewUrl: old,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> searches;

    /// Answers the song's own extension with [own] and a search of every
    /// extension with [others]; null fails that search.
    Future<String?> Function(Track track) refresher({
      List<Map<String, Object?>>? own = const [],
      List<Map<String, Object?>>? others = const [],
    }) {
      searches = [];
      messenger.setMockMethodCallHandler(backend, (call) async {
        final results = switch (call.method) {
          'searchTracksWithMetadataProvider' => own,
          'searchTracksWithMetadataProviders' => others,
          _ => const <Map<String, Object?>>[],
        };
        searches.add(call);
        if (results == null) throw PlatformException(code: 'offline');
        return jsonEncode(results);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(backend, null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return container.read(previewLinkRefreshProvider);
    }

    test('asks the song\'s own extension first', () async {
      final refresh = refresher(
        own: [
          {'id': 'other', 'name': 'Song', 'preview_url': 'https://e.test/a'},
          {'id': 'song-1', 'name': 'Song', 'preview_url': 'https://e.test/b'},
        ],
      );

      expect(await refresh(song), 'https://e.test/b');
      final arguments = searches.single.arguments as Map;
      expect(arguments['extension_id'], 'example-provider');
      expect(arguments['query'], 'Song Artist');
    });

    test('takes the same song from any other extension', () async {
      // Its own extension has no preview of its own, or the dead one again.
      for (final own in [
        <Map<String, Object?>>[
          {'id': 'song-1', 'name': 'Song'},
        ],
        <Map<String, Object?>>[
          {'id': 'song-1', 'name': 'Song', 'preview_url': old},
        ],
      ]) {
        final refresh = refresher(
          own: own,
          others: [
            {
              'id': 'x1',
              'name': 'Song',
              'artists': 'Artist',
              'isrc': 'AA0000000002',
              'provider_id': 'second-provider',
              'preview_url': 'https://e.test/another-recording',
            },
            {
              'id': 'x2',
              'name': 'Song (Remastered)',
              'artists': 'Artist',
              'isrc': 'aa0000000001',
              'provider_id': 'second-provider',
              'preview_url': 'https://e.test/same-recording',
            },
          ],
        );

        expect(await refresh(song), 'https://e.test/same-recording');
        expect(searches.map((call) => call.method), [
          'searchTracksWithMetadataProvider',
          'searchTracksWithMetadataProviders',
        ]);
      }
    });

    test('matches by title and first artist without an ISRC', () async {
      final refresh = refresher(
        others: [
          {
            'id': 'x1',
            'name': 'Song',
            'artists': 'Someone Else',
            'preview_url': 'https://e.test/wrong-artist',
          },
          {
            'id': 'x2',
            'name': ' song ',
            'artists': 'Artist, Guest',
            'preview_url': 'https://e.test/right',
          },
        ],
      );

      // A song that came from no extension is still looked up.
      expect(await refresh(song.copyWith(source: '')), 'https://e.test/right');
      expect(searches.single.method, 'searchTracksWithMetadataProviders');
    });

    test('has nothing when no extension knows the song', () async {
      final refresh = refresher(
        others: [
          {
            'id': 'x1',
            'name': 'Another Song',
            'artists': 'Artist',
            'preview_url': 'https://e.test/other',
          },
        ],
      );

      expect(await refresh(song), isNull);
    });

    test('fails only when no extension could be asked', () async {
      expect(await refresher(own: null)(song), isNull);
      await expectLater(
        refresher(own: null, others: null)(song),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}

class _PreviewDeck implements PlaybackDeck {
  _PreviewDeck({this.dead = const {}});

  /// Links whose server no longer serves them.
  final Set<String> dead;
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
  PlaybackTempoSupport get tempoSupport => PlaybackTempoSupport.full;
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
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) =>
      calls.add('positions');
  @override
  Future<void> configureOutput() async => calls.add('configure');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> setPlaybackRate(double rate) async => calls.add('rate $rate');
  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {
    calls.add('network $url');
    if (dead.contains(url)) throw StateError('HTTP 403');
  }

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
    int usbMaxSampleRate = 0,
    bool usbDitherHighPass = false,
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
  Future<bool> setNextDeck(PlaybackDeck? next) async => false;
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
