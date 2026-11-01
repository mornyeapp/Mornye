import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:smtc_windows/smtc_windows.dart' as smtc;

final _log = AppLogger('Smtc');

/// The System Media Transport Controls calls the session makes. The default
/// wraps smtc_windows; tests substitute a fake.
abstract interface class SmtcControls {
  Stream<smtc.PressedButton> get buttons;
  Future<void> setStatus(smtc.PlaybackStatus status);
  Future<void> setTimeline(smtc.PlaybackTimeline timeline);
  Future<void> setMetadata(smtc.MusicMetadata metadata);
  Future<void> setNextPrevious({required bool next, required bool previous});
}

class _WindowsSmtcControls implements SmtcControls {
  _WindowsSmtcControls(this._smtc);

  static Future<SmtcControls> create() async {
    await smtc.SMTCWindows.initialize();
    return _WindowsSmtcControls(
      smtc.SMTCWindows(
        config: const smtc.SMTCConfig(
          playEnabled: true,
          pauseEnabled: true,
          nextEnabled: true,
          prevEnabled: true,
          stopEnabled: false,
          fastForwardEnabled: false,
          rewindEnabled: false,
        ),
      ),
    );
  }

  final smtc.SMTCWindows _smtc;

  @override
  Stream<smtc.PressedButton> get buttons => _smtc.buttonPressStream;
  @override
  Future<void> setStatus(smtc.PlaybackStatus status) =>
      _smtc.setPlaybackStatus(status);
  @override
  Future<void> setTimeline(smtc.PlaybackTimeline timeline) =>
      _smtc.updateTimeline(timeline);
  @override
  Future<void> setMetadata(smtc.MusicMetadata metadata) =>
      _smtc.updateMetadata(metadata);
  @override
  Future<void> setNextPrevious({required bool next, required bool previous}) {
    final config = _smtc.config;
    if (config.nextEnabled == next && config.prevEnabled == previous) {
      return Future.value();
    }
    return _smtc.updateConfig(
      smtc.SMTCConfig(
        playEnabled: config.playEnabled,
        pauseEnabled: config.pauseEnabled,
        stopEnabled: config.stopEnabled,
        nextEnabled: next,
        prevEnabled: previous,
        fastForwardEnabled: config.fastForwardEnabled,
        rewindEnabled: config.rewindEnabled,
      ),
    );
  }
}

/// The Windows media session: audio_service's platform calls shown in the
/// System Media Transport Controls (media keys, the volume flyout and the
/// lock screen). The controls offer no seek request, so seeking stays in
/// the app.
class SmtcAudioService extends NoOpAudioService {
  SmtcAudioService({Future<SmtcControls> Function()? create})
    : _create = create ?? _WindowsSmtcControls.create;

  /// How often a playing timeline is refreshed when nothing else changes,
  /// as Microsoft suggests for the timeline properties.
  static const timelineInterval = Duration(seconds: 5);

  /// How far a playing position may depart from the last timeline before
  /// it counts as a jump, as in MPRIS.
  static const jumpTolerance = Duration(seconds: 1);

  final Future<SmtcControls> Function() _create;
  SmtcControls? _controls;
  StreamSubscription<smtc.PressedButton>? _buttons;
  AudioHandlerCallbacks? _callbacks;
  PlaybackStateMessage? _state;
  MediaItemMessage? _item;

  /// The status the controls were last given and the state their timeline
  /// was last built from. A failed update clears its value, so the next
  /// state sends it again.
  smtc.PlaybackStatus? _status;
  PlaybackStateMessage? _timeline;

