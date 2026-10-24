import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_store.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

LinkServerRecord _record(String id, {String address = 'https://10.0.0.2:1'}) =>
    LinkServerRecord(
      serverId: id,
      name: 'Desktop $id',
      connectionId: 'connection-$id',
      address: address,
      fingerprint: 'f' * 64,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('device id is a random UUID kept across stores', () async {
    final first = await LinkClientStore().deviceId();
    expect(
      first,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(await LinkClientStore().deviceId(), first);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(LinkClientStore.deviceIdKey), first);
  });

  test('records persist, replace by server id and keep order', () async {
    final store = LinkClientStore();
    await store.upsert(_record('a'));
    await store.upsert(_record('b'));
    await store.upsert(_record('a', address: 'https://10.0.0.9:2'));
    final servers = await LinkClientStore().servers();
    expect(servers.map((s) => s.serverId), ['a', 'b']);
    expect(servers.first.address, 'https://10.0.0.9:2');

    final preferences = await SharedPreferences.getInstance();
    final raw = jsonDecode(preferences.getString(LinkClientStore.serversKey)!);
    expect(raw, [
      _record('a', address: 'https://10.0.0.9:2').toJson(),
      _record('b').toJson(),
    ]);
  });

  test('address updates touch only the moved desktop', () async {
    final store = LinkClientStore();
    await store.upsert(_record('a'));
    await store.upsert(_record('b'));
    final servers = await store.updateAddress('b', 'https://10.0.0.7:47710');
    expect(servers.map((s) => s.address), [
      'https://10.0.0.2:1',
      'https://10.0.0.7:47710',
    ]);
    expect(servers.last.connectionId, 'connection-b');
    expect(servers.last.fingerprint, 'f' * 64);
    expect((await store.servers()).last.address, 'https://10.0.0.7:47710');
  });

  test('removing and the active choice persist', () async {
    final store = LinkClientStore();
    await store.upsert(_record('a'));
    await store.upsert(_record('b'));
    await store.setActiveServerId('b');
    expect(await store.activeServerId(), 'b');
    expect((await store.remove('a')).map((s) => s.serverId), ['b']);
    await store.setActiveServerId(null);
    expect(await store.activeServerId(), isNull);
  });

  test('broken or duplicate rows are skipped', () async {
    SharedPreferences.setMockInitialValues({
      LinkClientStore.serversKey: jsonEncode([
        _record('a').toJson(),
        {'serverId': 'b'},
        _record('a', address: 'https://10.0.0.3:1').toJson(),
        'junk',
      ]),
    });
    final servers = await LinkClientStore().servers();
    expect(servers.map((s) => s.serverId), ['a']);
    expect(servers.single.address, 'https://10.0.0.2:1');

    SharedPreferences.setMockInitialValues({
      LinkClientStore.serversKey: '{not json',
    });
    expect(await LinkClientStore().servers(), isEmpty);
  });
}
