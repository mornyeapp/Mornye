import 'dart:async';
import 'dart:io';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('Mpris');

const _rootInterface = 'org.mpris.MediaPlayer2';
const _playerInterface = 'org.mpris.MediaPlayer2.Player';

/// The Linux media session: audio_service's platform calls exported as an
/// MPRIS player on the session bus (desktop media keys, the GNOME and KDE
/// media controls, playerctl).
class MprisAudioService extends NoOpAudioService {
  MprisAudioService({DBusClient Function()? connect})
    : _connect = connect ?? DBusClient.session;

  final DBusClient Function() _connect;
  final player = MprisPlayerObject();
  DBusClient? _client;

  @override
  Future<void> configure(ConfigureRequest request) async {
    if (_client != null) return;
    try {
      final client = _connect();
      await client.registerObject(player);
      final reply = await client.requestName(
        'org.mpris.MediaPlayer2.mornye',
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply != DBusRequestNameReply.primaryOwner) {
        // A second instance still gets controls, under its own name.
        await client.requestName(
          'org.mpris.MediaPlayer2.mornye.instance$pid',
          flags: {DBusRequestNameFlag.doNotQueue},
        );
      }
      _client = client;
    } catch (error) {
      // No session bus (for example a bare X session): play without one.
      _log.w('MPRIS is unavailable: $error');
    }
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      player.callbacks = callbacks;

  @override
  Future<void> setState(SetStateRequest request) async =>
      player.updateState(request.state);

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async =>
      player.updateMediaItem(request.mediaItem);

  @override
  Future<void> stopService(StopServiceRequest request) async =>
      player.updateStopped();
}

/// `/org/mpris/MediaPlayer2`, implementing the root and Player interfaces.
class MprisPlayerObject extends DBusObject {
  MprisPlayerObject({DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(DBusObjectPath('/org/mpris/MediaPlayer2')) {
    playbackOutputVolume.addListener(_volumeChanged);
  }

  final DateTime Function() _now;
  AudioHandlerCallbacks? callbacks;
  PlaybackStateMessage? _state;
  MediaItemMessage? _item;
  int _track = 0;
  Timer? _volumeThrottleTimer;
  bool _volumePending = false;
  double? _lastEmittedVolume;

  static const _noTrack = DBusObjectPath.unchecked(
    '/org/mpris/MediaPlayer2/TrackList/NoTrack',
  );

  DBusObjectPath get _trackId => _item == null
      ? _noTrack
      : DBusObjectPath('/com/zarz/mornye/track/$_track');

  /// The position now, advanced from the last state at its speed.
  Duration get position {
    final state = _state;
    if (state == null) return Duration.zero;
    var value = state.updatePosition;
    if (state.playing &&
        state.processingState == AudioProcessingStateMessage.ready) {
      final elapsed = _now().difference(state.updateTime);
      value += elapsed * state.speed;
    }
    final length = _item?.duration;
    if (value < Duration.zero) return Duration.zero;
    if (length != null && length > Duration.zero && value > length) {
      return length;
    }
    return value;
  }

  String get _status {
    final state = _state;
    if (state == null ||
        state.processingState == AudioProcessingStateMessage.idle) {
      return 'Stopped';
    }
    return state.playing ? 'Playing' : 'Paused';
  }

  bool _can(MediaActionMessage action) {
    final state = _state;
    if (state == null) return false;
    return state.systemActions.contains(action) ||
        state.controls.any((control) => control.action == action);
  }

  bool get _hasItem => _item != null;

  Map<String, DBusValue> get _playerProperties => {
    'PlaybackStatus': DBusString(_status),
    'Rate': DBusDouble(_state?.speed ?? 1),
    'MinimumRate': DBusDouble(_minimumRate),
    'MaximumRate': DBusDouble(_maximumRate),
    'Metadata': _metadata,
    'Volume': DBusDouble(playbackOutputVolume.value),
    'Position': DBusInt64(position.inMicroseconds),
    'CanGoNext': DBusBoolean(_can(MediaActionMessage.skipToNext)),
    'CanGoPrevious': DBusBoolean(_can(MediaActionMessage.skipToPrevious)),
    'CanPlay': DBusBoolean(_hasItem),
    'CanPause': DBusBoolean(_hasItem),
    'CanSeek': DBusBoolean(_hasItem && _can(MediaActionMessage.seek)),
    'CanControl': const DBusBoolean(true),
  };

  double get _minimumRate => (_state?.speed ?? 1) < 1 ? _state!.speed : 1;
  double get _maximumRate => (_state?.speed ?? 1) > 1 ? _state!.speed : 1;

  static final _rootProperties = <String, DBusValue>{
    'CanQuit': DBusBoolean(false),
    'CanRaise': DBusBoolean(false),
    'HasTrackList': DBusBoolean(false),
    'Identity': DBusString('Mornye'),
    'DesktopEntry': DBusString('com.zarz.mornye'),
    'SupportedUriSchemes': DBusArray(DBusSignature('s')),
    'SupportedMimeTypes': DBusArray(DBusSignature('s')),
  };

  DBusValue get _metadata {
    final item = _item;
    if (item == null) {
      return DBusDict.stringVariant({'mpris:trackid': _noTrack});
    }
    final artPath = item.extras?['artCacheFile'];
    final art = artPath is String && artPath.isNotEmpty
        ? Uri.file(artPath).toString()
        : switch (item.artUri) {
            final Uri uri when uri.scheme != 'content' => uri.toString(),
            _ => null,
          };
    return DBusDict.stringVariant({
      'mpris:trackid': _trackId,
      'xesam:title': DBusString(item.title),
      if (item.artist case final artist? when artist.isNotEmpty)
        'xesam:artist': DBusArray.string([artist]),
      if (item.album case final album? when album.isNotEmpty)
        'xesam:album': DBusString(album),
      if (item.genre case final genre? when genre.isNotEmpty)
        'xesam:genre': DBusArray.string([genre]),
      if (item.duration case final length? when length > Duration.zero)
        'mpris:length': DBusInt64(length.inMicroseconds),
      if (art != null) 'mpris:artUrl': DBusString(art),
    });
  }

  void updateMediaItem(MediaItemMessage item) {
    final previous = _item;
    if (previous == null || previous.id != item.id) _track++;
    _item = item;
    unawaited(
      _emit({
        'Metadata': _metadata,
        'CanPlay': const DBusBoolean(true),
        'CanPause': const DBusBoolean(true),
        'CanSeek': DBusBoolean(_can(MediaActionMessage.seek)),
      }),
    );
  }

  void updateState(PlaybackStateMessage state) {
    final expected = position;
    final previous = _state;
    if (previous == null) {
      _state = state;
      final after = _playerProperties..remove('Position');
      if (after.isNotEmpty) unawaited(_emit(after));
      return;
    }
    final prevStatus = _status;
    final prevRate = previous.speed;
    final prevMinRate = _minimumRate;
    final prevMaxRate = _maximumRate;
    final prevCanNext = _can(MediaActionMessage.skipToNext);
    final prevCanPrevious = _can(MediaActionMessage.skipToPrevious);
    final prevCanSeek = _hasItem && _can(MediaActionMessage.seek);

    _state = state;

    final status = _status;
    final rate = state.speed;
    final minRate = _minimumRate;
    final maxRate = _maximumRate;
    final canNext = _can(MediaActionMessage.skipToNext);
    final canPrevious = _can(MediaActionMessage.skipToPrevious);
    final canSeek = _hasItem && _can(MediaActionMessage.seek);

    Map<String, DBusValue>? changed;
    void put(String key, DBusValue value) => (changed ??= {})[key] = value;
    if (status != prevStatus) put('PlaybackStatus', DBusString(status));
    if (rate != prevRate) put('Rate', DBusDouble(rate));
    if (minRate != prevMinRate) put('MinimumRate', DBusDouble(minRate));
    if (maxRate != prevMaxRate) put('MaximumRate', DBusDouble(maxRate));
    if (canNext != prevCanNext) put('CanGoNext', DBusBoolean(canNext));
    if (canPrevious != prevCanPrevious) {
      put('CanGoPrevious', DBusBoolean(canPrevious));
    }
    if (canSeek != prevCanSeek) put('CanSeek', DBusBoolean(canSeek));
    if (changed != null) unawaited(_emit(changed!));
    // Clients extrapolate Position from the rate; only a jump is signalled.
    if ((state.updatePosition - expected).abs() > const Duration(seconds: 1)) {
      unawaited(
        emitSignal(_playerInterface, 'Seeked', [
          DBusInt64(state.updatePosition.inMicroseconds),
        ]),
      );
    }
  }

  void updateStopped() {
    final state = _state;
    if (state == null) return;
    updateState(
      PlaybackStateMessage(
        processingState: AudioProcessingStateMessage.idle,
        playing: false,
        controls: state.controls,
        systemActions: state.systemActions,
        updatePosition: Duration.zero,
        updateTime: _now(),
      ),
    );
  }

  void _volumeChanged() {
    if (_volumeThrottleTimer != null) {
      _volumePending = true;
      return;
    }
    _emitCurrentVolume();
    _volumeThrottleTimer = Timer(const Duration(milliseconds: 60), () {
      _volumeThrottleTimer = null;
      if (_volumePending) {
        _volumePending = false;
        _emitCurrentVolume();
      }
    });
  }

  void _emitCurrentVolume() {
    final value = playbackOutputVolume.value;
    if (_lastEmittedVolume == value) return;
    _lastEmittedVolume = value;
    unawaited(_emit({'Volume': DBusDouble(value)}));
  }

  Future<void> _emit(Map<String, DBusValue> changed) async {
    if (client == null) return;
    try {
      await emitPropertiesChanged(_playerInterface, changedProperties: changed);
    } catch (error) {
      _log.w('Could not publish MPRIS state: $error');
    }
  }

  Future<DBusMethodResponse> _call(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      return DBusMethodErrorResponse.failed('$error');
    }
    return DBusMethodSuccessResponse();
  }

  Future<void> _seekTo(Duration target) async {
    final length = _item?.duration;
    var value = target < Duration.zero ? Duration.zero : target;
    if (length != null && length > Duration.zero && value > length) {
      value = length;
    }
    await callbacks?.seek(SeekRequest(position: value));
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) {
    final handler = callbacks;
    if (methodCall.interface == _rootInterface) {
      return switch (methodCall.name) {
        'Raise' || 'Quit' => Future.value(DBusMethodSuccessResponse()),
        _ => Future.value(DBusMethodErrorResponse.unknownMethod()),
      };
    }
    if (methodCall.interface != _playerInterface) {
      return Future.value(DBusMethodErrorResponse.unknownInterface());
    }
    if (handler == null) {
      return Future.value(DBusMethodErrorResponse.failed('Not ready'));
    }
    final values = methodCall.values;
    switch (methodCall.name) {
      case 'Play':
        return _call(() => handler.play(const PlayRequest()));
      case 'Pause':
        return _call(() => handler.pause(const PauseRequest()));
      case 'PlayPause':
        return _call(
          () => _state?.playing == true
              ? handler.pause(const PauseRequest())
              : handler.play(const PlayRequest()),
        );
      case 'Stop':
        return _call(() => handler.stop(const StopRequest()));
      case 'Next':
        return _call(() => handler.skipToNext(const SkipToNextRequest()));
      case 'Previous':
        return _call(
          () => handler.skipToPrevious(const SkipToPreviousRequest()),
        );
      case 'Seek':
        if (values.length != 1 || values.single is! DBusInt64) {
          return Future.value(DBusMethodErrorResponse.invalidArgs());
        }
        final offset = (values.single as DBusInt64).value;
        return _call(() => _seekTo(position + Duration(microseconds: offset)));
      case 'SetPosition':
        if (values.length != 2 ||
            values[0] is! DBusObjectPath ||
            values[1] is! DBusInt64) {
          return Future.value(DBusMethodErrorResponse.invalidArgs());
        }
        // Stale requests for a previous track are ignored, per the spec.
        if (values[0] != _trackId) {
          return Future.value(DBusMethodSuccessResponse());
        }
        final target = Duration(microseconds: (values[1] as DBusInt64).value);
        return _call(() => _seekTo(target));
      case 'OpenUri':
        return Future.value(DBusMethodErrorResponse.notSupported());
      default:
        return Future.value(DBusMethodErrorResponse.unknownMethod());
    }
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = switch (interface) {
      _rootInterface => _rootProperties[name],
      _playerInterface => _playerProperties[name],
      _ => null,
    };
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(switch (interface) {
        _rootInterface => _rootProperties,
        _playerInterface => _playerProperties,
        _ => const {},
      });

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface != _playerInterface) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    switch (name) {
      case 'Volume' when value is DBusDouble:
        // The in-app output volume; desktop never changes the system one.
        playbackOutputVolume.value = value.value.clamp(0.0, 1.0);
        return DBusMethodSuccessResponse();
      case 'Rate':
        // Speed is chosen in the app; the reported rate stays accurate.
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.propertyReadOnly();
    }
  }

