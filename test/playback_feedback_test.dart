import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/playback_feedback.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('playback errors show themed feedback (Mornye: $mornye)', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final runtime = MusicPlayerRuntime();
      addTearDown(runtime.dispose);
      final states = StreamController<PlaybackState>();
      addTearDown(states.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
            playbackStateProvider.overrideWith((_) => states.stream),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) =>
                AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final failed = PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: 'Audio output failed',
      );
      states.add(failed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.text('Cannot open file: Audio output failed'),
        findsOneWidget,
      );
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      states.add(failed.copyWith(updatePosition: const Duration(seconds: 1)));
      await tester.pumpAndSettle();
      expect(find.text('Cannot open file: Audio output failed'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'superseded errors do not linger after playback recovers ($mornye)',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final runtime = MusicPlayerRuntime();
        addTearDown(runtime.dispose);
        final states = StreamController<PlaybackState>();
        addTearDown(states.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              musicPlayerRuntimeProvider.overrideWithValue(runtime),
              playbackStateProvider.overrideWith((_) => states.stream),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              builder: (_, child) =>
                  AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
              home: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final failed = PlaybackState(
          processingState: AudioProcessingState.error,
          errorCode: 1,
          errorMessage: 'Cancelled source',
        );
        final ready = PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
        );
        states.add(failed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        states.add(ready);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Cannot open file: Cancelled source'), findsNothing);

        // A lasting failure is still visible, then clears when playback works.
        states.add(failed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.text('Cannot open file: Cancelled source'), findsOneWidget);
        states.add(ready);
        await tester.pumpAndSettle();
        expect(find.text('Cannot open file: Cancelled source'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('muted feedback is transient and themed (Mornye: $mornye)', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final runtime = MusicPlayerRuntime();
      addTearDown(runtime.dispose);
      // Notices emitted before the shell mounts must not be replayed.
      runtime.notifyMutedPlayback();
      final message = mornye
          ? 'Volume media nol. Lagu dijeda. Tekan play lagi untuk tetap memutar.'
          : 'Media volume is zero. Playback paused. Press play again to continue.';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
          child: MaterialApp(
            locale: Locale(mornye ? 'id' : 'en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) =>
                AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      // A later mute episode may emit the exact same warning again.
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
