import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/playback_normalization.dart';

void main() {
  test('updated gain replaces the cached volume for the same URI', () async {
    var gain = '-4.00 dB';
    final cache = PlaybackNormalizationCache(
      readMetadata: (_, {displayName}) async => {'replaygain_track_gain': gain},
    );
    const source = 'content://music/song';
    expect(await cache.volumeFor(source), closeTo(0.630957, 0.000001));
    gain = '-12.20 dB';
    cache.invalidate(source);
    expect(await cache.volumeFor(source), closeTo(0.245471, 0.000001));
  });

  test(
    'a read started before an edit cannot restore stale cache data',
    () async {
      final staleRead = Completer<Map<String, dynamic>>();
      var reads = 0;
      final cache = PlaybackNormalizationCache(
        readMetadata: (_, {displayName}) async {
          if (++reads == 1) return staleRead.future;
          return {'replaygain_track_gain': '-12.20 dB'};
        },
      );
      final pending = cache.volumeFor('song');
      cache.invalidate('song');
      await cache.volumeFor('song');
      staleRead.complete({'replaygain_track_gain': '-4.00 dB'});
      await pending;
      expect(await cache.volumeFor('song'), closeTo(0.245471, 0.000001));
      expect(reads, 2);
    },
  );

  test(
    'descriptor normalization uses hint and caches by original URI',
    () async {
      var reads = 0;
      final cache = PlaybackNormalizationCache(
        readMetadata: (path, {displayName}) async {
          reads++;
          expect(path, '/proc/self/fd/42');
          expect(displayName, 'Song.flac');
          return {
            'replaygain_track_gain': '-6.00 dB',
            'replaygain_album_gain': '-3.00 dB',
          };
        },
      );
      expect(
        await cache.volumeFor(
          '/proc/self/fd/42',
          displayName: 'Song.flac',
          cacheKey: 'content://music/song',
        ),
        closeTo(0.501187, 0.000001),
      );
      expect(
        await cache.volumeFor(
          '/proc/self/fd/99',
          displayName: 'Song.flac',
          cacheKey: 'content://music/song',
        ),
        closeTo(0.501187, 0.000001),
      );
      expect(reads, 1);
    },
  );

  test(
    'failed descriptor metadata does not poison local fallback cache',
    () async {
      var reads = 0;
      final cache = PlaybackNormalizationCache(
        readMetadata: (path, {displayName}) async {
          reads++;
          if (path.startsWith('/proc/')) {
            return {'error': 'descriptor access denied'};
          }
          return {'replaygain_album_gain': '-6.00 dB'};
        },
      );
      expect(
        await cache.volumeFor(
          '/proc/self/fd/42',
          displayName: 'Song.mp3',
          cacheKey: 'song',
        ),
        1.0,
      );
      expect(
        await cache.volumeFor('/cache/Song.mp3', cacheKey: 'song'),
        closeTo(0.501187, 0.000001),
      );
      expect(reads, 2);
    },
  );

  test('exceptions are retried and positive gain only attenuates', () async {
    var reads = 0;
    final cache = PlaybackNormalizationCache(
      readMetadata: (path, {displayName}) async {
        if (++reads == 1) throw StateError('temporarily unavailable');
        return {'replaygain_track_gain': '+6.00 dB'};
      },
    );
    expect(await cache.volumeFor('song'), 1.0);
    expect(await cache.volumeFor('song'), 1.0);
    expect(reads, 2);
  });

  test('pre-amp and gain mode reuse one tag read', () async {
    var reads = 0;
    final cache = PlaybackNormalizationCache(
      readMetadata: (_, {displayName}) async {
        reads++;
        return {
          'replaygain_track_gain': '-4.00 dB',
          'replaygain_album_gain': '-2.00 dB',
        };
      },
    );
    // -7 dB pre-amp targets -25 LUFS: -4 - 7 = -11 dB.
    expect(
      await cache.volumeFor('song', preampDb: -7),
      closeTo(0.281838, 0.000001),
    );
    expect(
      await cache.volumeFor('song', preferAlbumGain: true),
      closeTo(0.794328, 0.000001),
    );
    // A positive pre-amp still cannot raise a track above its source level.
    expect(await cache.volumeFor('song', preampDb: 6), 1.0);
    expect(reads, 1);
  });

  test('each gain mode falls back to the other tag', () async {
    final trackOnly = PlaybackNormalizationCache(
      readMetadata: (_, {displayName}) async => {
        'replaygain_track_gain': '-6.00 dB',
      },
    );
    final albumOnly = PlaybackNormalizationCache(
      readMetadata: (_, {displayName}) async => {
        'replaygain_album_gain': '-6.00 dB',
      },
    );
    expect(
      await trackOnly.volumeFor('song', preferAlbumGain: true),
      closeTo(0.501187, 0.000001),
    );
    expect(await albumOnly.volumeFor('song'), closeTo(0.501187, 0.000001));
  });

  test('turning quiet songs up raises them, up to +12 dB', () async {
    final cache = PlaybackNormalizationCache(
      readMetadata: (path, {displayName}) async => {
        'replaygain_track_gain': path == 'quiet' ? '+4.00 dB' : '+9.00 dB',
      },
    );
    expect(await cache.volumeFor('quiet'), 1.0);
    expect(
      await cache.volumeFor('quiet', boost: true),
      closeTo(1.584893, 0.000001),
    );
    // The -5 to -4 pre-amp step no longer reaches a wall at 0 dB.
    expect(
      await cache.volumeFor('quiet', preampDb: -5, boost: true),
      closeTo(0.891251, 0.000001),
    );
    expect(await cache.volumeFor('quiet', preampDb: -4, boost: true), 1.0);
    expect(
      await cache.volumeFor('quiet', preampDb: -3, boost: true),
      closeTo(1.122018, 0.000001),
    );
    expect(
      await cache.volumeFor('very quiet', preampDb: 6, boost: true),
      closeTo(PlaybackNormalizationCache.maxBoostVolume, 1e-9),
    );
  });

  test('untagged files ignore the pre-amp', () async {
    final cache = PlaybackNormalizationCache(
      readMetadata: (_, {displayName}) async => {},
    );
    expect(await cache.volumeFor('song', preampDb: -7), 1.0);
  });

  test('stored pre-amp and mode are sanitized', () {
    expect(playbackNormalizationPreampFromJson(-7.4), -7);
    expect(playbackNormalizationPreampFromJson(-40), -15);
    expect(playbackNormalizationPreampFromJson(20), 6);
    expect(playbackNormalizationPreampFromJson('loud'), 0);
    expect(playbackNormalizationModeFromJson('album'), 'album');
    expect(playbackNormalizationModeFromJson('smart'), 'track');
    final restored = AppSettings.fromJson(
      const AppSettings(
        playbackNormalizationPreamp: -7,
        playbackNormalizationMode: 'album',
      ).toJson(),
    );
    expect(restored.playbackNormalizationPreamp, -7);
    expect(restored.playbackNormalizationMode, 'album');
    expect(AppSettings.fromJson(const {}).playbackNormalizationPreamp, 0);
  });
}
