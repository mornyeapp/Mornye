import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/audio_output_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/audio_output');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Widget app({ValueChanged<bool>? onChanged, Color? background}) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: AudioOutputButton(
          onPickerChanged: onChanged,
          backgroundColor: background,
          width: 56,
        ),
      ),
    ),
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets(
    'iOS embeds the native audio route control and forwards its presentation',
    (tester) async {
      int? viewId;
      final visibility = <bool>[];
      final updates = <MethodCall>[];
      MethodChannel? viewChannel;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final args = call.arguments as Map<Object?, Object?>;
          expect(args['viewType'], 'com.zarz.mornye/audio_output');
          viewId = args['id'] as int;
          viewChannel = MethodChannel('com.zarz.mornye/audio_output/$viewId');
          messenger.setMockMethodCallHandler(
            viewChannel!,
            (call) async => updates.add(call),
          );
        }
        return null;
      });
      await tester.pumpWidget(app(onChanged: visibility.add));
      await tester.pumpAndSettle();
      expect(viewId, isNotNull);
      expect(updates.last.arguments, containsPair('label', 'Audio Output'));
      for (final open in [true, false]) {
        await messenger.handlePlatformMessage(
          viewChannel!.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('pickerChanged', open),
          ),
          (_) {},
        );
      }
      expect(visibility, [true, false]);
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(viewChannel!, null);
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
    await tester.tap(find.byTooltip('Audio Output'));
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
    expect(find.byType(SnackBar), findsNothing);

    final completion = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (_) => completion.future);
    await tester.tap(find.byTooltip('Audio Output'));
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
      if (defaultTargetPlatform == TargetPlatform.android) {
        await tester.tap(find.byTooltip('Audio Output'));
        await tester.pumpAndSettle();
        expect(requests, 1);
      }
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
