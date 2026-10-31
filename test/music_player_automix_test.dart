import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/automix_status.dart';
import 'package:mornye/services/playback_deck.dart';

import 'support/music_player_automix_harness.dart';

const _tracks = testTracks;
const _until = waitUntil;

/// Enough songs that a reshuffled pass repeats the previous order only about
/// once in 360,000 draws.
final _passTracks = [
  for (var i = 0; i < 10; i++)
    PlayableMedia(
      id: 'song-$i',
      source: '/song-$i.flac',
      title: 'Song $i',
      artist: 'Artist',
    ),
];

void main() {
  setUpMusicPlayerHarness();

  test(
    'USB preference is opt-in and persists with existing DSP preferences',
    () {
      const defaults = AppSettings();
      expect(defaults.usbBitPerfect, isFalse);
      expect(defaults.usbDirect, isFalse);
      expect(defaults.usbDsdOverPcm, isFalse);
      expect(defaults.usbAllowFixedVolume, isFalse);
      expect(defaults.dapExclusive, isFalse);
      final upgraded = AppSettings.fromJson({
        'usbBitPerfect': true,
        'usbDirect': true,
      });
      expect(upgraded.usbAllowFixedVolume, isFalse);
      final selected = defaults.copyWith(
        usbBitPerfect: true,
        usbDirect: true,
        usbDsdOverPcm: true,
        usbAllowFixedVolume: true,
        autoMix: true,
        playbackNormalization: true,
      );
      final restored = AppSettings.fromJson(selected.toJson());
      expect(restored.usbBitPerfect, isTrue);
      expect(restored.usbDirect, isTrue);
      expect(restored.usbDsdOverPcm, isTrue);
      expect(restored.usbAllowFixedVolume, isTrue);
      expect(
        AppSettings.fromJson(
          defaults.copyWith(dapExclusive: true).toJson(),
        ).dapExclusive,
        isTrue,
      );
      expect(restored.autoMix, isTrue);
      expect(restored.playbackNormalization, isTrue);
    },
  );

  fakeTimeTest(
    'USB mode prevents a second DSP deck even when AutoMix is enabled',
    () async {
      setAutoMixEnabled(true);
      setUsbBitPerfectEnabled(true);
      await handler.setQueueAndPlay(_tracks);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(native.live, {'music-player'});
      expect(native.lastVolume('music-player'), 1);
      expect(analyzer.calls, isEmpty);
    },
  );

  test(
    'Autoplay fills a single-track queue and follows its visible order',
    () async {
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await _until(() => handler.queue.value.length == 3);
      final planned = handler.queue.value.toList();
      expect(planned.first.id, 'one');
      expect(
        planned.skip(1).every((item) => item.extras?['autoplay'] == true),
        isTrue,
      );
      await native.event('music-player', 'audio.onComplete');
      await _until(() => handler.mediaItem.value?.id == planned[1].id);
      expect(native.sources['music-player'], planned[1].extras?['source']);
      setAutoplayEnabled(false);
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        planned[1].id,
      ]);
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'manual additions precede Autoplay and survive disabling or repeat',
    () async {
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await _until(() => handler.queue.value.length == 3);
      const manual = PlayableMedia(
        id: 'manual',
        source: '/manual.flac',
        title: 'Manual',
        artist: 'Other',
      );
      await handler.enqueue(manual);
      expect(handler.queue.value[1].id, 'manual');
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      expect(handler.queue.value[1].id, 'manual');
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.queue.value[1].id, 'manual');
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(handler.queue.value.map((item) => item.id), ['one', 'manual']);
      await handler.setRepeatMode(AudioServiceRepeatMode.none);
      await _until(() => handler.queue.value.length == 4);
      setAutoplayEnabled(false);
      expect(handler.queue.value.map((item) => item.id), ['one', 'manual']);
    },
  );

  test(
    'pending Autoplay is discarded after disabling or replacing the queue',
    () async {
      final pending = Completer<List<PlayableMedia>>();
      autoplayLoader = (_) => pending.future;
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      setAutoplayEnabled(false);
      await handler.setQueueAndPlay([_tracks.last]);
      pending.complete(_tracks);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.queue.value.map((item) => item.id), ['three']);
      expect(native.sources['music-player'], '/three.flac');
    },
  );

  test('pause during an Autoplay refill prevents automatic resume', () async {
    final pending = Completer<List<PlayableMedia>>();
    autoplayLoader = (_) => pending.future;
    setAutoplayEnabled(true);
    await handler.setQueueAndPlay([_tracks.first]);
    await native.event('music-player', 'audio.onComplete');
    await handler.pause();
    pending.complete(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.mediaItem.value?.id, 'one');
    expect(handler.playbackState.value.playing, isFalse);
    expect(native.resumedSources, ['/one.flac']);
  });

  test(
    'replacing a queue invalidates an in-flight recommendation batch',
    () async {
      final pending = Completer<List<PlayableMedia>>();
      autoplayLoader = (seed) =>
          seed.id == 'one' ? pending.future : Future.value([]);
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await handler.setQueueAndPlay([_tracks.last]);
      pending.complete(_tracks);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.queue.value.map((item) => item.id), ['three']);
      expect(native.sources['music-player'], '/three.flac');
    },
  );

  test(
    'duplicate completion while recommendations load advances only once',
    () async {
      final pending = Completer<List<PlayableMedia>>();
      autoplayLoader = (_) => pending.future;
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await native.event('music-player', 'audio.onComplete');
      await native.event('music-player', 'audio.onComplete');
      pending.complete(_tracks);
      await _until(() => handler.playbackState.value.queueIndex == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.playbackState.value.queueIndex, 1);
      expect(handler.mediaItem.value?.id, handler.queue.value[1].id);
    },
  );

  test(
    'Autoplay never adds a song dismissed from the current queue again',
    () async {
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await _until(() => handler.queue.value.length == 3);
      final removed = handler.queue.value[1];
      handler.removeQueuedItem(removed);
      await handler.skipToNext();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.queue.value.any((item) => item.id == removed.id), isFalse);
    },
  );

  test('empty Library ends playback and does not repeatedly refill', () async {
    var loads = 0;
    autoplayLoader = (_) async {
      loads++;
      return [];
    };
    setAutoplayEnabled(true);
    await handler.setQueueAndPlay([_tracks.first]);
    await native.event('music-player', 'audio.onComplete');
    await _until(
      () =>
          handler.playbackState.value.processingState ==
          AudioProcessingState.completed,
    );
    expect(handler.queue.value, hasLength(1));
    expect(loads, 1);
  });

  test(
    'rapid Next keeps the final audible source and displayed title together',
    () async {
      final gate = Completer<void>();
      native.sourceGates['/one.flac'] = gate;
      final first = handler.setQueueAndPlay(_tracks);
      await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
      final second = handler.skipToNext();
      final third = handler.skipToNext();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      gate.complete();
      await Future.wait([first, second, third]);
      expect(handler.mediaItem.value?.id, 'three');
      expect(native.sources['music-player'], '/three.flac');
      expect(native.resumedSources, ['/three.flac']);
    },
  );

  for (final shuffle in [false, true]) {
    test('Previous changes both title and audio (shuffle: $shuffle)', () async {
      if (shuffle) await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await handler.setQueueAndPlay(_tracks);
      final ordered = handler.queue.value.map((item) => item.id).toList();
      await handler.skipToNext();
      await handler.skipToNext();
      expect(native.sources['music-player'], '/${ordered[2]}.flac');

      // Repeat-one affects automatic completion, not an explicit Previous.
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      for (final id in ordered.take(2).toList().reversed) {
        await handler.skipToPrevious();
        expect(handler.mediaItem.value?.id, id);
        expect(native.preparedContents['music-player'], '/$id.flac');
        expect(native.resumedSources.last, '/$id.flac');
        expect(native.playing, {'music-player'});
      }
    });
  }

  test('rapid Previous discards a later track still preparing', () async {
    final gate = Completer<void>();
    native.sourceGates['/three.flac'] = gate;
    final last = handler.setQueueAndPlay(_tracks, initialIndex: 2);
    await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
    final second = handler.skipToPrevious();
    final first = handler.skipToPrevious();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    gate.complete();
    await Future.wait([last, second, first]);
    expect(handler.mediaItem.value?.id, 'one');
    expect(native.preparedContents['music-player'], '/one.flac');
    expect(native.resumedSources, ['/one.flac']);
  });

  test('Next and Previous reload a recycled SAF descriptor', () async {
    const descriptor = '/proc/self/fd/42';
    native.sourceContents[descriptor] = 'first file';
    await handler.setQueueAndPlay([
      const PlayableMedia(
        id: 'first',
        source: descriptor,
        title: 'First',
        artist: 'Artist',
      ),
      const PlayableMedia(
        id: 'second',
        source: descriptor,
        title: 'Second',
        artist: 'Artist',
      ),
    ]);
    expect(native.preparedContents['music-player'], 'first file');
    native.sourceContents[descriptor] = 'second file';
    await handler.skipToNext();
    expect(handler.mediaItem.value?.title, 'Second');
    expect(native.preparedContents['music-player'], 'second file');
    expect(native.playing, contains('music-player'));

    native.sourceContents[descriptor] = 'first file';
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.title, 'First');
    expect(native.preparedContents['music-player'], 'first file');
    expect(native.playing, {'music-player'});
  });

  test('replacing a queue during preparation drops the old request', () async {
    final gate = Completer<void>();
    native.sourceGates['/one.flac'] = gate;
    final first = handler.setQueueAndPlay(_tracks);
    await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
    final replacement = handler.setQueueAndPlay([_tracks[1]]);
    gate.complete();
    await Future.wait([first, replacement]);
    expect(handler.mediaItem.value?.id, 'two');
    expect(native.sources['music-player'], '/two.flac');
    expect(native.resumedSources, ['/two.flac']);
  });

  test('a song still preparing does not hold up the next one', () async {
    // A server that never answers keeps the first song preparing.
    final gate = Completer<void>();
    native.sourceGates['/one.flac'] = gate;
    final first = handler.setQueueAndPlay(_tracks);
    await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
    await handler.skipToNext();
    await first;
    expect(handler.mediaItem.value?.id, 'two');
    expect(native.sources['music-player'], '/two.flac');
    expect(native.resumedSources, ['/two.flac']);
    gate.complete();
  });

  for (final stop in [false, true]) {
    test(
      'a pending prepare cannot resume after ${stop ? 'stop' : 'pause'}',
      () async {
        final gate = Completer<void>();
        native.sourceGates['/one.flac'] = gate;
        final first = handler.setQueueAndPlay(_tracks);
        await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
        final cancel = stop ? handler.stop() : handler.pause();
        gate.complete();
        await Future.wait([first, cancel]);
        expect(native.resumedSources, isEmpty);
        expect(native.playing, isEmpty);
        expect(handler.playbackState.value.playing, isFalse);
        if (stop) expect(handler.mediaItem.value, isNull);
      },
    );
  }

  for (final action in ['pause', 'stop', 'dispose']) {
    test('$action cancels a source that never finishes preparing', () async {
      final gate = Completer<void>();
      native.sourceGates['/one.flac'] = gate;
      final first = handler.setQueueAndPlay(_tracks);
      await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
      final cancel = switch (action) {
        'pause' => handler.pause(),
        'stop' => handler.stop(),
        _ => handler.dispose(),
      };
      try {
        await cancel.timeout(const Duration(seconds: 1));
        await first;
        expect(native.resumedSources, isEmpty);
        expect(native.playing, isEmpty);
      } finally {
        gate.complete();
        await Future.wait([first, cancel]);
      }
    });
  }

  test('notification actions survive theme changes', () async {
    await handler.restoreSession(
      items: _tracks,
      index: 0,
      position: const Duration(seconds: 12),
      shuffle: false,
    );
    configurePlaybackNotification(
      presentation: const PlaybackNotification(
        mornye: true,
        mediaId: 'one',
        source: '/one.flac',
        loved: true,
      ),
      toggleFavorite: (_) async => false,
    );
    final state = handler.playbackState.value;
    expect(state.playing, isFalse);
    expect(state.updatePosition, const Duration(seconds: 12));
    expect(state.controls.map((control) => control.action), [
      MediaAction.custom,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.skipToNext,
      MediaAction.custom,
    ]);
    expect(state.controls.first.androidIcon, contains('star_filled'));
    expect(
      state.controls.last.customAction?.name,
      PlaybackNotification.shuffleAction,
    );
    expect(state.androidCompactActionIndices, [1, 2, 3]);
    expect(state.controls[1].androidIcon, 'drawable/ic_widget_previous');
    expect(state.controls[2].androidIcon, 'drawable/ic_widget_play');
    expect(state.controls[3].androidIcon, 'drawable/ic_widget_next');

    configurePlaybackNotification(
      presentation: const PlaybackNotification(
        mediaId: 'one',
        source: '/one.flac',
        loved: true,
      ),
      toggleFavorite: (_) async => false,
    );
    final material = handler.playbackState.value;
    expect(
      material.controls.first.customAction?.name,
      PlaybackNotification.favoriteAction,
    );
    expect(material.controls.first.androidIcon, contains('star_filled'));
    expect(material.controls.sublist(1, 4), [
      MediaControl.skipToPrevious,
      MediaControl.play,
      MediaControl.skipToNext,
    ]);
    expect(
      material.controls.last.customAction?.name,
      PlaybackNotification.shuffleAction,
    );
    expect(material.androidCompactActionIndices, [1, 2, 3]);
    expect(material.updatePosition, state.updatePosition);
    handler.playbackState.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 12),
        updateTime: DateTime.now().subtract(const Duration(seconds: 5)),
      ),
    );
    configurePlaybackNotification(
      presentation: const PlaybackNotification(mornye: true),
      toggleFavorite: (_) async => false,
    );
    expect(
      handler.playbackState.value.updatePosition.inMilliseconds,
      inInclusiveRange(17000, 17200),
      reason: 'Changing icons must not reset the live playback position',
    );
  });

  test(
    'Material notification shuffle toggles queue order without restarting audio',
    () async {
      configurePlaybackNotification(
        presentation: const PlaybackNotification(),
        toggleFavorite: (_) async => false,
      );
      await handler.setQueueAndPlay(_tracks, initialIndex: 1);
      final resumed = List.of(native.resumedSources);

      await handler.customAction(PlaybackNotification.shuffleAction);
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(handler.queue.value.first.id, 'two');
      expect(handler.queue.value.map((item) => item.id).toSet(), {
        'one',
        'two',
        'three',
      });
      expect(handler.mediaItem.value?.id, 'two');
      expect(
        handler.playbackState.value.controls.last.androidIcon,
        endsWith('shuffle_on'),
      );
      expect(handler.playbackState.value.controls.last.label, 'Shuffle on');

      await handler.customAction(PlaybackNotification.shuffleAction);
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.none,
      );
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'two',
        'three',
      ]);
      expect(handler.mediaItem.value?.id, 'two');
      expect(
        handler.playbackState.value.controls.last.androidIcon,
        endsWith('shuffle'),
      );
      expect(handler.playbackState.value.controls.last.label, 'Shuffle off');
      expect(handler.playbackState.value.playing, isTrue);
      expect(native.resumedSources, resumed);
    },
  );

  test(
    'shuffle plays the published queue and off restores the original order',
    () async {
      final tracks = [
        for (var i = 0; i < 8; i++)
          PlayableMedia(
            id: '$i',
            source: '/$i.flac',
            title: '$i',
            artist: 'Artist',
          ),
      ];
      await handler.setQueueAndPlay(tracks, initialIndex: 3);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      final planned = handler.queue.value.map((item) => item.id).toList();
      expect(planned.first, '3');
      expect(planned.toSet(), tracks.map((item) => item.id).toSet());
      for (var i = 1; i < planned.length; i++) {
        await handler.skipToNext();
        expect(handler.mediaItem.value?.id, planned[i]);
        expect(native.sources['music-player'], '/${planned[i]}.flac');
        expect(handler.queue.value.map((item) => item.id), planned);
      }
      final last = handler.mediaItem.value;
      final resumes = native.resumedSources.length;
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(
        handler.queue.value.map((item) => item.id),
        tracks.map((item) => item.id),
      );
      expect(handler.mediaItem.value, last);
      expect(handler.playbackState.value.queueIndex, int.parse(planned.last));
      expect(native.resumedSources.length, resumes);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      expect(handler.queue.value.first.id, planned.last);
      expect(handler.mediaItem.value, last);
    },
  );

  test(
    'automatic completion follows shuffle order and respects repeat off',
    () async {
      await handler.setQueueAndPlay(_tracks);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      final planned = handler.queue.value.map((item) => item.id).toList();
      for (var i = 1; i < planned.length; i++) {
        await native.event('music-player', 'audio.onComplete');
        await _until(
          () =>
              handler.mediaItem.value?.id == planned[i] &&
              handler.playbackState.value.processingState ==
                  AudioProcessingState.ready,
        );
      }
      await native.event('music-player', 'audio.onComplete');
      await _until(
        () =>
            handler.playbackState.value.processingState ==
            AudioProcessingState.completed,
      );
      expect(handler.mediaItem.value?.id, planned.last);
      expect(handler.queue.value.map((item) => item.id), planned);
    },
  );

  test('repeat all plays each shuffled pass in a new order', () async {
    await handler.setQueueAndPlay(_passTracks);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    final planned = handler.queue.value.map((item) => item.id).toList();
    bool ready() =>
        handler.playbackState.value.processingState ==
        AudioProcessingState.ready;
    for (var i = 1; i < planned.length; i++) {
      await native.event('music-player', 'audio.onComplete');
      await _until(() => handler.mediaItem.value?.id == planned[i] && ready());
    }
    await native.event('music-player', 'audio.onComplete');
    await _until(
      () =>
          handler.playbackState.value.queueIndex == 0 &&
          handler.mediaItem.value?.id != planned.last &&
          ready(),
    );
    final pass = handler.queue.value.map((item) => item.id).toList();
    expect(handler.mediaItem.value?.id, pass.first);
    expect(pass.toSet(), planned.toSet());
    expect(pass, isNot(orderedEquals(planned)));
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.id, planned.last);
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(handler.queue.value.map((item) => item.id), [
      for (final track in _passTracks) track.id,
    ]);
  });

  test(
    'shuffle restoration retains duplicate entries and explicit queue edits',
    () async {
      await handler.setQueueAndPlay([
        _tracks[0],
        _tracks[0],
        _tracks[1],
        _tracks[2],
      ]);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await handler.enqueue(
        const PlayableMedia(
          id: 'next',
          source: '/next.flac',
          title: 'Next',
          artist: '',
        ),
        playNext: true,
      );
      await handler.enqueueAll([
        const PlayableMedia(
          id: 'last',
          source: '/last.flac',
          title: 'Last',
          artist: '',
        ),
      ]);
      expect(handler.queue.value[1].id, 'next');
      await handler.onSourceDeleted('/two.flac');
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'next',
        'one',
        'three',
        'last',
      ]);
      expect(handler.playbackState.value.queueIndex, 0);
    },
  );

  test(
    'queue removal preserves duplicates, current audio and unshuffled order',
    () async {
      await handler.setQueueAndPlay([
        _tracks[0],
        _tracks[0],
        _tracks[1],
        _tracks[2],
      ]);
      final original = List.of(handler.queue.value);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      handler.removeQueuedItem(original[1]);
      handler.removeQueuedItem(original[1]); // A stale swipe is harmless.
      handler.removeQueuedItem(
        original[0],
      ); // The playing occurrence is protected.
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'two',
        'three',
      ]);
      expect(native.resumedSources, ['/one.flac']);
      await handler.skipToNext();
      handler.removeQueuedItem(original[0]);
      expect(handler.playbackState.value.queueIndex, 0);
      expect(handler.mediaItem.value?.id, 'two');
      expect(native.sources['music-player'], '/two.flac');
    },
  );

  test(
    'removing an earlier row during preparation preserves duration probing',
    () async {
      native.emitsDuration = false;
      final gate = Completer<void>();
      native.sourceGates['/three.flac'] = gate;
      final loading = handler.setQueueAndPlay(_tracks, initialIndex: 2);
      await _until(() => native.calls.any((call) => call.$2 == 'setSourceUrl'));
      handler.removeQueuedItem(handler.queue.value.first);
      gate.complete();
      await loading;
      await _until(
        () => handler.mediaItem.value?.duration == const Duration(seconds: 60),
      );
      expect(handler.playbackState.value.queueIndex, 1);
      expect(handler.mediaItem.value?.id, 'three');
      expect(native.resumedSources, ['/three.flac']);
    },
  );

  test('restored shuffle can return to the saved original order', () async {
    await handler.restoreSession(
      items: [_tracks[1], _tracks[2], _tracks[0]],
      index: 1,
      position: const Duration(seconds: 12),
      shuffle: true,
      originalOrder: [1, 2, 0],
    );
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(handler.queue.value.map((item) => item.id), ['one', 'two', 'three']);
    expect(handler.mediaItem.value?.id, 'three');
    expect(handler.playbackState.value.queueIndex, 2);
    expect(handler.playbackState.value.position.inSeconds, 12);
    expect(native.resumedSources, isEmpty);
  });

  test(
    'notification favorite retains clicked track and ignores double taps',
    () async {
      final save = Completer<void>();
      final selected = <String>[];
      configurePlaybackNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          selected.add(item.id);
          await save.future;
          return true;
        },
      );
      handler.mediaItem.add(_tracks.first.toMediaItem());
      final first = handler.customAction(PlaybackNotification.favoriteAction);
      handler.mediaItem.add(_tracks.last.toMediaItem());
      await handler.customAction(PlaybackNotification.favoriteAction);
      expect(selected, ['one']);
      save.complete();
      await first;
      expect(
        handler.playbackState.value.controls.first.androidIcon,
        endsWith('ic_notification_star'),
        reason:
            'Completing a favorite for the old track must not star the next one',
      );
      await handler.customAction(PlaybackNotification.favoriteAction);
      expect(selected, ['one', 'three']);
      expect(
        handler.playbackState.value.controls.first.androidIcon,
        endsWith('ic_notification_star_filled'),
      );
    },
  );

  test('Material favorites refresh without a UI rebuild', () async {
    var loved = false;
    configurePlaybackNotification(
      presentation: const PlaybackNotification(
        favoriteLabel: 'Add to Loved',
        unfavoriteLabel: 'Remove from Loved',
      ),
      toggleFavorite: (_) async => loved = !loved,
    );
    await handler.restoreSession(
      items: _tracks,
      index: 0,
      position: const Duration(seconds: 12),
      shuffle: false,
    );
    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(
      handler.playbackState.value.controls.first.androidIcon,
      endsWith('ic_notification_star_filled'),
    );
    expect(
      handler.playbackState.value.controls.first.label,
      'Remove from Loved',
    );
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 12),
    );

    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(
      handler.playbackState.value.controls.first.androidIcon,
      endsWith('ic_notification_star'),
    );
    expect(handler.playbackState.value.controls.first.label, 'Add to Loved');
    expect(native.resumedSources, isEmpty);
  });

  test('failed favorite save leaves the notification icon unchanged', () async {
    configurePlaybackNotification(
      presentation: const PlaybackNotification(mornye: true),
      toggleFavorite: (_) async => throw StateError('Save failed'),
    );
    handler.mediaItem.add(_tracks.first.toMediaItem());
    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(
      handler.playbackState.value.controls.first.androidIcon,
      endsWith('ic_notification_star'),
    );
  });

  Future<void> prepare() async {
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.length >= 2);
    await _until(
      () => native.calls.any((call) => call.$2 == 'setPlaybackRate'),
    );
  }

  Future<String> startMix({int startPosition = 55000}) async {
    await prepare();
    final incoming = native.prepared;
    native.positions['music-player'] = startPosition;
    await _until(() => handler.mediaItem.value?.id == 'two');
    await _until(() => (native.lastVolume(incoming) ?? 0) > 0);
    return incoming;
  }

  test(
    'haptics survives an AutoMix handoff followed by a manual skip',
    () async {
      musicPlayerRuntime.configure(
        musicPlayerRuntime.settings.copyWith(musicHaptics: true),
      );
      await startMix();
      await _until(() => hapticSongs.contains('two'));
      await handler.skipToNext();
      await _until(() => hapticSongs.contains('three'));
      expect(
        hapticsAnalyzer.paths,
        containsAllInOrder(['/one.flac', '/two.flac', '/three.flac']),
      );
    },
  );

  test('Previous after AutoMix handoff reloads the preceding audio', () async {
    final active = await startMix();
    await handler.seek(Duration.zero);
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.id, 'one');
    expect(native.preparedContents[active], '/one.flac');
    expect(native.resumedSources.last, '/one.flac');
    expect(native.playing, {active});
  });

  test(
    'AutoMix prepares and plays the next entry in the shuffled queue',
    () async {
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await prepare();
      final planned = handler.queue.value.map((item) => item.id).toList();
      final incoming = native.prepared;
      expect(native.sources[incoming], '/${planned[1]}.flac');
      native.positions['music-player'] = 55000;
      await _until(() => handler.mediaItem.value?.id == planned[1]);
      expect(handler.queue.value.map((item) => item.id), planned);
      expect(handler.playbackState.value.queueIndex, 1);
    },
  );

  test(
    'AutoMix into a repeat-all wrap opens the newly shuffled pass',
    () async {
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.setQueueAndPlay(_passTracks);
      final planned = handler.queue.value.map((item) => item.id).toList();
      await handler.skipToQueueItem(planned.length - 1);
      setAutoMixEnabled(true);
      await _until(
        () => native.calls.any(
          (call) => call.$1 != 'music-player' && call.$2 == 'setPlaybackRate',
        ),
      );
      final opener = native.sources[native.prepared];
      expect(opener, isNot('/${planned.last}.flac'));
      native.positions['music-player'] = 55000;
      await _until(() => handler.playbackState.value.queueIndex == 0);
      final pass = handler.queue.value.map((item) => item.id).toList();
      expect('/${pass.first}.flac', opener);
      expect(handler.mediaItem.value?.id, pass.first);
      expect(pass.toSet(), planned.toSet());
      expect(pass, isNot(orderedEquals(planned)));
    },
  );

  fakeTimeTest(
    'disabled AutoMix uses only the ordinary player and no analysis',
    () async {
      await handler.setQueueAndPlay(_tracks);
      native.positions['music-player'] = 56000;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(analyzer.calls, isEmpty);
      expect(native.live, {'music-player'});
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  fakeTimeTest(
    'handoff publishes native duration and ignores outgoing completion',
    () async {
      final incoming = await startMix();
      expect(native.playing, {'music-player', incoming});
      expect(handler.mediaItem.value?.duration, const Duration(minutes: 1));
      expect(handler.playbackState.value.queueIndex, 1);
      await native.event('music-player', 'audio.onComplete');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(handler.mediaItem.value?.id, 'two');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'pause during overlap stops both decks and restores incoming gain',
    () async {
      final incoming = await startMix();
      expect(autoMixStatus.value, AutoMixStatus.crossfading);
      await handler.pause();
      expect(native.live, {incoming});
      expect(native.playing, isEmpty);
      expect(native.lastVolume(incoming), 1);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  fakeTimeTest(
    'matched transition releases outgoing and restores tempo after the fade',
    () async {
      analyzer.matchBeats = true;
      final incoming = await startMix(startPosition: 55670);
      expect(autoMixStatus.value, AutoMixStatus.mixing);
      expect(handler.playbackState.value.speed, closeTo(120 / 124, 0.0001));
      await Future<void>.delayed(const Duration(milliseconds: 4200));
      expect(autoMixStatus.value, AutoMixStatus.idle);
      expect(native.live, {incoming});
      expect(native.lastVolume(incoming), closeTo(1, 0.0001));
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(handler.playbackState.value.speed, 1);
      expect(native.playing, {incoming});
      expect(
        native.calls.where(
          (call) => call.$1 == 'music-player' && call.$2 == 'dispose',
        ),
        hasLength(1),
      );
    },
  );

  fakeTimeTest(
    'matched transition starts the incoming song on the outgoing beat',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      int position(String id) => native.currentPosition(id);
      // The current song keeps playing while the next decoder starts late.
      final startup = Completer<void>();
      native.resumeGates[incoming] = startup;
      native.positions['music-player'] = 55500;
      native.clocks['music-player'] = time.stopwatch()..start();
      await _until(
        () => native.calls.any(
          (call) => call.$1 == incoming && call.$2 == 'resume',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      startup.complete();
      await _until(() => handler.mediaItem.value?.id == 'two');
      // The first incoming beat (0.17 s) belongs on the outgoing beat at
      // 55.67 s, with the next song slowed from 124 to 120 BPM.
      final expected = 170 + (position('music-player') - 55670) * 120 / 124;
      expect(position(incoming), closeTo(expected, 20));
    },
  );

  fakeTimeTest(
    'Auto waits for advancing audio before fading the current song',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.stalled.add(incoming);
      native.positions['music-player'] = 55670;
      await _until(() => native.playing.contains(incoming));
      await Future<void>.delayed(const Duration(milliseconds: 240));
      expect(native.lastVolume('music-player'), 1);
      expect(native.lastVolume(incoming), 0);
      expect(handler.mediaItem.value?.id, 'one');

      native.positions['music-player'] = 58500;
      native.stalled.remove(incoming);
      native.clocks[incoming]!.reset();
      await _until(() => handler.mediaItem.value?.id == 'two');
      // Startup consumed most of the outro. Finish the fade within the remaining
      // 1.5 seconds instead of fading against a song that has already ended.
      await _until(() => !native.live.contains('music-player'));
      expect(native.lastVolume(incoming), closeTo(1, 0.0001));
    },
  );

  fakeTimeTest(
    'unverified beat alignment uses an unstretched crossfade',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.ignoredSeeks.add(incoming);
      final startup = Completer<void>();
      native.resumeGates[incoming] = startup;
      native.positions['music-player'] = 55500;
      native.clocks['music-player'] = time.stopwatch()..start();
      await _until(
        () => native.calls.any(
          (call) => call.$1 == incoming && call.$2 == 'resume',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      startup.complete();
      await _until(() => handler.mediaItem.value?.id == 'two');
      expect(autoMixStatus.value, AutoMixStatus.crossfading);
      expect(handler.playbackState.value.speed, 1);
      expect(native.rates[incoming], 1);
    },
  );

  fakeTimeTest(
    'phase drift is corrected while mixing and pause restores the rate',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.positions['music-player'] = 55500;
      native.clocks['music-player'] = time.stopwatch()..start();
      await _until(() => handler.mediaItem.value?.id == 'two');
      expect(autoMixStatus.value, AutoMixStatus.mixing);
      native.positions[incoming] = native.positions[incoming]! - 35;
      await _until(() => native.rates[incoming]! > 120 / 124 + 0.005);
      expect(native.rates[incoming], lessThanOrEqualTo(120 / 124 * 1.02));
      await handler.pause();
      expect(native.rates[incoming], 1);
      expect(native.live, {incoming});
      expect(native.playing, isEmpty);
    },
  );

  fakeTimeTest(
    'a corrected mix finishes at normal speed and releases the outgoing deck',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.positions['music-player'] = 55500;
      native.clocks['music-player'] = time.stopwatch()..start();
      await _until(() => handler.mediaItem.value?.id == 'two');
      native.positions[incoming] = native.positions[incoming]! - 35;
      await _until(() => native.rates[incoming]! > 120 / 124 + 0.005);
      await Future<void>.delayed(const Duration(seconds: 14));
      expect(handler.mediaItem.value?.id, 'two');
      expect(autoMixStatus.value, AutoMixStatus.idle);
      expect(native.rates[incoming], 1);
      expect(native.lastVolume(incoming), 1);
      expect(native.live, isNot(contains('music-player')));
      expect(native.playing, {incoming});
    },
  );

  fakeTimeTest(
    'missing phase readings keep both decks audible without further corrections',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.positions['music-player'] = 55500;
      native.clocks['music-player'] = time.stopwatch()..start();
      await _until(() => handler.mediaItem.value?.id == 'two');
      expect(autoMixStatus.value, AutoMixStatus.mixing);
      native.missingPositions.add('music-player');
      await _until(() => autoMixStatus.value == AutoMixStatus.crossfading);
      expect(native.playing, {'music-player', incoming});
      expect(native.lastVolume('music-player'), greaterThan(0));
      expect(native.lastVolume(incoming), greaterThan(0));
      expect(native.rates[incoming], closeTo(120 / 124, 0.00001));
      await handler.pause();
      expect(native.rates[incoming], 1);
      expect(native.live, {incoming});
    },
  );

  test(
    'uncertain measured beats execute a bass handoff at unchanged tempo',
    () async {
      analyzer.matchBeats = true;
      analyzer.confidence = 0.4;
      await prepare();
      await _until(
        () => native.sources.values.any((path) => path.endsWith('/tail.wav')),
      );
      expect(effectRenderer.bassHandoffs, [true]);
      final incoming = native.sources.entries
          .singleWhere((entry) => entry.value == '/two.flac')
          .key;
      native.positions['music-player'] = 55000;
      await _until(() => handler.mediaItem.value?.id == 'two');
      expect(autoMixStatus.value, AutoMixStatus.crossfading);
      expect(native.rates[incoming], 1);
      await handler.pause();
      expect(native.live, {incoming});
      expect(await effectRenderer.tails.single.directory.exists(), isFalse);
    },
  );

  fakeTimeTest(
    'a stalled Auto standby leaves the current song playing',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.stalled.add(incoming);
      native.positions['music-player'] = 55670;
      await _until(() => native.playing.contains(incoming));
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(native.live, {'music-player'});
      expect(native.playing, {'music-player'});
      expect(native.lastVolume('music-player'), 1);
      expect(handler.mediaItem.value?.id, 'one');
      expect(analyzer.calls, hasLength(2));
    },
  );

  test('a late Auto timer still overlaps within the remaining outro', () async {
    analyzer.matchBeats = true;
    final incoming = await startMix(startPosition: 58500);
    await _until(() => !native.live.contains('music-player'));
    expect(native.lastVolume(incoming), closeTo(1, 0.0001));
    expect(native.playing, {incoming});
  });

  fakeTimeTest(
    'pausing while Auto waits for audio cancels the pending handoff',
    () async {
      analyzer.matchBeats = true;
      await prepare();
      final incoming = native.prepared;
      native.stalled.add(incoming);
      native.positions['music-player'] = 55670;
      await _until(() => native.playing.contains(incoming));
      await handler.pause();
      native.stalled.remove(incoming);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(handler.mediaItem.value?.id, 'one');
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.live, {'music-player'});
      expect(native.playing, isEmpty);
      expect(native.lastVolume('music-player'), 1);
    },
  );

  test(
    'seek during overlap cancels fade and seeks only the active deck',
    () async {
      final incoming = await startMix();
      await handler.seek(const Duration(seconds: 12));
      expect(native.live, {incoming});
      expect(native.positions[incoming], 12000);
      expect(native.lastVolume(incoming), 1);
    },
  );

  test(
    'rendered effect replaces outgoing deck and pause removes its temporary tail',
    () async {
      setAutoMixOptions(const AutoMixOptions(effect: AutoMixEffect.echo));
      await prepare();
      await _until(() => native.live.length == 3);
      final incoming = native.sources.entries
          .singleWhere((entry) => entry.value == '/two.flac')
          .key;
      final effect = native.sources.entries
          .singleWhere((entry) => entry.value.endsWith('/tail.wav'))
          .key;
      native.positions['music-player'] = 55000;
      await _until(() => handler.mediaItem.value?.id == 'two');
      await _until(() => !native.live.contains('music-player'));
      expect(native.playing, {incoming, effect});
      expect(autoMixStatus.value, AutoMixStatus.crossfading);
      await handler.pause();
      expect(native.live, {incoming});
      expect(await effectRenderer.tails.single.directory.exists(), isFalse);
    },
  );

  test('an effect deck that never sounds falls back without a drop', () async {
    setAutoMixOptions(const AutoMixOptions(effect: AutoMixEffect.echo));
    await prepare();
    await _until(
      () => native.sources.values.any((path) => path.endsWith('/tail.wav')),
    );
    final effect = native.sources.entries
        .singleWhere((entry) => entry.value.endsWith('/tail.wav'))
        .key;
    native.stalled.add(effect);
    native.positions['music-player'] = 55000;
    await _until(
      () =>
          native.calls.any((call) => call.$1 == effect && call.$2 == 'resume'),
    );
    // The live song keeps full gain while the silent effect deck is checked.
    expect(native.lastVolume('music-player'), 1);
    await _until(() => handler.mediaItem.value?.id == 'two');
    expect(native.live, isNot(contains(effect)));
    expect(native.lastVolume(effect), anyOf(isNull, 0));
    expect(native.playing, contains('music-player'));
  });

  test('effect rendering failure retains ordinary crossfade', () async {
    effectRenderer.fail = true;
    setAutoMixOptions(
      const AutoMixOptions(effect: AutoMixEffect.pitch, pitchSemitones: 2),
    );
    final incoming = await startMix();
    expect(native.playing, {'music-player', incoming});
    expect(effectRenderer.tails, isEmpty);
  });

  test(
    'effect startup keeps dry audio audible and blends before disposal',
    () async {
      setAutoMixOptions(const AutoMixOptions(effect: AutoMixEffect.muffled));
      await prepare();
      await _until(
        () => native.sources.values.any((path) => path.endsWith('/tail.wav')),
      );
      final effect = native.sources.entries
          .singleWhere((entry) => entry.value.endsWith('/tail.wav'))
          .key;
      final ready = Completer<void>();
      native.resumeGates[effect] = ready;
      native.positions['music-player'] = 55000;
      await _until(
        () => native.calls.any(
          (call) => call.$1 == effect && call.$2 == 'resume',
        ),
      );
      expect(native.lastVolume('music-player'), 1);
      expect(native.lastVolume(effect), 0);
      expect(native.playing, contains('music-player'));
      ready.complete();
      await _until(() => (native.lastVolume(effect) ?? 0) > 0);
      expect(native.lastVolume('music-player'), inExclusiveRange(0, 1));
      expect(native.lastVolume(effect), inExclusiveRange(0, 1));
      // Pausing during the handover must clean up both the dry and wet decks.
      await handler.pause();
      expect(native.live, hasLength(1));
      expect(native.playing, isEmpty);
      expect(await effectRenderer.tails.single.directory.exists(), isFalse);
    },
  );

  test(
    'turning AutoMix off releases the standby player without changing song',
    () async {
      await prepare();
      setAutoMixEnabled(false);
      await _until(() => native.live.length == 1);
      expect(native.live, {'music-player'});
      expect(handler.mediaItem.value?.id, 'one');
      expect(native.playing, {'music-player'});
    },
  );

  test('queue edit never starts the previously prepared next song', () async {
    await prepare();
    await handler.enqueue(_tracks[2], playNext: true);
    native.positions['music-player'] = 55000;
    await _until(() => analyzer.calls.length >= 4);
    await _until(() => handler.mediaItem.value?.id == 'three');
    expect(handler.mediaItem.value?.id, 'three');
  });

  test('manual skip invalidates an analysis still in flight', () async {
    analyzer.pending = Completer<AutoMixBeatGrid?>();
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.isNotEmpty);
    await handler.skipToNext();
    await handler.pause();
    analyzer.pending!.complete(null);
    analyzer.pending = null;
    await _until(() => native.live.length == 1);
    expect(handler.mediaItem.value?.id, 'two');
    expect(native.playing, isEmpty);
  });

  fakeTimeTest(
    'network playback uses URL transport and does not analyze remote files',
    () async {
      setAutoMixEnabled(true);
      const remote = PlayableMedia(
        id: 'remote',
        source: 'https://music.test/song.mp3',
        title: 'Remote',
        artist: 'Server',
      );
      await handler.setQueueAndPlay([remote, _tracks.first]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        native.calls.lastWhere((c) => c.$2 == 'setSourceUrl').$3['isLocal'],
        false,
      );
      expect(native.playing, {'music-player'});
      expect(analyzer.calls, isEmpty);
      await handler.skipToNext();
      expect(
        native.calls.lastWhere((c) => c.$2 == 'setSourceUrl').$3['isLocal'],
        true,
      );
      await handler.skipToPrevious();
      expect(handler.mediaItem.value?.id, remote.id);
      expect(native.preparedContents['music-player'], remote.source);
      expect(native.resumedSources.last, remote.source);
      expect(
        native.calls.lastWhere((c) => c.$2 == 'setSourceUrl').$3['isLocal'],
        false,
      );
    },
  );

  fakeTimeTest('a next song still arriving is not mixed in', () async {
    // A paired phone still sends it, or sends it again after the received
    // folder pruned it.
    final arrived = Completer<void>();
    addTearDown(arrived.complete);
    musicPlayerRuntime.streamWhileArriving(
      '/two.flac',
      url: 'http://127.0.0.1:1/two.flac',
      done: arrived.future,
    );
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(native.live, {'music-player'});
    expect(analyzer.calls, isEmpty);
  });

  fakeTimeTest('repeat one never prepares another deck', () async {
    setAutoMixEnabled(true);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    await handler.setQueueAndPlay(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(native.live, {'music-player'});
    expect(analyzer.calls, isEmpty);
  });

  const four = PlayableMedia(
    id: 'four',
    source: '/four.flac',
    title: 'Four',
    artist: 'Artist',
  );

  void setLengths(Duration length) {
    for (final track in [..._tracks, four]) {
      native.durations[track.source] = length.inMilliseconds;
    }
  }

  /// Plays deck [id] on from [milliseconds], its position following the
  /// clock as a song does.
  void playFrom(int milliseconds, [String id = 'music-player']) {
    native.positions[id] = milliseconds;
    native.clocks[id] = time.stopwatch()..start();
  }

  /// Waits for [ready] while the songs play, up to [limit] of their time.
  Future<void> playUntil(bool Function() ready, Duration limit) async {
    final clock = time.stopwatch()..start();
    while (!ready()) {
      if (clock.elapsed > limit) {
        fail('Playback did not reach the expected state');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  List<String> mixDecks() => [
    for (final call in native.calls)
      if (call.$2 == 'create' && call.$1.startsWith('music-mix-')) call.$1,
  ];

  /// Where [outgoing] was when [incoming] began to play, and how [incoming]
  /// was cued: the start, cue and rate of the plan.
  ({int at, int cue, double rate}) mixStart(
    String incoming, [
    String outgoing = 'music-player',
  ]) {
    Map<Object?, Object?> first(String method) => native.calls
        .firstWhere((call) => call.$1 == incoming && call.$2 == method)
        .$3;
    return (
      at: native.positionsAtResume[incoming]![outgoing]!,
      cue: first('seek')['position']! as int,
      rate: (first('setPlaybackRate')['playbackRate']! as num).toDouble(),
    );
  }

  fakeTimeTest('a long song prepares its mix only in its last 150 s', () async {
    setLengths(const Duration(minutes: 4));
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    native.positions['music-player'] = 89000;
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(analyzer.calls, isEmpty);
    expect(native.live, {'music-player'});
    expect(autoMixPreparing.value, isFalse);

    native.positions['music-player'] = 90500;
    await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
    expect(analyzer.calls, ['/one.flac', '/two.flac']);
    expect(mixDecks(), hasLength(1));
    native.positions['music-player'] = 235000;
    await _until(() => handler.mediaItem.value?.id == 'two');
  });

  fakeTimeTest(
    'songs skipped before their last 150 s decode and open nothing',
    () async {
      setLengths(const Duration(minutes: 4));
      setAutoMixEnabled(true);
      await handler.setQueueAndPlay([..._tracks, four]);
      native.positions['music-player'] = 10000;
      await Future<void>.delayed(const Duration(seconds: 1));
      await handler.skipToNext();
      native.positions['music-player'] = 60000;
      await Future<void>.delayed(const Duration(seconds: 1));
      await handler.skipToNext();
      native.positions['music-player'] = 85000;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(handler.mediaItem.value?.id, 'three');
      expect(analyzer.calls, isEmpty);
      expect(mixDecks(), isEmpty);

      native.positions['music-player'] = 200000;
      await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
      expect(analyzer.calls, ['/three.flac', '/four.flac']);
      expect(mixDecks(), hasLength(1));
      native.positions['music-player'] = 235000;
      await _until(() => handler.mediaItem.value?.id == 'four');
      expect(analyzer.calls, hasLength(2));
      expect(mixDecks(), hasLength(1));
    },
  );

  fakeTimeTest('a short song still prepares in its first seconds', () async {
    setLengths(const Duration(seconds: 150));
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(analyzer.calls, ['/one.flac', '/two.flac']);
    expect(mixDecks(), hasLength(1));
  });

  fakeTimeTest('preparation is reported until it ends or is dropped', () async {
    analyzer.pending = Completer<AutoMixBeatGrid?>();
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.isNotEmpty);
    expect(autoMixPreparing.value, isTrue);
    analyzer.pending!.complete(null);
    analyzer.pending = null;
    await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
    await _until(() => !autoMixPreparing.value);

    analyzer.pending = Completer<AutoMixBeatGrid?>();
    await handler.skipToNext();
    await _until(() => analyzer.calls.length == 3);
    expect(autoMixPreparing.value, isTrue);
    await handler.skipToNext();
    expect(autoMixPreparing.value, isFalse);
    await handler.skipToPrevious();
    await _until(() => analyzer.calls.length == 4);
    expect(autoMixPreparing.value, isTrue);
    await handler.dispose();
    expect(autoMixPreparing.value, isFalse);
  });

  fakeTimeTest('a pending mix sets its start timer once per song', () async {
    var arms = 0;
    time.onTimer = (_) {
      if (StackTrace.current.toString().contains('_MusicAutoMix.onPosition')) {
        arms++;
      }
    };
    addTearDown(() => time.onTimer = null);
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    playFrom(0);
    await playUntil(
      () => handler.mediaItem.value?.id == 'two',
      const Duration(seconds: 60),
    );
    expect(mixStart(mixDecks().single).at, inInclusiveRange(55000, 55100));
    // One timer from the end of preparation; the 270 ticks since then
    // followed the clock. A loaded machine may move a few by over 20 ms.
    expect(arms, inInclusiveRange(1, 6));
  });

  fakeTimeTest('a long song mixes at its planned moment', () async {
    setLengths(const Duration(seconds: 200));
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    playFrom(0);
    await playUntil(
      () => handler.mediaItem.value?.id == 'two',
      const Duration(seconds: 200),
    );
    final start = mixStart(mixDecks().single);
    expect(start.at, inInclusiveRange(195000, 195100));
    expect(start.cue, 0);
    expect(start.rate, 1);
  });

  fakeTimeTest('a long beat-matched song mixes on its planned beat', () async {
    analyzer.matchBeats = true;
    setLengths(const Duration(seconds: 200));
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    playFrom(0);
    await playUntil(
      () => handler.mediaItem.value?.id == 'two',
      const Duration(seconds: 200),
    );
    final start = mixStart(mixDecks().single);
    // 176.17 s (outro window plus phase) and 39 beats of 0.5 s, 4 s from
    // the end.
    expect(start.at, inInclusiveRange(195670, 195770));
    expect(start.cue, 170);
    expect(start.rate, closeTo(120 / 124, 1e-9));
    expect(autoMixStatus.value, AutoMixStatus.mixing);
  });

  fakeTimeTest(
    'a seek into the last 150 s prepares and mixes on time',
    () async {
      setLengths(const Duration(minutes: 4));
      setAutoMixEnabled(true);
      await handler.setQueueAndPlay(_tracks);
      playFrom(0);
      await Future<void>.delayed(const Duration(seconds: 1));
      await handler.seek(const Duration(seconds: 200));
      await playUntil(
        () => handler.mediaItem.value?.id == 'two',
        const Duration(seconds: 40),
      );
      final start = mixStart(mixDecks().last);
      expect(start.at, inInclusiveRange(235000, 235100));
      expect(start.cue, 0);
      expect(start.rate, 1);
    },
  );

  fakeTimeTest(
    'a seek back out of the last 150 s drops the mix until it returns',
    () async {
      setLengths(const Duration(minutes: 4));
      setAutoMixEnabled(true);
      await handler.setQueueAndPlay(_tracks);
      playFrom(100000);
      await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
      final dropped = native.prepared;
      expect(analyzer.calls, hasLength(2));

      await handler.seek(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(native.live, {'music-player'});
      expect(native.live, isNot(contains(dropped)));
      expect(analyzer.calls, hasLength(2));

      await handler.seek(const Duration(seconds: 89));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(analyzer.calls, hasLength(2));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(analyzer.calls, hasLength(4));
      await playUntil(
        () => handler.mediaItem.value?.id == 'two',
        const Duration(seconds: 150),
      );
      expect(mixStart(mixDecks().last).at, inInclusiveRange(235000, 235100));
    },
  );

  fakeTimeTest('a mix after a beat-matched one starts on time', () async {
    analyzer.matchBeats = true;
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    playFrom(0);
    await playUntil(
      () => handler.mediaItem.value?.id == 'two',
      const Duration(seconds: 60),
    );
    final second = mixDecks().single;
    expect(mixStart(second).at, inInclusiveRange(55670, 55770));
    expect(handler.playbackState.value.speed, closeTo(120 / 124, 1e-9));
    // The second song plays slowed while the first fades, then recovers
    // before its own mix is prepared.
    await playUntil(() => mixDecks().length == 2, const Duration(seconds: 20));
    expect(handler.playbackState.value.speed, 1);
    await playUntil(
      () => handler.mediaItem.value?.id == 'three',
      const Duration(seconds: 60),
    );
    expect(
      mixStart(mixDecks().last, second).at,
      inInclusiveRange(55670, 55770),
    );
    expect(analyzer.calls, hasLength(4));
  });

  fakeTimeTest(
    'a queue edit before the last 150 s costs no preparation',
    () async {
      setLengths(const Duration(minutes: 4));
      setAutoMixEnabled(true);
      await handler.setQueueAndPlay(_tracks);
      playFrom(0);
      await Future<void>.delayed(const Duration(seconds: 10));
      await handler.enqueue(four, playNext: true);
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(analyzer.calls, isEmpty);
      await handler.seek(const Duration(seconds: 100));
      await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
      expect(analyzer.calls, ['/one.flac', '/four.flac']);
      final incoming = native.prepared;
      expect(native.sources[incoming], '/four.flac');
      await playUntil(
        () => handler.mediaItem.value?.id == 'four',
        const Duration(seconds: 140),
      );
      expect(mixStart(incoming).at, inInclusiveRange(235000, 235100));
    },
  );

  fakeTimeTest('repeat all prepares the wrap in the last 150 s', () async {
    setLengths(const Duration(minutes: 4));
    setAutoMixEnabled(true);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    await handler.setQueueAndPlay(_tracks.take(2).toList());
    await handler.skipToNext();
    native.positions['music-player'] = 60000;
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(analyzer.calls, isEmpty);
    native.positions['music-player'] = 200000;
    await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
    expect(analyzer.calls, ['/two.flac', '/one.flac']);
    native.positions['music-player'] = 235000;
    await _until(() => handler.mediaItem.value?.id == 'one');
  });

  fakeTimeTest('exclusive output keeps the last 150 s unmixed', () async {
    setLengths(const Duration(minutes: 4));
    setAutoMixEnabled(true);
    // Settings changes set it from the exclusive output setting.
    playbackExclusiveOutput.value = true;
    addTearDown(() => playbackExclusiveOutput.value = false);
    await handler.setQueueAndPlay(_tracks);
    native.positions['music-player'] = 200000;
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(analyzer.calls, isEmpty);
    expect(native.live, {'music-player'});
    playbackExclusiveOutput.value = false;
    await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
    expect(analyzer.calls, ['/one.flac', '/two.flac']);
  });

  fakeTimeTest(
    'a next song that arrives before the last 150 s is mixed in',
    () async {
      setLengths(const Duration(minutes: 4));
      final arrived = Completer<void>();
      musicPlayerRuntime.streamWhileArriving(
        '/two.flac',
        url: 'http://127.0.0.1:1/two.flac',
        done: arrived.future,
      );
      setAutoMixEnabled(true);
      await handler.setQueueAndPlay(_tracks);
      native.positions['music-player'] = 10000;
      await Future<void>.delayed(const Duration(seconds: 1));
      arrived.complete();
      native.positions['music-player'] = 200000;
      await _until(() => native.calls.any((c) => c.$2 == 'setPlaybackRate'));
      expect(native.sources[native.prepared], '/two.flac');
    },
  );
}
