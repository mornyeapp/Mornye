import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/services/discord_artwork_resolver.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/desktop_platform.dart';

enum DiscordPresenceStatus {
  disabled,
  linkRequired,
  connecting,
  ready,
  active,
  unavailable,
  sdkUnavailable,
}

/// Only presentation metadata goes to Discord. Never send media IDs, file paths,
/// content URIs, credentials in artwork URLs, or upload local artwork.
Map<String, Object>? discordPresencePayload(
  MediaItem? item,
  PlaybackState state,
  DateTime now,
) {
  if (item == null ||
      !state.playing ||
      state.processingState != AudioProcessingState.ready) {
    return null;
  }
  String text(String? value) =>
      String.fromCharCodes((value ?? '').trim().runes.take(128));
  final artwork = discordPublicArtwork(item.artUri?.toString()) ?? '';
  final elapsed = now.difference(state.updateTime).inMilliseconds;
  final position =
      (state.updatePosition.inMilliseconds +
              elapsed.clamp(0, 1 << 50) * state.speed)
          .clamp(0, item.duration?.inMilliseconds ?? (1 << 50));
  final speed = state.speed;
  return {
    'title': text(item.title),
    'artist': text(item.artist),
    'state': text(item.artist),
    'artwork': artwork,
    if (speed > 0) ...{
      'start': ((now.millisecondsSinceEpoch - position / speed) / 1000).floor(),
      if (item.duration != null)
        'end':
            ((now.millisecondsSinceEpoch +
                        (item.duration!.inMilliseconds - position) / speed) /
                    1000)
                .floor(),
    },
  };
}

/// The plugin channel contract on desktop, where the Rust backend talks to
/// the Discord client over its local RPC IPC: `initialize`, `update`,
/// `clear` and `shutdown` map to the `discordPresence*` backend methods, and
/// the backend's `discordPresenceStatus` calls arrive as `status`.
class DesktopDiscordChannel extends MethodChannel {
  DesktopDiscordChannel({
    Future<Object?> Function(String method, Object? arguments)? invoke,
    Stream<String>? statuses,
  }) : _invoke = invoke ?? PlatformBridge.invokeDiscordPresence<Object?>,
       _statuses = statuses,
       super('com.zarz.mornye/discord');

  static const _methods = {
    'initialize': 'discordPresenceInitialize',
    'update': 'discordPresenceUpdate',
    'clear': 'discordPresenceClear',
    'shutdown': 'discordPresenceShutdown',
  };

  final Future<Object?> Function(String method, Object? arguments) _invoke;
  final Stream<String>? _statuses;
  StreamSubscription<String>? _statusSubscription;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final backendMethod = _methods[method];
    if (backendMethod == null) {
      // `authorize`, `refresh` and `connect` are the iOS account link.
      throw MissingPluginException('$method is not used on desktop');
    }
    return await _invoke(backendMethod, arguments) as T?;
  }

  @override
  void setMethodCallHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) {
    unawaited(_statusSubscription?.cancel());
    _statusSubscription = null;
    if (handler == null) return;
    _statusSubscription =
        (_statuses ?? PlatformBridge.discordPresenceStatusEvents()).listen(
          (status) => unawaited(
            Future<dynamic>.sync(
              () => handler(MethodCall('status', status)),
            ).catchError((_) {}),
          ),
        );
  }
}

