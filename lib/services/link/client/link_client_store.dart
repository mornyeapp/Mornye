import 'dart:convert';
import 'dart:math';

import 'package:mornye/services/link/link_client_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Paired desktops, the chosen one and this phone's device id, kept in
/// shared preferences. API keys stay in the network connection (secure
/// storage), never here.
class LinkClientStore {
  LinkClientStore({
    Future<SharedPreferences> Function()? preferences,
    Random? random,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _random = random ?? Random.secure();

  static const serversKey = 'link_client_servers';
  static const deviceIdKey = 'link_client_device_id';
  static const activeServerKey = 'link_client_active_server';

  final Future<SharedPreferences> Function() _preferences;
  final Random _random;
  Future<void> _mutation = Future.value();

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutation.then((_) => action());
    _mutation = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// This phone's id towards every desktop: random, created once.
  Future<String> deviceId() => _mutate(() async {
    final preferences = await _preferences();
    final existing = preferences.getString(deviceIdKey);
    if (existing != null && existing.length >= 16) return existing;
    final id = _uuid();
    await preferences.setString(deviceIdKey, id);
    return id;
  });

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<List<LinkServerRecord>> servers() async => _read(await _preferences());

  List<LinkServerRecord> _read(SharedPreferences preferences) {
    final raw = preferences.getString(serversKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final seen = <String>{};
      return List.unmodifiable([
        for (final row in decoded)
          if (LinkServerRecord.fromJson(row) case final record?
              when seen.add(record.serverId))
            record,
      ]);
    } on FormatException {
      return const [];
    }
  }

  Future<List<LinkServerRecord>> _write(
    List<LinkServerRecord> Function(List<LinkServerRecord> current) change,
  ) => _mutate(() async {
    final preferences = await _preferences();
    final next = List<LinkServerRecord>.unmodifiable(
      change([..._read(preferences)]),
    );
    await preferences.setString(
      serversKey,
      jsonEncode([for (final record in next) record.toJson()]),
    );
    return next;
  });

  /// Adds [record], or replaces the record with its server id in place.
  Future<List<LinkServerRecord>> upsert(LinkServerRecord record) =>
      _write((current) {
        final index = current.indexWhere((r) => r.serverId == record.serverId);
        if (index < 0) return current..add(record);
        return current..[index] = record;
      });

  Future<List<LinkServerRecord>> remove(String serverId) =>
      _write((current) => current..removeWhere((r) => r.serverId == serverId));

  /// Moves a paired desktop to [address] (`https://host:port`).
  Future<List<LinkServerRecord>> updateAddress(
    String serverId,
    String address,
  ) => _write(
    (current) => [
      for (final record in current)
        record.serverId == serverId
            ? LinkServerRecord(
                serverId: record.serverId,
                name: record.name,
                connectionId: record.connectionId,
                address: address,
                fingerprint: record.fingerprint,
              )
            : record,
    ],
  );

  Future<String?> activeServerId() async =>
      (await _preferences()).getString(activeServerKey);

  Future<void> setActiveServerId(String? serverId) => _mutate(() async {
    final preferences = await _preferences();
    if (serverId == null) {
      await preferences.remove(activeServerKey);
    } else {
      await preferences.setString(activeServerKey, serverId);
    }
  });
}
