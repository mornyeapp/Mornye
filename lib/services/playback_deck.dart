import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Transport state reported by a [PlaybackDeck].
enum PlaybackDeckState { stopped, playing, paused, completed, disposed }

/// The engine behind `PlaybackDependencies.createDeck`.
enum PlaybackEngine {
  /// audioplayers: Android, iOS and macOS, where the forks carry the
  /// equalizer tap and Android's USB output. Android can move ordinary
  /// sources to media3 ([playbackMedia3Engine]).
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

/// Android: the beta `media3Engine` setting, off by default. While it is on,
/// the music player and AutoMix decks play through media3
/// (`Media3EngineDeck`), except sources for the native USB and AAudio
/// outputs, which stay on audioplayers. A change applies from the next song.
final playbackMedia3Engine = ValueNotifier<bool>(false);

/// Android: the `skipSilence` setting while [playbackMedia3Engine] is on and
/// AutoMix is off. media3 decks jump over silent passages while it is true;
/// audioplayers decks ignore it.
final playbackSkipSilence = ValueNotifier<bool>(false);

/// The `playbackSpeed` setting. Every deck multiplies the rate it is given
/// ([PlaybackDeck.setPlaybackRate], 1 unless AutoMix is beat matching) by
/// this value, and applies a change at once, also mid-song.
final playbackSpeed = ValueNotifier<double>(1);

/// Pitch for every song, from the `playbackKeepPitch` and `playbackPitch`
/// settings.
@immutable
class PlaybackPitch {
  const PlaybackPitch({this.semitones = 0, this.followsRate = false});

  /// No shift; the pitch stays put while the speed changes.
  static const none = PlaybackPitch();

  /// Shift on top of [followsRate], from -12 to 12.
  final double semitones;

  /// True lets the pitch follow the deck's effective rate (a record played
  /// faster or slower); false keeps it while the speed changes.
  final bool followsRate;

  /// Frequency factor for a deck playing at [rate] (its effective rate,
  /// [playbackSpeed] included).
  double factorAt(double rate) =>
      math.pow(2, semitones / 12).toDouble() * (followsRate ? rate : 1);

  @override
  bool operator ==(Object other) =>
      other is PlaybackPitch &&
      other.semitones == semitones &&
      other.followsRate == followsRate;

  @override
  int get hashCode => Object.hash(semitones, followsRate);
}

/// Applied by every deck that can change pitch, at once, also mid-song.
final playbackPitch = ValueNotifier<PlaybackPitch>(PlaybackPitch.none);

/// What the output playing now can do with [playbackSpeed] and
/// [playbackPitch]. The music player keeps it current for the deck that
/// plays; the speed and pitch controls read it.
enum PlaybackTempoSupport {
  /// Speed, keeping or following pitch, and the pitch shift.
  full,

  /// Speed only (pitch kept); the pitch controls do nothing on this output.
  speedOnly,

  /// Neither: the audio does not pass through the app (Cast, Android USB
  /// bit-perfect or direct output).
  none,
}

final playbackTempoSupport = ValueNotifier<PlaybackTempoSupport>(
  PlaybackTempoSupport.full,
);

/// Counts changes of a deck's [PlaybackDeck.tempoSupport] that no call to
/// the deck caused (an engine refusing a pitch shift for its source), so
/// the music player publishes [playbackTempoSupport] again.
final playbackTempoSupportRevision = ValueNotifier<int>(0);

/// Called by a deck whose [PlaybackDeck.tempoSupport] changed by itself.
void notifyPlaybackTempoSupportChanged() =>
    playbackTempoSupportRevision.value++;

/// The `spatialAudio` setting. True lets the platform spatialize songs (its
/// default on Android); false asks it never to. media3 decks and the
/// audioplayers forks apply it; libmpv decks ignore it.
final playbackSpatialAudio = ValueNotifier<bool>(true);

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

/// A deck that can append a source to its existing output without opening a
/// second device. The start callback replaces the ordinary completion handoff.
abstract interface class QueuedPlaybackDeck implements PlaybackDeck {
  bool get canQueueNextSource;
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  });
  Future<void> clearNextSource();
}

/// One audio player owned by the music runtime. The main player and each
/// AutoMix deck are separate instances created through
/// `PlaybackDependencies.createDeck`.
///
/// Every implementation also:
/// - applies `playbackEqualizer` (`playback_equalizer.dart`) to its own output
///   and reports failures with `reportEqualizerError`, keyed by player id;
/// - multiplies [setVolume] by [playbackOutputVolume];
/// - multiplies [setPlaybackRate] by [playbackSpeed] and applies
///   [playbackPitch] at that effective rate, as far as [tempoSupport] says,
///   at once on every change, also mid-song and while paused (without
///   starting playback), and to every later source;
/// - delivers runtime failures as errors on [onPlayerStateChanged], and makes
///   [resume] throw when the current source failed to load.
abstract interface class PlaybackDeck {
  PlaybackDeckState get state;

  /// True while a native output bypasses the mixer (Android USB bit-perfect).
  /// Volume, rate and the equalizer have no effect in that mode.
  bool get isDirect;

  /// What this deck does with [playbackSpeed] and [playbackPitch] for the
  /// source it holds now. A change the deck notices by itself also calls
  /// [notifyPlaybackTempoSupportChanged].
  PlaybackTempoSupport get tempoSupport;

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
  /// throws when the deck cannot play DSD. [usbMaxSampleRate] above zero is
  /// the highest rate the direct USB driver may set on the DAC, and
  /// [usbDitherHighPass] picks high-pass dither for a song it converts.
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
