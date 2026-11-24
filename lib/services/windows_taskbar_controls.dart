import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('WindowsTaskbar');

typedef _Toolbar = ({
  bool visible,
  bool playing,
  bool toggle,
  bool previous,
  bool next,
  String toggleLabel,
  String previousLabel,
  String nextLabel,
});

/// The Windows thumbnail toolbar, sharing the system media session's handler.
class WindowsTaskbarControls {
  WindowsTaskbarControls({
    MethodChannel channel = const MethodChannel('com.zarz.mornye/taskbar'),
  }) : _channel = channel;

  final MethodChannel _channel;
  AudioHandlerCallbacks? callbacks;
  PlaybackStateMessage? _state;
  _Toolbar? _wanted, _sent;
  Future<void>? _sending;
  bool _closed = false;
  bool _reportedFailure = false;

  void initialize() => _channel.setMethodCallHandler(_pressed);

  bool _can(MediaActionMessage action) =>
      _state?.systemActions.contains(action) == true ||
      _state?.controls.any((control) => control.action == action) == true;

  String _label(MediaActionMessage action, String fallback) {
    for (final control in _state?.controls ?? const <MediaControlMessage>[]) {
      if (control.action == action && control.label.isNotEmpty) {
        return control.label;
      }
    }
    return fallback;
  }

  Future<void> update(PlaybackStateMessage state) {
    if (_closed) return Future.value();
    _state = state;
    final action = state.playing
        ? MediaActionMessage.pause
        : MediaActionMessage.play;
    _wanted = (
      visible: state.processingState != AudioProcessingStateMessage.idle,
      playing: state.playing,
      toggle: _can(action) || _can(MediaActionMessage.playPause),
      previous: _can(MediaActionMessage.skipToPrevious),
      next: _can(MediaActionMessage.skipToNext),
      toggleLabel: _label(action, state.playing ? 'Pause' : 'Play'),
      previousLabel: _label(MediaActionMessage.skipToPrevious, 'Previous'),
      nextLabel: _label(MediaActionMessage.skipToNext, 'Next'),
    );
    if (_wanted == _sent) return _sending ?? Future.value();
    return _sending ??= _flush();
  }

  Future<void> _flush() async {
    try {
      while (!_closed && _wanted != _sent) {
        final state = _wanted!;
        await _channel.invokeMethod<void>('update', {
          'visible': state.visible,
          'playing': state.playing,
          'toggle': state.toggle,
          'previous': state.previous,
          'next': state.next,
          'toggleLabel': state.toggleLabel,
          'previousLabel': state.previousLabel,
          'nextLabel': state.nextLabel,
        });
        _sent = state;
        _reportedFailure = false;
      }
    } catch (error) {
      if (!_reportedFailure) _log.w('Taskbar controls unavailable: $error');
      _reportedFailure = true;
    } finally {
      _sending = null;
    }
  }

  Future<void> _pressed(MethodCall call) async {
    final handler = callbacks;
    if (_closed || handler == null || _wanted?.visible != true) return;
    if (call.method != 'button') return;
    final action = switch (call.arguments) {
      'play' => MediaActionMessage.play,
      'pause' => MediaActionMessage.pause,
      'previous' => MediaActionMessage.skipToPrevious,
      'next' => MediaActionMessage.skipToNext,
      _ => null,
    };
    if (action == null ||
        (!_can(action) &&
            !(const {
                  MediaActionMessage.play,
                  MediaActionMessage.pause,
                }.contains(action) &&
                _can(MediaActionMessage.playPause)))) {
      return;
    }
    try {
      await switch (action) {
        MediaActionMessage.play => handler.play(const PlayRequest()),
        MediaActionMessage.pause => handler.pause(const PauseRequest()),
        MediaActionMessage.skipToPrevious => handler.skipToPrevious(
          const SkipToPreviousRequest(),
        ),
        MediaActionMessage.skipToNext => handler.skipToNext(
          const SkipToNextRequest(),
        ),
        _ => Future<void>.value(),
      };
    } catch (error) {
      _log.w('Taskbar ${action.name} failed: $error');
    }
  }

  Future<void> stop() => update(PlaybackStateMessage());

  Future<void> close() async {
    callbacks = null;
    await stop();
    _closed = true;
    _channel.setMethodCallHandler(null);
  }
}
