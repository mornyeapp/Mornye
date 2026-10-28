import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/metadata_autofill_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = MetadataAutofillService();

  test(
    'album video is resolved even when the track has a still cover',
    () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final resources = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getProviderMetadata');
        final arguments = call.arguments as Map;
        resources.add(arguments['resource_type'] as String);
        return jsonEncode(
          arguments['resource_type'] == 'track'
              ? {
                  'track': {
                    'id': 'motion-track',
                    'album_id': 'motion-album',
                    'cover_url': 'https://example.invalid/track.jpg',
                  },
                }
              : {
                  'album_info': {
                    'cover_url': 'https://example.invalid/album.jpg',
                    'header_video': 'https://example.invalid/motion.m3u8',
                  },
                },
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final details = await service.resolveDetails(
        {'id': 'motion-track'},
        providerId: 'motion-provider',
        includeCover: true,
      );
      expect(resources, ['track', 'album']);
      expect(details['cover_url'], 'https://example.invalid/track.jpg');
      for (final includeCover in [true, false]) {
        final result = await service.enrich(
          details,
          currentValues: const {},
          fields: includeCover ? {'cover'} : {},
          providerId: 'motion-provider',
          sourceTrackId: null,
          durationMs: 0,
          syncLyricsSettings: () async {},
          isCurrent: () => true,
        );
        expect(
          result!.headerVideoUrl,
          includeCover ? 'https://example.invalid/motion.m3u8' : null,
        );
      }
    },
  );

  Extension provider(String id, String name, {bool enabled = true}) =>
      Extension(
        id: id,
        name: id,
        displayName: name,
        version: '1.0.0',
        description: 'Metadata fixture',
        enabled: enabled,
        status: 'loaded',
        hasMetadataProvider: true,
      );

  test(
    'configured providers precede remaining enabled alphabetical providers',
    () {
      final ordered = service.orderedProviders(
        ExtensionState(
          extensions: [
            provider('third', 'Zeta'),
            provider('second', 'Alpha'),
            provider('first', 'Beta'),
            provider('disabled', 'Disabled', enabled: false),
          ],
          metadataProviderPriority: const ['missing', 'third', 'third'],
        ),
      );
      expect(ordered.map((extension) => extension.id), [
        'third',
        'second',
        'first',
      ]);
    },
  );

  test('Unicode title/artist and exact ISRC matches retain confidence', () {
    expect(service.normalizeText(' 春の歌 — 歌手 '), '春の歌 歌手');
    expect(
      service.matchIsConfident(
        {'name': '春の歌', 'artists': '歌手'},
        currentTitle: '春の歌',
        currentArtist: '歌手',
        currentAlbum: '',
        currentIsrc: '',
      ),
      isTrue,
    );
    expect(
      service.matchIsConfident(
        {
          'name': 'Other Song',
          'artists': 'Other Artist',
          'isrc': 'USABC1234567',
        },
        currentTitle: 'song',
        currentArtist: 'artist',
        currentAlbum: '',
        currentIsrc: 'USABC1234567',
      ),
      isTrue,
    );
    expect(
      service.matchIsConfident(
        {'name': 'Song', 'artists': 'Another Performer'},
        currentTitle: 'song',
        currentArtist: 'artist',
        currentAlbum: '',
        currentIsrc: '',
      ),
      isFalse,
    );
  });

  test(
    'selected-provider enrichment filters unknown counts but keeps explicit zero',
    () async {
      final result = await service.enrich(
        {
          'title': 'Song',
          'track_number': 0,
          'explicit': 0,
          'images': [
            {'large': 'https://example.invalid/cover.jpg'},
          ],
        },
        currentValues: const {},
        fields: {'title', 'explicit', 'cover'},
        providerId: 'example-provider',
        sourceTrackId: null,
        durationMs: 0,
        syncLyricsSettings: () async {},
        isCurrent: () => true,
      );
      expect(result!.values, {'title': 'Song', 'explicit': '0'});
      expect(result.coverUrl, 'https://example.invalid/cover.jpg');
      expect(result.sourceId, 'example-provider');
    },
  );

  test('cancelled enrichment performs no lyrics work', () async {
    var synced = false;
    final result = await service.enrich(
      null,
      currentValues: const {'title': 'Song', 'artist': 'Artist'},
      fields: {'lyrics'},
      providerId: null,
      sourceTrackId: null,
      durationMs: 0,
      syncLyricsSettings: () async {
        synced = true;
      },
      isCurrent: () => false,
    );
    expect(result, isNull);
    expect(synced, isFalse);
  });

  for (final instrumental in [false, true]) {
    test('lyrics-only enrichment handles instrumental=$instrumental', () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var synced = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getLyricsLRCWithSource');
        expect(synced, isTrue);
        return jsonEncode({
          'lyrics': instrumental ? '[instrumental:true]' : '[00:01.00]Lyric',
          'instrumental': instrumental,
          'source': 'Example Lyrics',
        });
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final result = await service.enrich(
        null,
        currentValues: const {'title': 'Song', 'artist': 'Artist'},
        fields: {'lyrics'},
        providerId: null,
        sourceTrackId: null,
        durationMs: 180000,
        syncLyricsSettings: () async {
          synced = true;
        },
        isCurrent: () => true,
      );
      expect(result!.lyricsSource, 'Example Lyrics');
      expect(result.values.containsKey('lyrics'), !instrumental);
    });
  }
}
