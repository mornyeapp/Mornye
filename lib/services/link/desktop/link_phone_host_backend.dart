import 'dart:async';
import 'dart:convert';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('MornyeLink');

/// Announces a phone host on the local network as the desktop's server does
/// itself (contract section 2: `_mornye._tcp`, TXT `v`, `id`, `fp`, and
/// `pf` for the platform). [BonsoirLinkHostAdvertiser] uses the platform's
/// service discovery; tests fake it.
abstract interface class LinkHostAdvertiser {
  Future<void> start(LinkHostServer server, {required String platform});
  Future<void> stop();
}

/// [LinkHostAdvertiser] on Bonsoir (Android NSD, Apple Bonjour). Raw mDNS
/// from Rust needs an entitlement on iOS and a multicast lock on Android;
/// the platform's own responder needs neither.
class BonsoirLinkHostAdvertiser implements LinkHostAdvertiser {
  BonsoirBroadcast? _broadcast;

  @override
  Future<void> start(LinkHostServer server, {required String platform}) async {
    await stop();
    final broadcast = _broadcast = BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: server.name,
        type: linkServiceType,
        port: server.port,
        attributes: {
          'v': '$linkProtocolVersion',
          'id': server.serverId,
          'fp': server.fingerprint,
          if (platform.isNotEmpty) 'pf': platform,
        },
      ),
    );
    await broadcast.initialize();
    await broadcast.start();
  }

  @override
  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null && broadcast.isReady && !broadcast.isStopped) {
      await broadcast.stop();
    }
  }
}

/// The folders and version the Rust server reads, as `linkConfigure` sends
/// them.
Future<Map<String, String>> _devicePaths() async => {
  'appSupportDir': (await getApplicationSupportDirectory()).path,
  'tempDir': (await getTemporaryDirectory()).path,
  'appVersion': AppInfo.version,
};

/// [LinkDesktopBackend] on a phone ("Share with other phones"): the desktop's
/// Rust server through `LinkHostPlugin` (`com.zarz.mornye/link`), announced
/// by a [LinkHostAdvertiser] instead of the server's own mDNS.
class ChannelLinkHostBackend implements LinkDesktopBackend {
  ChannelLinkHostBackend({
    MethodChannel channel = const MethodChannel('com.zarz.mornye/link'),
    EventChannel events = const EventChannel('com.zarz.mornye/link/events'),
    Future<Map<String, String>> Function()? paths,
    LinkHostAdvertiser? advertiser,
  }) : _channel = channel,
       _eventChannel = events,
       _paths = paths ?? _devicePaths,
       _advertiser = advertiser ?? BonsoirLinkHostAdvertiser();

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final Future<Map<String, String>> Function() _paths;
  final LinkHostAdvertiser _advertiser;
  Future<void>? _configured;

  /// One platform subscription shared by every stream below: the plugin
  /// keeps a single listener.
  late final Stream<({String method, Map<String, dynamic> arguments})> _events =
      _eventChannel.receiveBroadcastStream().expand(
        (raw) => [?_decodeEvent(raw)],
      );

  static ({String method, Map<String, dynamic> arguments})? _decodeEvent(
    Object? raw,
  ) {
    if (raw is! String) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final method = json['method'];
      final arguments = json['arguments'];
      if (method is! String) return null;
      return (method: method, arguments: _object(arguments));
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _object(Object? value) => value is Map
      ? value.map((key, value) => MapEntry(key.toString(), value))
      : <String, dynamic>{};

  Stream<Map<String, dynamic>> _named(String method) => _events
      .where((event) => event.method == method)
      .map((event) => event.arguments);

  Future<Object?> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    await (_configured ??= _configure());
    final reply = await _channel.invokeMethod<String>(method, jsonEncode(args));
    return reply == null ? null : jsonDecode(reply);
  }

