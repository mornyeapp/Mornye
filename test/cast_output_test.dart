import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/widgets/cast_device_picker.dart';

/// Records every call; closed by the test that made it.
class _FakeTransport implements CastTransport {
  final calls = <(String, Map<String, Object?>?)>[];
  final sent = StreamController<Object?>.broadcast(sync: true);

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add((method, arguments));
    return method == 'state' ? {'connected': false} : null;
  }

  @override
  Stream<Object?> events() => sent.stream;

  Future<void> close() => sent.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CastKind.parse', () {
    test('reads every kind the platforms send', () {
      expect(CastKind.parse('cast'), CastKind.cast);
      expect(CastKind.parse('dlna'), CastKind.dlna);
      expect(CastKind.parse('fcast'), CastKind.fcast);
      expect(CastKind.parse('roku'), CastKind.roku);
    });

    test('a missing kind is Google Cast, an unknown one is other', () {
      expect(CastKind.parse(null), CastKind.cast);
      expect(CastKind.parse('a-future-protocol'), CastKind.other);
      expect(CastKind.parse(''), CastKind.other);
      expect(CastKind.parse(3), CastKind.other);
    });

    test('others leaves out Google Cast only', () {
      expect(CastKind.others, isNot(contains(CastKind.cast)));
      expect(CastKind.others, hasLength(CastKind.values.length - 1));
    });
  });

  group('CastDevice.fromMap', () {
    test('keeps the kind and defaults to Google Cast', () {
      expect(
        CastDevice.fromMap({
          'id': 'dlna:uuid-1',
          'name': 'Kitchen',
          'model': 'Speaker One',
          'kind': 'dlna',
        }),
        const CastDevice(
          id: 'dlna:uuid-1',
          name: 'Kitchen',
          model: 'Speaker One',
          kind: CastKind.dlna,
        ),
      );
      expect(
        CastDevice.fromMap({'id': 'tv-1', 'name': 'Living Room'})?.kind,
        CastKind.cast,
      );
    });

    test('devices of another kind are not equal', () {
      const cast = CastDevice(id: 'x', name: 'A');
      const dlna = CastDevice(id: 'x', name: 'A', kind: CastKind.dlna);
      expect(cast == dlna, isFalse);
    });

    test('drops entries without an id or name', () {
      expect(CastDevice.fromMap({'id': '', 'name': 'A'}), isNull);
      expect(CastDevice.fromMap({'id': 'a'}), isNull);
      expect(CastDevice.fromMap('not a map'), isNull);
    });
  });

  group('CastOutput', () {
    late _FakeTransport transport;
    late CastOutput output;

    setUp(() {
      transport = _FakeTransport();
      output = CastOutput(transport: transport, nativePicker: false);
    });
    tearDown(() async {
      output.dispose();
      await transport.close();
    });

    Map<String, Object?>? lastDiscover() =>
        transport.calls.lastWhere((call) => call.$1 == 'discover').$2;

    test(
      'discover names the kinds asked for, and none for every kind',
      () async {
        await output.discover(true, kinds: CastKind.others);
        expect(lastDiscover(), {
          'on': true,
          'kinds': ['dlna', 'fcast', 'roku'],
        });
        await output.discover(true);
        expect(lastDiscover(), {'on': true});
        await output.discover(false, kinds: CastKind.others);
        expect(lastDiscover(), {'on': false});
      },
    );

    test('the session kind follows the snapshot', () async {
      await output.initialize();
      var changes = 0;
      output.addListener(() => changes++);
      transport.sent.add({
        'connected': true,
        'deviceId': 'fcast:den',
        'deviceName': 'Den',
        'host': '192.0.2.20',
        'kind': 'fcast',
      });
      expect(output.kind, CastKind.fcast);
      expect(output.hasVolume, isFalse);
      expect(changes, 1);

      transport.sent.add({
        'connected': true,
        'deviceId': 'fcast:den',
        'deviceName': 'Den',
        'host': '192.0.2.20',
        'kind': 'dlna',
        'volume': 0.5,
      });
      expect(output.kind, CastKind.dlna);
      expect(output.hasVolume, isTrue);
      expect(changes, 2);

      // Older platforms send no kind: Google Cast.
      transport.sent.add({'connected': true, 'deviceId': 'tv'});
      expect(output.kind, CastKind.cast);
    });

    test('device lists carry each receiver kind', () async {
      await output.initialize();
      transport.sent.add({
        'devices': [
          {'id': 'tv', 'name': 'Living Room', 'model': 'Stick'},
          {'id': 'dlna:a', 'name': 'Kitchen', 'kind': 'dlna'},
        ],
      });
      expect(output.devices.map((device) => device.kind), [
        CastKind.cast,
        CastKind.dlna,
      ]);
    });

    test('a platform without the plugin leaves the output idle', () async {
      final missing = CastOutput(
        channel: const MethodChannel('cast-missing-test'),
        events: const Stream.empty(),
      );
      addTearDown(missing.dispose);
      await missing.initialize();
      expect(missing.connected, isFalse);
      expect(missing.kind, CastKind.cast);
    });
  });

  group('castKindNames', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final id = lookupAppLocalizations(const Locale('id'));

    test('names the listed kinds in plain words', () {
      expect(castKindNames(en), 'Google Cast, DLNA and FCast');
      expect(castKindNames(en, {CastKind.cast}), 'Google Cast');
      expect(castKindNames(en, CastKind.others), 'DLNA and FCast');
      expect(castKindNames(id, CastKind.others), 'DLNA dan FCast');
    });

    test('a kind left out of the named list still has its name', () {
      expect(castKindNames(en, {CastKind.roku}), 'Roku');
      expect(castKindNames(en, {CastKind.other}), '');
    });

    test('description and searching line take the names', () {
      expect(
        en.audioOutputCastDescription(castKindNames(en)),
        'Google Cast, DLNA and FCast devices on the same Wi-Fi network',
      );
      expect(
        id.audioOutputCastSearching(castKindNames(id, CastKind.others)),
        'Mencari perangkat DLNA dan FCast…',
      );
    });
  });
}