  @override
  List<DBusIntrospectInterface> introspect() {
    DBusIntrospectProperty read(String name, String type) =>
        DBusIntrospectProperty(
          name,
          DBusSignature(type),
          access: DBusPropertyAccess.read,
        );
    DBusIntrospectMethod method(
      String name, [
      List<DBusIntrospectArgument> args = const [],
    ]) => DBusIntrospectMethod(name, args: args);
    DBusIntrospectArgument input(String name, String type) =>
        DBusIntrospectArgument(
          DBusSignature(type),
          DBusArgumentDirection.in_,
          name: name,
        );
    return [
      DBusIntrospectInterface(
        _rootInterface,
        methods: [method('Raise'), method('Quit')],
        properties: [
          read('CanQuit', 'b'),
          read('CanRaise', 'b'),
          read('HasTrackList', 'b'),
          read('Identity', 's'),
          read('DesktopEntry', 's'),
          read('SupportedUriSchemes', 'as'),
          read('SupportedMimeTypes', 'as'),
        ],
      ),
      DBusIntrospectInterface(
        _playerInterface,
        methods: [
          method('Next'),
          method('Previous'),
          method('Pause'),
          method('PlayPause'),
          method('Stop'),
          method('Play'),
          method('Seek', [input('Offset', 'x')]),
          method('SetPosition', [
            input('TrackId', 'o'),
            input('Position', 'x'),
          ]),
          method('OpenUri', [input('Uri', 's')]),
        ],
        signals: [
          DBusIntrospectSignal(
            'Seeked',
            args: [
              DBusIntrospectArgument(
                DBusSignature('x'),
                DBusArgumentDirection.out,
                name: 'Position',
              ),
            ],
          ),
        ],
        properties: [
          read('PlaybackStatus', 's'),
          DBusIntrospectProperty('Rate', DBusSignature('d')),
          read('Metadata', 'a{sv}'),
          DBusIntrospectProperty('Volume', DBusSignature('d')),
          read('Position', 'x'),
          read('MinimumRate', 'd'),
          read('MaximumRate', 'd'),
          read('CanGoNext', 'b'),
          read('CanGoPrevious', 'b'),
          read('CanPlay', 'b'),
          read('CanPause', 'b'),
          read('CanSeek', 'b'),
          read('CanControl', 'b'),
        ],
      ),
    ];
  }

  @visibleForTesting
  void dispose() {
    _volumeThrottleTimer?.cancel();
    _volumeThrottleTimer = null;
    playbackOutputVolume.removeListener(_volumeChanged);
  }
}
