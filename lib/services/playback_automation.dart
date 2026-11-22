// Device types are experimental in audio_session. Keep their interpretation
// here so platform route changes do not leak into transport or settings code.
// ignore_for_file: experimental_member_use

import 'package:audio_session/audio_session.dart';
import 'package:mornye/services/autoplay_personalization.dart'
    show AutoplayOutput;

/// The kind of output music plays on. Another device playing comes first,
/// then a DAC the player holds, then the connected [devices] (null where
/// the platform cannot list them). Two possible routes leave it unknown.
AutoplayOutput playbackOutputKind({
  Set<AudioDevice>? devices,
  bool dac = false,
  bool elsewhere = false,
}) {
  if (elsewhere) return AutoplayOutput.remote;
  if (dac) return AutoplayOutput.dac;
  if (devices == null) return AutoplayOutput.unknown;
  final routes = <AutoplayOutput>{};
  var speaker = false;
  for (final device in devices) {
    if (!device.isOutput) continue;
    switch (device.type) {
      case AudioDeviceType.builtInSpeaker:
        speaker = true;
      // Call and system routes, never music's.
      case AudioDeviceType.builtInEarpiece ||
          AudioDeviceType.builtInSpeakerSafe ||
          AudioDeviceType.bluetoothSco ||
          AudioDeviceType.telephony ||
          AudioDeviceType.remoteSubmix ||
          AudioDeviceType.fm:
        break;
      case AudioDeviceType.wiredHeadset || AudioDeviceType.wiredHeadphones:
        routes.add(AutoplayOutput.wired);
      case AudioDeviceType.bluetoothA2dp ||
          AudioDeviceType.bluetoothLe ||
          AudioDeviceType.hearingAid:
        routes.add(AutoplayOutput.bluetooth);
      case AudioDeviceType.usbAudio:
        routes.add(AutoplayOutput.dac);
      case AudioDeviceType.carAudio:
        routes.add(AutoplayOutput.car);
      case AudioDeviceType.airPlay:
        routes.add(AutoplayOutput.remote);
      default:
        routes.add(AutoplayOutput.unknown);
    }
  }
  if (routes.length == 1) return routes.single;
  return routes.isEmpty && speaker
      ? AutoplayOutput.speaker
      : AutoplayOutput.unknown;
}

/// How long a pause from a lost headphone or Bluetooth route stays resumable
/// when an output connects again. Long enough for a car or a charging case,
/// short enough that music does not start hours later.
const noisyPauseResumeWindow = Duration(minutes: 30);

/// Whether a connection at [now] resumes the route-loss pause made at
/// [pausedAt]. A clock that went back counts as too old.
bool resumesNoisyPause(
  DateTime? pausedAt,
  DateTime now, {
  Duration window = noisyPauseResumeWindow,
}) {
  if (pausedAt == null) return false;
  final elapsed = now.difference(pausedAt);
  return !elapsed.isNegative && elapsed <= window;
}

/// Serializes automatic transport requests and remembers who paused playback.
/// A volume change must never undo an explicit pause or a lost output route.
class PlaybackAutomation {
  PlaybackAutomation({
    required bool Function() isPlaying,
    required bool Function() canResume,
    required Future<void> Function() pause,
    required Future<void> Function() play,
    required void Function(Object) onError,
    void Function()? onMutedPause,
    DateTime Function()? now,
  }) : _isPlaying = isPlaying,
       _canResume = canResume,
       _pause = pause,
       _play = play,
       _onError = onError,
       _onMutedPause = onMutedPause,
       _now = now ?? DateTime.now;

  final bool Function() _isPlaying;
  final bool Function() _canResume;
  final Future<void> Function() _pause;
  final Future<void> Function() _play;
  final void Function(Object) _onError;
  final void Function()? _onMutedPause;
  final DateTime Function() _now;
  bool _pauseOnMute = false;
  bool _playOnHeadphonesConnected = false;
  bool _resumeAfterNoisyPause = false;
  bool? _muted;
  bool _pausedByMute = false;
  bool _allowMutedPlayback = false;
  bool _disposed = false;
  int _intentRevision = 0;
  Set<String>? _headphones;

  /// When playing music was paused because its output route went away.
  /// Kept in memory only, so a pause from before the app was killed is
  /// never resumed.
  DateTime? _noisyPauseAt;
  Future<void> _tail = Future<void>.value();

  bool get blocksPlayback =>
      _pauseOnMute && _muted != false && !_allowMutedPlayback;

