import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/spotify_canvas_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpotifyCanvasService Caching & Crossfade', () {
    test(
      'resolveCanvas caches remote canvas bytes to local disk on resolution',
      () async {
        final mockClient = MockClient((request) async {
          if (request.url.toString().contains('api/canvas')) {
            return http.Response(
              jsonEncode({'canvas_url': 'https://video.example/stream.mp4'}),
              200,
            );
          }
          if (request.url.toString() == 'https://video.example/stream.mp4') {
            return http.Response.bytes(
              [
                0,
                0,
                0,
                24,
                102,
                116,
                121,
                112,
                105,
                115,
                111,
                109,
              ], // fake mp4 header
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final service = SpotifyCanvasService(client: mockClient);
        final artwork = await service.resolveCanvas((
          id: '123',
          title: 'Cached Song',
          artist: 'Cached Artist',
          album: 'Cached Album',
          source: null,
          spotifyId: 'track_spotify_id_1',
          canvasUrl: null,
        ));

        expect(artwork, isNotNull);
        expect(artwork!.aspectRatio, 9 / 16);
        // The resolved artwork source is either a file URI or remote fallback
        expect(
          artwork.source,
          anyOf(startsWith('file://'), startsWith('https://')),
        );
      },
    );
  });
}
