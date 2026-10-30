import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/background_favorites.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

class _Deck implements PlaybackDeck {
  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  final volumes = <double>[];
  Map<String, bool>? outputOptions;
  final sources = <String>[];
  Duration position = Duration.zero;
  int disposals = 0;
  bool failStop = false;

  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => const Stream.empty();
  @override
  void startPositionUpdates(Duration interval) {}
  @override
  Future<void> configureOutput() async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> stop() async {
    if (failStop) throw StateError('Transport failed');
    state = PlaybackDeckState.stopped;
  }

  @override
  Future<void> pause() async => state = PlaybackDeckState.paused;
  @override
  Future<void> resume() async => state = PlaybackDeckState.playing;
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 60);
  @override
  Future<Duration?> getCurrentPosition() async => position;
  @override
  Future<void> dispose() async => disposals++;
  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async {
    sources.add(path);
    outputOptions = {
      'bitPerfect': preferBitPerfect,
      'direct': directUsb,
      'dop': allowDop,
      'fixedVolume': allowFixedVolume,
      'exclusive': dapExclusive,
    };
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async =>
      sources.add('${arriving ? 'arriving' : 'stream'} $url');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedSeekDeck extends _Deck {
  final seekStarted = Completer<void>();
  final seekBarrier = Completer<void>();
  final seekSources = <String>[];

  @override
  Future<void> seek(Duration value) async {
    seekStarted.complete();
    await seekBarrier.future;
    seekSources.add(sources.last);
    await super.seek(value);
  }
}

class _Session implements AudioSession {
  int configurations = 0;
  final activations = <bool>[];
  bool focusGranted = true;
  Object? activationError;
  Completer<void>? configureBarrier;
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();

  Future<void> dispose() => interruptions.close();

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
    await configureBarrier?.future;
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    if (activationError case final error?) throw error;
    return !active || focusGranted;
  }

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SessionStore implements AppStateDatabase {
  int clears = 0;
  int? persistedPositionMs;

  @override
  Future<Map<String, dynamic>?> getPlaybackSession() async => null;
  @override
  Future<void> savePlaybackSession(Map<String, dynamic> session) async {
    persistedPositionMs = session['positionMs'] as int?;
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    persistedPositionMs = positionMs;
    return true;
  }

  @override
  Future<void> clearPlaybackSession() async => clears++;

  @override
  Future<void> archivePlaybackSession(Map<String, dynamic> media) async =>
      clears++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResumeSessionStore extends _SessionStore {
  Map<String, dynamic>? active;
  Map<String, dynamic>? archived;
  Map<String, dynamic>? preview;
  Future<void> Function()? beforeResumeLoad;
  int resumeReads = 0;

  @override
  Future<Map<String, dynamic>?> getPlaybackSession() async => active;

  @override
  Future<void> savePlaybackSession(Map<String, dynamic> session) async {
    await super.savePlaybackSession(session);
    active = session;
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    if (active == null) return false;
    active = {
      ...active!,
      'index': index,
      'positionMs': positionMs,
      'shuffle': shuffle,
      'repeat': repeatMode,
    };
    return super.updatePlaybackSessionState(
      index: index,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
  }

  @override
  Future<void> archivePlaybackSession(Map<String, dynamic> media) async {
    archived = active;
    preview = {'media': media, 'positionMs': active?['positionMs']};
    active = null;
    clears++;
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackResumePreview() async => preview;

  @override
  Future<Map<String, dynamic>?> getPlaybackResumeSession() async {
    resumeReads++;
    await beforeResumeLoad?.call();
    return archived;
  }

  @override
  Future<void> clearPlaybackResume() async {
    archived = preview = null;
  }
}

class _DeletionHandler extends MusicPlayerHandler {
  _DeletionHandler(MusicPlayerRuntime runtime) : super(runtime: runtime);

  final deletedSources = <String>[];

  @override
  Future<void> onSourceDeleted(String source) async =>
      deletedSources.add(source);
}

class _Recorder extends ListeningRecorder {
  _Recorder({required super.write, required super.elapsed, required super.now});

  int updates = 0;
  ListeningTrack? latestTrack;

  @override
  void update(
    ListeningTrack? track, {
    required bool playing,
    bool ended = false,
  }) {
    updates++;
    latestTrack = track;
    super.update(track, playing: playing, ended: ended);
  }
}

/// Serves Library songs by offset, as the queue query does for rows that
/// have no seek cursor.
class _QueueLibrary implements LibraryDatabase {
  _QueueLibrary(this.rows);

  final List<Map<String, dynamic>> rows;
  final requests = <QueueLibraryDbQuery>[];

  @override
  Future<QueueLibraryDbPage> getQueueTrackPageResult(
    QueueLibraryDbQuery request,
  ) async {
    requests.add(request);
    return QueueLibraryDbPage(
      rows: rows.skip(request.offset).take(request.limit).toList(),
      nextCursor: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One scanned album and the songs a search finds, as a media browser such
/// as Android Auto reads them.
class _BrowsedLibrary implements LibraryDatabase {
  static Map<String, dynamic> song(String id, int number) => {
    'id': id,
    'trackName': 'Song $id',
    'artistName': 'Artist',
    'albumName': 'Album',
    'filePath': '/album/$id.flac',
    'scannedAt': '2026-01-01T00:00:00.000Z',
    'trackNumber': number,
  };

  final album = [song('c', 3), song('a', 1), song('b', 2)];

  @override
  Future<QueueLibraryDbPage> getQueueAlbumPageResult(
    QueueLibraryDbQuery request,
  ) async => const QueueLibraryDbPage(
    rows: [
      {
        'queue_source': 'local',
        'album_key': 'album',
        'album_name': 'Album',
        'artist_name': 'Artist',
      },
    ],
    nextCursor: null,
  );

  @override
  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracksByKey(
    String albumKey,
  ) async => albumKey == 'album' ? album : const [];

  @override
  Future<List<LibrarySearchHit>> searchLibrary({
    required String query,
    required LibrarySearchKind kind,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async => kind == LibrarySearchKind.songs && query == 'song b'
      ? const [
          LibrarySearchHit(
            kind: LibrarySearchKind.songs,
            id: 'b',
            title: 'Song b',
            source: 'local',
          ),
        ]
      : const [];

  @override
  Future<Map<String, dynamic>?> getById(String id) async {
    for (final row in album) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoHistory implements HistoryDatabase {
  @override
  Future<Map<String, dynamic>?> findByFilePath(String filePath) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Loved collection by track key.
class _Loved implements LibraryCollectionsDatabase {
  final keys = <String>{};

  @override
  Future<bool> containsLovedTrack(String trackKey) async =>
      keys.contains(trackKey);

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async => keys.add(trackKey);

  @override
  Future<void> deleteLovedEntry(String trackKey) async => keys.remove(trackKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MusicPlayerRuntime _runtime({
  AppSettings settings = const AppSettings(pauseOnMute: false),
  Future<MusicPlayerHandler> Function(MusicPlayerHandler Function())?
  initialize,
  List<_Deck>? decks,
  PlaybackDeck Function(String)? createDeck,
  Stream<double> volumeChanges = const Stream.empty(),
  SourceDeletionEvents? sourceDeletionEvents,
  SourceMetadataEvents? sourceMetadataEvents,
  Future<Map<String, dynamic>> Function(String, {String? displayName})?
  readMetadata,
  ListeningRecorder? recorder,
  AutoplayPersonalization Function()? createPersonalization,
  AutoplayTaste Function()? createTaste,
  AutoplayRanker Function()? createRanker,
  bool isIOS = false,
  bool isAndroid = false,
  Future<void> Function()? synchronizePlaybackState,
  _Session? session,
  AppStateDatabase? sessionDatabase,
  LibraryDatabase? libraryDatabase,
  HistoryDatabase? historyDatabase,
  LibraryCollectionsDatabase? collectionsDatabase,
  Future<String?> Function(String)? recoverMissingFile,
  Future<String> Function(String)? resolveNetworkSource,
}) {
  if (isAndroid) {
    const channel = MethodChannel(
      'com.ryanheise.audio_service.handler.methods',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }
  final audioSession = session ?? _Session();
  addTearDown(audioSession.dispose);
  final runtime = MusicPlayerRuntime(
    settings: settings,
    dependencies: PlaybackDependencies(
      createPersonalization:
          createPersonalization ?? AutoplayPersonalization.new,
      createTaste: createTaste ?? AutoplayTaste.new,
      createRanker: createRanker ?? AutoplayRanker.new,
      createDeck:
          createDeck ??
          (_) {
            final deck = _Deck();
            decks?.add(deck);
            return deck;
          },
      audioSession: () async => audioSession,
      initializeHandler: initialize ?? (builder) async => builder(),
      synchronizePlaybackState: synchronizePlaybackState ?? () async {},
      readMetadata:
          readMetadata ??
          (_, {displayName}) async => {'replaygain_track_gain': '-6 dB'},
      recoverMissingFile: recoverMissingFile ?? (_) async => null,
      resolveNetworkSource:
          resolveNetworkSource ?? NetworkStorageService.instance.resolve,
      sessionDatabase: sessionDatabase ?? _SessionStore(),
      libraryDatabase: libraryDatabase,
      historyDatabase: historyDatabase,
      collectionsDatabase: collectionsDatabase,
      recorder:
          recorder ??
          ListeningRecorder(
            write: (_) async {},
            elapsed: () => Duration.zero,
            now: () => DateTime(2026),
          ),
      volumeChanges: volumeChanges,
      sourceDeletionEvents: sourceDeletionEvents ?? SourceDeletionEvents(),
      sourceMetadataEvents: sourceMetadataEvents ?? SourceMetadataEvents(),
      isAndroid: isAndroid,
      isIOS: isIOS,
    ),
  );
  addTearDown(runtime.dispose);
  return runtime;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _item = MediaItem(id: 'one', title: 'One');
const _track = PlayableMedia(
  id: 'one',
  source: '/one.flac',
  title: 'One',
  artist: 'Artist',
  duration: Duration(seconds: 60),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'changed tags update queued copies without restarting playback',
    () async {
      final events = SourceMetadataEvents();
      final decks = <_Deck>[];
      var title = 'Old title';
      final runtime = _runtime(
        decks: decks,
        sourceMetadataEvents: events,
        readMetadata: (_, {displayName}) async => {
          'title': title,
          'artist': 'Edited artist',
          'album': 'Edited album',
        },
      );
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track, _track]);
      await handler.seek(const Duration(seconds: 34));
      await handler.pause();
      final sources = List.of(decks.first.sources);
      final position = decks.first.position;
      title = 'Edited title';
      await events.publish(_track.source);
      expect(handler.mediaItem.value!.title, title);
      expect(handler.queue.value.map((item) => item.title), [title, title]);
      expect(handler.mediaItem.value!.artist, 'Edited artist');
      expect(decks.first.sources, sources);
      expect(decks.first.position, position);
      expect(handler.playbackState.value.playing, isFalse);
      expect(RuntimeLinkPlayerPort(runtime).snapshot().current!.title, title);
      await runtime.dispose();
      await events.publish(_track.source);
    },
  );

  test(
    'an older metadata read cannot overwrite a newer successful edit',
    () async {
      final old = Completer<Map<String, dynamic>>();
      var reads = 0;
      final handler = await _runtime(
        settings: const AppSettings(
          playbackNormalization: false,
          pauseOnMute: false,
        ),
        readMetadata: (_, {displayName}) {
          reads++;
          return reads == 1
              ? old.future
              : Future.value({'title': 'Newest title'});
        },
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      await handler.onSourceMetadataChanged('/unrelated.flac');
      expect(reads, 0);
      final pending = handler.onSourceMetadataChanged(_track.source);
      await handler.onSourceMetadataChanged(_track.source);
      expect(handler.mediaItem.value!.title, 'Newest title');
      old.complete({'title': 'Stale title'});
      await pending;
      expect(handler.mediaItem.value!.title, 'Newest title');
      expect(handler.queue.value.single.title, 'Newest title');
    },
  );

  test('the local player publishes Android stream volume handling', () async {
    final handler = await _runtime().initialize();
    expect(handler.androidPlaybackInfo.value, isA<LocalAndroidPlaybackInfo>());
  });

  test(
    'Link adopts repeat before either player has been initialized',
    () async {
      final desktop = _runtime();
      await RuntimeLinkPlayerPort(desktop).setRepeat(LinkRepeatMode.one);
      expect(
        desktop.handler!.playbackState.value.repeatMode,
        AudioServiceRepeatMode.one,
      );
      final phone = _runtime();
      await LinkMusicPhonePlayer(
        runtime: phone,
        controller: MusicPlayerController(runtime: phone),
        writeVolume: (_) async {},
      ).setRepeat(LinkRepeatMode.all);
      expect(
        phone.handler!.playbackState.value.repeatMode,
        AudioServiceRepeatMode.all,
      );
    },
  );

  test(
    'a handed-off shuffled queue keeps its order and current song',
    () async {
      final handler = await _runtime().initialize();
      final media = [
        for (var i = 0; i < 12; i++)
          PlayableMedia(
            id: '$i',
            source: '/$i.flac',
            title: 'Song $i',
            artist: 'Artist',
          ),
      ];
      await handler.setQueueAndPlay(media, initialIndex: 4, shuffle: true);
      expect(
        handler.queue.value.map((item) => item.id),
        media.map((item) => item.id),
      );
      expect(handler.mediaItem.value?.id, '4');
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      await handler.setQueueAndPlay(media, initialIndex: 2, shuffle: false);
      expect(
        handler.queue.value.map((item) => item.id),
        media.map((item) => item.id),
      );
      expect(handler.mediaItem.value?.id, '2');
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.none,
      );
    },
  );

  test('dismissing a paused player ends the saved session and permits new '
      'playback', () async {
    final store = _SessionStore();
    final decks = <_Deck>[];
    final runtime = _runtime(sessionDatabase: store, decks: decks);
    final controller = MusicPlayerController(runtime: runtime);
    final handler = await runtime.initialize();
    await controller.playSingle(_track);
    await handler.pause();

    await controller.dismiss();

    expect(decks.single.state, PlaybackDeckState.stopped);
    expect(handler.mediaItem.value, isNull);
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(store.clears, 1);
    expect(handler.queue.value.map((item) => item.id), ['one']);

    await controller.playSingle(_track);
    expect(handler.mediaItem.value?.id, 'one');
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'Home resumes a dismissed queue at its position after a fresh runtime',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'resume-runtime-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final tracks = [
        for (var i = 0; i < 3; i++)
          PlayableMedia(
            id: '$i',
            source: (await File(
              '${directory.path}/$i.flac',
            ).writeAsString('audio')).path,
            title: 'Track $i',
            artist: 'Artist',
            artUri: 'https://example.com/cover.jpg',
            duration: const Duration(minutes: 3),
          ),
      ];
      final store = _ResumeSessionStore();
      final decks = <_Deck>[];
      final runtime = _runtime(sessionDatabase: store, decks: decks);
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay(tracks, initialIndex: 1, shuffle: true);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      decks.single.position = const Duration(seconds: 23);
      await handler.pause();
      final order = handler.queue.value.map((item) => item.id).toList();
      await MusicPlayerController(runtime: runtime).dismiss();
      expect(handler.mediaItem.value, isNull);
      expect(store.active, isNull);
      expect(store.archived?['positionMs'], 23000);

      final resumedDecks = <_Deck>[];
      final fresh = _runtime(sessionDatabase: store, decks: resumedDecks);
      await fresh.restoreSession();
      expect(fresh.handler, isNull);
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(fresh)],
      );
      addTearDown(container.dispose);
      final preview = await container.read(playbackResumeProvider.future);
      expect(preview?.media.id, '1');
      expect(preview?.position, const Duration(seconds: 23));
      expect(fresh.handler, isNull);

      expect(
        await MusicPlayerController(runtime: fresh).resumeSavedSession(),
        isTrue,
      );
      expect(fresh.handler!.queue.value.map((item) => item.id), order);
      expect(fresh.handler!.mediaItem.value?.id, '1');
      expect(resumedDecks.single.position, const Duration(seconds: 23));
      expect(fresh.handler!.playbackState.value.playing, isTrue);
      expect(
        fresh.handler!.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(
        fresh.handler!.playbackState.value.repeatMode,
        AudioServiceRepeatMode.all,
      );
    },
  );

  test(
    'switching to external stops playback and keeps the saved session',
    () async {
      final store = _ResumeSessionStore();
      final decks = <_Deck>[];
      final runtime = _runtime(sessionDatabase: store, decks: decks);
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track]);
      decks.single.position = const Duration(seconds: 23);
      final stopped = handler.mediaItem.firstWhere((item) => item == null);
      runtime.configure(runtime.settings.copyWith(playerMode: 'external'));
      await stopped;
      expect(decks.single.state, PlaybackDeckState.stopped);
      expect(store.archived?['positionMs'], 23000);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        await MusicPlayerController(runtime: runtime).resumeSavedSession(),
        isFalse,
      );
      expect(store.resumeReads, 0);
    },
  );

  test(
    'external startup does not initialize the internal player or restore a session',
    () async {
      final store = _ResumeSessionStore();
      final runtime = _runtime(
        settings: const AppSettings(playerMode: 'external'),
        sessionDatabase: store,
      );
      await runtime.restoreSession();
      await runtime.recoverRestoredArtwork();
      expect(runtime.handler, isNull);
      expect(store.clears, 0);
      expect(store.resumeReads, 0);
    },
  );

  test('a repeated Resume request cannot replace newer playback', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final store = _ResumeSessionStore()
      ..archived = {
        'media': [
          const PlayableMedia(
            id: 'saved',
            source: 'network://fixture/saved.flac',
            title: 'Saved',
            artist: 'Artist',
            artUri: 'https://example.com/cover.jpg',
          ).toJson(),
        ],
        'index': 0,
        'positionMs': 23000,
      }
      ..beforeResumeLoad = () {
        entered.complete();
        return release.future;
      };
    final runtime = _runtime(sessionDatabase: store);
    final controller = MusicPlayerController(runtime: runtime);
    final pending = controller.resumeSavedSession();
    expect(identical(pending, controller.resumeSavedSession()), isTrue);
    await entered.future;
    await controller.playSingle(_track);
    release.complete();
    expect(await pending, isFalse);
    expect(store.resumeReads, 1);
    expect(runtime.handler!.mediaItem.value?.id, _track.id);
    expect(runtime.handler!.playbackState.value.playing, isTrue);
  });

  test(
    'a removed saved file leaves Home without a stale Resume card',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'resume-missing-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = _ResumeSessionStore()
        ..preview = {
          'media': PlayableMedia(
            id: 'missing',
            source: '${directory.path}/missing.flac',
            title: 'Missing',
            artist: 'Artist',
          ).toJson(),
          'positionMs': 23000,
        };
      final runtime = _runtime(sessionDatabase: store);
      expect(await loadPlaybackResumePreview(runtime), isNull);
      expect(runtime.handler, isNull);
    },
  );

  test(
    'deleting a saved source refreshes an already loaded Resume card',
    () async {
      final directory = await Directory.systemTemp.createTemp('resume-delete-');
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/saved.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final store = _ResumeSessionStore()
        ..preview = {
          'media': PlayableMedia(
            id: 'saved',
            source: file.path,
            title: 'Saved',
            artist: 'Artist',
          ).toJson(),
          'positionMs': 23000,
        };
      final runtime = _runtime(
        sessionDatabase: store,
        sourceDeletionEvents: events,
      );
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);
      expect(await container.read(playbackResumeProvider.future), isNotNull);
      expect(await deleteFile(file.path, deletionEvents: events), isTrue);
      expect(await container.read(playbackResumeProvider.future), isNull);
      expect(runtime.handler, isNull);
    },
  );

  for (final state in [
    PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    PlaybackState(processingState: AudioProcessingState.loading),
    PlaybackState(processingState: AudioProcessingState.buffering),
  ]) {
    test('dismiss ignores playing=${state.playing}, '
        'processing=${state.processingState.name}', () async {
      final store = _SessionStore();
      final runtime = _runtime(sessionDatabase: store);
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track]);
      handler.playbackState.add(state);

      await MusicPlayerController(runtime: runtime).dismiss();

      expect(handler.mediaItem.value?.id, 'one');
      expect(handler.playbackState.value, state);
      expect(store.clears, 0);
    });
  }

  test('a pending seek cannot move the next song', () async {
    final deck = _DelayedSeekDeck();
    final runtime = _runtime(createDeck: (_) => deck);
    final handler = await runtime.initialize();
    const nextTrack = PlayableMedia(
      id: 'two',
      source: '/two.flac',
      title: 'Two',
      artist: 'Artist',
    );
    await handler.setQueueAndPlay([_track, nextTrack]);
    final seek = handler.seek(const Duration(seconds: 12));
    await deck.seekStarted.future;
    final next = handler.skipToNext();
    try {
      await _settle();
      expect(deck.sources, ['/one.flac']);
    } finally {
      deck.seekBarrier.complete();
      await Future.wait([seek, next]);
    }
    expect(deck.seekSources, ['/one.flac']);
    expect(handler.mediaItem.value?.id, 'two');
    expect(handler.playbackState.value.updatePosition, Duration.zero);
  });

  test(
    'trained personalized ranking runs through the real autoplay worker',
    () async {
      final model = AutoplayPreferenceModel();
      const preferred = AutoplayLearningTrack(
        source: '/jazz.flac',
        title: 'Jazz',
        artist: 'Jazz Artist',
        genre: 'Jazz',
        duration: Duration(seconds: 60),
      );
      const avoided = AutoplayLearningTrack(
        source: '/rock.flac',
        title: 'Rock',
        artist: 'Rock Artist',
        genre: 'Rock',
        duration: Duration(seconds: 60),
      );
      const seed = AutoplayLearningTrack(
        source: '/one.flac',
        title: 'One',
        artist: 'Artist',
      );
      for (var i = 0; i < 80; i++) {
        model.learn(preferred, previous: seed, at: DateTime.now(), reward: 1);
        model.learn(avoided, previous: seed, at: DateTime.now(), reward: 0);
      }
      final learning = AutoplayPersonalization(
        load: () async => model.encode(),
        save: (_) async {},
      );
      final runtime = _runtime(
        settings: const AppSettings(
          pauseOnMute: false,
          autoplay: true,
          autoplayPersonalization: true,
        ),
        createPersonalization: () => learning,
      );
      final handler = MusicPlayerHandler(
        runtime: runtime,
        autoplayLibraryLoader: (_) async => [
          const PlayableMedia(
            id: 'rock',
            source: '/rock.flac',
            title: 'Rock',
            artist: 'Rock Artist',
            genre: 'Rock',
            duration: Duration(seconds: 60),
          ),
          const PlayableMedia(
            id: 'jazz',
            source: '/jazz.flac',
            title: 'Jazz',
            artist: 'Jazz Artist',
            genre: 'Jazz',
            duration: Duration(seconds: 60),
          ),
        ],
      );
      await learning.ensureLoaded();
      await handler.setQueueAndPlay([_track]);
      await handler.queue
          .firstWhere((queue) => queue.length == 3)
          .timeout(const Duration(seconds: 5));
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'jazz',
        'rock',
      ]);
      expect(handler.playbackState.value.playing, isTrue);
      await resetAutoplayLearning(runtime: runtime);
      expect(learning.observations, 0);
      await handler.queue
          .firstWhere((queue) => queue.length == 3)
          .timeout(const Duration(seconds: 5));
      expect(handler.queue.value.first.id, 'one');
      runtime.configure(
        runtime.settings.copyWith(autoplayPersonalization: false),
      );
      await handler.queue
          .firstWhere((queue) => queue.length == 3)
          .timeout(const Duration(seconds: 5));
      expect(handler.queue.value.first.id, 'one');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test('songs played together rank through the real autoplay worker', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('autoplay-taste-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await AutoplayTaste.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/taste.db',
    );
    addTearDown(db.close);
    final taste = AutoplayTaste(
      open: () async => db,
      train: (plays) async => trainAutoplayTaste(plays),
    );
    // Night artists play together, and Day artists, never with each other.
    for (var session = 0; session < 16; session++) {
      final group = session.isEven ? 'Night' : 'Day';
      for (var i = 0; i < 8; i++) {
        taste.record(
          AutoplayFeedback(
            kind: AutoplayFeedbackKind.listened,
            track: AutoplayLearningTrack(
              source: '/$group/$i.flac',
              title: 'Song ${i % 4}',
              artist: '$group ${1 + i % 3}',
            ),
            previous: null,
            at: DateTime(
              2026,
            ).add(Duration(hours: 3 * session, minutes: 4 * i)),
            reward: 1,
          ),
        );
      }
    }
    await taste.train();
    expect(taste.model?.positives, 128);
    final runtime = _runtime(
      settings: const AppSettings(
        pauseOnMute: false,
        autoplay: true,
        autoplayPersonalization: true,
      ),
      createPersonalization: () =>
          AutoplayPersonalization(load: () async => null, save: (_) async {}),
      createTaste: () => taste,
    );
    final handler = MusicPlayerHandler(
      runtime: runtime,
      autoplayLibraryLoader: (_) async => [
        const PlayableMedia(
          id: 'day',
          source: '/day.flac',
          title: 'Song 2',
          artist: 'Day 2',
        ),
        const PlayableMedia(
          id: 'night',
          source: '/night.flac',
          title: 'Song 2',
          artist: 'Night 3',
        ),
      ],
    );
    await handler.setQueueAndPlay([
      const PlayableMedia(
        id: 'one',
        source: '/one.flac',
        title: 'Song 0',
        artist: 'Night 1',
      ),
    ]);
    await handler.queue
        .firstWhere((queue) => queue.length == 3)
        .timeout(const Duration(seconds: 5));
    expect(handler.queue.value.map((item) => item.id), ['one', 'night', 'day']);
    await resetAutoplayLearning(runtime: runtime);
    expect(await taste.readLog(), isEmpty);
    expect(taste.model, isNull);
  });

  test('how the listener takes autoplay picks teaches the ranker', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('autoplay-rank-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await AutoplayRanker.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/ranker.db',
    );
    addTearDown(db.close);
    final ranker = AutoplayRanker(
      open: () async => db,
      train: (outcomes) async => trainAutoplayRanker(outcomes),
    );
    var elapsed = Duration.zero;
    final learning = AutoplayPersonalization(
      load: () async => null,
      save: (_) async {},
      elapsed: () => elapsed,
      now: () => DateTime(2026),
    );
    final runtime = _runtime(
      settings: const AppSettings(
        pauseOnMute: false,
        autoplay: true,
        autoplayPersonalization: true,
      ),
      createPersonalization: () => learning,
      createRanker: () => ranker,
    );
    final handler = MusicPlayerHandler(
      runtime: runtime,
      autoplayLibraryLoader: (_) async => [
        for (final id in ['two', 'three'])
          PlayableMedia(
            id: id,
            source: '/$id.flac',
            title: id,
            artist: 'Artist $id',
            duration: const Duration(seconds: 60),
          ),
      ],
    );
    await learning.ensureLoaded();
    await handler.setQueueAndPlay([_track]);
    await handler.queue
        .firstWhere((queue) => queue.length == 3)
        .timeout(const Duration(seconds: 5));
    await _settle();
    // The song the listener chose says nothing about autoplay's ranking.
    elapsed += const Duration(seconds: 40);
    await handler.skipToNext();
    await _settle();
    expect(await ranker.readOutcomes(), isEmpty);
    // Skipping the first pick within seconds.
    elapsed += const Duration(seconds: 5);
    await handler.skipToNext();
    await _settle();
    final outcomes = await ranker.readOutcomes();
    expect(outcomes, hasLength(1));
    expect(outcomes.single.reward, 0);
    // A new artist, before learning has a preference model.
    expect(outcomes.single.parts, {'novelty': 1});

    await resetAutoplayLearning(runtime: runtime);
    expect(await ranker.readOutcomes(), isEmpty);
  });

  test(
    'player learns explicit skips, excludes pauses and obeys live opt-out',
    () async {
      var elapsed = Duration.zero;
      final learning = AutoplayPersonalization(
        load: () async => null,
        save: (_) async {},
        elapsed: () => elapsed,
        now: () => DateTime(2026),
      );
      final runtime = _runtime(
        settings: const AppSettings(
          pauseOnMute: false,
          autoplayPersonalization: true,
        ),
        createPersonalization: () => learning,
      );
      final handler = await runtime.initialize();
      await learning.ensureLoaded();
      const second = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Other',
        duration: Duration(seconds: 60),
      );
      await handler.setQueueAndPlay([_track, second]);
      await _settle();
      elapsed += const Duration(seconds: 10);
      await handler.pause();
      elapsed += const Duration(hours: 1);
      await handler.play();
      await _settle();
      await handler.skipToNext();
      await _settle();
      expect(learning.observations, 1);
      expect(
        learning.adjustment(
          const AutoplayLearningTrack(
            source: '/one.flac',
            title: 'One',
            artist: 'Artist',
            duration: Duration(seconds: 60),
          ),
          const AutoplayLearningTrack(
            source: '/two.flac',
            title: 'Two',
            artist: 'Other',
          ),
          DateTime(2026),
        ),
        lessThan(0),
      );
      elapsed += const Duration(seconds: 10);
      await handler.skipToQueueItem(
        1,
      ); // Restarting is not rejecting this song.
      await _settle();
      expect(learning.observations, 1);
      runtime.configure(
        runtime.settings.copyWith(autoplayPersonalization: false),
      );
      elapsed += const Duration(seconds: 50);
      await handler.skipToQueueItem(0);
      expect(learning.observations, 1);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  test(
    'initializing and restoring a paused session does not request audio focus',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      final handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
      ).initialize();
      await handler.restoreSession(
        items: [_track],
        index: 0,
        position: const Duration(seconds: 12),
        shuffle: false,
      );
      await _settle();
      expect(session.activations, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
      expect(decks.single.state, PlaybackDeckState.stopped);
    },
  );

  for (final target in [Duration.zero, const Duration(seconds: 7)]) {
    test('seek after restore replaces the saved start with $target', () async {
      final decks = <_Deck>[];
      final store = _SessionStore();
      final handler = await _runtime(
        decks: decks,
        sessionDatabase: store,
      ).initialize();
      await handler.restoreSession(
        items: [_track],
        index: 0,
        position: const Duration(seconds: 30),
        shuffle: false,
      );

      await handler.seek(target);
      expect(handler.playbackState.value.updatePosition, target);
      expect(decks.single.sources, isEmpty);
      expect(decks.single.position, Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);
      expect(store.persistedPositionMs, target.inMilliseconds);

      await handler.play();
      expect(decks.single.position, target);
      expect(handler.playbackState.value.playing, isTrue);
    });
  }

  test(
    'denied audio focus leaves a new source paused and allows retry',
    () async {
      final session = _Session()..focusGranted = false;
      final decks = <_Deck>[];
      final handler = await _runtime(
        session: session,
        decks: decks,
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      expect(decks.single.state, isNot(PlaybackDeckState.playing));
      expect(handler.playbackState.value.playing, isFalse);

      session.focusGranted = true;
      await handler.play();
      expect(decks.single.state, PlaybackDeckState.playing);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.mediaItem.value?.id, _track.id);
    },
  );

  for (final resolved in [
    '/received/Phone song.flac',
    'http://127.0.0.1:1/song.flac',
    'https://example.invalid/song.flac',
  ]) {
    test('a phone song opens its resolved source: $resolved', () async {
      final decks = <_Deck>[];
      final handler = await _runtime(
        decks: decks,
        resolveNetworkSource: (_) async => resolved,
      ).initialize();
      await handler.setQueueAndPlay([
        const PlayableMedia(
          id: 'phone-song',
          source: 'network://example-phone/song.flac',
          title: 'Phone song',
          artist: 'Artist',
        ),
      ]);
      final isStream = resolved.startsWith('http');
      expect(decks.single.sources, [isStream ? 'stream $resolved' : resolved]);
      expect(handler.playbackState.value.playing, isTrue);
    });
  }

  test('a file still arriving plays from its stream until whole', () async {
    final decks = <_Deck>[];
    final runtime = _runtime(decks: decks);
    final handler = await runtime.initialize();
    final arrived = Completer<void>();
    runtime.streamWhileArriving(
      '/one.flac',
      url: 'http://127.0.0.1:1/one.flac',
      done: arrived.future,
    );
    await handler.setQueueAndPlay([_track]);
    // Marked, so AVPlayer starts it without reading to its unwritten end.
    expect(decks.single.sources, ['arriving http://127.0.0.1:1/one.flac']);

    arrived.complete();
    await _settle();
    expect(runtime.arrivingFile('/one.flac'), isNull);
    await handler.skipToQueueItem(0);
    expect(decks.single.sources.last, '/one.flac');
  });

  test(
    'a received file that is gone plays as the phone sends it again',
    () async {
      final decks = <_Deck>[];
      final arrived = Completer<void>();
      late final MusicPlayerRuntime runtime;
      runtime = _runtime(
        decks: decks,
        recoverMissingFile: (path) async {
          // Fetching it again streams it as a phone song arriving does.
          runtime.streamWhileArriving(
            path,
            url: 'http://127.0.0.1:1/one.flac',
            done: arrived.future,
          );
          return 'http://127.0.0.1:1/one.flac';
        },
      );
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track]);
      expect(decks.single.sources, ['arriving http://127.0.0.1:1/one.flac']);
      expect(handler.playbackState.value.playing, isTrue);
      arrived.complete();
    },
  );

  test('a gone file no phone can send fails as unavailable', () async {
    final decks = <_Deck>[];
    final runtime = _runtime(
      decks: decks,
      recoverMissingFile: (_) async =>
          throw const LinkException('unavailable', 'No phone is connected'),
    );
    final handler = await runtime.initialize();
    await handler.setQueueAndPlay([_track]);
    expect(decks.single.sources, isEmpty);
    expect(
      handler.playbackState.value.errorMessage,
      contains('Audio file is unavailable'),
    );
  });

  test('denied or failed audio focus cannot resume a paused source', () async {
    final session = _Session();
    final decks = <_Deck>[];
    final handler = await _runtime(session: session, decks: decks).initialize();
    await handler.setQueueAndPlay([_track]);
    await handler.pause();
    session.focusGranted = false;
    await handler.play();
    expect(decks.single.state, PlaybackDeckState.paused);
    expect(handler.playbackState.value.playing, isFalse);

    session.activationError = PlatformException(code: 'focus-unavailable');
    await handler.play();
    expect(decks.single.state, PlaybackDeckState.paused);
    expect(handler.playbackState.value.playing, isFalse);

    session.activationError = null;
    session.focusGranted = true;
    await handler.play();
    expect(decks.single.state, PlaybackDeckState.playing);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'Android awaits foreground service acknowledgement before resuming',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      Completer<void>? promotion;
      final handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
        synchronizePlaybackState: () async => promotion?.future,
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      await handler.pause();
      session.activations.clear();
      promotion = Completer<void>();
      final resume = handler.play();
      await _settle();
      expect(session.activations, isEmpty);
      expect(decks.single.state, PlaybackDeckState.paused);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      promotion.complete();
      await resume;
      expect(session.activations, [true]);
      expect(decks.single.state, PlaybackDeckState.playing);

      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      expect(decks.single.state, PlaybackDeckState.paused);
      session.activations.clear();
      promotion = Completer<void>();
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _settle();
      expect(session.activations, isEmpty);
      expect(decks.single.state, PlaybackDeckState.paused);
      promotion.complete();
      await _settle();
      expect(session.activations, [true]);
      expect(decks.single.state, PlaybackDeckState.playing);
    },
  );

  test('pause cancels a resume awaiting foreground promotion', () async {
    final session = _Session();
    final decks = <_Deck>[];
    Completer<void>? promotion;
    final handler = await _runtime(
      session: session,
      decks: decks,
      isAndroid: true,
      synchronizePlaybackState: () async => promotion?.future,
    ).initialize();
    await handler.setQueueAndPlay([_track]);
    await handler.pause();
    session.activations.clear();
    promotion = Completer<void>();
    final resume = handler.play();
    await _settle();
    final pause = handler.pause();
    promotion.complete();
    await Future.wait([resume, pause]);
    expect(session.activations, isEmpty);
    expect(decks.single.state, PlaybackDeckState.paused);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test(
    'foreground promotion failure prevents audio focus and playback',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      final handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
        synchronizePlaybackState: () async =>
            throw PlatformException(code: 'foreground-denied'),
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      expect(session.activations, isEmpty);
      expect(decks.single.state, isNot(PlaybackDeckState.playing));
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test(
    'iOS restores controls across unlock/background without changing track',
    () async {
      const channel = MethodChannel(
        'com.ryanheise.audio_service.client.methods',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => calls.add(call));
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final session = _Session();
      final runtime = _runtime(isIOS: true, session: session);
      final handler = await runtime.initialize();
      await _settle();
      handler.mediaItem.add(_item);
      final state = PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 17),
      );
      handler.playbackState.add(state);
      final configurations = session.configurations;
      for (final lifecycle in [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
      ]) {
        handler.didChangeAppLifecycleState(lifecycle);
        await _settle();
      }
      expect(session.configurations, configurations + 5);
      expect(session.activations, List.filled(5, true));
      expect(
        calls.map((call) => call.method),
        List.filled(5, 'refreshNowPlayingInfo'),
      );
      expect(handler.mediaItem.value, same(_item));
      expect(handler.playbackState.value, same(state));
    },
  );

  test(
    'iOS does not reclaim controls when paused, stopped or interrupted',
    () async {
      final session = _Session();
      final runtime = _runtime(isIOS: true, session: session);
      final handler = await runtime.initialize();
      await _settle();
      final configurations = session.configurations;
      await handler.restoreIosNowPlaying();
      handler.mediaItem.add(_item);
      handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.ready),
      );
      await handler.restoreIosNowPlaying();
      handler.playbackState.add(PlaybackState(playing: true));
      await handler.restoreIosNowPlaying();
      expect(session.configurations, configurations);
      expect(session.activations, isEmpty);

      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      await handler.restoreIosNowPlaying();
      expect(session.activations, isEmpty);
      await handler.dispose();
      await handler.restoreIosNowPlaying();
      expect(session.activations, isEmpty);
    },
  );

  test(
    'iOS recovery cannot activate audio after a pause during configuration',
    () async {
      final session = _Session();
      final handler = await _runtime(
        isIOS: true,
        session: session,
      ).initialize();
      await _settle();
      handler.mediaItem.add(_item);
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      session.configureBarrier = Completer<void>();
      final restore = handler.restoreIosNowPlaying();
      await _settle();
      await handler.pause();
      session.configureBarrier!.complete();
      await restore;
      expect(session.activations, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test(
    'muted start pauses and warns; explicit resume survives source reload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'muted-playback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsString('audio');
      final volume = StreamController<double>.broadcast();
      addTearDown(volume.close);
      final runtime = _runtime(
        settings: const AppSettings(playerMode: 'internal', pauseOnMute: true),
        volumeChanges: volume.stream,
      );
      var warnings = 0;
      final notices = runtime.mutedPlaybackEvents.listen((_) => warnings++);
      addTearDown(notices.cancel);
      final handler = await runtime.initialize();
      volume.add(0);
      await _settle();
      await handler.setQueueAndPlay([
        PlayableMedia(
          id: 'muted',
          source: file.path,
          title: 'Muted',
          artist: '',
        ),
      ]);
      await _settle();
      await _settle();
      expect(handler.mediaItem.value?.id, 'muted');
      expect(handler.playbackState.value.playing, isFalse);
      expect(warnings, 1);

      await handler.play();
      await _settle();
      expect(handler.playbackState.value.playing, isTrue);
      volume.add(0);
      await _settle();
      expect(handler.playbackState.value.playing, isTrue);
      expect(warnings, 1);

      volume.add(0.5);
      await _settle();
      volume.add(0);
      await _settle();
      await _settle();
      expect(handler.playbackState.value.playing, isFalse);
      expect(warnings, 2);
      await handler.pause();
      volume.add(0.5);
      await _settle();
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test(
    'position ticks skip listening updates while flushes retain time',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = _Recorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 1, 23, 59, 50).add(elapsed),
      );
      final handler = await _runtime(recorder: recorder).initialize();
      handler.mediaItem.add(_item);
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      await _settle();
      final updates = recorder.updates;
      for (var tick = 1; tick <= 1200; tick++) {
        elapsed = Duration(milliseconds: tick * 500);
        handler.playbackState.add(
          handler.playbackState.value.copyWith(updatePosition: elapsed),
        );
        if (tick % 20 == 0) await recorder.flush();
      }
      await _settle();
      expect(recorder.updates, updates);
      expect(
        writes.fold<int>(0, (sum, delta) => sum + delta.milliseconds),
        600000,
      );
      expect(writes.fold<int>(0, (sum, delta) => sum + delta.plays), 1);
      expect(writes.first.day, '2026-10-01');
      expect(writes.first.milliseconds, 10000);
      expect(
        writes.skip(1).every((delta) => delta.day == '2026-10-02'),
        isTrue,
      );
    },
  );

  test(
    'listening transitions retain buffering, repeat and metadata semantics',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = _Recorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 1, 23, 59, 50).add(elapsed),
      );
      final handler = await _runtime(recorder: recorder).initialize();
      Future<void> state(bool playing, AudioProcessingState processing) async {
        handler.playbackState.add(
          handler.playbackState.value.copyWith(
            playing: playing,
            processingState: processing,
          ),
        );
        await _settle();
      }

      handler.mediaItem.add(_item);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 5);
      final beforeSeek = recorder.updates;
      handler.playbackState.add(
        handler.playbackState.value.copyWith(
          updatePosition: const Duration(minutes: 10),
        ),
      );
      await _settle();
      expect(recorder.updates, beforeSeek);
      await recorder.flush();
      await state(true, AudioProcessingState.buffering);
      elapsed += const Duration(seconds: 20);
      await state(false, AudioProcessingState.ready);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 25);
      await state(false, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 10);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 10);
      await state(false, AudioProcessingState.ready);
      await state(false, AudioProcessingState.completed);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 35);
      await recorder.flush();
      final beforeMetadata = recorder.updates;
      handler.mediaItem.add(_item.copyWith(title: 'Revised', artist: 'Guest'));
      await _settle();
      expect(recorder.updates, beforeMetadata + 1);
      expect(recorder.latestTrack?.title, 'Revised');
      expect(recorder.latestTrack?.artist, 'Guest');
      recorder.setEnabled(false);
      elapsed += const Duration(seconds: 25);
      await recorder.flush();
      recorder.setEnabled(true);
      elapsed += const Duration(seconds: 5);
      await recorder.flush();
      handler.mediaItem.add(const MediaItem(id: 'two', title: 'Two'));
      await _settle();
      elapsed += const Duration(seconds: 10);
      await recorder.flush();
      final one = writes.where((delta) => delta.track.key == 'one').toList();
      expect(one.fold<int>(0, (sum, delta) => sum + delta.milliseconds), 80000);
      expect(one.fold<int>(0, (sum, delta) => sum + delta.plays), 2);
      expect(one.first.day, '2026-10-01');
      expect(one.first.milliseconds, 5000);
      expect(one.skip(1).every((delta) => delta.day == '2026-10-02'), isTrue);
      expect(writes.last.track.key, 'two');
      expect(writes.last.milliseconds, 10000);
      expect(writes.last.plays, 0);
    },
  );

  test(
    'deletion subscriptions follow handler ownership and scoped overrides',
    () async {
      final events = SourceDeletionEvents();
      late MusicPlayerRuntime first;
      late MusicPlayerRuntime second;
      first = _runtime(
        sourceDeletionEvents: events,
        initialize: (_) async => _DeletionHandler(first),
      );
      second = _runtime(
        sourceDeletionEvents: events,
        initialize: (_) async => _DeletionHandler(second),
      );
      late MusicPlayerRuntime isolated;
      isolated = _runtime(initialize: (_) async => _DeletionHandler(isolated));
      final firstHandler = await first.initialize() as _DeletionHandler;
      final secondHandler = await second.initialize() as _DeletionHandler;
      final isolatedHandler = await isolated.initialize() as _DeletionHandler;
      first.attach(firstHandler); // Reattaching must not subscribe twice.
      await events.publish('/one.flac');
      expect(firstHandler.deletedSources, ['/one.flac']);
      expect(secondHandler.deletedSources, ['/one.flac']);
      expect(isolatedHandler.deletedSources, isEmpty);
      await firstHandler.dispose();
      final replacement = await first.initialize() as _DeletionHandler;
      await events.publish('/two.flac');
      expect(firstHandler.deletedSources, ['/one.flac']);
      expect(replacement.deletedSources, ['/two.flac']);
      expect(secondHandler.deletedSources, ['/one.flac', '/two.flac']);
      await first.dispose();
      await second.dispose();
      await events.publish('/three.flac');
      expect(replacement.deletedSources, ['/two.flac']);
      expect(secondHandler.deletedSources, ['/one.flac', '/two.flac']);
    },
  );

  test(
    'storage deletion removes duplicates and advances every attached player',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'queued-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/one.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final runtimes = [
        _runtime(sourceDeletionEvents: events),
        _runtime(sourceDeletionEvents: events),
      ];
      final removed = PlayableMedia(
        id: 'removed',
        source: file.path,
        title: 'Removed',
        artist: '',
      );
      for (final runtime in runtimes) {
        await (await runtime.initialize()).setQueueAndPlay([
          removed,
          removed,
          _track,
        ]);
      }
      expect(await deleteFile(file.path, deletionEvents: events), isTrue);
      for (final runtime in runtimes) {
        expect(runtime.handler!.queue.value.map((item) => item.id), ['one']);
        expect(runtime.handler!.mediaItem.value?.id, 'one');
        expect(runtime.handler!.playbackState.value.queueIndex, 0);
      }
    },
  );

  test(
    'SAF deletion releases cached playback copies before returning',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cached-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cached = await File(
        '${directory.path}/copy.flac',
      ).writeAsString('audio');
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'safCopyToTemp' => cached.path,
          'safDelete' => true,
          _ => null,
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = SourceDeletionEvents();
      final runtime = _runtime(sourceDeletionEvents: events);
      final handler = await runtime.initialize();
      const source = 'content://test.provider/document/song.flac';
      const removed = PlayableMedia(
        id: 'removed',
        source: source,
        title: 'Removed',
        artist: '',
        artUri: 'https://example.com/cover.jpg',
      );
      await handler.setQueueAndPlay([removed, _track]);
      expect(await cached.exists(), isTrue);
      expect(await deleteFile(source, deletionEvents: events), isTrue);
      expect(await cached.exists(), isFalse);
      expect(handler.queue.value.map((item) => item.id), ['one']);
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  test('failed player stop cannot undo a confirmed storage deletion', () async {
    final directory = await Directory.systemTemp.createTemp('failed-reaction-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/song.flac',
    ).writeAsString('audio');
    final events = SourceDeletionEvents();
    final decks = <_Deck>[];
    final runtime = _runtime(decks: decks, sourceDeletionEvents: events);
    final handler = await runtime.initialize();
    await handler.setQueueAndPlay([
      PlayableMedia(
        id: 'removed',
        source: file.path,
        title: 'Removed',
        artist: '',
      ),
    ]);
    decks.single.failStop = true;
    expect(await deleteFile(file.path, deletionEvents: events), isTrue);
    expect(await file.exists(), isFalse);
    expect(handler.queue.value, isEmpty);
  });

  test(
    'deletion retires a pending SAF copy without blocking a later copy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pending-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final stale = await File(
        '${directory.path}/stale.flac',
      ).writeAsString('old');
      final replacement = await File(
        '${directory.path}/new.flac',
      ).writeAsString('new');
      final copying = Completer<void>();
      final release = Completer<String>();
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var copies = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'safDelete') return true;
        if (call.method != 'safCopyToTemp') return null;
        if (++copies > 1) return replacement.path;
        copying.complete();
        return release.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = SourceDeletionEvents();
      final handler = await _runtime(sourceDeletionEvents: events).initialize();
      const source = 'content://test.provider/document/pending.flac';
      const removed = PlayableMedia(
        id: 'removed',
        source: source,
        title: 'Removed',
        artist: '',
        artUri: 'https://example.com/cover.jpg',
      );
      final playing = handler.setQueueAndPlay([removed]);
      await copying.future;
      try {
        expect(
          await deleteFile(
            source,
            deletionEvents: events,
          ).timeout(const Duration(seconds: 1)),
          isTrue,
        );
        expect(handler.queue.value, isEmpty);
      } finally {
        release.complete(stale.path);
      }
      final restarted = handler.setQueueAndPlay([removed]);
      await playing;
      await restarted;
      expect(copies, 2);
      expect(await stale.exists(), isFalse);
      expect(await replacement.exists(), isTrue);
      expect(handler.mediaItem.value?.id, 'removed');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'player metadata follows playback after restoring the last session',
    () async {
      final runtime = _runtime();
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);
      final titles = <String?>[];
      final subscription = container.listen(currentMediaItemProvider, (
        _,
        next,
      ) {
        if (next.hasValue) titles.add(next.value?.title);
      });
      addTearDown(subscription.close);
      await container.read(currentMediaItemProvider.future);
      final handler = await runtime.initialize();
      const second = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Other',
        duration: Duration(seconds: 60),
      );
      await handler.restoreSession(
        items: [_track, second],
        index: 0,
        position: const Duration(seconds: 15),
        shuffle: false,
      );
      await container.pump();
      expect(titles.last, 'One');
      final controller = container.read(musicPlayerControllerProvider);
      await controller.next();
      await container.pump();
      expect(handler.playbackState.value.playing, isTrue);
      expect(titles.last, 'Two');

      await controller.playSingle(_track);
      await container.pump();
      expect(handler.playbackState.value.playing, isTrue);
      expect(titles.last, 'One');
      expect(
        container.read(currentMediaItemProvider).value?.extras?['source'],
        _track.source,
      );
    },
  );

  test(
    'Library shuffle queues downloads and scanned songs in Library order',
    () async {
      const added = '2026-01-01T00:00:00.000Z';
      Map<String, dynamic> row(int i) => {
        'source': i.isEven ? 'downloaded' : 'local',
        'item': {
          'id': 'song-$i',
          'trackName': 'Song $i',
          'artistName': 'Artist',
          'albumName': 'Album',
          // One scanned row has no file to play.
          'filePath': i == 1 ? '' : '/song-$i.flac',
          if (i.isEven) ...{'service': 'extension', 'downloadedAt': added},
          if (i.isOdd) 'scannedAt': added,
        },
      };
      // More than one page of 1,000 songs.
      final library = _QueueLibrary([for (var i = 0; i < 1001; i++) row(i)]);
      final runtime = _runtime(
        settings: const AppSettings(
          pauseOnMute: false,
          localLibraryEnabled: true,
        ),
        libraryDatabase: library,
      );
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);
      final controller = container.read(musicPlayerControllerProvider);

      expect(await controller.shuffleLibrary(), isTrue);
      expect(library.requests.map((request) => request.offset), [0, 1000]);
      expect(library.requests.every((request) => request.includeLocal), true);
      final handler = runtime.handler!;
      final libraryOrder = [
        for (var i = 0; i < 1001; i++)
          if (i != 1) 'song-$i',
      ];
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(handler.queue.value.first.id, handler.mediaItem.value?.id);
      expect(
        handler.queue.value.map((item) => item.id).toSet(),
        libraryOrder.toSet(),
      );

      await controller.setShuffle(false);
      expect(handler.queue.value.map((item) => item.id), libraryOrder);
    },
  );

  test('a media browser plays the album a song was chosen from', () async {
    final runtime = _runtime(
      libraryDatabase: _BrowsedLibrary(),
      historyDatabase: _NoHistory(),
    );
    final handler = await runtime.initialize();

    final album = (await handler.getChildren(
      MediaLibraryBrowser.albumsId,
    )).single;
    final songs = await handler.getChildren(album.id);
    expect(
      [for (final song in songs) song.title],
      ['Song a', 'Song b', 'Song c'],
    );
    await handler.playFromMediaId(songs[1].id);

    expect(handler.queue.value.map((item) => item.id), ['a', 'b', 'c']);
    expect(handler.mediaItem.value?.id, 'b');
    expect(
      handler.playbackState.value.shuffleMode,
      AudioServiceShuffleMode.none,
    );
    // Media resumption offers the song that plays.
    expect(
      (await handler.getChildren(
        AudioService.recentRootId,
      )).map((item) => item.id),
      ['b'],
    );
    // Queue items still play by their own ids.
    await handler.playFromMediaId('c');
    expect(handler.mediaItem.value?.id, 'c');
  });

  test(
    'a spoken request plays what it names and resumes without words',
    () async {
      final runtime = _runtime(
        libraryDatabase: _BrowsedLibrary(),
        historyDatabase: _NoHistory(),
      );
      final handler = await runtime.initialize();

      await handler.playFromSearch('song b');
      expect(handler.queue.value.map((item) => item.id), ['b']);
      expect(handler.playbackState.value.playing, isTrue);

      await handler.pause();
      await handler.playFromSearch('');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.queue.value.map((item) => item.id), ['b']);
    },
  );

  test('the star loves songs until the app shell takes it over', () async {
    final loved = _Loved();
    final runtime = _runtime(
      libraryDatabase: _BrowsedLibrary(),
      historyDatabase: _NoHistory(),
      collectionsDatabase: loved,
    );
    String keyFor(String id) => trackCollectionKey(
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem.fromJson(_BrowsedLibrary.song(id, 1)),
      ).toTrack(),
    );
    final dependencies = runtime.dependencies;
    runtime.configureBackgroundNotification(
      presentation: const PlaybackNotification(),
      favorites: BackgroundFavorites(
        library: dependencies.libraryDatabase,
        history: dependencies.historyDatabase,
        collections: loved,
      ),
    );
    final handler = await runtime.initialize();
    final album = (await handler.getChildren(
      MediaLibraryBrowser.albumsId,
    )).single;
    await handler.playFromMediaId(
      (await handler.getChildren(album.id)).first.id,
    );

    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(loved.keys, {keyFor('a')});
    expect(runtime.notification.mediaId, 'a');
    expect(runtime.notification.loved, isTrue);

    // A song loved earlier shows a filled star when it starts.
    loved.keys.add(keyFor('b'));
    await handler.skipToNext();
    await pumpEventQueue();
    expect(runtime.notification.mediaId, 'b');
    expect(runtime.notification.loved, isTrue);

    final shellToggles = <String>[];
    runtime.configureNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (item) async {
        shellToggles.add(item.id);
        return false;
      },
    );
    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(shellToggles, ['b']);
    expect(loved.keys, contains(keyFor('b')));
    await handler.skipToNext();
    await pumpEventQueue();
    // The background binding no longer follows the playing song.
    expect(runtime.notification.mediaId, 'b');
    expect(runtime.notification.loved, isFalse);
  });

  test(
    'pre-init events have empty values and cancellation never waits for init',
    () async {
      var calls = 0;
      final runtime = _runtime(
        initialize: (builder) async {
          calls++;
          return builder();
        },
      );
      final items = <MediaItem?>[];
      final queues = <List<MediaItem>>[];
      final states = <PlaybackState>[];
      final itemEvents = runtime.mediaItemEvents().listen(items.add);
      final queueEvents = runtime.queueEvents().listen(queues.add);
      final stateEvents = runtime.playbackStateEvents().listen(states.add);
      await _settle();

      expect(items, [null]);
      expect(queues, [isEmpty]);
      expect(states, isEmpty);
      await Future.wait([
        itemEvents.cancel(),
        queueEvents.cancel(),
        stateEvents.cancel(),
      ]).timeout(const Duration(seconds: 1));
      expect(calls, 0);
      await runtime.initialize();
      await _settle();
      expect(items, [null]);
      expect(queues, [isEmpty]);
      expect(states, isEmpty);
    },
  );

  test(
    'pending init is deduplicated and uses the latest live configuration',
    () async {
      final ready = Completer<MusicPlayerHandler>();
      final volume = StreamController<double>.broadcast();
      addTearDown(volume.close);
      var calls = 0;
      late MusicPlayerHandler created;
      final runtime = _runtime(
        volumeChanges: volume.stream,
        initialize: (builder) {
          calls++;
          created = builder();
          return ready.future;
        },
      );
      final items = <MediaItem?>[];
      final events = runtime.mediaItemEvents().listen(items.add);
      addTearDown(events.cancel);
      runtime.configure(runtime.settings.copyWith(autoMix: true));
      final first = runtime.initialize();
      expect(runtime.initialize(), same(first));
      await _settle();
      expect(calls, 1);
      expect(runtime.handler, isNull);
      expect(volume.hasListener, isFalse);
      runtime.configure(runtime.settings.copyWith(pauseOnMute: true));
      created.mediaItem.add(_item);
      await _settle();
      expect(volume.hasListener, isTrue);
      expect(items, [null]);
      ready.complete(created);
      expect(await first, same(created));
      expect(await runtime.initialize(), same(created));
      await _settle();
      expect(items, [null, _item]);
      expect(calls, 1);
      expect(runtime.settings.autoMix, isTrue);
      await runtime.dispose();
      expect(volume.hasListener, isFalse);
    },
  );

  test('failed initialization releases its handler and can retry', () async {
    var calls = 0;
    final decks = <_Deck>[];
    final runtime = _runtime(
      decks: decks,
      initialize: (builder) async {
        final handler = builder();
        if (++calls == 1) throw StateError('Initialization failed');
        return handler;
      },
    );
    await expectLater(runtime.initialize(), throwsStateError);
    expect(
      LogBuffer().entries.any(
        (entry) =>
            entry.tag == 'MusicPlayerRuntime' &&
            entry.level == 'ERROR' &&
            entry.message == 'Failed to initialize playback' &&
            entry.error?.contains('Initialization failed') == true,
      ),
      isTrue,
    );
    expect(runtime.handler, isNull);
    expect(decks.single.disposals, 1);
    final retried = await runtime.initialize();
    expect(runtime.handler, same(retried));
    expect(calls, 2);
    await runtime.dispose();
    expect(decks.map((deck) => deck.disposals), [1, 1]);
  });

  test(
    'deck construction failure leaves no partial handler and can retry',
    () async {
      var calls = 0;
      final deck = _Deck();
      final runtime = _runtime(
        createDeck: (_) {
          if (++calls == 1) throw StateError('Deck creation failed');
          return deck;
        },
      );
      await expectLater(runtime.initialize(), throwsStateError);
      expect(runtime.handler, isNull);
      final handler = await runtime.initialize();
      expect(runtime.handler, same(handler));
      expect(calls, 2);
      await runtime.dispose();
      expect(deck.disposals, 1);
    },
  );

  test('an initializer returning a disposed handler can retry', () async {
    var calls = 0;
    final runtime = _runtime(
      initialize: (builder) async {
        final handler = builder();
        if (++calls == 1) await handler.dispose();
        return handler;
      },
    );
    await expectLater(runtime.initialize(), throwsStateError);
    final handler = await runtime.initialize();
    expect(runtime.handler, same(handler));
    expect(handler.isDisposed, isFalse);
    expect(calls, 2);
  });

  test(
    'runtime disposal retires a pending handler and closes its events',
    () async {
      final ready = Completer<MusicPlayerHandler>();
      final decks = <_Deck>[];
      late MusicPlayerHandler created;
      final runtime = _runtime(
        decks: decks,
        initialize: (builder) {
          created = builder();
          return ready.future;
        },
      );
      final closed = Completer<void>();
      final events = runtime.mediaItemEvents().listen(
        (_) {},
        onDone: closed.complete,
      );
      addTearDown(events.cancel);
      final pending = runtime.initialize();
      final failed = expectLater(pending, throwsStateError);
      await _settle();
      final disposed = runtime.dispose();
      expect(runtime.dispose(), same(disposed));
      expect(created.isDisposed, isTrue);
      expect(runtime.handler, isNull);
      ready.complete(created);
      await failed;
      await disposed;
      await closed.future.timeout(const Duration(seconds: 1));
      expect(decks.single.disposals, 1);
      await expectLater(runtime.initialize(), throwsStateError);
    },
  );

  test(
    'a delayed builder cannot create playback resources after disposal',
    () async {
      final build = Completer<void>();
      final decks = <_Deck>[];
      final runtime = _runtime(
        decks: decks,
        initialize: (builder) async {
          await build.future;
          return builder();
        },
      );
      final failed = expectLater(runtime.initialize(), throwsStateError);
      await _settle();
      final disposed = runtime.dispose();
      build.complete();
      await failed;
      await disposed;
      expect(runtime.handler, isNull);
      expect(decks, isEmpty);
    },
  );

  test(
    'event subscribers follow a replacement and ignore the retired handler',
    () async {
      final runtime = _runtime();
      final items = <MediaItem?>[];
      final queues = <List<MediaItem>>[];
      final itemEvents = runtime.mediaItemEvents().listen(items.add);
      final queueEvents = runtime.queueEvents().listen(queues.add);
      addTearDown(itemEvents.cancel);
      addTearDown(queueEvents.cancel);
      final first = await runtime.initialize();
      first.mediaItem.add(_item);
      first.queue.add([_item]);
      await _settle();
      expect(items.last, _item);
      expect(queues.last, [_item]);
      await first.dispose();
      await _settle();
      expect(items.last, isNull);
      expect(queues.last, isEmpty);
      first.mediaItem.add(const MediaItem(id: 'stale', title: 'Stale'));
      first.queue.add([_item]);
      final second = await runtime.initialize();
      const replacement = MediaItem(id: 'two', title: 'Two');
      second.mediaItem.add(replacement);
      second.queue.add([replacement]);
      await _settle();
      expect(items.last, replacement);
      expect(queues.last, [replacement]);
      expect(items.whereType<MediaItem>().map((item) => item.id), [
        'one',
        'two',
      ]);
    },
  );

  test(
    'provider scopes isolate transport settings and notification favorites',
    () async {
      final firstDecks = <_Deck>[];
      final secondDecks = <_Deck>[];
      final first = _runtime(
        decks: firstDecks,
        settings: const AppSettings(
          pauseOnMute: false,
          playbackNormalization: true,
        ),
      );
      final second = _runtime(
        decks: secondDecks,
        settings: const AppSettings(
          pauseOnMute: false,
          usbBitPerfect: true,
          usbDirect: true,
          usbDsdOverPcm: true,
          usbAllowFixedVolume: true,
          dapExclusive: true,
        ),
      );
      final containers = [
        for (final runtime in [first, second])
          ProviderContainer(
            overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
          ),
      ];
      for (final container in containers) {
        addTearDown(container.dispose);
        await container.read(musicPlayerControllerProvider).playSingle(_track);
      }
      expect(firstDecks.single.state, PlaybackDeckState.playing);
      expect(secondDecks.single.state, PlaybackDeckState.playing);
      expect(firstDecks.single.volumes.last, closeTo(0.501, 0.001));
      expect(secondDecks.single.volumes.last, 1);
      expect(firstDecks.single.outputOptions!.values, everyElement(isFalse));
      expect(secondDecks.single.outputOptions!.values, everyElement(isTrue));
      final toggled = <String>[];
      first.configureNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          toggled.add('first:${item.id}');
          return true;
        },
      );
      second.configureNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          toggled.add('second:${item.id}');
          return false;
        },
      );
      await first.handler!.customAction(PlaybackNotification.favoriteAction);
      expect(first.notification.loved, isTrue);
      expect(second.notification.loved, isFalse);
      await second.handler!.customAction(PlaybackNotification.favoriteAction);
      expect(toggled, ['first:one', 'second:one']);
      expect(
        first.handler!.playbackState.value.controls.first.label,
        'Remove from favorites',
      );
      expect(
        second.handler!.playbackState.value.controls.first.label,
        'Favorite',
      );
      // A pre-amp change reaches the playing track without a restart.
      first.configure(first.settings.copyWith(playbackNormalizationPreamp: -6));
      await _settle();
      expect(firstDecks.single.volumes.last, closeTo(0.251, 0.001));
      first.configure(first.settings.copyWith(playbackNormalization: false));
      await _settle();
      expect(firstDecks.single.volumes.last, 1);
      expect(second.settings.usbBitPerfect, isTrue);
      expect(secondDecks.single.volumes, [1]);
    },
  );
}
