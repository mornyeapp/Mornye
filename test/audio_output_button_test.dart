import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/widgets/audio_output_button.dart';

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
      await tester.tap(find.byTooltip('Audio Output'));
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
      await tester.tap(find.byTooltip('Audio Output'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cast to TV'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Looking for Google Cast devices…'), findsOneWidget);
      expect(calls.map((call) => call.method), contains('discover'));

      events.add({
        'devices': [
          {'id': 'tv-1', 'name': 'Living Room', 'model': 'Chromecast'},
          {'id': '', 'name': 'Broken entry'},
        ],
      });
      await tester.pump();
      expect(find.text('Living Room'), findsOneWidget);
      expect(find.text('Chromecast'), findsOneWidget);
      expect(find.text('Broken entry'), findsNothing);
      expect(find.text('Looking for Google Cast devices…'), findsNothing);

      await tester.tap(find.text('Living Room'));
      await tester.pumpAndSettle();
      final connect = calls.lastWhere((call) => call.method == 'connect');
      expect(connect.arguments, {'deviceId': 'tv-1'});
      expect(output.connected, isTrue);
      expect(find.text('Looking for Google Cast devices…'), findsNothing);
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
    await tester.tap(find.byTooltip('Audio Output'));
    await tester.pumpAndSettle();
    expect(find.text('Cast to TV'), findsOneWidget);
    expect(
      find.text('Google Cast devices on the same Wi-Fi network'),
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

  testWidgets('successful native request has no error and disposal is safe', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    await tester.pumpWidget(app());
    await tester.tap(find.byTooltip('Audio Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This device and Bluetooth'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    final completion = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (_) => completion.future);
    await tester.tap(find.byTooltip('Audio Output'));
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
      await tester.tap(find.byTooltip('Audio Output'));
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
