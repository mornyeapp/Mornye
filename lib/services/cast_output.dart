import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native Cast session survives Activity recreation with the shared engine.
class CastOutput extends ChangeNotifier {
  CastOutput({
    MethodChannel channel = const MethodChannel('com.zarz.mornye/cast'),
    Stream<Object?>? events,
  }) : _channel = channel,
       _events = events;

  static final instance = CastOutput();
  final MethodChannel _channel;
  final Stream<Object?>? _events;
  final _updates = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );
  StreamSubscription<Object?>? _subscription;
  Future<void>? _initializing;
  Map<Object?, Object?> _status = const {};
  bool _disposed = false;

  bool get connected => _status['connected'] == true;
  String? get deviceId => _status['deviceId'] as String?;
  int get revision => (_status['revision'] as num?)?.toInt() ?? 0;
  String? get deviceName => _status['deviceName'] as String?;
  String? get host => _status['host'] as String?;
  double get volume => (_status['volume'] as num?)?.toDouble() ?? 0;
  Stream<Map<Object?, Object?>> get updates => _updates.stream;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    _subscription =
        (_events ??
                const EventChannel(
                  'com.zarz.mornye/cast/events',
                ).receiveBroadcastStream())
            .listen(
              _receive,
              onError: (Object _) => _receive(const {'connected': false}),
            );
    try {
      final state = await _channel.invokeMapMethod<Object?, Object?>('state');
      if (state != null) _receive(state);
    } on MissingPluginException {
      // Ordinary playback stays available on builds without Google Cast.
    } on PlatformException {
      // Google Play services can be unavailable on otherwise supported devices.
    }
  }

  void _receive(Object? event) {
    if (_disposed || event is! Map<Object?, Object?>) return;
    final oldId = deviceId;
    final oldHost = host;
    final oldRevision = revision;
    final wasConnected = connected;
    _status = event;
    _updates.add(event);
    if (oldId != deviceId ||
        oldHost != host ||
        oldRevision != revision ||
        wasConnected != connected) {
      notifyListeners();
    }
  }

  Future<bool> showPicker() async {
    await initialize();
    return await _channel.invokeMethod<bool>('show') ?? false;
  }

  Future<void> command(String name, [Map<String, Object?>? arguments]) =>
      _channel
          .invokeMethod<void>(name, arguments)
          .timeout(const Duration(seconds: 25));

  Future<Duration> position() async =>
      Duration(milliseconds: await _channel.invokeMethod<int>('position') ?? 0);

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(_updates.close());
    super.dispose();
  }
}