  Future<void> _configure() async {
    try {
      await _channel.invokeMethod<String>(
        'linkConfigure',
        jsonEncode(await _paths()),
      );
    } on Object {
      // Tried again on the next call.
      _configured = null;
      rethrow;
    }
  }

  @override
  Future<LinkHostServer> start({
    required String name,
    int? port,
    String platform = '',
    List<String>? features,
  }) async {
    final server = LinkHostServer.fromJson(
      _object(
        await _call('linkStart', {
          'name': name,
          'port': ?port,
          if (platform.isNotEmpty) 'platform': platform,
          'features': ?features,
          'advertise': false,
        }),
      ),
    );
    try {
      await _advertiser.start(server, platform: platform);
    } on Object catch (error) {
      // The server still answers phones that know its address.
      _log.w('Link: announcing this phone on the network failed: $error');
    }
    return server;
  }

  @override
  Future<void> stop() async {
    try {
      await _advertiser.stop();
    } on Object catch (error) {
      _log.w('Link: withdrawing the network announcement failed: $error');
    }
    await _call('linkStop');
  }

  @override
  Future<({LinkHostServer? server, List<LinkClientInfo> clients})>
  status() async {
    final json = _object(await _call('linkStatus'));
    return (
      server: json['running'] == true ? LinkHostServer.fromJson(json) : null,
      clients: linkClientsFromJson(json['clients']),
    );
  }

  @override
  Future<int> setCatalog(String path) async {
    final songs = _object(await _call('linkSetCatalog', {'path': path}));
    return (songs['songs'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<LinkPairingWindow> beginPairing() async =>
      LinkPairingWindow.fromJson(_object(await _call('linkBeginPairing')));

  @override
  Future<void> endPairing() => _call('linkEndPairing');

  @override
  Future<List<LinkPairedDevice>> devices() async {
    final devices = await _call('linkDevices');
    return [
      if (devices is List)
        for (final device in devices)
          LinkPairedDevice.fromJson(_object(device)),
    ];
  }

  @override
  Future<void> revoke(String deviceId) =>
      _call('linkRevoke', {'deviceId': deviceId});

  @override
  Future<LinkAppKey> createKey(String name) async => LinkAppKey.fromJson(
    _object(await _call('linkCreateKey', {'name': name})),
  );

  @override
  Future<void> reply(
    String requestId, {
    Object? result,
    LinkException? error,
  }) => _call('linkReply', {
    'requestId': requestId,
    if (error != null) 'error': error.toJson() else 'result': result,
  });

  @override
  Future<int> send(Map<String, dynamic> message, {String? deviceId}) async {
    final reply = _object(
      await _call('linkSend', {'deviceId': ?deviceId, 'message': message}),
    );
    return (reply['delivered'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<bool?>> embeddedPictures(List<String> paths) async {
    final pictures = _object(
      await _call('linkEmbeddedPictures', {'paths': paths}),
    )['pictures'];
    return [
      for (var i = 0; i < paths.length; i++)
        pictures is List && i < pictures.length && pictures[i] is bool
            ? pictures[i] as bool
            : null,
    ];
  }

  @override
  Stream<LinkRequestEvent> get requests =>
      _named('linkRequest').map(LinkRequestEvent.fromJson);

  @override
  Stream<LinkMessageEvent> get messages =>
      _named('linkMessage').map(LinkMessageEvent.fromJson);

  @override
  Stream<List<LinkClientInfo>> get clients =>
      _named('linkClients').map((json) => linkClientsFromJson(json['clients']));

  @override
  Stream<LinkPairingEvent> get pairing => _events.expand(
    (event) => [
      if (event.method == 'linkPaired')
        LinkPairedEvent.fromJson(event.arguments)
      else if (event.method == 'linkPairingEnded')
        LinkPairingEndedEvent.fromReason(event.arguments['reason']?.toString()),
    ],
  );

  /// Withdraws the network announcement; the plugin stops the server when
  /// the engine goes.
  Future<void> dispose() => _advertiser.stop().catchError((Object _) {});
}
