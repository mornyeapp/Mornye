import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'performance_probe.dart';

const _lyrics = '[00:00.00]Pipeline opening\n[00:01.00]Pipeline second line';

// An access here fails the test instead of opening a user history database.
class _UnusedHistory extends Fake implements HistoryDatabase {}

final class _AudioPropertyAddress extends Struct {
  @Uint32()
  external int selector;
  @Uint32()
  external int scope;
  @Uint32()
  external int element;
}

/// Independent of AVPlayer preparation: an absent default output makes its
/// transport unavailable even when the same asset decodes successfully.
Map<String, Object> _nativeOutputPreflight() {
  final coreAudio = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreAudio.framework/CoreAudio',
  );
  final read = coreAudio
      .lookupFunction<
        Int32 Function(
          Uint32,
          Pointer<_AudioPropertyAddress>,
          Uint32,
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          int,
          Pointer<_AudioPropertyAddress>,
          int,
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('AudioObjectGetPropertyData');
  final address = calloc<_AudioPropertyAddress>();
  final size = calloc<Uint32>();
  final device = calloc<Uint32>();
  try {
    address.ref
      ..selector =
          0x644f7574 // kAudioHardwarePropertyDefaultOutputDevice: dOut.
      ..scope =
          0x676c6f62 // kAudioObjectPropertyScopeGlobal: glob.
      ..element = 0; // kAudioObjectPropertyElementMain.
    size.value = sizeOf<Uint32>();
    final status = read(1, address, 0, nullptr, size, device.cast<Void>());
    return {
      'checked_utc': DateTime.now().toUtc().toIso8601String(),
      'core_audio_read_status': status,
      if (status == 0) 'default_output_device_id': device.value,
    };
  } finally {
    calloc.free(address);
    calloc.free(size);
    calloc.free(device);
  }
}

class _Trace {
  final clock = Stopwatch()..start();
  final counters = <String, int>{};
  final events = <Map<String, Object?>>[];

  void mark(String stage, [String? source]) {
    counters.update(stage, (value) => value + 1, ifAbsent: () => 1);
    events.add({
      'stage': stage,
      'elapsed_ms': clock.elapsedMicroseconds / 1000,
      if (source != null) 'source': Uri.parse(source).pathSegments.last,
    });
  }

  Future<T> call<T>(String stage, Future<T> Function() action) async {
    mark('${stage}_start');
    try {
      return await action();
    } finally {
      mark('${stage}_end');
    }
  }

  Map<String, int> delta(Map<String, int> before) => {
    for (final entry in counters.entries)
      if (entry.value != (before[entry.key] ?? 0))
        entry.key: entry.value - (before[entry.key] ?? 0),
  };
}

/// Counts calls at the real deck boundary, without replacing native work.
class _MeasuredDeck implements PlaybackDeck {
  _MeasuredDeck(this.inner, this.trace) {
    subscriptions.addAll([
      inner.onPlayerStateChanged.listen((state) {
        trace.mark('native_${state.name}', source);
      }, onError: (Object error) => trace.mark('native_error')),
      inner.onPositionChanged.listen((position) {
        trace.mark('native_position', source);
        trace.events.last['position_ms'] = position.inMilliseconds;
        if (position > Duration.zero) {
          trace.mark('native_position_positive', source);
          trace.events.last['position_ms'] = position.inMilliseconds;
        }
      }),
    ]);
  }

  final PlaybackDeck inner;
  final _Trace trace;
  final subscriptions = <StreamSubscription<dynamic>>[];
  String? source;

