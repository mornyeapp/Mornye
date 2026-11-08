import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const album = (album: 'An Album', artist: 'An Artist');
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('motion-test-'),
  );
  tearDown(() async => root.delete(recursive: true));

  Future<File> seedLegacyVideo() async {
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (_) async => true,
      download: (_, output) async {
        await File(output).writeAsBytes([1]);
        return 0.75;
      },
    );
    final saved = await store.save(
      album,
      resolveSource: () async => 'https://example.com/cover.m3u8',
    );
    final file = File.fromUri(Uri.parse(saved!.source));
    final info = root.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.json'),
    );
    await info.writeAsString('{"aspectRatio":0.75}');
    return file;
  }

  test('an alias shows one saved video under another artist', () async {
    var downloads = 0;
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (_) async => true,
      download: (_, output) async {
        downloads++;
        await File(output).writeAsBytes([1]);
        return 1;
      },
    );
    const guest = (album: 'An Album', artist: 'An Artist feat. A Guest');
    final saved = await store.save(
      album,
      resolveSource: () async => 'https://example.com/cover.mp4',
    );
    expect(await store.find(guest), isNull);

    await store.alias(guest, album);
    expect((await store.find(guest))?.source, saved!.source);
    // Saving under the alias reuses the video instead of fetching it again.
    expect(
      (await store.save(
        guest,
        resolveSource: () async => 'https://example.com/cover.mp4',
      ))?.source,
      saved.source,
    );
    expect(downloads, 1);

    await store.remove(guest);
    expect(await store.find(guest), isNull);
    expect(await store.find(album), isNotNull);
    await store.remove(album);
    expect(await store.find(album), isNull);
    expect(root.listSync(), isEmpty);
  });

  test('successful transfers with broken video data are not cached', () async {
    final store = MotionArtworkStore(
      directory: () async => root,
      download: (_, output) async {
        await File(output).writeAsBytes([1]);
        return 0.75;
      },
      validate: (_) async => false,
    );
    expect(
      await store.save(
        album,
        resolveSource: () async => 'https://example.com/cover.m3u8',
      ),
      isNull,
    );
    expect(root.listSync(), isEmpty);
  });

  test('corrupt legacy video is replaced only after a valid repair', () async {
    final legacy = await seedLegacyVideo();
    var failDownload = true;
    var validations = 0;
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (path) async {
        validations++;
        return (await File(path).readAsBytes()).single == 2;
      },
      download: (_, output) async {
        if (failDownload) throw const SocketException('offline');
        await File(output).writeAsBytes([2]);
        return 0.75;
      },
    );
    expect(await store.find(album), isNull);
    expect(await store.find(album), isNull);
    expect(validations, 1);
    Future<String?> resolve() async => 'https://example.com/cover.m3u8';
    expect(await store.save(album, resolveSource: resolve), isNull);
    expect(await legacy.readAsBytes(), [1]);
    failDownload = false;
    final repaired = await store.save(album, resolveSource: resolve);
    expect(repaired?.source, legacy.uri.toString());
    expect(await legacy.readAsBytes(), [2]);
    expect((await store.find(album))?.source, repaired?.source);
    expect(validations, 2);
    expect(
      root.listSync().where((file) => file.path.contains('partial')),
      isEmpty,
    );
  });

  test(
    'healthy legacy video stays available offline after validation',
    () async {
      final legacy = await seedLegacyVideo();
      var validations = 0;
      final store = MotionArtworkStore(
        directory: () async => root,
        validate: (_) async {
          validations++;
          return true;
        },
        download: (_, _) async => throw StateError('offline'),
      );
      final results = await Future.wait([store.find(album), store.find(album)]);
      expect(
        results.map((art) => art?.source),
        everyElement(legacy.uri.toString()),
      );
      expect(validations, 1);
    },
  );

  test('a failed legacy check does not prevent clearing artwork', () async {
    await seedLegacyVideo();
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (_) async => throw StateError('decoder unavailable'),
    );
    expect(await store.find(album), isNull);
    await store.clear();
    expect(await root.exists(), isFalse);
    await root.create();
  });

  for (final hasLegacyCopy in [true, false]) {
    test(
      'player never searches or downloads missing artwork (legacy=$hasLegacyCopy)',
      () async {
        final legacy = hasLegacyCopy ? await seedLegacyVideo() : null;
        final store = MotionArtworkStore(
          directory: () async => root,
          validate: (path) async =>
              (await File(path).readAsBytes()).single == 2,
          download: (_, _) async => throw StateError('must not download'),
        );
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          fail('Playback must not call an extension: ${call.method}');
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final container = ProviderContainer(
          overrides: [motionArtworkStoreProvider.overrideWithValue(store)],
        );
        addTearDown(container.dispose);
        final initial = await container.read(
          playerMotionArtworkProvider(album).future,
        );
        expect(initial, isNull);
        expect(container.read(extensionProvider.exists), isFalse);
        // Playback reads the motion-artwork preference without loading an
        // extension or fetching any artwork.
        expect(container.read(settingsProvider.exists), isTrue);
        if (legacy != null) {
          expect(await legacy.readAsBytes(), [1]);
        } else {
          expect(await store.find(album), isNull);
        }
      },
    );
  }

  test(
    'saved video survives restart and app directory relocation offline',
    () async {
      var downloads = 0;
      var location = Directory('${root.path}/old-container');
      final store = MotionArtworkStore(
        directory: () async => location,
        validate: (_) async => true,
        download: (_, output) async {
          downloads++;
          await File(output).writeAsBytes([1, 2, 3, 4]);
          return 0.75;
        },
      );
      final saved = await store.save(
        album,
        resolveSource: () async => 'https://example.com/cover.m3u8',
      );
      expect(saved?.aspectRatio, 0.75);
      expect(await File.fromUri(Uri.parse(saved!.source)).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      location = await location.rename('${root.path}/new-container');
      final restarted = MotionArtworkStore(
        directory: () async => location,
        validate: (_) async => throw StateError('already validated'),
        download: (_, _) async => throw StateError('offline'),
      );
      final cached = await restarted.save((
        album: '  AN   ALBUM ',
        artist: 'AN ARTIST',
      ), resolveSource: () async => throw StateError('offline'));
      expect(cached?.source, contains('new-container'));
      expect(cached?.aspectRatio, 0.75);
      expect(downloads, 1);
      final container = ProviderContainer(
        overrides: [motionArtworkStoreProvider.overrideWithValue(restarted)],
      );
      addTearDown(container.dispose);
      final playback = await container.read(
        playerMotionArtworkProvider(album).future,
      );
      expect(playback?.source, cached?.source);
      expect(container.read(extensionProvider.exists), isFalse);
    },
  );

  test('concurrent tracks in one album download one complete video', () async {
    final gate = Completer<void>();
    var downloads = 0;
    var lookups = 0;
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (_) async => true,
      download: (_, output) async {
        downloads++;
        await gate.future;
        await File(output).writeAsBytes([1]);
        return 0.75;
      },
    );
    Future<String?> resolve() async {
      lookups++;
      return 'https://example.com/video.mp4';
    }

    final first = store.save(album, resolveSource: resolve);
    final second = store.save(album, resolveSource: resolve);
    gate.complete();
    final saved = await Future.wait([first, second]);
    expect(saved.first?.source, saved.last?.source);
    expect(downloads, 1);
    expect(lookups, 1);
    expect(
      root.listSync().whereType<File>().where((f) => f.path.endsWith('.mp4')),
      hasLength(1),
    );
  });

  test(
    'failed optional transfers leave no partial file and can retry',
    () async {
      var fail = true;
      final store = MotionArtworkStore(
        directory: () async => root,
        validate: (_) async => true,
        download: (_, output) async {
          await File(output).writeAsBytes([1]);
          if (fail) throw const SocketException('offline');
          return 1.0;
        },
      );
      Future<String?> resolve() async => 'https://example.com/video.mp4';
      expect(await store.save(album, resolveSource: resolve), isNull);
      expect(root.listSync(), isEmpty);
      expect(await store.find(album), isNull);
      fail = false;
      expect(await store.save(album, resolveSource: resolve), isNotNull);
    },
  );

  test(
    'only remote artwork is downloaded and unknown albums keep static art',
    () async {
      final store = MotionArtworkStore(
        directory: () async => root,
        download: (_, _) async => throw StateError('must not download'),
      );
      expect(
        await store.save(
          album,
          resolveSource: () async => 'file:///private/video.mp4',
        ),
        isNull,
      );
      expect(
        await store.save((
          album: '',
          artist: '',
        ), resolveSource: () async => throw StateError('no album')),
        isNull,
      );
      expect(root.listSync(), isEmpty);
    },
  );

  test(
    'clearing saved motion waits for writes and keeps the music file',
    () async {
      final music = File('${root.path}/song.flac');
      await music.writeAsBytes([9, 8, 7]);
      final gate = Completer<void>();
      final started = Completer<void>();
      final store = MotionArtworkStore(
        directory: () async => Directory('${root.path}/motion'),
        validate: (_) async => true,
        download: (_, output) async {
          started.complete();
          await gate.future;
          await File(output).writeAsBytes([1]);
          return 0.75;
        },
      );
      final save = store.save(
        album,
        resolveSource: () async => 'https://example.com/cover.mp4',
      );
      await started.future;
      final clear = store.clear();
      expect(
        await store.save(
          album,
          resolveSource: () async => throw StateError('clearing'),
        ),
        isNull,
      );
      gate.complete();
      await save;
      await clear;
      expect(await store.find(album), isNull);
      expect(await music.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'download queue track serialization retains extension motion artwork',
    () {
      final track = Track.fromBackendMap({
        'id': 'track',
        'name': 'Track',
        'artists': 'Artist',
        'album_name': 'Album',
        'header_video': 'https://example.com/cover.m3u8',
      }, source: 'example-provider');
      final restored = Track.fromJson(track.copyWith(name: 'Updated').toJson());
      expect(restored.headerVideoUrl, 'https://example.com/cover.m3u8');
      expect(restored.source, 'example-provider');
    },
  );
}
