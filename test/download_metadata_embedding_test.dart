import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/download_metadata_embedding.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/utils/artist_utils.dart';

class EmbeddingHarness {
  final events = <String>[];
  final nativeWrites = <Map<String, String>>[];
  final fallbackWrites = <Map<String, String>>[];
  late final DownloadMetadataEmbedding service;

  EmbeddingHarness({
    bool nativeSuccess = true,
    bool gainWriteSuccess = true,
    ReplayGainResult? gain,
    Future<String?> Function(String, int)? loadCover,
    Future<String> Function(Track)? loadLyrics,
  }) {
    service = DownloadMetadataEmbedding(
      onReplayGain: (track, path, result) => events.add('aggregate'),
      loadCover: loadCover,
      loadLyrics:
          loadLyrics ??
          (_) async {
            events.add('lyrics');
            return '[00:01.00]Line';
          },
      editMetadata: (path, metadata) async {
        events.add('native');
        nativeWrites.add(Map.of(metadata));
        return {
          'success': nativeSuccess,
          'method': nativeSuccess ? 'rust' : 'ffmpeg',
        };
      },
      writeWithFFmpeg: (path, format, cover, metadata, artistMode) async {
        events.add('ffmpeg');
        fallbackWrites.add(Map.of(metadata));
        return path;
      },
      scanReplayGain: (_) async {
        events.add('scan');
        return gain;
      },
      scanAndApplyReplayGain: (_) async {
        events.add('scanAndApply');
        return gain;
      },
      writeReplayGain: (_, _, _) async {
        events.add('writeGain');
        return gainWriteSuccess;
      },
    );
  }
}

