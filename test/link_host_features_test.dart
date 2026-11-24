import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';

const _computer = LinkServerRecord(
  serverId: 'server-1',
  name: 'Studio',
  connectionId: 'connection-1',
  address: 'https://192.0.2.10:47710',
  fingerprint: 'ab',
);

void main() {
  group('LinkServerRecord', () {
    test('an older host that announces nothing has every ability', () {
      for (final feature in LinkHostFeatures.all) {
        expect(_computer.supports(feature), isTrue, reason: feature);
      }
      expect(_computer.isPhone, isFalse);
    });

    test('a phone host has only what it announces', () {
      final phone = _computer.announced(platform: 'android', features: []);
      expect(phone.isPhone, isTrue);
      for (final feature in LinkHostFeatures.all) {
        expect(phone.supports(feature), isFalse, reason: feature);
      }
      expect(
        _computer
            .announced(platform: 'ios', features: [LinkHostFeatures.open])
            .supports(LinkHostFeatures.open),
        isTrue,
      );
    });

    test('announcing the same again keeps the record', () {
      final phone = _computer.announced(platform: 'android', features: []);
      expect(
        identical(phone.announced(platform: 'android', features: []), phone),
        isTrue,
      );
      expect(
        identical(_computer.announced(platform: '', features: null), _computer),
        isTrue,
      );
    });

    test('keeps platform and features through JSON and copies', () {
      final phone = _computer.announced(platform: 'android', features: []);
      final restored = LinkServerRecord.fromJson(phone.toJson())!;
      expect(restored.platform, 'android');
      expect(restored.features, isEmpty);
      final moved = restored.copyWith(address: 'https://192.0.2.11:47710');
      expect(moved.features, isEmpty);
      expect(moved.platform, 'android');

      // Records saved before hosts announced anything read as computers.
      final old = LinkServerRecord.fromJson(_computer.toJson())!;
      expect(_computer.toJson().containsKey('features'), isFalse);
      expect(old.features, isNull);
      expect(old.platform, isEmpty);
    });
  });

  group('LinkServerInfo', () {
    test('reads the platform and features a host announces', () {
      final info = LinkServerInfo.fromJson({
        'serverId': 'server-2',
        'fingerprint': 'AB',
        'name': 'Pocket',
        'platform': 'android',
        'features': ['downloads', 7, ''],
      })!;
      expect(info.platform, 'android');
      expect(info.features, ['downloads']);
      expect(LinkServerInfo.fromJson(info.toJson())!.features, ['downloads']);
    });

    test('an older host reads as one with everything', () {
      final info = LinkServerInfo.fromJson({
        'serverId': 'server-2',
        'fingerprint': 'ab',
      })!;
      expect(info.platform, isEmpty);
      expect(info.features, isNull);
      expect(linkHostFeaturesFromJson('downloads'), isNull);
    });
  });

  group('discovery', () {
    LinkServiceResolved service(Map<String, String> attributes) =>
        LinkServiceResolved(
          name: 'Pocket',
          port: 47710,
          addresses: const ['192.0.2.20'],
          attributes: {
            'v': '$linkProtocolVersion',
            'id': 'server-2',
            'fp': 'ab' * 32,
            ...attributes,
          },
        );

    test('a phone host says so in its TXT record', () {
      final phone = linkDiscoveredServerFrom(service({'pf': 'Android'}))!;
      expect(phone.platform, 'android');
      expect(phone.isPhone, isTrue);
      final computer = linkDiscoveredServerFrom(service({}))!;
      expect(computer.platform, isEmpty);
      expect(computer.isPhone, isFalse);
      expect(phone == computer, isFalse);
    });
  });
}