  @override
  Future<void> configure(ConfigureRequest request) async {
    if (_controls != null) return;
    try {
      final controls = await _create();
      _controls = controls;
      _buttons = controls.buttons.listen(_pressed);
    } catch (error) {
      _log.w('Media transport controls are unavailable: $error');
    }
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      _callbacks = callbacks;

  void _pressed(smtc.PressedButton button) {
    final callbacks = _callbacks;
    if (callbacks == null) return;
    final Future<void> action = switch (button) {
      smtc.PressedButton.play => callbacks.play(const PlayRequest()),
      smtc.PressedButton.pause => callbacks.pause(const PauseRequest()),
      smtc.PressedButton.next => callbacks.skipToNext(
        const SkipToNextRequest(),
      ),
      smtc.PressedButton.previous => callbacks.skipToPrevious(
        const SkipToPreviousRequest(),
      ),
      smtc.PressedButton.stop => callbacks.stop(const StopRequest()),
      _ => Future.value(),
    };
    unawaited(
      action.catchError(
        (Object error) => _log.w('Media control ${button.name}: $error'),
      ),
    );
  }

  bool _can(MediaActionMessage action) {
    final state = _state;
    if (state == null) return false;
    return state.systemActions.contains(action) ||
        state.controls.any((control) => control.action == action);
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    _state = request.state;
    final controls = _controls;
    if (controls == null) return;
    final state = request.state;
    await _guard(() async {
      await _setStatus(controls, _statusOf(state));
      await controls.setNextPrevious(
        next: _can(MediaActionMessage.skipToNext),
        previous: _can(MediaActionMessage.skipToPrevious),
      );
      if (_timelineDue(state)) await _publishTimeline(controls);
    });
  }

  static smtc.PlaybackStatus _statusOf(PlaybackStateMessage state) =>
      state.processingState == AudioProcessingStateMessage.idle
      ? smtc.PlaybackStatus.stopped
      : state.playing
      ? smtc.PlaybackStatus.playing
      : smtc.PlaybackStatus.paused;

  Future<void> _setStatus(
    SmtcControls controls,
    smtc.PlaybackStatus status,
  ) async {
    if (_status == status) return;
    _status = status;
    try {
      await controls.setStatus(status);
    } catch (_) {
      _status = null;
      rethrow;
    }
  }

  /// Whether [state] needs a new timeline: a status or speed change, a seek
  /// or jump, or [timelineInterval] since the last one while playing. The
  /// controls carry no rate, so between updates they show the last one or
  /// advance it themselves.
  bool _timelineDue(PlaybackStateMessage state) {
    final sent = _timeline;
    if (sent == null) return true;
    final status = _statusOf(sent);
    if (status != _statusOf(state) || sent.speed != state.speed) return true;
    if (status != smtc.PlaybackStatus.playing) {
      return state.updatePosition != sent.updatePosition;
    }
    final elapsed = state.updateTime.difference(sent.updateTime);
    if (elapsed >= timelineInterval) return true;
    final expected = sent.updatePosition + elapsed * sent.speed;
    return (state.updatePosition - expected).abs() > jumpTolerance;
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    _item = request.mediaItem;
    final controls = _controls;
    if (controls == null) return;
    final item = request.mediaItem;
    await _guard(() async {
      await controls.setMetadata(
        smtc.MusicMetadata(
          title: item.title,
          artist: item.artist,
          album: item.album,
          thumbnail: thumbnailFor(item),
        ),
      );
      await _publishTimeline(controls);
    });
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    final controls = _controls;
    if (controls == null) return;
    await _guard(() => _setStatus(controls, smtc.PlaybackStatus.stopped));
  }

  Future<void> _publishTimeline(SmtcControls controls) async {
    final state = _timeline = _state;
    final length = _item?.duration ?? Duration.zero;
    final position = state?.updatePosition ?? Duration.zero;
    try {
      await controls.setTimeline(
        smtc.PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: length.inMilliseconds,
          positionMs: position.inMilliseconds.clamp(0, length.inMilliseconds),
          minSeekTimeMs: 0,
          maxSeekTimeMs: length.inMilliseconds,
        ),
      );
    } catch (_) {
      _timeline = null;
      rethrow;
    }
  }

  /// Artwork the controls can read: the file audio_service cached, or an
  /// http(s) URL. Other schemes would fail to parse in the plugin.
  static String? thumbnailFor(MediaItemMessage item) {
    final cached = item.extras?['artCacheFile'];
    if (cached is String && cached.isNotEmpty) {
      return Uri.file(cached, windows: true).toString();
    }
    final uri = item.artUri;
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      return uri.toString();
    }
    if (uri != null && uri.scheme == 'file') return uri.toString();
    return null;
  }

  Future<void> _guard(Future<void> Function() update) async {
    try {
      await update();
    } catch (error) {
      _log.w('Could not update the media transport controls: $error');
    }
  }

  /// Stops listening, for tests and shutdown.
  Future<void> close() async {
    await _buttons?.cancel();
    _buttons = null;
  }
}
