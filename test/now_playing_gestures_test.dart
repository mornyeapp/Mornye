import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

class _MockPlayerController extends MusicPlayerController {
  int nextCalls = 0;
  int previousCalls = 0;

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> previous() async {
    previousCalls++;
  }
}

void main() {
  testWidgets('NowPlayingScreen artwork gestures trigger next and previous', (
    tester,
  ) async {
    final mockController = _MockPlayerController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(
              const MediaItem(
                id: 'track-1',
                title: 'Test Song',
                artist: 'Test Artist',
              ),
            ),
          ),
          playbackPlayingProvider.overrideWith((ref) => true),
          playbackLoadingProvider.overrideWith((ref) => false),
          musicPlayerControllerProvider.overrideWith((ref) => mockController),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const NowPlayingScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify gesture detector exists on artwork
    final gestureFinder = find.byKey(
      const ValueKey('now-playing-artwork-gesture'),
    );
    expect(gestureFinder, findsOneWidget);

    // Swipe left (negative dx) -> triggers next()
    await tester.drag(gestureFinder, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(mockController.nextCalls, 1);
    expect(mockController.previousCalls, 0);

    // Swipe right (positive dx) -> triggers previous()
    await tester.drag(gestureFinder, const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(mockController.previousCalls, 1);

    // Swipe down (positive dy) -> triggers dismiss
    await tester.drag(gestureFinder, const Offset(0, 300));
    await tester.pumpAndSettle();
  });
}
