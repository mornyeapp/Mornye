import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/cast_device_picker.dart';

/// A sender whose `connect` reports a session of the chosen device's kind.
class _FakeSender implements CastTransport {
  final calls = <(String, Map<String, Object?>?)>[];
  final sent = StreamController<Object?>.broadcast(sync: true);
  final kinds = <String, String>{};

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add((method, arguments));
    switch (method) {
      case 'state':
        return {'connected': false};
      case 'connect':
        final id = arguments!['deviceId']! as String;
        sent.add({
          'connected': true,
          'deviceId': id,
          'deviceName': 'Receiver $id',
          'host': '192.0.2.30',
          'kind': kinds[id],
        });
      case 'disconnect':
        sent.add({'connected': false});
    }
    return null;
  }

  @override
  Stream<Object?> events() => sent.stream;

  void devices(List<Map<String, Object?>> list) {
    for (final device in list) {
      kinds[device['id']! as String] = '${device['kind'] ?? 'cast'}';
    }
    sent.add({'devices': list});
  }
}

const _receivers = [
  {'id': 'tv-1', 'name': 'Living Room', 'model': 'Stick'},
  {
    'id': 'dlna:uuid-1',
    'name': 'Kitchen',
    'model': 'Speaker One',
    'kind': 'dlna',
  },
  {'id': 'fcast:den', 'name': 'Den', 'kind': 'fcast'},
  {'id': 'next:1', 'name': 'Attic', 'kind': 'a-future-protocol'},
];

void main() {
  late _FakeSender sender;
  late CastOutput output;

  setUp(() {
    sender = _FakeSender();
    output = CastOutput(transport: sender, nativePicker: false);
  });
  tearDown(() async {
    output.dispose();
    await sender.sent.close();
  });

  Future<void> open(
    WidgetTester tester, {
    required bool mornye,
    Set<CastKind>? kinds,
  }) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Mornye's glass reads the settings.
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(const AppSettings()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
              : AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showCastDevicePicker(
                    context,
                    output: output,
                    kinds: kinds,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Map<String, Object?>? lastCall(String method) =>
      sender.calls.lastWhere((call) => call.$1 == method).$2;

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style lists every kind, connects and stops', (tester) async {
      await open(tester, mornye: mornye);
      expect(find.text('Cast to TV'), findsOneWidget);
      expect(
        find.text(
          'Google Cast, DLNA and FCast devices on the same Wi-Fi network',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Looking for Google Cast, DLNA and FCast devices…'),
        findsOneWidget,
      );
      expect(lastCall('discover'), {'on': true});

      sender.devices(_receivers);
      await tester.pump();
      expect(find.text('Living Room'), findsOneWidget);
      expect(find.text('Google Cast · Stick'), findsOneWidget);
      expect(find.text('DLNA · Speaker One'), findsOneWidget);
      expect(find.text('FCast'), findsOneWidget);
      // A kind this build does not know is listed without a protocol name.
      expect(find.text('Attic'), findsOneWidget);
      expect(find.byKey(const ValueKey('cast-device-searching')), findsNothing);
      expect(find.byKey(const ValueKey('cast-stop')), findsNothing);

      await tester.tap(find.text('Kitchen'));
      await tester.pumpAndSettle();
      expect(lastCall('connect'), {'deviceId': 'dlna:uuid-1'});
      expect(output.connected, isTrue);
      expect(output.kind, CastKind.dlna);
      // Closing the sheet stops looking.
      expect(sender.calls.last.$1, 'discover');
      expect(sender.calls.last.$2, {'on': false});
      expect(find.text('Kitchen'), findsNothing);

      await tester.tap(find.text('Open'));
      await tester.pump();
      sender.devices(_receivers);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cast-stop')), findsOneWidget);
      await tester.tap(find.text('Stop casting'));
      await tester.pumpAndSettle();
      expect(lastCall('disconnect'), isNull);
      expect(output.connected, isFalse);
      expect(find.text('Stop casting'), findsNothing);
    });

    testWidgets('$style lists only the kinds it is asked for', (tester) async {
      // A Google Cast session belongs to Google's dialog on Android.
      await output.initialize();
      sender.sent.add({
        'connected': true,
        'deviceId': 'tv-1',
        'deviceName': 'Living Room',
        'host': '192.0.2.10',
        'kind': 'cast',
      });
      await open(tester, mornye: mornye, kinds: CastKind.others);
      expect(find.text('Other TVs and speakers'), findsOneWidget);
      expect(
        find.text('DLNA and FCast devices on the same Wi-Fi network'),
        findsOneWidget,
      );
      expect(find.text('Looking for DLNA and FCast devices…'), findsOneWidget);
      expect(lastCall('discover'), {
        'on': true,
        'kinds': ['dlna', 'fcast', 'roku'],
      });

      sender.devices(_receivers);
      await tester.pump();
      expect(find.text('Living Room'), findsNothing);
      expect(find.text('Kitchen'), findsOneWidget);
      expect(find.text('Den'), findsOneWidget);
      expect(find.byKey(const ValueKey('cast-stop')), findsNothing);
      await tester.tap(find.text('Den'));
      await tester.pumpAndSettle();
      expect(lastCall('connect'), {'deviceId': 'fcast:den'});
      expect(output.kind, CastKind.fcast);
    });
  }

  testWidgets('a failed connect stays open and says so', (tester) async {
    output.dispose();
    final failing = output = CastOutput(
      transport: _FailingConnect(sender),
      nativePicker: false,
    );
    await open(tester, mornye: false);
    sender.devices(_receivers);
    await tester.pump();
    await tester.tap(find.text('Den'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Could not connect to Den'), findsOneWidget);
    expect(find.text('Den'), findsOneWidget);
    expect(failing.connected, isFalse);
  });
}

class _FailingConnect implements CastTransport {
  _FailingConnect(this.inner);

  final _FakeSender inner;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      method == 'connect'
      ? Future.error(StateError('unreachable'))
      : inner.invoke(method, arguments);

  @override
  Stream<Object?> events() => inner.events();
}
