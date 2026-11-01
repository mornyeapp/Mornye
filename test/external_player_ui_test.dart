import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/music_player_runtime.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  void setPlayerMode(String mode) => state = state.copyWith(playerMode: mode);
}

class _Runtime extends MusicPlayerRuntime {
  _Runtime(this.source);

  final String source;

  MediaItem get item =>
      MediaItem(id: 'song', title: 'Song', extras: {'source': source});

  @override
  Stream<MediaItem?> mediaItemEvents() => Stream.value(item);

  @override
  Stream<PlaybackState> playbackStateEvents() =>
      Stream.value(PlaybackState(playing: true, queueIndex: 0));

  @override
  Stream<List<MediaItem>> queueEvents() => Stream.value([item]);
}

void main() {
  test(
    'external mode hides the internal session and restores UI on return',
    () async {
      final runtime = _Runtime('/music/song.flac');
      addTearDown(runtime.dispose);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
        ],
      );
      addTearDown(container.dispose);
      container.listen(currentMediaItemProvider, (_, _) {});
      container.listen(playbackStateProvider, (_, _) {});
      container.listen(playQueueProvider, (_, _) {});
      expect(
        (await container.read(currentMediaItemProvider.future))?.id,
        'song',
      );
      expect(
        (await container.read(playbackStateProvider.future)).playing,
        isTrue,
      );
      expect(await container.read(playQueueProvider.future), hasLength(1));

      container.read(settingsProvider.notifier).setPlayerMode('external');
      await container.pump();
      expect(container.read(playerUiEnabledProvider), isFalse);
      expect(await container.read(currentMediaItemProvider.future), isNull);
      expect(
        (await container.read(playbackStateProvider.future)).playing,
        isFalse,
      );
      expect(await container.read(playQueueProvider.future), isEmpty);
      expect(await container.read(playbackResumeProvider.future), isNull);
      expect(
        container
            .read(
              mediaItemPlaybackUiProvider((id: 'song', path: runtime.source)),
            )
            .isCurrent,
        isFalse,
      );

      container.read(settingsProvider.notifier).setPlayerMode('internal');
      await container.pump();
      expect(container.read(playerUiEnabledProvider), isTrue);
      expect(
        (await container.read(currentMediaItemProvider.future))?.id,
        'song',
      );
      expect(
        (await container.read(playbackStateProvider.future)).playing,
        isTrue,
      );
    },
  );

  test(
    'network playback retains controls when the internal player is required',
    () async {
      final runtime = _Runtime('network://fixture/song.flac');
      addTearDown(runtime.dispose);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
        ],
      );
      addTearDown(container.dispose);
      container.read(settingsProvider.notifier).setPlayerMode('external');
      container.listen(playerUiEnabledProvider, (_, _) {});
      container.listen(currentMediaItemProvider, (_, _) {});
      container.listen(playbackStateProvider, (_, _) {});
      container.listen(playQueueProvider, (_, _) {});
      await container.read(localMediaItemProvider.future);
      await container.pump();
      expect(container.read(playerUiEnabledProvider), isTrue);
      expect(
        (await container.read(currentMediaItemProvider.future))?.id,
        'song',
      );
      expect(
        (await container.read(playbackStateProvider.future)).playing,
        isTrue,
      );
      expect(await container.read(playQueueProvider.future), hasLength(1));
      expect(await container.read(playbackResumeProvider.future), isNull);
    },
  );
}
