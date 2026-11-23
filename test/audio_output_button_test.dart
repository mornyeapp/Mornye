import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/widgets/audio_output_button.dart';

import 'support/tooltip_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/audio_output');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Widget app({
    ValueChanged<bool>? onChanged,
    Color? background,
    CastOutput? output,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: AudioOutputButton(
          onPickerChanged: onChanged,
          backgroundColor: background,
          width: 56,
          output: output,
        ),
      ),
    ),
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });
  const searching = 'Looking for Google Cast, DLNA and FCast devices…';

  testWidgets(
    'iOS opens AirPlay from the sheet and keeps controls up until it closes',
    (tester) async {
      final picker = Completer<bool>();
      final visibility = <bool>[];
      final requests = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) {
        requests.add(call.method);
        return picker.future;
      });
      await tester.pumpWidget(app(onChanged: visibility.add));
      await tester.tap(findByTooltip('Audio Output'));
      await tester.pumpAndSettle();
      expect(find.text('Cast to TV'), findsOneWidget);
      await tester.tap(find.text('AirPlay and Bluetooth'));
      await tester.pumpAndSettle();
      expect(requests, ['show']);
      expect(visibility, [true]);
      picker.complete(true);
      await tester.pumpAndSettle();
      expect(visibility, [true, false]);
      expect(find.byType(SnackBar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS lists Cast receivers in the app and connects to the chosen one',
    (tester) async {
      const castChannel = MethodChannel('cast-test');
      final events = StreamController<Object?>.broadcast(sync: true);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(castChannel, (call) async {
        calls.add(call);
        if (call.method == 'connect') {
          events.add({
            'connected': true,
            'deviceId': 'tv-1',
            'deviceName': 'Living Room',
            'host': '192.0.2.10',
          });
        }
        return call.method == 'state' ? {'connected': false} : null;
      });
      final output = CastOutput(
        channel: castChannel,
        events: events.stream,
        nativePicker: false,
      );
      addTearDown(() async {
        output.dispose();
        await events.close();
        messenger.setMockMethodCallHandler(castChannel, null);
      });
      await tester.pumpWidget(app(output: output));
      await tester.tap(findByTooltip('Audio Output'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Google Cast, DLNA and FCast devices on the same Wi-Fi network',
        ),
        findsOneWidget,
      );
      // iOS lists every kind under one row.
      expect(find.text('Other TVs and speakers'), findsNothing);
      await tester.tap(find.text('Cast to TV'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(searching), findsOneWidget);
      final discover = calls.lastWhere((call) => call.method == 'discover');
      expect(discover.arguments, {'on': true});

      events.add({
        'devices': [
          {'id': 'tv-1', 'name': 'Living Room', 'model': 'Chromecast'},
          {'id': '', 'name': 'Broken entry'},
        ],
      });
      await tester.pump();
      expect(find.text('Living Room'), findsOneWidget);
      expect(find.text('Google Cast · Chromecast'), findsOneWidget);
      expect(find.text('Broken entry'), findsNothing);
      expect(find.text(searching), findsNothing);

      await tester.tap(find.text('Living Room'));
      await tester.pumpAndSettle();
      final connect = calls.lastWhere((call) => call.method == 'connect');
      expect(connect.arguments, {'deviceId': 'tv-1'});
      expect(output.connected, isTrue);
      expect(find.text(searching), findsNothing);
      // Closing the list stops looking for receivers.
      expect(calls.last.method, 'discover');
      expect(calls.last.arguments, {'on': false});
      expect(find.byIcon(Icons.cast_connected), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('opens native output picker once and reports failure visibly', (
    tester,
  ) async {
    final completion = Completer<bool>();
    var requests = 0;
    final visibility = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'show');
      requests++;
      return completion.future;
    });
    await tester.pumpWidget(app(onChanged: visibility.add));
    await tester.tap(findByTooltip('Audio Output'));
    await tester.pumpAndSettle();
    expect(find.text('Cast to TV'), findsOneWidget);
    expect(
      find.text('Google Cast devices on the same Wi-Fi network'),
      findsOneWidget,
    );
    expect(find.text('Other TVs and speakers'), findsOneWidget);
    expect(
      find.text('DLNA and FCast devices on the same Wi-Fi network'),
      findsOneWidget,
    );
    await tester.tap(find.text('This device and Bluetooth'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(visibility, [true]);
    completion.complete(false);
    await tester.pumpAndSettle();
    expect(visibility, [true, false]);
    expect(find.text('Unable to open audio output settings.'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  group('Android cast rows', () {
    const castChannel = MethodChannel('android-cast-test');
    late StreamController<Object?> events;
    late List<MethodCall> calls;
    late CastOutput output;

    setUp(() {
      events = StreamController<Object?>.broadcast(sync: true);
      calls = [];
      messenger.setMockMethodCallHandler(castChannel, (call) async {
        calls.add(call);
        if (call.method == 'disconnect') events.add({'connected': false});
        return call.method == 'state' ? {'connected': false} : null;
      });
      output = CastOutput(channel: castChannel, events: events.stream);
    });
    tearDown(() async {
      output.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(castChannel, null);
    });

    Future<void> openSheet(WidgetTester tester) async {
      await tester.pumpWidget(app(output: output));
      await tester.tap(findByTooltip('Audio Output'));
      await tester.pumpAndSettle();
    }

    Finder row(String key, String text) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.text(text),
    );

    testWidgets('the other row opens the app list without Google Cast', (
      tester,
    ) async {
      await openSheet(tester);
      await tester.tap(find.text('Other TVs and speakers'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls.map((call) => call.method), isNot(contains('show')));
      final discover = calls.lastWhere((call) => call.method == 'discover');
      expect(discover.arguments, {
        'on': true,
        'kinds': ['dlna', 'fcast', 'roku'],
      });
      expect(find.text('Looking for DLNA and FCast devices…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a session of another kind is named on its own row and stops', (
      tester,
    ) async {
      await output.initialize();
      events.add({
        'connected': true,
        'deviceId': 'dlna:uuid-1',
        'deviceName': 'Kitchen',
        'host': '192.0.2.40',
        'kind': 'dlna',
      });
      await openSheet(tester);
      expect(row('audio-output-cast', 'Cast to TV'), findsOneWidget);
      expect(row('audio-output-cast-other', 'Kitchen'), findsOneWidget);
      expect(find.text('Other TVs and speakers'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('audio-output-cast-other')),
          matching: find.byIcon(Icons.cast_connected),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Stop casting'));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'disconnect');
      expect(output.connected, isFalse);
      expect(find.byType(SnackBar), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a stop that fails names no Google service', (tester) async {
      await output.initialize();
      events.add({
        'connected': true,
        'deviceId': 'fcast:den',
        'deviceName': 'Den',
        'host': '192.0.2.41',
        'kind': 'fcast',
      });
      messenger.setMockMethodCallHandler(castChannel, (call) async {
        if (call.method == 'disconnect') {
          throw PlatformException(code: 'CAST_UNAVAILABLE');
        }
        return null;
      });
      await openSheet(tester);
      await tester.tap(find.text('Stop casting'));
      await tester.pumpAndSettle();
      expect(
        find.text('Unable to reach cast devices. Check local network access.'),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a Google Cast session is named on the Cast row', (
      tester,
    ) async {
      await output.initialize();
      events.add({
        'connected': true,
        'deviceId': 'tv-1',
        'deviceName': 'Living Room',
        'host': '192.0.2.10',
      });
      await openSheet(tester);
      expect(row('audio-output-cast', 'Living Room'), findsOneWidget);
      expect(
        row('audio-output-cast-other', 'Other TVs and speakers'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('audio-output-stop')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  testWidgets('successful native request has no error and disposal is safe', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    await tester.pumpWidget(app());
    await tester.tap(findByTooltip('Audio Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This device and Bluetooth'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    final completion = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (_) => completion.future);
    await tester.tap(findByTooltip('Audio Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This device and Bluetooth'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    completion.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'a filled button is a pill as wide as asked and still opens',
    (tester) async {
      var requests = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        requests++;
        return true;
      });
      messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (_) async => null,
      );
      await tester.pumpWidget(app(background: Colors.grey));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(AudioOutputButton)),
        const Size(56, 48),
      );
      await tester.tap(findByTooltip('Audio Output'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(
          defaultTargetPlatform == TargetPlatform.iOS
              ? 'AirPlay and Bluetooth'
              : 'This device and Bluetooth',
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('unsupported desktop does not expose an inert control', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(UiKitView), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