  bool get _watchesDevices =>
      _playOnHeadphonesConnected || _resumeAfterNoisyPause;

  Future<void> configure({
    required bool pauseOnMute,
    required bool playOnHeadphonesConnected,
    bool resumeAfterNoisyPause = false,
  }) {
    if (_pauseOnMute == pauseOnMute &&
        _playOnHeadphonesConnected == playOnHeadphonesConnected &&
        _resumeAfterNoisyPause == resumeAfterNoisyPause) {
      return _tail;
    }
    final watchedDevices = _watchesDevices;
    cancelPendingActions();
    if (_pauseOnMute != pauseOnMute) {
      _muted = null;
      _allowMutedPlayback = false;
    }
    _pauseOnMute = pauseOnMute;
    _playOnHeadphonesConnected = playOnHeadphonesConnected;
    _resumeAfterNoisyPause = resumeAfterNoisyPause;
    if (watchedDevices != _watchesDevices) _headphones = null;
    return _enqueue(_applyVolume);
  }

  /// Any explicit transport change, track change or other pause supersedes
  /// automatic work, including a resumable route-loss pause.
  void cancelPendingActions() {
    _cancelQueued();
    _noisyPauseAt = null;
  }

  void _cancelQueued() {
    _intentRevision++;
    _pausedByMute = false;
  }

  /// Playing music was paused because headphones or a Bluetooth output went
  /// away. Call after the pause request supersedes pending actions.
  void noisyPause() => _noisyPauseAt = _now();

  /// A second, explicit Play accepts silent playback until volume is raised.
  /// Keep this choice across source reloads and duplicate zero-volume events.
  void manualPlaybackRequested() {
    if (_pausedByMute && _muted == true) _allowMutedPlayback = true;
    cancelPendingActions();
  }

  Future<void> volumeChanged(double volume) {
    if (!volume.isFinite) return _tail;
    _muted = volume <= 0;
    if (!_muted!) _allowMutedPlayback = false;
    return _enqueue(_applyVolume);
  }

  Future<void> playbackStarted() => _enqueue(_applyVolume);

  Future<void> _applyVolume() async {
    if (!_pauseOnMute) return;
    if (_muted == true && !_allowMutedPlayback) {
      if (_isPlaying() && _canResume()) {
        _pausedByMute = true;
        await _pause();
        if (_pausedByMute && _muted == true && !_allowMutedPlayback) {
          _onMutedPause?.call();
        }
      }
    } else if (_muted == false && _pausedByMute) {
      _pausedByMute = false;
      if (!_isPlaying() && _canResume()) await _play();
    }
  }

  Future<void> devicesChanged(Set<AudioDevice> devices) {
    final headphones = devices
        .where(_isHeadphoneOutput)
        .map((device) => device.id)
        .toSet();
    final previous = _headphones;
    _headphones = headphones;
    // The initial device inventory is not a connection gesture.
    if (previous == null || !_watchesDevices) return _tail;
    if (previous.isNotEmpty && headphones.isEmpty) {
      if (!_playOnHeadphonesConnected) return _tail;
      // The route-loss pause stays resumable; this pause is the same one.
      _cancelQueued();
      return _enqueue(() async {
        if (_isPlaying()) await _pause();
      });
    }
    if (headphones.difference(previous).isEmpty) return _tail;
    return _enqueue(() async {
      final resumesNoisy =
          _resumeAfterNoisyPause && resumesNoisyPause(_noisyPauseAt, _now());
      _noisyPauseAt = null;
      if ((_playOnHeadphonesConnected || resumesNoisy) &&
          !blocksPlayback &&
          !_isPlaying() &&
          _canResume()) {
        await _play();
      }
    });
  }

  static bool _isHeadphoneOutput(AudioDevice device) =>
      device.isOutput &&
      const {
        AudioDeviceType.wiredHeadset,
        AudioDeviceType.wiredHeadphones,
        AudioDeviceType.usbAudio,
        AudioDeviceType.bluetoothA2dp,
        AudioDeviceType.bluetoothLe,
        AudioDeviceType.hearingAid,
      }.contains(device.type);

  Future<void> _enqueue(Future<void> Function() action) {
    final revision = _intentRevision;
    _tail = _tail.then((_) async {
      if (_disposed || revision != _intentRevision) return;
      try {
        await action();
      } catch (error) {
        _pausedByMute = false;
        _onError(error);
      }
    });
    return _tail;
  }

  Future<void> dispose() async {
    _disposed = true;
    cancelPendingActions();
    await _tail;
  }
}
