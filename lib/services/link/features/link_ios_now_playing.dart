import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkNowPlaying');

/// iOS 27 publishes remote playback through a Now Playing app extension.
/// Pairing credentials use a separate channel call and a shared Keychain
/// item. Only an install without the app group, and so without that
/// Keychain, lets the native side carry them in the session attributes.
class IosLinkNowPlaying with WidgetsBindingObserver {
  IosLinkNowPlaying({
    required this.remote,
    required LinkServerRecord server,
    required this.apiKey,
    required this.track,
    Future<Object?> Function(String, Map<String, Object?>?)? invoke,
  }) : _server = server,
       _invoke = invoke ?? _channel.invokeMethod<Object?>,
       _binding = '${DateTime.now().microsecondsSinceEpoch}-${_nextBinding++}';

  static const _channel = MethodChannel('com.zarz.mornye/link_now_playing');
  static int _nextBinding = 0;

  final RemotePlayback remote;
  LinkServerRecord _server;
  LinkServerRecord get server => _server;
  final Future<String?> Function() apiKey;

  /// The computer's current track.
  final TrackRef? Function() track;
  final Future<Object?> Function(String, Map<String, Object?>?) _invoke;
  final String _binding;
  final _subscriptions = <StreamSubscription<Object?>>[];
  MediaItem? _item;
  PlaybackState? _state;
  double _volume = 1;
  bool _disposed = false;
  bool _configured = false;
  bool _nativeConfigured = false;
  bool _ended = false;
  bool _scheduled = false;
  bool _draining = false;
  Map<String, Object?>? _pending;
  Map<String, Object?>? _sent;
  DateTime? _retryAfter;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.addAll([
      remote.mediaItems.listen((item) {
        _item = item;
        _schedule();
      }),
      remote.playbackStates.listen((state) {
        _state = state;
        _schedule();
      }),
      remote.volumes.listen((volume) {
        if (volume.isFinite) {
          _volume = volume.clamp(0, 1);
          _schedule();
        }
      }),
    ]);
    unawaited(_configure());
  }

  /// Keeps the system's remote controls on the paired computer's current IP.
  void updateServer(LinkServerRecord server) {
    if (_disposed || server.serverId != _server.serverId) return;
    if (server.address == _server.address &&
        server.fingerprint == _server.fingerprint &&
        server.name == _server.name) {
      return;
    }
    _server = server;
    _configured = false;
    unawaited(_configure());
  }

  Future<void> _configure() async {
    final server = _server;
    try {
      if (await _invoke('supported', null) != true ||
          _disposed ||
          !identical(server, _server)) {
        return;
      }
      final key = await apiKey();
      if (_disposed ||
          !identical(server, _server) ||
          key == null ||
          key.isEmpty) {
        return;
      }
      await _invoke('configure', {
        'binding': _binding,
        'id': server.serverId,
        'address': server.address,
        'fingerprint': server.fingerprint,
        'apiKey': key,
      });
      _nativeConfigured = true;
      if (_disposed) {
        await _end();
        return;
      }
      if (!identical(server, _server)) return;
      _configured = true;
      _sent = null;
      _retryAfter = null;
      _schedule();
      await _drain();
    } on MissingPluginException {
      // An older native build continues to use its existing media handler.
    } on Object catch (error) {
      _log.w(
        'Could not configure the iOS remote session (${error.runtimeType})',
      );
    }
  }

  void _schedule() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_disposed) return;
      final item = _item;
      final state = _state;
      final duration = item?.duration;
      final track = item == null ? null : this.track();
      _pending = {
        'id': server.serverId,
        'deviceName': server.name,
        // As the extension names the computer's track when it refreshes.
        'trackId': track == null
            ? ''
            : track.songId ?? track.fileId ?? '${track.title}|${track.artist}',
        // The extension loads a catalog song's cover from the computer.
        'songId': track?.serverId == server.serverId ? track?.songId : null,
        'title': item?.title ?? '',
        'artist': item?.artist ?? '',
        'album': item?.album ?? '',
        'duration': duration != null && duration > Duration.zero
            ? duration.inMilliseconds / 1000
            : null,
        'position': (state?.updatePosition.inMilliseconds ?? 0) / 1000,
        'updatedAt':
            (state?.updateTime ?? DateTime.now()).millisecondsSinceEpoch / 1000,
        'playing': state?.playing ?? false,
        'volume': _volume,
        'artwork': item?.artUri?.toString(),
      };
      unawaited(_drain());
    });
  }

  bool _unchanged(Map<String, Object?> next) {
    final sent = _sent;
    if (sent == null) return false;
    for (final key in next.keys) {
      if (key != 'position' && key != 'updatedAt' && next[key] != sent[key]) {
        return false;
      }
    }
    final elapsed = sent['playing'] == true
        ? ((next['updatedAt'] as double) - (sent['updatedAt'] as double)).clamp(
            0,
            double.infinity,
          )
        : 0;
    return ((next['position'] as double) -
                (sent['position'] as double) -
                elapsed)
            .abs() <
        1.5;
  }

  Future<void> _drain() async {
    if (!_configured ||
        _draining ||
        _disposed ||
        (_retryAfter?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _draining = true;
    try {
      while (!_disposed && _pending != null) {
        final snapshot = _pending!;
        _pending = null;
        if (_unchanged(snapshot)) continue;
        await _invoke('update', {'binding': _binding, 'state': snapshot});
        _sent = snapshot;
      }
    } on Object catch (error) {
      _retryAfter = DateTime.now().add(const Duration(seconds: 5));
      _log.w('Could not publish the iOS remote session (${error.runtimeType})');
    } finally {
      _draining = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _retryAfter = null;
      _sent = null;
      _schedule();
    }
  }

  Future<void> _end() async {
    if (_ended) return;
    _ended = true;
    try {
      await _invoke('end', {'binding': _binding});
    } on Object catch (error) {
      _log.w('Could not end the iOS remote session (${error.runtimeType})');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_nativeConfigured) unawaited(_end());
  }
}
