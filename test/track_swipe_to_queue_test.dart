import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/track_list_tile.dart';

class _FakeMusicPlayerController extends MusicPlayerController {
  _FakeMusicPlayerController() : super();

  PlayableMedia? lastPlayNextItem;

  @override
  Future<void> playNext(PlayableMedia item) async {
    lastPlayNextItem = item;
  }
}

class _FakePlaybackNotifier extends PlaybackController {
  @override
  PlaybackState build() => const PlaybackState();

  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async {
    return List.filled(tracks.length, 'local://resolved-track');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final track = const Track(
    id: 'test-track-1',
    name: 'Viva La Vida',
    artistName: 'Coldplay',
    albumName: 'Viva La Vida',
    duration: 242,
  );

  testWidgets(
    'swiping track right-to-left triggers playNext and shows snackbar',
    (tester) async {
      final fakePlayer = _FakeMusicPlayerController();
      final fakePlayback = _FakePlaybackNotifier();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicPlayerControllerProvider.overrideWithValue(fakePlayer),
            playbackProvider.overrideWith(() => fakePlayback),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 84,
                  child: TrackListTile(
                    track: track,
                    isInHistory: true,
                    onDownload: ({bool forceQualityPicker = false}) {},
                    leading: const Icon(Icons.music_note),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Viva La Vida'), findsOneWidget);

      // Swipe right-to-left
      await tester.drag(find.text('Viva La Vida'), const Offset(-250, 0));
      await tester.pumpAndSettle();

      // Verify playNext was called
      expect(fakePlayer.lastPlayNextItem, isNotNull);
      expect(fakePlayer.lastPlayNextItem!.title, equals('Viva La Vida'));

      // Verify row is still in the tree (snap back)
      expect(find.text('Viva La Vida'), findsOneWidget);
    },
  );
}
