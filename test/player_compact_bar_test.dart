import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/player_compact_bar.dart';

class _Player extends MusicPlayerController {
  final calls = <String>[];

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');
}

void main() {
  testWidgets('the compact player keeps the transport, timeline and queue', (
    tester,
  ) async {
    final player = _Player();
    final seekPreview = PlaybackSeekPreview();
    addTearDown(seekPreview.dispose);
    var queueOpened = 0;
    final theme = AppTheme.light();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackPlayingProvider.overrideWith((ref) => true),
          playbackLoadingProvider.overrideWith((ref) => false),
          playbackPositionProvider.overrideWith(
            (ref) => const Duration(seconds: 30),
          ),
          musicPlayerControllerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: theme,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // The playing timeline keeps moving; the player rests here.
          home: TickerMode(
            enabled: false,
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: PlayerCompactBar(
                  mediaItem: const MediaItem(
                    id: 'song',
                    title: 'Song',
                    artist: 'Artist',
                    duration: Duration(minutes: 2),
                  ),
                  seekPreview: seekPreview,
                  colorScheme: theme.colorScheme,
                  onOpenQueue: () => queueOpened++,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Song'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('2:00'), findsOneWidget);
    expect(find.byType(PlaybackSeekSlider), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.text('Song')));
    await tester.tap(find.byTooltip(l10n.nowPlayingPreviousTrack));
    await tester.tap(find.byTooltip(l10n.actionPause));
    await tester.tap(find.byTooltip(l10n.nowPlayingNextTrack));
    expect(player.calls, ['previous', 'pause', 'next']);
    await tester.tap(find.byTooltip(l10n.nowPlayingUpNext));
    expect(queueOpened, 1);
    expect(tester.takeException(), isNull);
  });
}