/// Cover eviction deletes files without awaiting, so poll until [check] holds.
Future<void> _eventually(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met within ${timeout.inMilliseconds} ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _expectDeleted(Iterable<String> paths) => _eventually(() async {
  for (final path in paths) {
    if (await File(path).exists()) return false;
  }
  return true;
});

void main() {
  test(
    'download separators reach native tags and FFmpeg fallback without changing the track',
    () async {
      const track = Track(
        id: 'example',
        name: 'Title, unchanged',
        artistName: 'A, B',
        albumName: 'Album',
        albumArtist: 'C, D',
        duration: 100,
        composer: 'E; F',
        genre: 'Rock, Pop',
      );
      const settings = AppSettings(
        embedLyrics: false,
        metadataSeparators: MetadataSeparators(
          artist: ' / ',
          albumArtist: '; ',
          composer: ' | ',
          genre: '; ',
        ),
      );
      final harness = EmbeddingHarness(nativeSuccess: false);
      await harness.service.embed(
        '/example/song.mp3',
        track,
        settings: settings,
        extensionState: const ExtensionState(),
        format: 'mp3',
      );
      expect(harness.nativeWrites.single['artist'], 'A, B');
      expect(harness.nativeWrites.single['artist_separator'], ' / ');
      expect(harness.fallbackWrites.single['ARTIST'], 'A / B');
      expect(harness.fallbackWrites.single['ALBUMARTIST'], 'C; D');
      expect(harness.fallbackWrites.single['COMPOSER'], 'E | F');
      expect(harness.fallbackWrites.single['GENRE'], 'Rock; Pop');
      expect(harness.fallbackWrites.single['TITLE'], 'Title, unchanged');
      expect(track.artistName, 'A, B');
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  final ac4Writes = <Map<String, String>>[];
  final splitRewrites = <Map<Object?, Object?>>[];
  var handledAc4 = false;
  const track = Track(
    id: 'example:recording',
    source: 'example',
    name: 'Song',
    artistName: 'Artist, Guest',
    albumName: 'Album',
    albumArtist: 'Artist, Guest',
    duration: 180,
    trackNumber: 2,
    totalTracks: 12,
    discNumber: 1,
    totalDiscs: 2,
    releaseDate: '2026-01-02',
    isrc: 'USAAA2400001',
    composer: 'Composer',
    genre: 'Genre',
    label: 'Label',
    copyright: 'Copyright',
    comment: 'Comment',
    explicit: true,
    albumType: 'Compilation',
    upc: '012345678901',
  );
  const gain = ReplayGainResult(
    trackGain: '-5.00 dB',
    trackPeak: '0.900000',
    integratedLufs: -13,
    truePeakLinear: 0.9,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-embedding-');
    ac4Writes.clear();
    splitRewrites.clear();
    handledAc4 = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      switch (call.method) {
        case 'acquireDownloadDirectory':
          return 'test-scope';
        case 'releaseDownloadDirectory':
          return null;
        case 'writeAC4Metadata':
          ac4Writes.add(
            Map<String, String>.from(
              jsonDecode(args['metadata_json'] as String) as Map,
            ),
          );
          return jsonEncode({'handled': handledAc4});
        case 'rewriteSplitArtistTags':
          splitRewrites.add(args);
          return jsonEncode({'success': true});
      }
      fail('Unexpected backend call: ${call.method}');
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  for (final format in ['flac', 'm4a', 'mp3', 'opus']) {
    test(
      '$format embeds enriched artwork at the configured resolution',
      () async {
        final cover = await File(
          '${directory.path}/full-size.png',
        ).writeAsBytes([1, 2, 3]);
        final harness = EmbeddingHarness(
          loadCover: (url, dimension) async {
            expect(url, 'https://example.test/cover/3000.jpg');
            expect(dimension, 0);
            return cover.path;
          },
        );
        await harness.service.embed(
          '${directory.path}/song.$format',
          track.copyWith(coverUrl: 'https://example.test/cover/3000.jpg'),
          settings: const AppSettings(embedLyrics: false),
          extensionState: const ExtensionState(),
          format: format,
        );
        expect(harness.nativeWrites.single['cover_path'], cover.path);
        harness.service.clearCoverCache();
        await _expectDeleted([cover.path]);
      },
    );
  }

  for (final format in ['flac', 'm4a', 'mp3', 'opus']) {
    test(
      '$format native tags retain writer-specific keys and full credits',
      () async {
        final harness = EmbeddingHarness();
        await harness.service.embed(
          '${directory.path}/song.$format',
          track,
          settings: const AppSettings(
            embedLyrics: false,
            artistTagMode: artistTagModeSplitVorbis,
          ),
          extensionState: const ExtensionState(),
          format: format,
          genre: 'Override',
          label: 'Override label',
          copyright: 'Override copyright',
          comment: 'Override comment',
        );
        expect(harness.nativeWrites.single, {
          'title': 'Song',
          'artist': 'Artist, Guest',
          'album': 'Album',
          'album_artist': 'Artist, Guest',
          'date': '2026-01-02',
          'isrc': 'USAAA2400001',
          'composer': 'Composer',
          'genre': 'Override',
          'label': 'Override label',
          'copyright': 'Override copyright',
          'comment': 'Override comment',
          'track_number': '2',
          'track_total': '12',
          'disc_number': '1',
          'disc_total': '2',
          'explicit': '1',
          'album_type': 'Compilation',
          'upc': '012345678901',
          'compilation': '1',
          'artist_tag_mode': artistTagModeSplitVorbis,
          if (format == 'flac' || format == 'm4a') 'lyrics': '',
          if (format == 'flac') 'unsyncedlyrics': '',
        });
        expect(harness.fallbackWrites, isEmpty);
        expect(splitRewrites, isEmpty);
      },
    );

    test(
      '$format fallback preserves totals, legacy tags and lyric clearing',
      () async {
        final harness = EmbeddingHarness(nativeSuccess: false);
        await harness.service.embed(
          '${directory.path}/song.$format',
          track,
          settings: const AppSettings(embedLyrics: false),
          extensionState: const ExtensionState(),
          format: format,
        );
        expect(harness.fallbackWrites.single, {
          'TITLE': 'Song',
          'ARTIST': 'Artist, Guest',
          'ALBUM': 'Album',
          'ALBUMARTIST': 'Artist, Guest',
          'DATE': '2026-01-02',
          'ISRC': 'USAAA2400001',
          'COMPOSER': 'Composer',
          'GENRE': 'Genre',
          'ORGANIZATION': 'Label',
          'COPYRIGHT': 'Copyright',
          'COMMENT': 'Comment',
          'TRACKNUMBER': '2/12',
          'DISCNUMBER': '1/2',
          'ITUNESADVISORY': '1',
          'RELEASETYPE': 'compilation',
          'BARCODE': '012345678901',
          'COMPILATION': '1',
          if (format == 'flac' || format == 'mp3') ...{
            'TRACK': '2/12',
            'DISC': '1/2',
            'YEAR': '2026',
          },
          if (format == 'flac' || format == 'm4a') 'LYRICS': '',
          if (format == 'flac') 'UNSYNCEDLYRICS': '',
        });
        expect(harness.events, ['native', 'ffmpeg']);
      },
    );
  }

  test(
    'AC-4 resolves primary credits and stops after the native MP4 writer',
    () async {
      handledAc4 = true;
      final harness = EmbeddingHarness();
      final result = await harness.service.embed(
        '${directory.path}/song.m4a',
        track,
        settings: const AppSettings(artistTagMode: artistTagModePrimary),
        extensionState: const ExtensionState(),
        format: 'm4a',
        lyricsLrc: '[00:02.00]Prepared line',
      );
      expect(result, '[00:02.00]Prepared line');
      expect(ac4Writes.single, {
        'title': 'Song',
        'artist': 'Artist',
        'album': 'Album',
        'albumArtist': 'Artist',
        'date': '2026-01-02',
        'genre': 'Genre',
        'composer': 'Composer',
        'trackNumber': '2',
        'totalTracks': '12',
        'discNumber': '1',
        'totalDiscs': '2',
        'isrc': 'USAAA2400001',
        'label': 'Label',
        'copyright': 'Copyright',
        'comment': 'Comment',
        'lyrics': result,
      });
      expect(harness.events, isEmpty);
    },
  );

  for (final mode in ['embed', 'external', 'both']) {
    test(
      'lyrics mode $mode reuses a supplied LRC and honors sidecar writes',
      () async {
        final harness = EmbeddingHarness();
        final path = '${directory.path}/song.flac';
        final result = await harness.service.embed(
          path,
          track,
          settings: AppSettings(lyricsMode: mode),
          extensionState: const ExtensionState(),
          format: 'flac',
          lyricsLrc: '[00:01.00]Prepared line',
        );
        expect(result, '[00:01.00]Prepared line');
        expect(harness.events, ['native']);
        expect(
          harness.nativeWrites.single['lyrics'],
          mode == 'external' ? '' : result,
        );
        final sidecar = File('${directory.path}/song.lrc');
        expect(await sidecar.exists(), mode != 'embed');
        if (await sidecar.exists()) {
          expect(await sidecar.readAsString(), result);
        }
      },
    );
  }

  test('SAF caller receives lyrics without writing a local sidecar', () async {
    final harness = EmbeddingHarness();
    final result = await harness.service.embed(
      '${directory.path}/song.flac',
      track,
      settings: const AppSettings(lyricsMode: 'both'),
      extensionState: const ExtensionState(),
      format: 'flac',
      writeExternalLrc: false,
    );
    expect(result, '[00:01.00]Line');
    expect(harness.events, ['lyrics', 'native']);
    expect(await File('${directory.path}/song.lrc').exists(), isFalse);
  });

  test(
    'manifest skipLyrics suppresses both fetching and a supplied LRC',
    () async {
      final harness = EmbeddingHarness();
      final state = ExtensionState(
        extensions: [
          Extension(
            id: 'example-downloader',
            name: 'example-downloader',
            displayName: 'Example Downloader',
            version: '1.0.0',
            description: '',
            enabled: true,
            status: 'ready',
            skipLyrics: true,
          ),
        ],
      );
      final result = await harness.service.embed(
        '${directory.path}/song.flac',
        track,
        settings: const AppSettings(lyricsMode: 'both'),
        extensionState: state,
        format: 'flac',
        downloadService: ' EXAMPLE-DOWNLOADER ',
        lyricsLrc: '[00:01.00]Prepared line',
      );
      expect(result, isNull);
      expect(harness.events, ['native']);
      expect(harness.nativeWrites.single['lyrics'], '');
      expect(await File('${directory.path}/song.lrc').exists(), isFalse);
    },
  );

  test(
    'header-only download lyrics fall back to fetched lyrics before embedding',
    () async {
      for (final format in ['flac', 'm4a', 'mp3', 'opus']) {
        final harness = EmbeddingHarness();
        final result = await harness.service.embed(
          '${directory.path}/song.$format',
          track,
          settings: const AppSettings(lyricsMode: 'embed'),
          extensionState: const ExtensionState(),
          format: format,
          lyricsLrc: '[ar:Artist]\n[ti:Song]\n[00:01.00]',
        );
        expect(harness.events, ['lyrics', 'native']);
        expect(result, '[00:01.00]Line');
        expect(harness.nativeWrites.single['lyrics'], result);
        expect(await File('${directory.path}/song.lrc').exists(), isFalse);
      }
    },
  );

  for (final invalidLyrics in [
    '[instrumental:true]',
    '[ar:Artist]\n[ti:Song]',
  ]) {
    test('non-display lyrics are discarded: $invalidLyrics', () async {
      final harness = EmbeddingHarness(loadLyrics: (_) async => invalidLyrics);
      final result = await harness.service.embed(
        '${directory.path}/song.mp3',
        track,
        settings: const AppSettings(),
        extensionState: const ExtensionState(),
        format: 'mp3',
      );
      expect(result, isNull);
      expect(harness.nativeWrites.single.containsKey('lyrics'), isFalse);
    });
  }

  test(
    'cover download overlaps lyrics and coalesces concurrent album tracks',
    () async {
      final coverStarted = Completer<void>();
      final coverReady = Completer<String?>();
      final lyricsStarted = Completer<void>();
      var downloads = 0;
      final coverFile = File('${directory.path}/cover.jpg');
      await coverFile.writeAsBytes([1, 2, 3]);
      final harness = EmbeddingHarness(
        loadCover: (url, dimension) {
          downloads++;
          expect(url, 'https://example.test/cover');
          if (!coverStarted.isCompleted) coverStarted.complete();
          return coverReady.future;
        },
        loadLyrics: (_) async {
          expect(coverStarted.isCompleted, isTrue);
          if (!lyricsStarted.isCompleted) lyricsStarted.complete();
          return '[00:01.00]Line';
        },
      );
      final withCover = track.copyWith(coverUrl: 'https://example.test/cover');
      final first = harness.service.embed(
        '${directory.path}/first.flac',
        withCover,
        settings: const AppSettings(),
        extensionState: const ExtensionState(),
        format: 'flac',
      );
      final second = harness.service.embed(
        '${directory.path}/second.flac',
        withCover,
        settings: const AppSettings(),
        extensionState: const ExtensionState(),
        format: 'flac',
      );
      await lyricsStarted.future;
      expect(downloads, 1);
      expect(harness.nativeWrites, isEmpty);
      coverReady.complete(coverFile.path);
      expect(await Future.wait([first, second]), [
        '[00:01.00]Line',
        '[00:01.00]Line',
      ]);
      expect(harness.nativeWrites.map((fields) => fields['cover_path']), [
        coverFile.path,
        coverFile.path,
      ]);
      harness.service.clearCoverCache();
      await _expectDeleted([coverFile.path]);
      expect(await coverFile.exists(), isFalse);
    },
  );

  test(
    'mixed playlist artwork survives eviction while lyrics are pending',
    () async {
      final lyricsStarted = Completer<void>();
      final lyricsReady = Completer<String>();
      final paths = <String, String>{};
      final harness = EmbeddingHarness(
        loadCover: (url, _) async {
          final path = '${directory.path}/playlist-cover-${paths.length}.jpg';
          paths[url] = path;
          await File(path).writeAsBytes([1, 2, 3]);
          return path;
        },
        loadLyrics: (_) {
          lyricsStarted.complete();
          return lyricsReady.future;
        },
      );
      final first = harness.service.embed(
        '${directory.path}/slow.flac',
        track.copyWith(coverUrl: 'https://example.test/cover-0'),
        settings: const AppSettings(),
        extensionState: const ExtensionState(),
        format: 'flac',
      );
      await lyricsStarted.future;
      for (var index = 1; index < 12; index++) {
        await harness.service.embed(
          '${directory.path}/song-$index.flac',
          track.copyWith(coverUrl: 'https://example.test/cover-$index'),
          settings: const AppSettings(embedLyrics: false),
          extensionState: const ExtensionState(),
          format: 'flac',
        );
      }
      lyricsReady.complete('[00:01.00]Line');
      await first;
      expect(
        harness.nativeWrites.last['cover_path'],
        paths['https://example.test/cover-0'],
      );
      harness.service.clearCoverCache();
      await _expectDeleted(paths.values);
    },
  );

  test('queue cache cleanup waits for every active cover writer', () async {
    final cover = await File(
      '${directory.path}/shared.jpg',
    ).writeAsBytes([1, 2, 3]);
    final started = Completer<void>();
    final gates = {'first': Completer<void>(), 'second': Completer<void>()};
    var writers = 0;
    var downloads = 0;
    final stillPresent = <bool>[];
    final service = DownloadMetadataEmbedding(
      onReplayGain: (_, _, _) {},
      loadCover: (_, _) async {
        downloads++;
        return cover.path;
      },
      editMetadata: (path, fields) async {
        expect(fields['cover_path'], cover.path);
        if (++writers == 2) started.complete();
        await gates[path]!.future;
        stillPresent.add(await cover.exists());
        return {'success': true, 'method': 'rust'};
      },
    );
    Future<String?> embed(String path) => service.embed(
      path,
      track.copyWith(coverUrl: 'https://example.test/shared.jpg'),
      settings: const AppSettings(embedLyrics: false),
      extensionState: const ExtensionState(),
      format: 'flac',
    );
    final first = embed('first');
    final second = embed('second');
    await started.future;
    service.clearCoverCache();
    gates['first']!.complete();
    await first;
    expect(await cover.exists(), isTrue);
    gates['second']!.complete();
    await second;
    expect(downloads, 1);
    expect(stillPresent, [true, true]);
    await _expectDeleted([cover.path]);
  });

  test(
    'failed covers retry and cache dimensions select separate artwork',
    () async {
      final requests = <int>[];
      final harness = EmbeddingHarness(
        loadCover: (_, dimension) async {
          requests.add(dimension);
          if (requests.length == 1) throw StateError('cover unavailable');
          if (requests.length == 2) return null;
          final path = '${directory.path}/cover-$dimension.jpg';
          await File(path).writeAsBytes([1]);
          return path;
        },
      );
      for (final dimension in [100, 100, 100, 100, 200]) {
        await harness.service.embed(
          '${directory.path}/song.flac',
          track.copyWith(coverUrl: 'https://example.test/cover'),
          settings: AppSettings(
            embedLyrics: false,
            embeddedCoverMaxDimension: dimension,
          ),
          extensionState: const ExtensionState(),
          format: 'flac',
        );
      }
      expect(requests, [100, 100, 100, 200]);
      expect(harness.nativeWrites.first.containsKey('cover_path'), isFalse);
      expect(
        harness.nativeWrites.last['cover_path'],
        '${directory.path}/cover-200.jpg',
      );
      harness.service.clearCoverCache();
      await _expectDeleted([
        '${directory.path}/cover-100.jpg',
        '${directory.path}/cover-200.jpg',
      ]);
    },
  );

  test(
    'cover LRU touch keeps reused release and deletes the least recent file',
    () async {
      final paths = <String, String>{};
      final harness = EmbeddingHarness(
        loadCover: (url, _) async {
          final path = '${directory.path}/cover-${paths.length}.jpg';
          await File(path).writeAsBytes([1]);
          paths[url] = path;
          return path;
        },
      );
      for (final id in [0, 1, 2, 3, 4, 5, 6, 7, 0, 8]) {
        await harness.service.embed(
          '${directory.path}/song.flac',
          track.copyWith(coverUrl: 'https://example.test/cover-$id'),
          settings: const AppSettings(embedLyrics: false),
          extensionState: const ExtensionState(),
          format: 'flac',
        );
      }
      expect(paths.length, 9);
      await _expectDeleted([paths['https://example.test/cover-1']!]);
      expect(
        await File(paths['https://example.test/cover-0']!).exists(),
        isTrue,
      );
      expect(
        await File(paths['https://example.test/cover-1']!).exists(),
        isFalse,
      );
      harness.service.clearCoverCache();
      await _expectDeleted(paths.values);
      for (final path in paths.values) {
        expect(await File(path).exists(), isFalse);
      }
    },
  );

  test(
    'synchronously failed artwork is contained while lyrics are pending',
    () async {
      var requests = 0;
      final lyrics = Completer<String>();
      final startedLyrics = Completer<void>();
      final harness = EmbeddingHarness(
        loadCover: (_, _) {
          requests++;
          throw StateError('cover unavailable');
        },
        loadLyrics: (_) {
          if (!startedLyrics.isCompleted) startedLyrics.complete();
          return lyrics.future;
        },
      );
      final selected = track.copyWith(
        coverUrl: 'https://example.test/failed-cover',
      );
      final first = harness.service.embed(
        '${directory.path}/first.flac',
        selected,
        settings: const AppSettings(),
        extensionState: const ExtensionState(),
        format: 'flac',
      );
      await startedLyrics.future;
      await Future<void>.delayed(Duration.zero);
      expect(harness.nativeWrites, isEmpty);
      lyrics.complete('[00:01.00]Line');
      expect(await first, '[00:01.00]Line');
      await harness.service.embed(
        '${directory.path}/second.flac',
        selected,
        settings: const AppSettings(),
        extensionState: const ExtensionState(),
        format: 'flac',
      );
      expect(requests, 2);
      expect(
        harness.nativeWrites.every(
          (fields) => !fields.containsKey('cover_path'),
        ),
        isTrue,
      );
    },
  );

  for (final format in ['flac', 'm4a', 'mp3', 'opus']) {
    test('$format gain aggregation preserves writer ordering', () async {
      final harness = EmbeddingHarness(gain: gain);
      await harness.service.embed(
        '${directory.path}/song.$format',
        track,
        settings: const AppSettings(embedLyrics: false, embedReplayGain: true),
        extensionState: const ExtensionState(),
        format: format,
      );
      expect(harness.events, switch (format) {
        'flac' => ['native', 'scanAndApply', 'aggregate'],
        'm4a' => ['scan', 'aggregate', 'ffmpeg', 'native'],
        'mp3' => ['scan', 'aggregate', 'ffmpeg'],
        _ => ['scan', 'native', 'writeGain', 'aggregate'],
      });
      if (format == 'm4a' || format == 'mp3') {
        expect(
          harness.fallbackWrites.single['REPLAYGAIN_TRACK_GAIN'],
          gain.trackGain,
        );
      }
      if (format == 'opus') {
        expect(
          harness.nativeWrites.single.containsKey('replaygain_track_gain'),
          isFalse,
        );
      }
    });
  }

  test('failed Opus R128 save does not aggregate unpersisted gain', () async {
    final harness = EmbeddingHarness(gain: gain, gainWriteSuccess: false);
    await harness.service.embed(
      '${directory.path}/song.opus',
      track,
      settings: const AppSettings(embedLyrics: false, embedReplayGain: true),
      extensionState: const ExtensionState(),
      format: 'opus',
    );
    expect(harness.events, ['scan', 'native', 'writeGain']);
  });

  test(
    'metadata disabled still writes and aggregates enabled ReplayGain',
    () async {
      final harness = EmbeddingHarness(gain: gain);
      final result = await harness.service.embed(
        '${directory.path}/song.flac',
        track,
        settings: const AppSettings(
          embedMetadata: false,
          embedReplayGain: true,
        ),
        extensionState: const ExtensionState(),
        format: 'flac',
      );
      expect(result, isNull);
      expect(harness.events, ['scanAndApply', 'aggregate']);
    },
  );
}
