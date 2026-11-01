import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/services/link/features/link_downloads.dart' as phone;
import 'package:mornye/services/link/link_protocol.dart';

DownloadItem _item(String id, {double progress = 0.5}) => DownloadItem(
  id: id,
  track: Track(
    id: id,
    name: 'Song $id',
    artistName: 'Example artist',
    albumName: 'Album',
    duration: 100,
  ),
  service: 'example-service',
  status: DownloadStatus.downloading,
  progress: progress,
  createdAt: DateTime(2024),
);

const _phone = LinkClientInfo(
  deviceId: 'phone',
  name: 'Phone',
  platform: 'ios',
);
const _legacy = LinkClientInfo(
  deviceId: 'legacy',
  name: 'Other',
  platform: 'android',
);

void main() {
  late List<DownloadItem> items;
  late LinkDownloadUpdates updates;
  late List<({String peer, Map<String, dynamic> message})> sent;
  late Future<int> Function() deliver;

  setUp(() {
    items = List.generate(200, (i) => _item('q$i'));
    sent = [];
    deliver = () async => 1;
    updates = LinkDownloadUpdates(
      items: () => items,
      send: (message, peer) {
        sent.add((peer: peer, message: message));
        return deliver();
      },
    )..keepConnected([_phone]);
  });
  tearDown(() => updates.dispose());

  Future<void> subscribe() async {
    expect(updates.subscribe('phone', 1), isTrue);
    await updates.publish();
    expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
    sent.clear();
  }

  test(
    'legacy phones keep full snapshots, unchanged queues send nothing',
    () async {
      await updates.publish();
      expect(sent.single.message['items'], hasLength(200));
      expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
      sent.clear();
      await updates.publish();
      expect(sent, isEmpty);
      items[50] = _item('q50', progress: 0.8);
      await updates.publish();
      expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
      expect(sent.single.message['items'], hasLength(200));
    },
  );

  test(
    'one changed row replaces a 200-row push only for opted-in peers',
    () async {
      updates.keepConnected([_phone, _legacy]);
      expect(updates.subscribe('phone', 1), isTrue);
      await updates.publish();
      sent.clear();
      items[50] = _item('q50', progress: 0.8);
      await updates.publish();
      final delta = sent.singleWhere((entry) => entry.peer == 'phone').message;
      final full = sent.singleWhere((entry) => entry.peer == 'legacy').message;
      expect(delta['type'], LinkMessageTypes.downloadsDelta);
      expect(delta['items'], [linkDownloadSummary(items[50])]);
      expect(delta['removed'], isEmpty);
      expect(delta.containsKey('order'), isFalse);
      expect(full['type'], LinkMessageTypes.downloadsChanged);
      expect(full['items'], hasLength(200));
      final deltaBytes = utf8.encode(jsonEncode(delta)).length;
      final fullBytes = utf8.encode(jsonEncode(full)).length;
      expect(deltaBytes, lessThan(fullBytes ~/ 20));
      debugPrint(
        '200-row progress push: $fullBytes bytes full, $deltaBytes bytes delta',
      );
    },
  );

  test(
    'window rollover, reordering and clearing match a fresh full list',
    () async {
      final before = phone.linkParseDownloads(linkDownloadsPayload(items));
      await subscribe();
      items = [...items, for (var i = 200; i < 205; i++) _item('q$i')];
      await updates.publish();
      final rollover = sent.single.message;
      expect(rollover['items'], hasLength(5));
      expect(rollover['removed'], ['q0', 'q1', 'q2', 'q3', 'q4']);
      expect(rollover['order'], hasLength(200));
      var merged = phone.linkApplyDownloadDelta(before, rollover)!;
      expect(merged.map((item) => item.id), [
        for (var i = 5; i < 205; i++) 'q$i',
      ]);
      sent.clear();
      items = items.skip(5).toList().reversed.toList();
      await updates.publish();
      expect(sent.single.message['items'], isEmpty);
      expect(sent.single.message['removed'], isEmpty);
      merged = phone.linkApplyDownloadDelta(merged, sent.single.message)!;
      expect(merged.map((item) => item.id), items.map((item) => item.id));
      sent.clear();
      items = [];
      await updates.publish();
      expect(sent.single.message['removed'], hasLength(200));
      expect(
        phone.linkApplyDownloadDelta(merged, sent.single.message),
        isEmpty,
      );
    },
  );

  test(
    'a new peer snapshot does not flush another peer progress window',
    () async {
      await subscribe();
      items[0] = _item('q0', progress: 0.9);
      updates.keepConnected([_phone, _legacy]);
      await updates.publish(snapshotsOnly: true);
      expect(sent, hasLength(1));
      expect(sent.single.peer, 'legacy');
      sent.clear();
      await updates.publish();
      expect(sent, hasLength(1));
      expect(sent.single.peer, 'phone');
      expect(sent.single.message['type'], LinkMessageTypes.downloadsDelta);
    },
  );

  test(
    'only connected peers can negotiate the supported delta version',
    () async {
      expect(updates.subscribe('absent', 1), isFalse);
      expect(updates.subscribe('phone', 2), isFalse);
      await updates.publish();
      sent.clear();
      items[0] = _item('q0', progress: 0.9);
      await updates.publish();
      expect(sent.single.peer, 'phone');
      expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
    },
  );

  test(
    'reconnect and repeated subscriptions always establish a full baseline',
    () async {
      await subscribe();
      items[0] = _item('q0', progress: 0.9);
      updates.keepConnected([]);
      await updates.publish();
      expect(sent, isEmpty);
      updates.keepConnected([_phone]);
      await updates.publish();
      expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
      sent.clear();
      expect(updates.subscribe('phone', 1), isTrue);
      await updates.publish();
      expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
    },
  );

  test('a slow send coalesces to the newest update in wire order', () async {
    await subscribe();
    final gate = Completer<int>();
    deliver = () => gate.future;
    items[0] = _item('q0', progress: 0.6);
    final first = updates.publish();
    items[0] = _item('q0', progress: 0.7);
    updates.publish();
    items[0] = _item('q0', progress: 0.8);
    updates.publish();
    expect(sent, hasLength(1));
    deliver = () async => 1;
    gate.complete(1);
    await first;
    expect(sent, hasLength(2));
    expect(
      ((sent.last.message['items'] as List).single
          as Map<String, dynamic>)['progress'],
      0.8,
    );
  });

  test('failed sends force a full snapshot on the next update', () async {
    await subscribe();
    deliver = () async => 0;
    items[0] = _item('q0', progress: 0.6);
    await updates.publish();
    sent.clear();
    deliver = () async => 1;
    items[0] = _item('q0', progress: 0.7);
    await updates.publish();
    expect(sent.single.message['type'], LinkMessageTypes.downloadsChanged);
    expect(sent.single.message['items'], hasLength(200));
  });

  test(
    'a replacement connection cannot inherit an in-flight baseline',
    () async {
      await subscribe();
      final gate = Completer<int>();
      deliver = () => gate.future;
      items[0] = _item('q0', progress: 0.6);
      final first = updates.publish();
      updates.keepConnected([
        const LinkClientInfo(
          deviceId: 'phone',
          name: 'Phone',
          platform: 'ios',
          connectedMs: 10,
        ),
      ]);
      updates.subscribe('phone', 1);
      items[0] = _item('q0', progress: 0.8);
      updates.publish();
      deliver = () async => 1;
      gate.complete(1);
      await first;
      expect(sent, hasLength(2));
      expect(sent.last.message['type'], LinkMessageTypes.downloadsChanged);
    },
  );

  test('disposal stops pending peers and coalesced updates', () async {
    updates.keepConnected([_phone, _legacy]);
    final gate = Completer<int>();
    deliver = () => gate.future;
    final pending = updates.publish();
    updates.publish();
    updates.dispose();
    gate.complete(1);
    await pending;
    expect(sent, hasLength(1));
    await updates.publish();
    expect(sent, hasLength(1));
  });
}
