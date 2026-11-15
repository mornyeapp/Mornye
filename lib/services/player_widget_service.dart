import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/utils/logger.dart';

class PlayerWidgetArtwork {
  const PlayerWidgetArtwork(this.png, this.background);

  final Uint8List png;
  final int background;
}

/// Shares only presentation data with the launcher. Playback stays owned by
/// the existing audio handler, including when a widget sends a command.
class PlayerWidgetService {
  PlayerWidgetService({
    MethodChannel channel = const MethodChannel(
      'com.zarz.mornye/player_widget',
    ),
    Future<PlayerWidgetArtwork?> Function(Uri?)? loadArtwork,
  }) : _channel = channel,
       _loadArtwork = loadArtwork ?? _readArtwork;

  static final instance = PlayerWidgetService();
  static final _log = AppLogger('PlayerWidget');
  final MethodChannel _channel;
  final Future<PlayerWidgetArtwork?> Function(Uri?) _loadArtwork;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  AudioHandler? _handler;
  Uri? _artUri;
  PlayerWidgetArtwork? _artwork;
  String? _lastPayload;
  String? _lastArtworkKey;
  int? _installedWidgetCount;
  Future<void>? _consumerQuery;
  int _artworkGeneration = 0;
  Future<void> _writes = Future.value();
  Future<void> _commands = Future.value();
  bool _initialized = false;

