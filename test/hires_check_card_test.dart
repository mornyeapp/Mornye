import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/hires_check_card.dart';

import 'support/tooltip_finder.dart';

const _limitedResult = <String, dynamic>{
  'supported': true,
  'verdict': 'band_limited',
  'declared_sample_rate': 96000,
  'cutoff_frequency_hz': 27164.0625,
  'declared_bit_depth': 24,
  'effective_bit_depth': 24,
  'analyzed_duration_s': 30,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final capture = GlobalKey();
  var calls = 0;

  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ('Google Sans Flex', 'assets/fonts/GoogleSansFlex.ttf'),
      ('Inter', 'assets/fonts/InterVariable.ttf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  setUp(() {
    calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'checkHiResAuthenticity');
          calls++;
          return _limitedResult;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> openCard(
    WidgetTester tester, {
    bool mornye = true,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    String path = '/music/track.flac',
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: mornye
            ? MornyeTheme.build(brightness)
            : brightness == Brightness.light
            ? AppTheme.light()
            : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(key: capture, child: child),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: HiResCheckCard(filePath: path),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> captureCard(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_HIRES_CARD')) return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/tmp/mornye-hires-$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final mornye in [true, false]) {
    for (final brightness in Brightness.values) {
      final name = '${mornye ? 'mornye' : 'material'}-${brightness.name}';
      testWidgets('centered action and neutral bandwidth result ($name)', (
        tester,
      ) async {
        await openCard(tester, mornye: mornye, brightness: brightness);
        await tester.pumpAndSettle();
        final button = find.ancestor(
          of: find.text('Check'),
          matching: mornye
              ? find.byType(CupertinoButton)
              : find.byType(ExpressiveButton),
        );
        expect(button, findsOneWidget);
        expect(tester.getSize(button).width, greaterThan(300));
        expect(tester.getCenter(button).dx, closeTo(195, 1));
        expect(find.byType(M3ECard), mornye ? findsNothing : findsOneWidget);
        await captureCard(tester, '$name-idle');

        await tester.tap(find.text('Check'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.text('Limited bandwidth'), findsOneWidget);
        expect(find.text('Fake Hi-Res'), findsNothing);
        expect(find.text('96.0 kHz'), findsOneWidget);
        expect(find.text('48.0 kHz'), findsOneWidget);
        expect(find.text('~27.2 kHz'), findsOneWidget);
        expect(find.text('24 / 24'), findsOneWidget);
        final rowValue = tester.getRect(find.text('~27.2 kHz'));
        final rowLabel = tester.getRect(find.text('Estimated cutoff'));
        expect(rowValue.top, closeTo(rowLabel.top, 1));
        expect(rowValue.left, greaterThan(rowLabel.right));
        expect(rowValue.right, closeTo(354, 1));
        expect(tester.takeException(), isNull);
        await captureCard(tester, '$name-result');
        await tester.tap(findByTooltip('Re-analyze'));
        await tester.pumpAndSettle();
        expect(calls, 2);
      });
    }
  }

  for (final mornye in [true, false]) {
    testWidgets('large text stays readable ($mornye)', (tester) async {
      await openCard(tester, mornye: mornye, textScale: 2);
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Based on 30.0 seconds'),
        180,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a result from the previous track cannot overwrite the new track',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) => pending.future);
      await openCard(tester);
      await tester.tap(find.text('Check'));
      await tester.pump();
      await openCard(tester, path: '/music/another.flac');
      pending.complete(_limitedResult);
      await tester.pumpAndSettle();
      expect(find.text('Check'), findsOneWidget);
      expect(find.text('Limited bandwidth'), findsNothing);
    },
  );

  testWidgets('legacy suspect results are not presented as proven fakes', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            ..._limitedResult,
            'verdict': 'fake_hires',
            'confidence': 'suspect',
          },
        );
    await openCard(tester);
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text('Limited bandwidth'), findsOneWidget);
    expect(find.textContaining('Declares'), findsNothing);
  });
}