/// Owns one SDK connection, independent of the player screen's lifetime.
/// All failures stay in this optional integration and cannot stop playback.
class DiscordPresenceService {
  DiscordPresenceService({
    MethodChannel? channel,
    bool? requiresLink,
    Future<String?> Function()? readRefreshToken,
    Future<void> Function(String?)? writeRefreshToken,
    DateTime Function()? now,
    Future<String?> Function(MediaItem)? resolveArtwork,
  }) : _channel =
           channel ??
           (isDesktopPlatform
               ? DesktopDiscordChannel()
               : const MethodChannel('com.zarz.mornye/discord')),
       // Desktop IPC needs no OAuth: like Android, no account link.
       requiresLink = requiresLink ?? Platform.isIOS,
       _readRefreshToken = readRefreshToken ?? _readToken,
       _writeRefreshToken = writeRefreshToken ?? _writeToken,
       _now = now ?? DateTime.now,
       _resolveArtwork = resolveArtwork ?? DiscordArtworkResolver().resolve {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static final instance = DiscordPresenceService();
  static const _tokenKey = 'discord_presence_refresh_token';
  static const _storage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static Future<String?> _readToken() => _storage.read(key: _tokenKey);
  static Future<void> _writeToken(String? token) => token == null
      ? _storage.delete(key: _tokenKey)
      : _storage.write(key: _tokenKey, value: token);

  final MethodChannel _channel;
  final bool requiresLink;
  final Future<String?> Function() _readRefreshToken;
  final Future<void> Function(String?) _writeRefreshToken;
  final DateTime Function() _now;
  final Future<String?> Function(MediaItem) _resolveArtwork;
  String? _artworkKey;
  String? _artwork;
  int _artworkRequest = 0;
  final status = ValueNotifier(DiscordPresenceStatus.disabled);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  AudioHandler? _handler;
  bool _enabled = false;
  bool _initialized = false;
  bool _ready = false;
  bool _authenticating = false;

  /// A token refresh could not reach Discord: the account stays linked and
  /// the refresh is repeated.
  bool _refreshPending = false;
  bool _visible = false;
  int _generation = 0;

  /// The generation whose start is under way.
  int? _starting;
  Map<String, Object>? _lastPayload;
  DateTime? _lastUpdate;
  Timer? _pending;
  Timer? _retry;
  Timer? _refresh;
  Future<void> _tokenWrites = Future.value();

  void bind(AudioHandler handler) {
    if (identical(handler, _handler)) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _handler = handler;
    _subscriptions.add(handler.mediaItem.listen((_) => _schedule()));
    _subscriptions.add(handler.playbackState.listen((_) => _schedule()));
    _schedule();
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    ++_generation;
    _artworkRequest++;
    _artworkKey = null;
    _artwork = null;
    _pending?.cancel();
    _retry?.cancel();
    _refresh?.cancel();
    _ready = false;
    _visible = false;
    _lastPayload = null;
    _lastUpdate = null;
    _authenticating = false;
    _refreshPending = false;
    if (!enabled) {
      _initialized = false;
      status.value = DiscordPresenceStatus.disabled;
      await _invoke('shutdown');
      return;
    }
    await _start();
  }

  /// Starts the SDK for the current generation. On Android this needs an
  /// activity, so a start that found none is repeated when one appears.
  Future<void> _start() async {
    final generation = _generation;
    _starting = generation;
    status.value = DiscordPresenceStatus.connecting;
    try {
      final available = await _channel.invokeMethod<bool>('initialize');
      if (generation != _generation) return;
      _initialized = available == true;
      if (!_initialized) {
        status.value = DiscordPresenceStatus.sdkUnavailable;
        return;
      }
      _retry?.cancel();
      _retry = Timer.periodic(const Duration(seconds: 30), (_) {
        if (status.value != DiscordPresenceStatus.unavailable) return;
        if (_refreshPending) {
          unawaited(_authenticate(interactive: false));
          return;
        }
        _lastPayload = null;
        _schedule();
      });
      if (requiresLink) {
        await _authenticate(interactive: false);
      } else {
        _ready = true;
        status.value = DiscordPresenceStatus.ready;
        _schedule();
      }
    } catch (_) {
      if (generation == _generation) {
        status.value = DiscordPresenceStatus.sdkUnavailable;
      }
    } finally {
      if (_starting == generation) _starting = null;
    }
  }

  Future<void> link() => _authenticate(interactive: true);

  Future<void> forgetAccount() async {
    await setEnabled(false);
    // Serialize writes so a late refresh cannot restore a removed account.
    _tokenWrites = _tokenWrites.then((_) => _writeRefreshToken(null));
    try {
      await _tokenWrites;
    } catch (_) {
      _tokenWrites = Future.value();
      status.value = DiscordPresenceStatus.unavailable;
    }
  }

  Future<void> _authenticate({required bool interactive}) async {
    if (!_enabled || !_initialized || _authenticating || !requiresLink) return;
    _authenticating = true;
    _refreshPending = false;
    _ready = false;
    _pending?.cancel();
    _refresh?.cancel();
    final generation = _generation;
    status.value = DiscordPresenceStatus.connecting;
    try {
      await _tokenWrites;
      final token = interactive ? null : await _readRefreshToken();
      if (generation != _generation) return;
      if (!interactive && (token == null || token.isEmpty)) {
        status.value = DiscordPresenceStatus.linkRequired;
        return;
      }
      final credentials = await _channel.invokeMapMethod<String, dynamic>(
        interactive ? 'authorize' : 'refresh',
        interactive ? null : {'refresh': token},
      );
      if (generation != _generation) return;
      final access = credentials?['access'] as String?;
      final refresh = credentials?['refresh'] as String?;
      if (access == null ||
          access.isEmpty ||
          refresh == null ||
          refresh.isEmpty) {
        status.value = DiscordPresenceStatus.linkRequired;
        return;
      }
      _tokenWrites = _tokenWrites.then((_) => _writeRefreshToken(refresh));
      await _tokenWrites;
      if (generation != _generation) return;
      await _channel.invokeMethod<void>('connect', {'access': access});
      if (generation != _generation) return;
      final expires = (credentials?['expiresIn'] as num?)?.toInt() ?? 3600;
      _refresh = Timer(Duration(seconds: (expires - 60).clamp(30, 604800)), () {
        unawaited(_authenticate(interactive: false));
      });
    } catch (error) {
      // Do not log OAuth tokens or native exception details.
      _tokenWrites = Future.value();
      if (generation == _generation) {
        // Being offline does not end the link: the stored token is still
        // good, so the retry timer refreshes again.
        _refreshPending =
            !interactive &&
            error is PlatformException &&
            error.code == 'network';
        status.value = _refreshPending
            ? DiscordPresenceStatus.unavailable
            : DiscordPresenceStatus.linkRequired;
      }
    } finally {
      if (generation == _generation) _authenticating = false;
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'status' || !_enabled) return;
    switch (call.arguments) {
      case 'ready':
        _ready = true;
        _lastPayload = null;
        status.value = DiscordPresenceStatus.ready;
        _schedule();
      case 'active':
        if (_visible) status.value = DiscordPresenceStatus.active;
      case 'connecting':
        _ready = false;
        status.value = DiscordPresenceStatus.connecting;
      case 'expired':
        unawaited(_authenticate(interactive: false));
      case 'available':
        // Android: an activity exists again.
        if (!_initialized && _starting != _generation) unawaited(_start());
      case 'unavailable':
        status.value = DiscordPresenceStatus.unavailable;
    }
  }

  bool _samePayload(Map<String, Object> payload) {
    final previous = _lastPayload;
    if (previous == null) return false;
    for (final key in ['title', 'artist', 'state', 'artwork']) {
      if (payload[key] != previous[key]) return false;
    }
    for (final key in ['start', 'end']) {
      final a = payload[key] as int?;
      final b = previous[key] as int?;
      if (a == null || b == null) {
        if (a != b) return false;
      } else if ((a - b).abs() > 2) {
        return false;
      }
    }
    return true;
  }

  void _schedule() {
    if (!_enabled || !_initialized) return;
    final handler = _handler;
    if (handler == null) return;
    final now = _now();
    final payload = discordPresencePayload(
      handler.mediaItem.value,
      handler.playbackState.value,
      now,
    );
    if (payload == null) {
      _artworkRequest++;
      _artworkKey = null;
      _artwork = null;
      _pending?.cancel();
      _pending = null;
      _lastPayload = null;
      if (_visible) {
        _visible = false;
        status.value = DiscordPresenceStatus.ready;
        unawaited(_invoke('clear'));
      }
      return;
    }
    if (!_ready) return;
    final item = handler.mediaItem.value!;
    final key = [
      item.id,
      item.title,
      item.artist,
      item.album,
      item.artUri,
      item.duration,
    ].join('\u0000');
    if (_artworkKey != key) {
      _artworkKey = key;
      _artwork = null;
      final request = ++_artworkRequest;
      if (payload['artwork'] == '') {
        unawaited(_loadArtwork(item, request));
      }
    }
    if (payload['artwork'] == '' && _artwork != null) {
      payload['artwork'] = _artwork!;
    }
    if (_samePayload(payload)) return;
    final elapsed = _lastUpdate == null
        ? const Duration(seconds: 15)
        : now.difference(_lastUpdate!);
    if (elapsed < const Duration(seconds: 15)) {
      _pending ??= Timer(const Duration(seconds: 15) - elapsed, () {
        _pending = null;
        _schedule();
      });
      return;
    }
    _pending?.cancel();
    _pending = null;
    _lastPayload = payload;
    _lastUpdate = now;
    _visible = true;
    unawaited(_invoke('update', payload));
  }

  Future<void> _loadArtwork(MediaItem item, int request) async {
    try {
      final url = discordPublicArtwork(await _resolveArtwork(item));
      if (!_enabled || request != _artworkRequest || url == null) return;
      _artwork = url;
      _schedule();
    } catch (_) {
      // Artwork is optional; an offline lookup cannot interrupt playback.
    }
  }

  Future<void> _invoke(String method, [Map<String, Object>? arguments]) async {
    final generation = _generation;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (_) {
      if (_enabled && generation == _generation) {
        status.value = DiscordPresenceStatus.unavailable;
      }
    }
  }

  Future<void> dispose() async {
    await setEnabled(false);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _channel.setMethodCallHandler(null);
    status.dispose();
  }
}
