import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_output_volume.dart';
import 'package:mornye/services/system_volume_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/player_volume_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('In-app volume writes suppress the system volume panel', () async {
    const channel = MethodChannel('com.kurenai7968.volume_controller.method');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => calls.add(call),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(systemVolumeWriterProvider)(0.7);
    expect(calls.single.method, 'setVolume');
    expect(calls.single.arguments, {'volume': 0.7, 'showSystemUI': false});
  });

  test('Desktop volume writes set the in-app gain, never the system', () async {
    const channel = MethodChannel('com.kurenai7968.volume_controller.method');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => calls.add(call),
    );
    debugDesktopPlatformOverride = true;
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDesktopPlatformOverride = null;
      playbackOutputVolume.value = 1;
    });
    final volume = SystemVolumeService();
    final values = <double>[];
    final subscription = volume.changes.listen(values.add);
    addTearDown(subscription.cancel);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(systemVolumeWriterProvider)(0.4);
    await Future<void>.delayed(Duration.zero);
    expect(playbackOutputVolume.value, 0.4);
    expect(values, [1, 0.4]);
    expect(calls, isEmpty);
  });

  testWidgets('Slow volume writes coalesce and cannot reset an active drag', (
    tester,
  ) async {
    final writes = <double>[];
    final completions = <Completer<void>>[];
    final volumes = StreamController<double>();
    addTearDown(volumes.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          systemVolumeProvider.overrideWith((ref) => volumes.stream),
          systemVolumeWriterProvider.overrideWith(
            (ref) => (value) {
              writes.add(value);
              final completion = Completer<void>();
              completions.add(completion);
              return completion.future;
            },
          ),
        ],
        child: MaterialApp(
          // The Mornye glass slider, which reports drag start itself.
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: PlayerVolumeControl()),
        ),
      ),
    );
    volumes.add(0.5);
    await tester.pumpAndSettle();
    Slider slider() => tester.widget(find.byType(Slider));

    slider().onChangeStart!(0.5);
    slider().onChanged!(0.6);
    slider().onChanged!(0.7);
    slider().onChanged!(0.8);
    await tester.pump();
    expect(writes, [0.6]);
    expect(slider().value, 0.8);

    completions.first.complete();
    await tester.pump();
    expect(writes, [0.6, 0.8]);
    volumes.add(0.6);
    completions.last.complete();
    await tester.pump();
    expect(slider().value, 0.8);

    slider().onChangeEnd!(0.8);
    slider().onChangeStart!(0.8);
    slider().onChanged!(0.9);
    completions.last.complete();
    await tester.pump();
    expect(writes.last, 0.9);
    completions.last.complete();
    await tester.pump();
    expect(slider().value, 0.9);

    slider().onChangeEnd!(0.9);
    volumes.add(0.9);
    completions.last.complete();
    await tester.pump();
    volumes.add(0.3);
    await tester.pumpAndSettle();
    expect(slider().value, 0.3);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'Desktop wheel adjusts volume without scrolling the page ($mornye)',
      (tester) async {
        PlaybackOutputVolumeStore.debugReset();
        debugDesktopPlatformOverride = true;
        playbackOutputVolume.value = 0.5;
        addTearDown(() {
          PlaybackOutputVolumeStore.debugReset();
          debugDesktopPlatformOverride = null;
          playbackOutputVolume.value = 1;
        });
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              systemVolumeProvider.overrideWith(
                (ref) => playbackOutputVolumeChanges(),
              ),
            ],
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ListView(
                  controller: scroll,
                  children: const [
                    PlayerVolumeControl(),
                    SizedBox(height: 2000),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final icon = find.byIcon(
          mornye ? CupertinoIcons.speaker_3_fill : Icons.volume_up_rounded,
        );
        final position = tester.getCenter(icon);
        void wheel(Offset delta) => tester.binding.handlePointerEvent(
          PointerScrollEvent(position: position, scrollDelta: delta),
        );

        // Repeated events before a rebuild still use the latest app gain.
        for (var i = 0; i < 3; i++) {
          wheel(const Offset(0, -20));
        }
        expect(playbackOutputVolume.value, closeTo(0.65, 0.000001));
        wheel(const Offset(0, 20));
        expect(playbackOutputVolume.value, closeTo(0.6, 0.000001));
        wheel(const Offset(20, 0));
        expect(playbackOutputVolume.value, closeTo(0.6, 0.000001));
        await tester.pumpAndSettle();
        expect(scroll.offset, 0);

        for (var i = 0; i < 30; i++) {
          wheel(const Offset(0, 20));
        }
        expect(playbackOutputVolume.value, 0);
        for (var i = 0; i < 30; i++) {
          wheel(const Offset(0, -20));
        }
        expect(playbackOutputVolume.value, 1);
        await tester.pumpAndSettle();
        expect(scroll.offset, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'Material holds dragged volume (reduced motion: $reducedMotion)',
      (tester) async {
        final writes = <double>[];
        final volumes = StreamController<double>();
        addTearDown(volumes.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              systemVolumeProvider.overrideWith((ref) => volumes.stream),
              systemVolumeWriterProvider.overrideWith(
                (ref) =>
                    (value) async => writes.add(value),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: const Scaffold(body: PlayerVolumeControl()),
              ),
            ),
          ),
        );
        volumes.add(0.5);
        await tester.pumpAndSettle();
        AppSlider slider() => tester.widget(find.byType(AppSlider));
        expect(slider().value, 0.5);

        // A finger on the track: the write finishes and the system echoes an
        // older level, but the thumb stays where the user put it.
        final finger = await tester.startGesture(
          tester.getCenter(find.byType(AppSlider)),
        );
        await finger.moveBy(const Offset(20, 0));
        await tester.pump();
        await finger.moveBy(const Offset(100, 0));
        await tester.pump();
        final draggedVolume = slider().value;
        expect(draggedVolume, greaterThan(0.5));
        expect(writes.last, draggedVolume);
        volumes.add(0.6);
        await tester.pump();
        expect(slider().value, draggedVolume);

        // Once the finger lifts the slider follows the system again.
        await finger.up();
        expect(writes.last, draggedVolume);
        volumes.add(draggedVolume);
        await tester.pumpAndSettle();
        expect(slider().value, draggedVolume);
        volumes.add(0.2);
        await tester.pumpAndSettle();
        expect(slider().value, 0.2);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
