import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/smart_playlists_provider.dart';
import 'package:mornye/screens/smart_playlist_screen.dart';
import 'package:mornye/services/smart_playlists_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmartPlaylistsService', () {
    test('SmartPlaylistType has distinct keys and display titles', () {
      expect(SmartPlaylistType.recentlyAdded.title, isNotEmpty);
      expect(SmartPlaylistType.mostPlayed.title, isNotEmpty);
      expect(SmartPlaylistType.bpmMix.title, isNotEmpty);
      expect(SmartPlaylistType.recentlyAdded.id, 'smart_recently_added');
      expect(SmartPlaylistType.mostPlayed.id, 'smart_most_played');
      expect(SmartPlaylistType.bpmMix.id, 'smart_bpm_mix');
    });

    test('getPlaylistTracks maps records to Track objects', () async {
      final service = SmartPlaylistsService();
      expect(service, isNotNull);
      final tracks = await service.getPlaylistTracks(
        SmartPlaylistType.recentlyAdded,
      );
      expect(tracks, isA<List<Track>>());
    });

    testWidgets(
      'SmartPlaylistScreen renders loading and loads tracks provider',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              smartPlaylistTracksProvider(
                SmartPlaylistType.recentlyAdded,
              ).overrideWith(
                (ref) async => [
                  const Track(
                    id: 't1',
                    name: 'Dynamic Track 1',
                    artistName: 'Artist 1',
                    albumName: 'Album 1',
                    duration: 180000,
                  ),
                ],
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: SmartPlaylistScreen(type: SmartPlaylistType.recentlyAdded),
            ),
          ),
        );

        await tester.pumpAndSettle();
        expect(find.text('Aggiunti di recente'), findsWidgets);
        expect(find.text('Dynamic Track 1'), findsOneWidget);
      },
    );
  });
}
