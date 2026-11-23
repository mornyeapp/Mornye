import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// The protocol a receiver speaks, as the platform names it in `kind`.
enum CastKind {
  cast('cast', 'Google Cast'),
  dlna('dlna', 'DLNA'),
  fcast('fcast', 'FCast'),
  roku('roku', 'Roku'),

  /// A kind this build does not know; listed without a protocol name.
  other(null, null);

  const CastKind(this.wireName, this.label);

  final String? wireName;

  /// The protocol's own name, shown to people as it is.
  final String? label;

  /// The kinds the app's text names, in this order. The only list to edit
  /// when the sender gains or drops a protocol.
  static const named = [cast, dlna, fcast];

  /// Every kind but Google Cast, which Android reaches through Google's SDK.
  static final Set<CastKind> others = Set.unmodifiable(
    values.where((kind) => kind != cast),
  );

  /// A missing kind is Google Cast, as older platforms sent no kind.
  static CastKind parse(Object? value) => value == null
      ? cast
      : values.firstWhere(
          (kind) => kind.wireName == value,
          orElse: () => other,
        );
}

@immutable
class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    this.model = '',
    this.kind = CastKind.cast,
  });

  final String id;
  final String name;
  final String model;
  final CastKind kind;

  static CastDevice? fromMap(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], name = value['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    return CastDevice(
      id: id,
      name: name,
      model: '${value['model'] ?? ''}',
      kind: CastKind.parse(value['kind']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CastDevice &&
      other.id == id &&
      other.name == name &&
      other.model == model &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, model, kind);
}

/// How [CastOutput] reaches the platform: Android's Google Cast plugin and
/// the iOS Rust sender answer on a MethodChannel; desktop calls the Rust
/// backend over dart:ffi. Events are session snapshots, or `{"devices"}`
/// when the discovered list changes.
abstract interface class CastTransport {
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]);

  Stream<Object?> events();
}

class MethodChannelCastTransport implements CastTransport {
  const MethodChannelCastTransport({
    this.channel = const MethodChannel('com.zarz.mornye/cast'),
    this.eventStream,
  });

  final MethodChannel channel;
  final Stream<Object?>? eventStream;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      channel.invokeMethod<Object?>(method, arguments);

  @override
  Stream<Object?> events() =>
      eventStream ??
      const EventChannel(
        'com.zarz.mornye/cast/events',
      ).receiveBroadcastStream();
}

class DesktopCastTransport implements CastTransport {
  const DesktopCastTransport();

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      PlatformBridge.castCall(method, arguments);

  @override
  Stream<Object?> events() => PlatformBridge.castEvents();
}

/// The Cast session. On Android it survives Activity recreation with the
/// shared engine; elsewhere it lives in the Rust backend.
class CastOutput extends ChangeNotifier {
  CastOutput({
    MethodChannel channel = const MethodChannel('com.zarz.mornye/cast'),
    Stream<Object?>? events,
    CastTransport? transport,
    bool? nativePicker,
  }) : _transport =
           transport ??
           MethodChannelCastTransport(channel: channel, eventStream: events),
       _nativePicker = nativePicker;

  static final instance = CastOutput(
    transport: isDesktopPlatform ? const DesktopCastTransport() : null,
  );

  /// Android shows Google's own device dialog ([showPicker]) for Google
  /// Cast; every other kind, and every kind elsewhere, is listed in
  /// [devices] after [discover].
  bool get nativePicker =>
      _nativePicker ?? defaultTargetPlatform == TargetPlatform.android;
  final bool? _nativePicker;
  final CastTransport _transport;
  final _updates = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );
  StreamSubscription<Object?>? _subscription;
  Future<void>? _initializing;
  Map<Object?, Object?> _status = const {};
  List<CastDevice> _devices = const [];
  bool _disposed = false;

  bool get connected => _status['connected'] == true;
  String? get deviceId => _status['deviceId'] as String?;
  int get revision => (_status['revision'] as num?)?.toInt() ?? 0;
  String? get deviceName => _status['deviceName'] as String?;
  String? get host => _status['host'] as String?;
  double get volume => (_status['volume'] as num?)?.toDouble() ?? 0;

  /// Whether the receiver reports its volume; some only step it.
  bool get hasVolume => _status['volume'] is num;

  /// The protocol of the connected session.
  CastKind get kind => CastKind.parse(_status['kind']);
  Stream<Map<Object?, Object?>> get updates => _updates.stream;

  /// Receivers found since [discover] was turned on.
  List<CastDevice> get devices => _devices;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    _subscription = _transport.events().listen(
      _receive,
      onError: (Object _) => _receive(const {'connected': false}),
    );
    try {
      final state = await _transport.invoke('state');
      if (state is Map<Object?, Object?>) _receive(state);
    } on MissingPluginException {
      // Ordinary playback stays available on builds without Google Cast.
    } on PlatformException {
      // Google Play services can be unavailable on otherwise supported devices.
    }
  }

  void _receive(Object? event) {
    if (_disposed || event is! Map<Object?, Object?>) return;
    if (event['devices'] case final List<Object?> list) {
      final devices = list.map(CastDevice.fromMap).nonNulls.toList();
      if (!listEquals(devices, _devices)) {
        _devices = List.unmodifiable(devices);
        notifyListeners();
      }
      return;
    }
    final oldId = deviceId;
    final oldHost = host;
    final oldRevision = revision;
    final wasConnected = connected;
    final oldName = deviceName;
    final oldKind = kind;
    _status = event;
    _updates.add(event);
    if (oldId != deviceId ||
        oldHost != host ||
        oldRevision != revision ||
        wasConnected != connected ||
        oldName != deviceName ||
        oldKind != kind) {
      notifyListeners();
    }
  }

  /// Android only: Google's device dialog.
  Future<bool> showPicker() async {
    await initialize();
    return await _transport.invoke('show') as bool? ?? false;
  }

  /// Looks for receivers of [kinds] (every kind when null) while [on]; the
  /// list arrives in [devices].
  Future<void> discover(bool on, {Set<CastKind>? kinds}) async {
    await initialize();
    await _transport.invoke('discover', {
      'on': on,
      if (on && kinds != null)
        'kinds': [
          for (final kind in CastKind.values)
            if (kinds.contains(kind) && kind.wireName != null) kind.wireName,
        ],
    });
    if (!on && _devices.isNotEmpty) {
      _devices = const [];
      notifyListeners();
    }
  }

  Future<void> connect(String deviceId) async {
    await initialize();
    await _transport
        .invoke('connect', {'deviceId': deviceId})
        .timeout(const Duration(seconds: 45));
  }

  Future<void> command(
    String name, [
    Map<String, Object?>? arguments,
    Duration timeout = const Duration(seconds: 25),
  ]) => request<Object?>(name, arguments, timeout);

  Future<T?> request<T>(
    String name, [
    Map<String, Object?>? arguments,
    Duration timeout = const Duration(seconds: 25),
  ]) async => await _transport.invoke(name, arguments).timeout(timeout) as T?;

  Future<Duration> position() async => Duration(
    milliseconds: (await _transport.invoke('position') as num?)?.toInt() ?? 0,
  );

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(_updates.close());
    super.dispose();
  }
}