  @override
  PlaybackDeckState get state => inner.state;
  @override
  bool get isDirect => inner.isDirect;
  @override
  bool get needsSourceReload => inner.needsSourceReload;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged =>
      inner.onPlayerStateChanged;
  @override
  Stream<Duration> get onPositionChanged => inner.onPositionChanged;
  @override
  Stream<Duration> get onDurationChanged => inner.onDurationChanged;
  @override
  Stream<void> get onPlayerComplete => inner.onPlayerComplete;

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) =>
      inner.startPositionUpdates(interval, wanted: wanted);
  @override
  Future<void> configureOutput() =>
      trace.call('configure', inner.configureOutput);
  @override
  Future<void> setVolume(double volume) => inner.setVolume(volume);
  @override
  Future<void> setPlaybackRate(double rate) => inner.setPlaybackRate(rate);

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) {
    source = path;
    return trace.call(
      'prepare',
      () => inner.setFileSource(
        path,
        preferBitPerfect: preferBitPerfect,
        directUsb: directUsb,
        allowDop: allowDop,
        requiresDsd: requiresDsd,
        allowFixedVolume: allowFixedVolume,
        dapExclusive: dapExclusive,
      ),
    );
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) {
    source = url;
    return trace.call(
      'prepare',
      () => inner.setNetworkSource(url, arriving: arriving),
    );
  }

  @override
  Future<void> cancelPreparation() =>
      trace.call('cancel_prepare', inner.cancelPreparation);
  @override
  Future<void> resume() => trace.call('resume', inner.resume);
  @override
  Future<void> pause() => trace.call('pause', inner.pause);
  @override
  Future<void> stop() => trace.call('stop', inner.stop);
  @override
  Future<void> seek(Duration position) =>
      trace.call('seek', () => inner.seek(position));
  @override
  Future<Duration?> getCurrentPosition() =>
      trace.call('position_query', inner.getCurrentPosition);
  @override
  Future<Duration?> getDuration() =>
      trace.call('duration_query', inner.getDuration);
  @override
  Future<bool> setNextDeck(PlaybackDeck? next) =>
      inner.setNextDeck(next is _MeasuredDeck ? next.inner : next);

  @override
  Future<void> dispose() async {
    await inner.dispose();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

Future<void> _waitUntil(bool Function() ready, String stage) async {
  final clock = Stopwatch()..start();
  while (!ready() && clock.elapsed < const Duration(seconds: 15)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue, reason: '$stage timed out');
}

Future<void> _writeAudio(String path) => Isolate.run(() async {
  const sampleRate = 44100;
  const sampleCount = sampleRate * 45;
  final bytes = Uint8List(44 + sampleCount * 4);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, bytes.length - 44, Endian.little);
  var random = 42;
  for (var offset = 44; offset < bytes.length; offset += 2) {
    random = (1664525 * random + 1013904223) & 0xffffffff;
    data.setInt16(offset, (random >> 17) - 16384, Endian.little);
  }
  await File(path).writeAsBytes(bytes);
});

