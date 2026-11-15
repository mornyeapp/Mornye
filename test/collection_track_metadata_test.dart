import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

void main() {
  final screens = <String, Widget>{
    'artist': const ArtistScreen(
      artistId: 'direct-artist',
      artistName: 'Example Artist',
      extensionId: 'example-metadata',
    ),
    'extension album': const ExtensionAlbumScreen(
      extensionId: 'example-metadata',
      albumId: 'extension-album',
      albumName: 'Example Album',
    ),
    'extension playlist': const ExtensionPlaylistScreen(
      extensionId: 'example-metadata',
      playlistId: 'extension-playlist',
      playlistName: 'Example Playlist',
    ),
    'extension artist': const ExtensionArtistScreen(
      extensionId: 'example-metadata',
      artistId: 'extension-artist',
      artistName: 'Example Artist',
    ),
    'playlist': const PlaylistScreen(
      playlistId: 'direct-playlist',
      playlistName: 'Example Playlist',
      metadataProviderId: 'example-metadata',
      tracks: [],
    ),
  };

  for (final entry in screens.entries) {
    testWidgets('${entry.key} preserves supplied track metadata', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        // Flush the debounced platform metadata cache before the next case.
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
      });
      const payload = <String, dynamic>{
        'id': 'example-song',
        'spotify_id': 'example-song',
        'provider_id': 'example-metadata',
        'name': 'Example Song',
        'artists': 'Example Artist',
        'album_name': 'Example Album',
        'album_artist': 'Example Album Artist',
        'album_type': 'album',
        'duration_ms': 180000,
        'track_number': 1,
        'genre': 'Example Genre',
        'label': 'Example Label',
        'copyright': 'Example Copyright',
        'comment': 'Example Comment',
        'upc': '0123456789012',
        'audio_quality': '24-bit/96000Hz',
        'audio_modes': 'STEREO',
      };
      const channel = MethodChannel('com.zarz.mornye/backend');
      var requested = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getProviderMetadata') {
              requested = true;
              return jsonEncode({
                'track_list': [payload],
                'top_tracks': [payload],
                'albums': <Map<String, dynamic>>[],
                'album_info': {'name': 'Example Album', 'total_tracks': 1},
                'playlist_info': {'name': 'Example Playlist'},
                'artist_info': {'name': 'Example Artist'},
              });
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await PlatformBridge.clearTrackCache();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: entry.value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requested, isTrue);
      final track = tester
          .widget<TrackCollectionQuickActions>(
            find.byType(TrackCollectionQuickActions).first,
          )
          .track;
      expect(track.id, 'example-song');
      expect(track.duration, 180);
      expect(track.genre, payload['genre']);
      expect(track.label, payload['label']);
      expect(track.copyright, payload['copyright']);
      expect(track.comment, payload['comment']);
      expect(track.upc, payload['upc']);
      expect(track.albumArtist, payload['album_artist']);
      expect(track.albumType, payload['album_type']);
      expect(track.audioQuality, payload['audio_quality']);
      expect(track.audioModes, payload['audio_modes']);
      await tester.pumpWidget(const SizedBox());
      await PlatformBridge.clearTrackCache();
      await tester.pumpAndSettle();
    });
  }
}