  Future<void> initialize(Future<void> Function(String) onCommand) async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'installedWidgetCountChanged' &&
          call.arguments is int) {
        await _setInstalledWidgetCount(call.arguments as int);
        return true;
      }
      if (call.method != 'command' || call.arguments is! String) return false;
      final command = call.arguments as String;
      if (!const {
        'play',
        'pause',
        'toggle',
        'next',
        'previous',
        'open',
      }.contains(command)) {
        return false;
      }
      final operation = _commands.then((_) async {
        await onCommand(command);
        await publish(force: true);
      });
      _commands = operation.catchError((Object error) {
        _log.w('Widget command failed: $error');
      });
      await operation;
      return true;
    });
    try {
      await _channel.invokeMethod<void>('ready');
      await _refreshConsumers();
    } on MissingPluginException {
      // Desktop and tests do not install the mobile widget bridge.
    } on PlatformException catch (error) {
      _log.w('Widget bridge unavailable: ${error.code}');
    }
  }

  Future<void> _refreshConsumers() => _consumerQuery ??= () async {
    try {
      final count = await _channel.invokeMethod<int>('getInstalledWidgetCount');
      if (count != null) await _setInstalledWidgetCount(count);
    } on MissingPluginException {
      // Older bridges and desktop keep the existing lightweight publishing.
    } on PlatformException catch (error) {
      _log.w('Widget consumer query failed: ${error.code}');
    }
  }();

  Future<void> _setInstalledWidgetCount(int count) async {
    final wasAbsent = _installedWidgetCount == 0;
    _installedWidgetCount = count;
    if (count == 0) {
      _artworkGeneration++;
      _artwork = null;
      _lastArtworkKey = null;
      await publish();
    } else if (wasAbsent) {
      final generation = ++_artworkGeneration;
      await _updateArtwork(_artUri, generation);
      await publish(force: true);
    }
  }

  void bind(AudioHandler handler) {
    if (identical(_handler, handler)) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _handler = handler;
    _subscriptions.add(
      handler.mediaItem.listen((item) {
        if (_artUri != item?.artUri) {
          _artUri = item?.artUri;
          _artwork = null;
          final generation = ++_artworkGeneration;
          unawaited(() async {
            await _refreshConsumers();
            if (_installedWidgetCount != 0 &&
                generation == _artworkGeneration) {
              await _updateArtwork(item?.artUri, generation);
            }
          }());
        }
        unawaited(publish());
      }),
    );
    _subscriptions.add(
      handler.playbackState
          .map(
            (state) => (
              state.playing,
              state.controls.any(
                (control) => control.action == MediaAction.skipToPrevious,
              ),
              state.controls.any(
                (control) => control.action == MediaAction.skipToNext,
              ),
            ),
          )
          .distinct(
            (previous, next) => previous == next && _lastPayload != null,
          )
          .listen((_) => unawaited(publish())),
    );
  }

  Future<void> _updateArtwork(Uri? uri, int generation) async {
    try {
      final artwork = await _loadArtwork(uri);
      if (generation != _artworkGeneration || _installedWidgetCount == 0) {
        return;
      }
      _artwork = artwork;
      await publish();
    } catch (error) {
      _log.w('Widget artwork unavailable: $error');
    }
  }

  Future<void> publish({bool force = false}) {
    final handler = _handler;
    if (handler == null) return Future.value();
    final item = handler.mediaItem.value;
    final state = handler.playbackState.value;
    final payload = <String, Object?>{
      'id': item?.id ?? '',
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'album': item?.album ?? '',
      'playing': item != null && state.playing,
      'canPlay': item != null,
      'canPrevious': state.controls.any(
        (control) => control.action == MediaAction.skipToPrevious,
      ),
      'canNext': state.controls.any(
        (control) => control.action == MediaAction.skipToNext,
      ),
      'artworkKey': _artwork == null ? '' : _artUri.toString(),
      'background': _artwork?.background ?? 0xff292433,
    };
    final key = jsonEncode(payload);
    if (!force && key == _lastPayload) return _writes;
    _lastPayload = key;
    // No position ticks cross the platform channel. Widgets refresh on a
    // track/transport change, not twice a second alongside the player UI.
    final artwork = _artwork;
    _writes = _writes.then((_) async {
      try {
        await _channel.invokeMethod<void>('update', {
          ...payload,
          if (artwork != null && payload['artworkKey'] != _lastArtworkKey)
            'artwork': artwork.png,
        });
        _lastArtworkKey = payload['artworkKey'] as String;
      } on MissingPluginException {
        // Mobile-only capability.
      } on PlatformException catch (error) {
        _lastPayload = null;
        _lastArtworkKey = null;
        _log.w('Widget update failed: ${error.code}');
      }
    });
    return _writes;
  }

  static Future<void> control(AudioHandler handler, String command) async {
    switch (command) {
      case 'play':
        await handler.play();
      case 'pause':
        await handler.pause();
      case 'toggle':
        if (handler.playbackState.value.playing) {
          await handler.pause();
        } else {
          await handler.play();
        }
      case 'next':
        await handler.skipToNext();
      case 'previous':
        await handler.skipToPrevious();
    }
  }

  Future<void> dispose() async {
    _artworkGeneration++;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _handler = null;
    await _writes;
    _consumerQuery = null;
    _installedWidgetCount = null;
    _lastArtworkKey = null;
    _lastPayload = null;
    _initialized = false;
    _channel.setMethodCallHandler(null);
  }

  static Future<PlayerWidgetArtwork?> _readArtwork(Uri? uri) async {
    if (uri == null) return null;
    final File file;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      file = await CoverCacheManager.instance.getSingleFile(uri.toString());
    } else if (uri.scheme == 'file' || !uri.hasScheme) {
      file = File(uri.scheme == 'file' ? uri.toFilePath() : uri.toString());
    } else {
      return null;
    }
    if (!await file.exists() || await file.length() > 20 * 1024 * 1024) {
      return null;
    }
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: 256,
      targetHeight: 256,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final rgba = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (rgba == null || png == null) return null;
        var red = 0.0;
        var green = 0.0;
        var blue = 0.0;
        var weight = 0.0;
        for (var i = 0; i < rgba.lengthInBytes; i += 64) {
          final alpha = rgba.getUint8(i + 3) / 255;
          red += rgba.getUint8(i) * alpha;
          green += rgba.getUint8(i + 1) * alpha;
          blue += rgba.getUint8(i + 2) * alpha;
          weight += alpha;
        }
        final average = weight == 0
            ? const Color(0xff292433)
            : Color.fromARGB(
                255,
                (red / weight).round(),
                (green / weight).round(),
                (blue / weight).round(),
              );
        final hsl = HSLColor.fromColor(average);
        final background = hsl
            .withLightness(hsl.lightness.clamp(0.12, 0.26))
            .toColor();
        return PlayerWidgetArtwork(
          png.buffer.asUint8List(),
          background.toARGB32(),
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
