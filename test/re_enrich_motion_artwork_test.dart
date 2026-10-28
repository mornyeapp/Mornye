import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';

void main() {
  test(
    're-enriched video is stored once per album outside the music file',
    () async {
      final root = await Directory.systemTemp.createTemp('reenrich-motion-');
      addTearDown(() => root.delete(recursive: true));
      var downloads = 0;
      final store = MotionArtworkStore(
        directory: () async => root,
        validate: (_) async => true,
        download: (source, output) async {
          expect(source, 'https://example.invalid/motion.m3u8');
          downloads++;
          await File(output).writeAsBytes([1, 2, 3]);
          return 0.75;
        },
      );
      const resolvedAlbum = (album: 'Resolved Album', artist: 'Artist');
      final container = ProviderContainer(
        overrides: [
          motionArtworkStoreProvider.overrideWithValue(store),
          playerMotionArtworkProvider(resolvedAlbum).overrideWith(
            (ref) => ref.watch(motionArtworkStoreProvider).find(resolvedAlbum),
          ),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen(
        playerMotionArtworkProvider(resolvedAlbum),
        (_, _) {},
      );
      addTearDown(listener.close);
      expect(
        await container.read(playerMotionArtworkProvider(resolvedAlbum).future),
        isNull,
      );
      for (var index = 0; index < 2; index++) {
        await saveReEnrichedMotionArtwork(
          container,
          metadata: {
            'header_video': 'https://example.invalid/motion.m3u8',
            'album_name': 'Resolved Album',
          },
          albumName: 'Original Album',
          artistName: 'Artist',
        );
      }
      expect(downloads, 1);
      expect(
        await container.read(playerMotionArtworkProvider(resolvedAlbum).future),
        isNotNull,
      );
      expect(
        await store.find((album: 'Original Album', artist: 'Artist')),
        isNull,
      );
      final artwork = await store.find((
        album: 'Resolved Album',
        artist: 'Artist',
      ));
      expect(artwork!.source, startsWith('file:'));
      expect(artwork.aspectRatio, 0.75);
    },
  );

  test('absent and invalid video URLs do not open app storage', () async {
    var opened = false;
    final store = MotionArtworkStore(
      directory: () async {
        opened = true;
        throw StateError('must not open storage');
      },
    );
    final container = ProviderContainer(
      overrides: [motionArtworkStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    for (final url in [null, '', 'file:///tmp/video.mp4']) {
      await saveReEnrichedMotionArtwork(
        container,
        metadata: {'header_video': url},
        albumName: 'Album',
        artistName: 'Artist',
      );
    }
    expect(opened, isFalse);
  });
}
