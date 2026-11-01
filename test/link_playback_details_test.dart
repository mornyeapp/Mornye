import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_playback_details.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_player_service.dart'
    show MusicPlayerHandler;

import 'support/link_desktop_fakes.dart';
import 'support/link_fakes.dart';

class _SnapshotHandler extends BaseAudioHandler implements MusicPlayerHandler {
  @override
  Future<void> stop({bool keepResume = false}) => super.stop();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected handler call: ${invocation.memberName}',
  );
}

class _SnapshotRuntime extends MusicPlayerRuntime {
  _SnapshotRuntime(this.player);
  final MusicPlayerHandler player;
  @override
  MusicPlayerHandler get handler => player;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CoverStore covers;
  late FakeLinkClient phone2;
  final thumbnail = Uint8List.fromList([
    0xff,
    0xd8,
    0xff,
    ...List.filled(24, 1),
  ]);
  const track = TrackRef(
    title: 'Phone one song',
    artist: 'Artist',
    durationMs: 200000,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-playback-details-test-');
    covers = CoverStore(
      directory: () async => Directory('${root.path}/covers'),
      fetch: (_, _) async =>
          fail('The cover must arrive through the paired channel'),
    );
    phone2 = FakeLinkClient();
  });
  tearDown(() async {
    await phone2.close();
    await covers.dispose();
    await root.delete(recursive: true);
  });

  test(
    'phone 1 upload playing on PC reaches phone 2 without a catalog entry',
    () async {
      final cover = File('${root.path}/private-cover.jpg');
      await cover.writeAsBytes(thumbnail);
      final privateAudio = '${root.path}/received/private-upload.flac';
      final item = LinkPlayerItem.fromMediaItem(
        MediaItem(
          id: 'uploaded-song',
          title: track.title,
          artist: track.artist,
          duration: const Duration(milliseconds: 200000),
          artUri: Uri.file(cover.path),
          extras: {
            'source': privateAudio,
            'bit_depth': 24,
            'sample_rate': 96000,
            'format': 'flac',
          },
        ),
      );
      final player = FakeLinkPlayer()
        ..current = LinkPlayerSnapshot(
          queue: [item],
          index: 0,
          playing: true,
          updatedMs: 1000,
        );
      final index = DesktopLinkCatalogIndex.empty('desktop');
      final router = LinkHostRouter();
      LinkDesktopOps(
        player: player,
        downloads: FakeLinkDownloads(),
        downloadItems: () => [],
        openUrl: (_) async {},
        index: () => index,
        desktopName: () => 'PC',
        playbackDetails: LinkPlaybackDetails(
          readMetadata: (source) async {
            expect(source, privateAudio);
            return {
              'album': 'Phone album',
              'bit_depth': 24,
              'sample_rate': 96000,
              'bitrate': 2400,
              'format': 'flac',
              'genre': 'Rock',
              'album_artist': 'Album artist',
              'track_number': 13,
              'lyrics': '[00:00.00]From phone one',
              'path': privateAudio,
            };
          },
          shrink: (bytes) async => bytes,
        ),
      ).register(router);
      final state = LinkPlayerState.fromJson(
        await router.dispatch(
          LinkRequest(
            requestId: 'state',
            op: LinkOps.state,
            deviceId: 'phone-2',
            args: {},
          ),
        ),
      )!;
      expect(state.track!.songId, isNull);
      expect(index.length, 0);
      Map<Object?, Object?>? received;
      phone2.onPost = (op, body) async {
        final reply = await router.dispatch(
          LinkRequest(
            requestId: 'details',
            op: op,
            deviceId: 'phone-2',
            args: body,
          ),
        );
        received = reply as Map;
        return reply;
      };
      final media = (await readLinkPlaybackDetails(
        client: phone2,
        track: state.track!,
        covers: covers,
      ))!;
      expect(media.album, 'Phone album');
      expect(media.bitDepth, 24);
      expect(media.sampleRate, 96000);
      expect(media.bitrate, 2400);
      expect(media.format, 'flac');
      expect(media.genre, 'Rock');
      final controller = PlayerMetadataController(
        readMetadata: (_) async =>
            fail('A display-only track has no local file'),
      );
      addTearDown(controller.dispose);
      await controller.load(media.toMediaItem(covers: covers));
      expect(controller.metadata!['album_artist'], 'Album artist');
      expect(controller.metadata!['track_number'], 13);
      expect(controller.lyrics.isEmpty, isFalse);
      expect(controller.metadata!['sample_rate'], 96000);
      expect(controller.metadata!.containsKey('path'), isFalse);
      expect(controller.canSearchOnline, isFalse);
      await controller.load(null);
      expect(controller.metadata, isNull);
      expect(media.duration, const Duration(milliseconds: 200000));
      final file = File(Uri.parse(media.artUri!).toFilePath());
      expect(file.path, startsWith('${root.path}/covers/'));
      expect(await file.readAsBytes(), thumbnail);
      expect(jsonEncode(received), isNot(contains(root.path)));
      expect(received!.containsKey('path'), isFalse);
      expect(media.toMediaItem(covers: covers).extras!['sample_rate'], 96000);
      expect(player.calls, isEmpty);
    },
  );

  test(
    'requests outside the PC queue cannot name or probe arbitrary files',
    () async {
      var probes = 0;
      final router = LinkHostRouter();
      LinkDesktopOps(
        player: FakeLinkPlayer(),
        downloads: FakeLinkDownloads(),
        downloadItems: () => [],
        openUrl: (_) async {},
        index: () => DesktopLinkCatalogIndex.empty('desktop'),
        desktopName: () => 'PC',
        playbackDetails: LinkPlaybackDetails(
          readMetadata: (_) async {
            probes++;
            return {};
          },
        ),
      ).register(router);
      await expectLater(
        router.dispatch(
          LinkRequest(
            requestId: 'bad',
            op: LinkOps.playbackDetails,
            deviceId: 'phone-2',
            args: {'track': track.toJson(), 'path': '/private/secret'},
          ),
        ),
        throwsA(isA<LinkException>()),
      );
      expect(probes, 0);
    },
  );

  test('local identity and artwork survive remote enrichment', () async {
    final cover = File('${root.path}/local.jpg');
    await cover.writeAsBytes(thumbnail);
    final local = PlayableMedia(
      id: 'local',
      source: '/music/song.flac',
      title: track.title,
      artist: track.artist,
      album: 'Local album',
      artUri: Uri.file(cover.path).toString(),
      bitDepth: 16,
      sampleRate: 44100,
    );
    phone2.onPost = (_, _) => {
      'album': 'Remote album',
      'bit_depth': 24,
      'sample_rate': 96000,
      'format': 'flac',
      'cover': base64Encode(thumbnail),
    };
    final media = (await readLinkPlaybackDetails(
      client: phone2,
      track: track,
      covers: covers,
      local: local,
    ))!;
    expect(media.id, local.id);
    expect(media.source, local.source);
    expect(media.artUri, local.artUri);
    expect(media.album, local.album);
    expect(media.sampleRate, 44100);
    expect(media.format, 'flac');
  });

  test('old hosts retain the existing fallback', () async {
    phone2.onPost = (_, _) =>
        const LinkException('not_found', 'Unknown operation');
    const local = PlayableMedia(
      id: 'local',
      source: '/song.flac',
      title: 'Song',
      artist: 'Artist',
    );
    expect(
      await readLinkPlaybackDetails(
        client: phone2,
        track: track,
        covers: covers,
        local: local,
      ),
      same(local),
    );
  });

  test('Windows received paths are used for the host probe only', () async {
    const source = r'C:\received\song.flac';
    final details = LinkPlaybackDetails(
      readMetadata: (path) async {
        expect(path, source);
        return {'format': 'flac', 'sample_rate': 44100, 'path': path};
      },
      artwork: (_) async => null,
    );
    final reply = await details.read(
      const LinkPlayerItem(
        id: 'received',
        path: 'network://phone-one/song.flac',
        metadataSource: source,
        title: 'Song',
        artist: 'Artist',
      ),
    );
    expect(reply['sample_rate'], 44100);
    expect(jsonEncode(reply), isNot(contains('received')));
  });

  test(
    'runtime snapshots keep current cover and tags while reusing position ticks',
    () async {
      final handler = _SnapshotHandler();
      addTearDown(() async {
        await handler.queue.close();
        await handler.mediaItem.close();
        await handler.playbackState.close();
      });
      const basic = MediaItem(
        id: 'song',
        title: 'Song',
        extras: {'source': '/song.flac'},
      );
      final rich = basic.copyWith(
        artUri: Uri.file('/cover.jpg'),
        extras: {
          'source': '/song.flac',
          'resolvedSource': '/received/song.flac',
          'format': 'flac',
          'sample_rate': 96000,
        },
      );
      handler.queue.add([basic]);
      handler.mediaItem.add(rich);
      handler.playbackState.add(PlaybackState(queueIndex: 0));
      final port = RuntimeLinkPlayerPort(_SnapshotRuntime(handler));
      final snapshot = port.snapshot();
      expect(snapshot.current!.artwork, rich.artUri.toString());
      expect(snapshot.current!.metadataSource, '/received/song.flac');
      expect(snapshot.current!.audioMetadata['sample_rate'], 96000);
      handler.playbackState.add(
        PlaybackState(
          queueIndex: 0,
          updatePosition: const Duration(seconds: 3),
        ),
      );
      expect(port.snapshot().queue, same(snapshot.queue));
      handler.queue.add([]);
      expect(port.snapshot().current!.title, 'Song');
    },
  );

  test('album thumbnails are encoded once across queue entries', () async {
    final cover = File('${root.path}/album.jpg');
    await cover.writeAsBytes(thumbnail);
    var shrinks = 0;
    final details = LinkPlaybackDetails(
      readMetadata: (_) async => {},
      shrink: (bytes) async {
        shrinks++;
        return bytes;
      },
    );
    for (var song = 0; song < 3; song++) {
      await details.read(
        LinkPlayerItem(
          id: '$song',
          path: '/song$song.flac',
          title: 'Song',
          artist: 'Artist',
          artwork: Uri.file(cover.path).toString(),
        ),
      );
    }
    expect(shrinks, 1);
  });

  test(
    'an old local probe cannot overwrite display-only remote metadata',
    () async {
      final started = Completer<void>();
      final old = Completer<Map<String, dynamic>>();
      final controller = PlayerMetadataController(
        readMetadata: (_) {
          started.complete();
          return old.future;
        },
      );
      addTearDown(controller.dispose);
      final loading = controller.load(
        const MediaItem(
          id: 'old',
          title: 'Old',
          extras: {'source': '/old.flac'},
        ),
      );
      await started.future;
      await controller.load(
        const MediaItem(
          id: 'remote',
          title: 'Remote',
          extras: {
            'source': '',
            'displayMetadata': {
              'sample_rate': 96000,
              'genre': 'Rock',
              'path': '/private',
            },
          },
        ),
      );
      old.complete({'sample_rate': 44100, 'genre': 'Old'});
      await loading;
      expect(controller.metadata!['sample_rate'], 96000);
      expect(controller.metadata!['genre'], 'Rock');
      expect(controller.metadata!.containsKey('path'), isFalse);
    },
  );

  test(
    'invalid or oversized artwork does not discard quality metadata',
    () async {
      for (final cover in ['invalid base64', 'a' * (400 * 1024)]) {
        phone2.onPost = (_, _) => {
          'format': 'flac',
          'sample_rate': 44100,
          'cover': cover,
        };
        final media = (await readLinkPlaybackDetails(
          client: phone2,
          track: track,
          covers: covers,
        ))!;
        expect(media.artUri, isNull);
        expect(media.sampleRate, 44100);
        expect(media.format, 'flac');
      }
    },
  );
}
