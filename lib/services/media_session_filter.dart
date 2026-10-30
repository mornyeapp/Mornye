import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';

/// The system media session (notification, lock screen, Bluetooth, cars and
/// watches) behind [platform], sent only the playback states it cannot work
/// out itself. The OS advances the position from the last state's position,
/// update time and speed, so a state that differs only by a position within
/// [tolerance] of that is held back. The app's own listeners still see every
/// state.
class MediaSessionFilter extends AudioServicePlatform {
  MediaSessionFilter(this.platform);

  final AudioServicePlatform platform;

  /// How far the position may drift from what the OS shows while playing.
  static const tolerance = Duration(milliseconds: 500);

  /// What the OS was last sent, and the newest state it was offered.
  PlaybackStateMessage? _sent;
  SetStateRequest? _latest;

  /// Whether the next state goes out whatever it holds.
  bool _followUp = false;

  @override
  Future<void> setState(SetStateRequest request) {
    _latest = request;
    final sent = _sent;
    if (!_followUp && sent != null && _advancesTo(sent, request.state)) {
      return Future.value();
    }
    return _send(request);
  }

  Future<void> _send(SetStateRequest request) async {
    final previous = _sent;
    final state = _sent = request.state;
    // Apple's Now Playing takes a playing state's position again only when
    // it changes, so after a stall or a load at the same position it keeps
    // advancing from the earlier one until the next state.
    _followUp =
        previous != null &&
        previous.playing &&
        state.playing &&
        previous.speed == state.speed &&
        previous.updatePosition == state.updatePosition;
    try {
      await platform.setState(request);
    } catch (_) {
      if (identical(_sent, request.state)) _sent = null;
      rethrow;
    }
  }

  /// Apple's Now Playing republishes each media item with the position of
  /// the last state as it was, not advanced. The newest state goes first and
  /// the next one follows, so the position is current again within a tick.
  @override
  Future<void> setMediaItem(SetMediaItemRequest request) {
    final latest = _latest;
    if (latest != null && !identical(latest.state, _sent)) {
      // A failure clears what was sent, so the next state goes out.
      _send(latest).ignore();
    }
    _followUp = true;
    return platform.setMediaItem(request);
  }

  /// A stopped session starts again from the next state.
  @override
  Future<void> stopService(StopServiceRequest request) {
    _sent = null;
    _latest = null;
    return platform.stopService(request);
  }

  @override
  Future<void> configure(ConfigureRequest request) =>
      platform.configure(request);

  @override
  Future<void> setQueue(SetQueueRequest request) => platform.setQueue(request);

  @override
  Future<void> setAndroidPlaybackInfo(SetAndroidPlaybackInfoRequest request) =>
      platform.setAndroidPlaybackInfo(request);

  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) => platform.androidForceEnableMediaButtons(request);

  @override
  Future<void> notifyChildrenChanged(NotifyChildrenChangedRequest request) =>
      platform.notifyChildrenChanged(request);

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      platform.setHandlerCallbacks(callbacks);

  /// Whether the OS, shown [sent], already shows [next]: nothing but the
  /// position changed, and only as far as [sent] advances on its own.
  static bool _advancesTo(
    PlaybackStateMessage sent,
    PlaybackStateMessage next,
  ) {
    if (sent.processingState != next.processingState ||
        sent.playing != next.playing ||
        sent.speed != next.speed ||
        sent.bufferedPosition != next.bufferedPosition ||
        sent.queueIndex != next.queueIndex ||
        sent.repeatMode != next.repeatMode ||
        sent.shuffleMode != next.shuffleMode ||
        sent.captioningEnabled != next.captioningEnabled ||
        sent.errorCode != next.errorCode ||
        sent.errorMessage != next.errorMessage ||
        !setEquals(sent.systemActions, next.systemActions) ||
        !listEquals(
          sent.androidCompactActionIndices,
          next.androidCompactActionIndices,
        ) ||
        !_sameControls(sent.controls, next.controls)) {
      return false;
    }
    final advancing =
        sent.playing &&
        sent.processingState == AudioProcessingStateMessage.ready;
    if (!advancing) return sent.updatePosition == next.updatePosition;
    final expected =
        sent.updatePosition +
        next.updateTime.difference(sent.updateTime) * sent.speed;
    return (next.updatePosition - expected).abs() < tolerance;
  }

  static bool _sameControls(
    List<MediaControlMessage> a,
    List<MediaControlMessage> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.androidIcon != y.androidIcon ||
          x.label != y.label ||
          x.action != y.action ||
          x.customAction?.name != y.customAction?.name ||
          !mapEquals(x.customAction?.extras, y.customAction?.extras)) {
        return false;
      }
    }
    return true;
  }
}

/// Installs [MediaSessionFilter] before `AudioService.init`, which reads the
/// platform instance once. The Android, iOS and macOS sessions advance the
/// position on their own; Windows and Linux keep every state as before.
void installMediaSessionFilter() {
  final platform = AudioServicePlatform.instance;
  if (platform is MediaSessionFilter) return;
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    AudioServicePlatform.instance = MediaSessionFilter(platform);
  }
}
