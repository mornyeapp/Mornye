import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Transport state reported by a [PlaybackDeck].
enum PlaybackDeckState { stopped, playing, paused, completed, disposed }

/// The engine behind `PlaybackDependencies.createDeck`.
enum PlaybackEngine {
  /// audioplayers: Android, iOS and macOS, where the forks carry the
  /// equalizer tap and Android's USB output.
  audioplayers,

  /// libmpv through media_kit: Windows and Linux.
  mediaKit,
}

/// Forces [playbackEngine], for tests that drive one engine on any host.
@visibleForTesting
PlaybackEngine? debugPlaybackEngineOverride;

PlaybackEngine get playbackEngine {
  final override = debugPlaybackEngineOverride;
  if (override != null) return override;
  if (!isDesktopPlatform) return PlaybackEngine.audioplayers;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux => PlaybackEngine.mediaKit,
    _ => PlaybackEngine.audioplayers,
  };
}

/// In-app output gain from 0 to 1 for platforms where the app must not change
/// the system volume (desktop). Every deck multiplies the gain it is given
/// (normalization, AutoMix fades) by this value. Mobile keeps it at 1.
final playbackOutputVolume = ValueNotifier<double>(1);

/// [playbackOutputVolume] as a stream: the current value, then each change.
Stream<double> playbackOutputVolumeChanges() =>
    Stream<double>.multi((listener) {
      void changed() => listener.add(playbackOutputVolume.value);
      playbackOutputVolume.addListener(changed);
      changed();
      listener.onCancel = () => playbackOutputVolume.removeListener(changed);
    });

/// Desktop exclusive output, from the `exclusiveOutput` setting, always
/// through libmpv: WASAPI exclusive on Windows, Core Audio hog mode on macOS
/// (see `ExclusiveOutputDeck`), an ALSA `hw:` device on Linux. AutoMix and
/// previews stay off while it is on, so only the main player opens the
/// device.
final playbackExclusiveOutput = ValueNotifier<bool>(false);

/// Linux: the ALSA device [playbackExclusiveOutput] opens, as an mpv device
/// name. Empty until one is known; the output stays shared meanwhile.
final playbackExclusiveDevice = ValueNotifier<String>('');

/// Whether [playbackExclusiveOutput] took the device for the current track.
enum ExclusiveOutputStatus {
  /// Off, or no track has opened the output since it was turned on.
  pending,

  /// The current track plays in exclusive mode.
  active,

  /// The device refused exclusive access (another app holds it, or exclusive
  /// control is disallowed); the track plays through the system mixer.
  unavailable,
}

final playbackExclusiveStatus = ValueNotifier<ExclusiveOutputStatus>(
  ExclusiveOutputStatus.pending,
);

/// One audio player owned by the music runtime. The main player and each
/// AutoMix deck are separate instances created through
/// `PlaybackDependencies.createDeck`.
///
/// Every implementation also:
/// - applies `playbackEqualizer` (`playback_equalizer.dart`) to its own output
///   and reports failures with `reportEqualizerError`, keyed by player id;
/// - multiplies [setVolume] by [playbackOutputVolume];
/// - delivers runtime failures as errors on [onPlayerStateChanged], and makes
///   [resume] throw when the current source failed to load.
abstract interface class PlaybackDeck {
  PlaybackDeckState get state;

  /// True while a native output bypasses the mixer (Android USB bit-perfect).
  /// Volume, rate and the equalizer have no effect in that mode.
  bool get isDirect;

  /// True when a direct output lost its route and the source must be loaded
  /// again before playback can continue.
  bool get needsSourceReload;

  Stream<PlaybackDeckState> get onPlayerStateChanged;
  Stream<Duration> get onDurationChanged;
  Stream<Duration> get onPositionChanged;
  Stream<void> get onPlayerComplete;

  /// Emits [onPositionChanged] every [interval] while playing. Updates must
  /// not depend on rendered frames: AutoMix runs with the display asleep.
  /// A tick [wanted] answers false for is skipped without asking the engine.
  void startPositionUpdates(Duration interval, {bool Function()? wanted});

  /// Applies the platform's music output configuration (audio focus, usage,
  /// keeping the source after completion). Called before each new source.
  Future<void> configureOutput();

  /// Linear gain from 0 to 1, before [playbackOutputVolume].
  Future<void> setVolume(double volume);
  Future<void> setPlaybackRate(double rate);

  /// Loads [url]. [arriving] marks a file still being written behind it (a
  /// song a paired phone is sending), which must start before it is whole.
  Future<void> setNetworkSource(String url, {bool arriving = false});

  /// Loads a local file. The output flags request Android's native USB and
  /// exclusive paths; other decks ignore them, except that [requiresDsd]
  /// throws when the deck cannot play DSD.
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  });

  /// Abandons a source that is still preparing, if any.
  Future<void> cancelPreparation();

  Future<void> resume();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// Has the engine start [next], a paused deck holding a loaded source, the
  /// moment this deck's source ends, so the two songs join without a gap.
  /// [resume] on [next] afterwards only confirms the state. Returns false
  /// when the engine cannot chain these decks; [next] then waits for
  /// [resume]. Null unlinks a deck set earlier.
  Future<bool> setNextDeck(PlaybackDeck? next);

  Future<Duration?> getCurrentPosition();
  Future<Duration?> getDuration();

  /// Releases the native player. The deck is unusable afterwards.
  Future<void> dispose();
}