Future<File> _taggedAudio(Directory root) async {
  final wav = '${root.path}/source.wav';
  await _writeAudio(wav);
  final cover = await File('${root.path}/cover.png').writeAsBytes(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5xkAAAAASUVORK5CYII=',
    ),
  );
  final flac = File('${root.path}/source.flac');
  final session = await FFmpegKit.executeWithArguments([
    '-y',
    '-i',
    wav,
    '-i',
    cover.path,
    '-map',
    '0:a',
    '-map',
    '1:v',
    '-c:a',
    'flac',
    '-c:v',
    'copy',
    '-disposition:v',
    'attached_pic',
    '-metadata',
    'title=Pipeline title',
    '-metadata',
    'artist=Pipeline artist',
    '-metadata',
    'album=Pipeline album',
    '-metadata',
    'lyrics=$_lyrics',
    '-metadata',
    'REPLAYGAIN_TRACK_GAIN=-4.0 dB',
    flac.path,
  ]);
  expect(
    ReturnCode.isSuccess(await session.getReturnCode()),
    isTrue,
    reason: await session.getOutput(),
  );
  return flac;
}

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  testWidgets('native playback pipeline, churn, seek and paused tail', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: 'playback_pipeline');
    final output = _nativeOutputPreflight();
    expect(
      output['core_audio_read_status'],
      0,
      reason: 'CoreAudio route preflight failed',
    );
    if (output['default_output_device_id'] == 0) {
      const reason =
          'CoreAudio reports no default output device. Native playback transport cannot be measured; existing app output ownership was left unchanged.';
      markTestSkipped(reason);
      await (await getTemporaryDirectory()).create(recursive: true);
      await probe.finish(
        metadata: {
          'status': 'skipped',
          'skip_reason': reason,
          'native_output_preflight': output,
          'scope':
              'Native playback was not started and no transport latency was measured.',
        },
      );
      return;
    }
    final root = await Directory.systemTemp.createTemp('playback-pipeline-');
    final trace = _Trace();
    final runs = <Map<String, Object?>>[];
    final databases = <Database>[];
    final previousVolume = playbackOutputVolume.value;
    final previousExclusive = playbackExclusiveOutput.value;
    debugDesktopPlatformOverride = true;
    playbackOutputVolume.value = 0;
    playbackExclusiveOutput.value = false;
    final cache = await Directory('${root.path}/embedded').create();
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      cache,
    );
    MusicPlayerRuntime? runtime;
    late MusicPlayerHandler handler;
    PlayerMetadataController? metadata;
    StreamSubscription<MediaItem?>? items;
    HttpServer? server;
    NetworkStorageService? storage;
    NetworkMetadataService? networkMetadata;
    var backendInitialized = false;
    try {
      final media = await Directory('${root.path}/media').create();
      final extensions = await Directory('${root.path}/extensions').create();
      final data = await Directory('${root.path}/data').create();
      final covers = await Directory('${root.path}/covers').create();
      final networkCache = await Directory(
        '${root.path}/network_metadata',
      ).create();
      await PlatformBridge.initExtensionSystem(
        extensions.path,
        data.path,
        masterKey: base64Encode(List<int>.filled(32, 1)),
        lyricsProviders: const [],
        lyricsFetchOptions: const {},
        allowedDirectories: [
          media.path,
          cache.path,
          covers.path,
          networkCache.path,
        ],
      );
      backendInitialized = true;
      await PlatformBridge.setAllowPrivateNetwork(true);
      final audio = await _taggedAudio(media);
      final setupCover = File('${cache.path}/fixture-cover-check.png');
      final coverResult = await PlatformBridge.extractCoverToFile(
        audio.path,
        setupCover.path,
      );
      expect(
        coverResult['error'],
        isNull,
        reason: 'Native fixture cover extraction: $coverResult',
      );
      expect(
        await setupCover.exists(),
        isTrue,
        reason: 'Native fixture cover extraction: $coverResult',
      );
      expect(
        await setupCover.readAsBytes(),
        await File('${media.path}/cover.png').readAsBytes(),
      );
      await setupCover.delete();
      final sessionDb = await AppStateDatabase.openWithFactory(
        databaseFactory,
        '${root.path}/session.db',
      );
      databases.add(sessionDb);
      final libraryDb = await openDatabase(
        '${root.path}/library.db',
        version: LibrarySchema.version,
        onCreate: LibrarySchema.create,
      );
      databases.add(libraryDb);
      final collectionsDb = await LibraryCollectionsDatabase.openWithFactory(
        databaseFactory,
        '${root.path}/collections.db',
      );
      databases.add(collectionsDb);
      final listeningDb = await ListeningStatisticsStore.openWithFactory(
        databaseFactory,
        '${root.path}/listening.db',
      );
      databases.add(listeningDb);
      final learningDb = await openDatabase('${root.path}/learning.db');
      databases.add(learningDb);
      final native = const PlaybackDependencies();
      final decks = <_MeasuredDeck>[];
      final recorderClock = Stopwatch()..start();
      storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      final network = storage;
      networkMetadata = NetworkMetadataService(
        storage: network,
        cacheDirectory: () async => root,
      );
      final networkReader = networkMetadata;
      Future<Map<String, dynamic>> readFile(
        String path, {
        String? displayName,
      }) => trace.call(
        'normalization_metadata',
        () => PlatformBridge.readFileMetadata(path, displayName: displayName),
      );
      runtime = MusicPlayerRuntime(
        settings: const AppSettings(
          playerMode: 'internal',
          playbackNormalization: true,
          pauseOnMute: false,
          gaplessPlayback: false,
          autoplay: false,
          autoplayPersonalization: false,
          localLibraryEnabled: false,
          exclusiveOutput: false,
        ),
        dependencies: PlaybackDependencies(
          createDeck: (id) {
            final deck = _MeasuredDeck(native.createDeck(id), trace);
            decks.add(deck);
            return deck;
          },
          readMetadata: readFile,
          readNetworkMetadata: (source) =>
              trace.call('network_metadata', () => networkReader.read(source)),
          resolveNetworkSource: (source) =>
              trace.call('resolve_network', () => network.resolve(source)),
          recoverMissingFile: (_) async => null,
          sessionDatabase: AppStateDatabase.withDatabase(sessionDb),
          libraryDatabase: LibraryDatabase.withDatabase(
            libraryDb,
            historyAttached: true,
          ),
          historyDatabase: _UnusedHistory(),
          collectionsDatabase: LibraryCollectionsDatabase.withDatabase(
            collectionsDb,
          ),
          recorder: ListeningRecorder(
            elapsed: () => recorderClock.elapsed,
            now: DateTime.now,
            write: (deltas) => trace.call(
              'listening_write',
              () => writeListeningDeltas(listeningDb, deltas),
            ),
          ),
          coverStore: CoverStore(directory: () async => covers),
          createPersonalization: () => AutoplayPersonalization(
            load: () async => null,
            save: (_) async {},
          ),
          createTaste: () => AutoplayTaste(open: () async => learningDb),
          createRanker: () => AutoplayRanker(open: () async => learningDb),
          volumeChanges: const Stream.empty(),
          isAndroid: false,
          isIOS: false,
        ),
      );
      handler = MusicPlayerHandler(runtime: runtime);
      metadata = PlayerMetadataController(
        metadataEvents: SourceMetadataEvents(),
        readMetadata: (path) => trace.call(
          'player_metadata',
          () => path.startsWith('network://')
              ? networkReader.read(path)
              : readPlaybackFileMetadataWithRetry(path),
        ),
        parseLyrics: (raw) => trace.call(
          'lyrics_parse',
          () => LyricsParser.parseAsyncNative(raw),
        ),
      );
      final playerMetadata = metadata;
      Uri? lastArtwork;
      items = handler.mediaItem.listen((item) {
        trace.mark('media_item', item?.extras?['source']?.toString());
        if (item?.artUri != null && item!.artUri != lastArtwork) {
          trace.mark('artwork_available');
        }
        lastArtwork = item?.artUri;
        unawaited(playerMetadata.load(item));
      });
      var queue = <PlayableMedia>[];
      Future<void>? pendingPlay;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: const Key('pipeline_play'),
                    onPressed: () {
                      trace.mark('click');
                      pendingPlay = handler.setQueueAndPlay(queue);
                    },
                    child: const Text('Play fixture'),
                  ),
                  StreamBuilder<MediaItem?>(
                    stream: handler.mediaItem,
                    builder: (_, snapshot) =>
                        Text(snapshot.data?.title ?? 'Ready'),
                  ),
                  ListenableBuilder(
                    listenable: playerMetadata,
                    builder: (_, _) => Text(
                      playerMetadata.loading
                          ? 'Reading tags'
                          : playerMetadata.lyrics.plainText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;

      Future<void> clickAndWait(String name, List<PlayableMedia> tracks) async {
        final eventStart = trace.events.length;
        final before = Map<String, int>.of(trace.counters);
        queue = tracks;
        await tester.tap(find.byKey(const Key('pipeline_play')));
        await _waitUntil(() => pendingPlay != null, 'click dispatch');
        await pendingPlay;
        pendingPlay = null;
        expect(
          handler.playbackState.value.processingState,
          isNot(AudioProcessingState.error),
          reason: handler.playbackState.value.errorMessage,
        );
        await _waitUntil(() {
          final events = trace.events.skip(eventStart).toList();
          final resume = events.indexWhere(
            (event) => event['stage'] == 'resume_start',
          );
          return resume >= 0 &&
              events
                  .skip(resume)
                  .any((event) => event['stage'] == 'native_position_positive');
        }, 'native position after this source resumed');
        await _waitUntil(
          () =>
              !playerMetadata.loading && playerMetadata.lyrics.lines.isNotEmpty,
          'metadata and native lyric parse',
        );
        await _waitUntil(
          () => handler.mediaItem.value?.artUri != null,
          'embedded cover recovery',
        );
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.ready,
        );
        expect(handler.playbackState.value.playing, isTrue);
        trace.mark('operation_ready');
        final readyCounters = Map<String, int>.of(trace.counters);
        await probe.wait(const Duration(milliseconds: 1200));
        final events = trace.events.skip(eventStart).toList();
        final clickMs =
            events.firstWhere(
                  (event) => event['stage'] == 'click',
                )['elapsed_ms']
                as double;
        double? afterClick(String stage) {
          final resume = events.indexWhere(
            (event) => event['stage'] == 'resume_start',
          );
          final candidates = stage == 'native_position_positive' && resume >= 0
              ? events.skip(resume)
              : events;
          final event = candidates
              .where((event) => event['stage'] == stage)
              .firstOrNull;
          return event == null
              ? null
              : (event['elapsed_ms'] as double) - clickMs;
        }

        runs.add({
          'name': name,
          'events': events,
          'latency_from_click_ms': {
            for (final stage in [
              'prepare_start',
              'prepare_end',
              'native_playing',
              'native_position_positive',
              'normalization_metadata_end',
              'player_metadata_end',
              'lyrics_parse_end',
              'artwork_available',
              'operation_ready',
            ])
              stage: afterClick(stage),
          },
          'counts': trace.delta(before),
          'tail_after_ready_counts': trace.delta(readyCounters),
        });
      }

      PlayableMedia track(String id, String source) => PlayableMedia(
        id: id,
        source: source,
        title: 'Queue title $id',
        artist: 'Queue artist',
        duration: const Duration(seconds: 45),
        format: 'flac',
        sampleRate: 44100,
        bitDepth: 16,
      );
      final localFiles = [
        for (var i = 0; i < 3; i++)
          await audio.copy('${media.path}/local-$i.flac'),
      ];
      var localRun = 0;
      await probe.measure(
        'local_click_to_native_position_metadata_art_and_tail',
        () async {
          final file = localFiles[localRun++];
          await clickAndWait('local_cold_$localRun', [
            track('local-$localRun', file.path),
          ]);
        },
        warmup: () async {},
        repetitions: 3,
      );

      final payload = await audio.readAsBytes();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Map<String, Object?>>[];
      var transferred = 0;
      Completer<void>? slowResponse;
      server.listen((request) async {
        final range = request.headers.value('range');
        final part = networkByteRange(range, payload.length);
        final length = part.end - part.start + 1;
        requests.add({
          'method': request.method,
          'range': range,
          'path': request.uri.path,
          'elapsed_ms': trace.clock.elapsedMicroseconds / 1000,
          'bytes': request.method == 'HEAD' ? 0 : length,
        });
        if (request.uri.path.startsWith('/slow-')) {
          await slowResponse?.future;
        }
        request.response.statusCode = range == null ? 200 : 206;
        request.response.headers.set('Content-Type', 'audio/flac');
        request.response.headers.set('Accept-Ranges', 'bytes');
        if (range != null) {
          request.response.headers.set(
            'Content-Range',
            'bytes ${part.start}-${part.end}/${payload.length}',
          );
        }
        request.response.contentLength = length;
        if (request.method != 'HEAD') {
          transferred += length;
          request.response.add(
            Uint8List.sublistView(payload, part.start, part.end + 1),
          );
        }
        try {
          await request.response.close();
        } on IOException {
          // Replaced sources may close their HTTP reader during cancellation.
        }
      });
      await network.save(
        NetworkConnection(
          id: 'pipeline',
          name: 'Pipeline fixture',
          protocol: NetworkProtocol.http,
          address: 'http://127.0.0.1:${server.port}/',
        ),
      );
      var networkRun = 0;
      await probe.measure(
        'network_resolve_native_prepare_shared_metadata_and_tail',
        () async {
          final requestStart = requests.length;
          final bytesBefore = transferred;
          final source = NetworkStorageService.source(
            'pipeline',
            'network-${networkRun++}.flac',
          );
          await clickAndWait('network_cold_$networkRun', [
            track('network-$networkRun', source),
          ]);
          runs.last.addAll({
            'http_requests': requests.skip(requestStart).toList(),
            'http_bytes': transferred - bytesBefore,
          });
        },
        warmup: () async {},
        repetitions: 3,
      );

      await probe.measure(
        'rapid_track_change_and_seek',
        () async {
          await handler.setQueueAndPlay([
            for (var i = 0; i < 3; i++) track('rapid-$i', audio.path),
          ]);
          final eventStart = trace.events.length;
          final before = Map<String, int>.of(trace.counters);
          final first = handler.skipToNext();
          final second = handler.skipToNext();
          await Future.wait([first, second]);
          expect(handler.mediaItem.value?.id, 'rapid-2');
          final deck = decks.single;
          final seeks = [
            for (final seconds in [2, 7, 11, 5])
              handler.seek(Duration(seconds: seconds)),
          ];
          await Future.wait(seeks);
          await _waitUntil(
            () =>
                handler.playbackState.value.position >=
                const Duration(milliseconds: 4900),
            'final seek publication',
          );
          final position = await deck.getCurrentPosition();
          expect(
            position,
            greaterThanOrEqualTo(const Duration(milliseconds: 4900)),
          );
          expect(position, lessThan(const Duration(seconds: 7)));
          trace.mark('churn_ready');
          await probe.wait(const Duration(milliseconds: 1200));
          expect(handler.mediaItem.value?.id, 'rapid-2');
          runs.add({
            'name': 'rapid_change_seek',
            'events': trace.events.skip(eventStart).toList(),
            'counts': trace.delta(before),
          });
        },
        warmup: () async {},
        repetitions: 3,
      );

      runtime.configure(
        runtime.settings.copyWith(playbackNormalization: false),
      );
      await probe.wait(const Duration(milliseconds: 200));
      var cancelRun = 0;
      await probe.measure(
        'cancel_inflight_native_prepare',
        () async {
          final before = Map<String, int>.of(trace.counters);
          final eventStart = trace.events.length;
          slowResponse = Completer<void>();
          final slowPath = '/slow-${cancelRun++}.flac';
          final slow = handler.setQueueAndPlay([
            track(
              'slow-$cancelRun',
              'http://127.0.0.1:${server!.port}$slowPath',
            ),
          ]);
          try {
            await _waitUntil(
              () => requests.any((request) => request['path'] == slowPath),
              'native HTTP preparation request',
            );
            trace.mark('cancel_click');
            final elapsed = Stopwatch()..start();
            await handler
                .setQueueAndPlay([track('replacement', audio.path)])
                .timeout(const Duration(seconds: 3));
            trace.mark('cancel_replacement_ready');
            expect(handler.mediaItem.value?.id, 'replacement');
            expect(
              handler.playbackState.value.processingState,
              AudioProcessingState.ready,
            );
            expect(handler.playbackState.value.playing, isTrue);
            runs.add({
              'name': 'cancel_inflight_prepare',
              'replacement_ms_while_old_http_response_held':
                  elapsed.elapsedMicroseconds / 1000,
              'counts': trace.delta(before),
              'events': trace.events.skip(eventStart).toList(),
            });
          } finally {
            slowResponse!.complete();
            slowResponse = null;
            await slow;
          }
          await probe.wait(const Duration(milliseconds: 300));
          expect(handler.mediaItem.value?.id, 'replacement');
        },
        warmup: () async {},
        repetitions: 3,
      );

      await handler.pause();
      await probe.wait(const Duration(milliseconds: 500));
      await probe.measure(
        'paused_idle_tail',
        () async {
          final before = Map<String, int>.of(trace.counters);
          final requestStart = requests.length;
          await probe.wait(const Duration(seconds: 2));
          final delta = trace.delta(before);
          expect(delta['normalization_metadata_start'] ?? 0, 0);
          expect(delta['player_metadata_start'] ?? 0, 0);
          expect(delta['native_position'] ?? 0, 0);
          expect(requests.length, requestStart);
          runs.add({
            'name': 'paused_idle',
            'counts': delta,
            'http_requests': requests.length - requestStart,
          });
        },
        warmup: () async {},
        repetitions: 3,
        allowIdle: true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await (await getTemporaryDirectory()).create(recursive: true);
      await probe.finish(
        metadata: {
          'scope':
              'Widget click through real MusicPlayerHandler, real default native deck, Rust metadata and lyric parsing, embedded artwork, private native SQLite and loopback range HTTP. AudioService system-session initialization and the full app shell are excluded. Playback volume is zero; exclusive output, AutoMix, gapless and online lyrics are disabled.',
          'audio_bytes': payload.length,
          'native_output_preflight': output,
          'fixture_cover_extraction_verified': true,
          'operation_runs': runs,
          'session_sqlite_total_changes': await sessionDb.rawQuery(
            'SELECT total_changes() AS changes',
          ),
          'http_requests': requests.length,
          'http_bytes': transferred,
          'stage_timing_basis':
              'Monotonic timestamps at production boundaries. Native playing is a deck event; positive position requires a native player position event, never optimistic handler state.',
        },
      );
    } finally {
      await items?.cancel();
      metadata?.dispose();
      await runtime?.dispose();
      await networkMetadata?.cancelPending();
      await storage?.dispose();
      await server?.close(force: true);
      await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
      DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
        null,
      );
      if (backendInitialized) await PlatformBridge.cleanupExtensions();
      for (final database in databases.reversed) {
        await database.close();
      }
      playbackOutputVolume.value = previousVolume;
      playbackExclusiveOutput.value = previousExclusive;
      debugDesktopPlatformOverride = null;
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
