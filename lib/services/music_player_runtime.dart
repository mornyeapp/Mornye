import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/alsa_output_devices.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/exclusive_output_deck.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/background_favorites.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/cast_playback_deck.dart';
import 'package:mornye/services/discord_presence_service.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/download_file_recovery.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:mornye/services/media_session_art_cache.dart';
import 'package:mornye/services/media_session_desktop.dart';
import 'package:mornye/services/media_session_filter.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_playback_cache.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/services/playback_output_volume.dart';
import 'package:mornye/services/player_widget_service.dart';
import 'package:mornye/services/remote_media_session.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/services/song_analysis.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/services/system_volume_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/file_access.dart' show fileExists;

final _log = AppLogger('MusicPlayerRuntime');

/// The handler the system media session talks to, and the player it shows
/// unless a remote device plays in its place.
({SwitchAudioHandler session, MusicPlayerHandler local})? _systemSession;

/// The process services used by a player. Tests can replace effects without
/// changing the queue, transport, interruption or automation algorithms.
class PlaybackDependencies {
  const PlaybackDependencies({
    this.createDeck = _createDeck,
    this.createCastDeck = _createCastDeck,
    this.createPreviewDeck = _createPreviewDeck,
    this.audioSession = _getAudioSession,
    this.readMetadata = PlatformBridge.readFileMetadata,
    this.readNetworkMetadata = _readNetworkMetadata,
    this.resolveNetworkSource = _resolveNetworkSource,
    this.offlineCopy = _offlineCopy,
    this.networkCache = _networkCache,
    this.networkSourceReachable = _networkSourceReachable,
    this.recoverMissingFile = _recoverMissingFile,
    this.recoverMovedDownload = _recoverMovedDownload,
    this.initializeHandler = _initializeAudioHandler,
    this.synchronizePlaybackState = _synchronizePlaybackState,
    this.createPersonalization = AutoplayPersonalization.new,
    this.createTaste = AutoplayTaste.new,
    this.createRanker = AutoplayRanker.new,
    this.createSongAnalysis = _createSongAnalysis,
    AppStateDatabase? sessionDatabase,
    LibraryDatabase? libraryDatabase,
    HistoryDatabase? historyDatabase,
    LibraryCollectionsDatabase? collectionsDatabase,
    ListeningRecorder? recorder,
    CoverStore? coverStore,
    SourceDeletionEvents? sourceDeletionEvents,
    SourceMetadataEvents? sourceMetadataEvents,
    Stream<double>? volumeChanges,
    bool? isIOS,
    bool? isAndroid,
    this.notificationChannel = const MethodChannel(
      'com.zarz.mornye/playback_notification',
    ),
  }) : _sessionDatabase = sessionDatabase,
       _libraryDatabase = libraryDatabase,
       _historyDatabase = historyDatabase,
       _collectionsDatabase = collectionsDatabase,
       _recorder = recorder,
       _coverStore = coverStore,
       _sourceDeletionEvents = sourceDeletionEvents,
       _sourceMetadataEvents = sourceMetadataEvents,
       _volumeChanges = volumeChanges,
       _isIOS = isIOS,
       _isAndroid = isAndroid;

  final PlaybackDeck Function(String playerId) createDeck;
  final PlaybackDeck Function(CastOutput output, MediaItem? Function() metadata)
  createCastDeck;

  /// The search and catalog preview player.
  final PlaybackDeck Function(String playerId) createPreviewDeck;
  final Future<AudioSession> Function() audioSession;
  final Future<Map<String, dynamic>> Function(String, {String? displayName})
  readMetadata;
  final Future<Map<String, dynamic>> Function(String) readNetworkMetadata;
  final Future<String> Function(String) resolveNetworkSource;
  final Future<String?> Function(String) offlineCopy;

  /// The local copies of network songs around the one playing; null plays
  /// every network song from its server.
  final NetworkPlaybackCache? Function() networkCache;

  /// Whether a `network://` Library song can play now, as autoplay asks
  /// before queueing it.
  final Future<bool> Function(String) networkSourceReachable;

  /// What plays in place of a local song file that is gone but can be
  /// fetched again, such as a song a paired phone sent that the received
  /// folder pruned: a path, or a URL streaming it as it arrives. Null for
  /// any other path; throws when it cannot be fetched.
  final Future<String?> Function(String) recoverMissingFile;
  final Future<String?> Function(
    String source,
    String historyId,
    AppSettings settings,
  )
  recoverMovedDownload;
  final Future<MusicPlayerHandler> Function(MusicPlayerHandler Function())
  initializeHandler;
  final Future<void> Function() synchronizePlaybackState;
  final MethodChannel notificationChannel;
  final AutoplayPersonalization Function() createPersonalization;
  final AutoplayTaste Function() createTaste;
  final AutoplayRanker Function() createRanker;

  /// Analysis of how the Library's songs sound, reading songs from it.
  final SongAnalysis Function(LibraryDatabase library) createSongAnalysis;
  final AppStateDatabase? _sessionDatabase;
  final LibraryDatabase? _libraryDatabase;
  final HistoryDatabase? _historyDatabase;
  final LibraryCollectionsDatabase? _collectionsDatabase;
  final ListeningRecorder? _recorder;
  final CoverStore? _coverStore;
  final SourceDeletionEvents? _sourceDeletionEvents;
  final SourceMetadataEvents? _sourceMetadataEvents;
  final Stream<double>? _volumeChanges;
  final bool? _isIOS, _isAndroid;

  AppStateDatabase get sessionDatabase =>
      _sessionDatabase ?? AppStateDatabase.instance;
  LibraryDatabase get libraryDatabase =>
      _libraryDatabase ?? LibraryDatabase.instance;
  HistoryDatabase get historyDatabase =>
      _historyDatabase ?? HistoryDatabase.instance;
  LibraryCollectionsDatabase get collectionsDatabase =>
      _collectionsDatabase ?? LibraryCollectionsDatabase.instance;
  ListeningRecorder get recorder => _recorder ?? listeningRecorder;
  CoverStore get coverStore => _coverStore ?? CoverStore.instance;
  SourceDeletionEvents get sourceDeletionEvents =>
      _sourceDeletionEvents ?? SourceDeletionEvents.instance;
  SourceMetadataEvents get sourceMetadataEvents =>
      _sourceMetadataEvents ?? SourceMetadataEvents.instance;
  Stream<double> get volumeChanges =>
      _volumeChanges ?? SystemVolumeService.instance.changes;
  bool get isIOS => _isIOS ?? Platform.isIOS;
  bool get isAndroid => _isAndroid ?? Platform.isAndroid;

  // Windows and Linux play through libmpv. Without the library they fall
  // back to audioplayers, which has no equalizer there. macOS plays through
  // AVPlayer and moves to libmpv for exclusive output (hog mode).
  static PlaybackDeck _createDeck(String playerId) {
    if (playbackEngine == PlaybackEngine.mediaKit &&
        MediaKitPlaybackDeck.isAvailable) {
      return MediaKitPlaybackDeck(playerId: playerId);
    }
    final shared = AudioplayersPlaybackDeck(playerId: playerId);
    if (!isDesktopPlatform || defaultTargetPlatform != TargetPlatform.macOS) {
      return shared;
    }
    return ExclusiveOutputDeck(
      shared: shared,
      createExclusive: () => MediaKitPlaybackDeck(playerId: playerId),
      exclusiveAvailable: () => MediaKitPlaybackDeck.isAvailable,
    );
  }

  static PlaybackDeck _createCastDeck(
    CastOutput output,
    MediaItem? Function() metadata,
  ) => CastPlaybackDeck(output: output, metadata: metadata);

  // Previews follow the in-app volume on desktop. Mobile previews keep
  // playing without the equalizer.
  static PlaybackDeck _createPreviewDeck(String playerId) => isDesktopPlatform
      ? _createDeck(playerId)
      : AudioplayersPlaybackDeck(playerId: playerId, equalizerAvailable: false);
  static Future<AudioSession> _getAudioSession() => AudioSession.instance;
  static SongAnalysis _createSongAnalysis(LibraryDatabase library) =>
      SongAnalysis(library: library);
  static Future<Map<String, dynamic>> _readNetworkMetadata(String source) =>
      NetworkMetadataService.instance.read(source);
  static Future<String> _resolveNetworkSource(String source) =>
      NetworkStorageService.instance.resolve(source);
  static Future<String?> _offlineCopy(String source) async {
    final row = await HistoryDatabase.instance.findOfflineCopy(source);
    final path = row?['filePath'] as String?;
    return path != null && await fileExists(path) ? path : null;
  }

  static NetworkPlaybackCache? _networkCache() => NetworkPlaybackCache.instance;

  static Future<bool> _networkSourceReachable(String source) =>
      NetworkStorageService.instance.reachable(source);
  static Future<String?> _recoverMissingFile(String path) async {
    final sources = NetworkStorageService.instance.virtualSources;
    return sources is NetworkLocalCopies ? sources.recover(path) : null;
  }

  static Future<String?> _recoverMovedDownload(
    String source,
    String historyId,
    AppSettings settings,
  ) => DownloadFileRecovery.instance.recover(
    source,
    historyId: historyId,
    settings: settings,
  );

  static Future<void> _synchronizePlaybackState() async {
    // The session's switch takes each state from the player a microtask
    // later; let the one just published reach it first.
    await Future<void>.delayed(Duration.zero);
    await AudioService.synchronizePlaybackState();
  }

  static Future<MusicPlayerHandler> _initializeAudioHandler(
    MusicPlayerHandler Function() builder,
  ) async {
    // MPRIS on Linux and SMTC on Windows; other OSes keep the plugin and
    // send it only the states their sessions cannot advance themselves.
    installDesktopMediaSession();
    installMediaSessionFilter();
    late final MusicPlayerHandler handler;
    final session = await AudioService.init(
      // The switch lets a remote device take over the system session.
      builder: () => SwitchAudioHandler(handler = builder()),
      cacheManager: mediaSessionArtCache(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.zarz.mornye.playback',
        androidNotificationChannelName: 'Playback',
        // The notification mark omits the adaptive launcher's safe-zone padding.
        androidNotificationIcon: 'drawable/ic_notification_mornye',
        artDownscaleWidth: 512,
        artDownscaleHeight: 512,
        // Keep background resume eligible for audio focus. The Android fork
        // releases the CPU wake lock on pause and demotes the service on stop.
        androidStopForegroundOnPause: false,
        androidBrowsableRootExtras: MediaLibraryBrowser.rootExtras,
      ),
    );
    _systemSession = (session: session, local: handler);
    return handler;
  }
}

/// Owns a player lifetime and its latest immutable settings. Configuration is
/// available before lazy initialization and remains live while it is pending.
class MusicPlayerRuntime {
  MusicPlayerRuntime({
    AppSettings settings = const AppSettings(),
    this.dependencies = const PlaybackDependencies(),
  }) : _settings = settings;

  final PlaybackDependencies dependencies;
  LastfmService? _lastfm;
  LastfmService get lastfm => _lastfm ??= LastfmService();
  AutoplayPersonalization? _personalization;
  // What learning observes also teaches [taste] what plays together and
  // [ranker] how much each part of a score counts.
  AutoplayPersonalization get personalization =>
      _personalization ??= (dependencies.createPersonalization()
        ..feedback.listen(taste.record)
        ..feedback.listen(ranker.record));
  AutoplayTaste? _taste;
  AutoplayTaste get taste => _taste ??= dependencies.createTaste();
  AutoplayRanker? _ranker;
  AutoplayRanker get ranker => _ranker ??= dependencies.createRanker();
  SongAnalysis? _songAnalysis;

  /// How the Library's songs sound, analyzed in the background for Autoplay.
  SongAnalysis get songAnalysis =>
      _songAnalysis ??= dependencies.createSongAnalysis(
        dependencies.libraryDatabase,
      )..configure(_settings);
  AppSettings _settings;
  MusicPlayerHandler? _handler;
  void Function()? _unsubscribeSourceDeletion;
  void Function()? _unsubscribeSourceMetadata;
  Future<MusicPlayerHandler>? _initFuture;
  Future<void>? _restoreFuture;
  final _handlers = StreamController<MusicPlayerHandler?>.broadcast(sync: true);
  final _mutedPlaybackEvents = StreamController<void>.broadcast();
  bool _initializing = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  String _unknownTitle = 'Unknown title', _unknownArtist = 'Unknown artist';
  PlaybackNotification _notification = const PlaybackNotification();
  Future<bool> Function(MediaItem)? _toggleFavorite;
  StreamSubscription<MediaItem?>? _backgroundFavorites;
  Future<void> Function()? exclusiveAudioHook;
  RemotePlayback? _remote;
  RemoteMediaSession? _remoteSession;
  final _arriving = <String, ({String url, Future<void> done})>{};
  bool _coversPrepared = false;
  static const _coverTrimDelay = Duration(minutes: 2);

  /// The Library that media browsers such as Android Auto show.
  late final browser = MediaLibraryBrowser(
    library: dependencies.libraryDatabase,
    history: dependencies.historyDatabase,
    collections: dependencies.collectionsDatabase,
    includeLocal: () => _settings.localLibraryEnabled,
    strings: () => appLocalizationsFor(_settings.locale),
    covers: dependencies.coverStore,
  );

  AppSettings get settings => _settings;
  MusicPlayerHandler? get handler => _initializing ? null : _handler;
  String get unknownTitle => _unknownTitle;
  String get unknownArtist => _unknownArtist;
  PlaybackNotification get notification => _notification;

  // Transient feedback is never replayed when a screen or app shell reopens.
  Stream<void> get mutedPlaybackEvents => _mutedPlaybackEvents.stream;

  void notifyMutedPlayback() {
    if (!_disposed) _mutedPlaybackEvents.add(null);
  }

  /// Feeds the exclusive output setting to the decks.
  void _configureExclusiveOutput(AppSettings settings) {
    final exclusive = settings.exclusiveOutput && isDesktopPlatform;
    if (!exclusive) {
      playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;
    } else if (!playbackExclusiveOutput.value) {
      // Stop a playing preview before its deck would reopen the output too.
      unawaited(exclusiveAudioHook?.call());
    }
    if (exclusive && defaultTargetPlatform == TargetPlatform.linux) {
      final device = settings.exclusiveOutputDevice;
      if (device.isNotEmpty) {
        playbackExclusiveDevice.value = device;
      } else {
        // No choice yet: the first card, as ALSA's own default.
        unawaited(
          listAlsaOutputDevices().then((devices) {
            if (devices.isNotEmpty && _settings.exclusiveOutputDevice.isEmpty) {
              playbackExclusiveDevice.value = devices.first.id;
            }
          }),
        );
      }
    }
    playbackExclusiveOutput.value = exclusive;
  }

  void configure(AppSettings settings) {
    final previous = _settings;
    _settings = settings;
    _configureExclusiveOutput(settings);
    _songAnalysis?.configure(settings);
    _handler?.applySettings(previous);
    if (previous.playerMode == 'internal' &&
        settings.playerMode != 'internal') {
      _restoreFuture = null;
      final handler = _handler;
      if (handler != null) {
        unawaited(
          handler.stop(keepResume: true).catchError((
            Object error,
            StackTrace stack,
          ) {
            _log.e('Failed to stop the internal player', error, stack);
          }),
        );
      }
    }
  }

  /// Starts analyzing Library songs in the background, and the song playing
  /// soon after it starts.
  void startSongAnalysis() {
    if (!_disposed) songAnalysis.start(mediaItemEvents());
  }

  /// Reads which network covers are stored, so songs show theirs from the
  /// start, then trims the stored covers once, a while later.
  void prepareCovers() {
    if (_coversPrepared || _disposed) return;
    _coversPrepared = true;
    final covers = dependencies.coverStore;
    unawaited(
      () async {
        await covers.warmUp();
        await Future<void>.delayed(_coverTrimDelay);
        if (!_disposed) await covers.trim();
      }().catchError((Object error) {
        _log.w('Could not trim stored covers: $error');
      }),
    );
  }

  void updateStrings({
    required String unknownTitle,
    required String unknownArtist,
  }) {
    _unknownTitle = unknownTitle;
    _unknownArtist = unknownArtist;
  }

  /// Media controls for playback that started while the app shell is closed,
  /// such as from a car. Its star loves songs through [favorites] and shows
  /// whether the current song is loved, until the shell configures them.
  void configureBackgroundNotification({
    required PlaybackNotification presentation,
    required BackgroundFavorites favorites,
  }) {
    if (_toggleFavorite != null || _disposed) return;
    _notification = presentation;
    _toggleFavorite = favorites.toggle;
    _handler?.refreshNotificationControls();
    ({String id, Object? source})? shown;
    _backgroundFavorites = mediaItemEvents().listen((item) async {
      final current = item == null
          ? null
          : (id: item.id, source: item.extras?['source']);
      if (item == null || current == shown) return;
      shown = current;
      try {
        final loved = await favorites.isLoved(item);
        if (_backgroundFavorites != null && shown == current) {
          updateFavorite(item, loved);
        }
      } catch (error) {
        _log.w('Could not read whether the song is loved: $error');
      }
    });
  }

  void configureNotification({
    required PlaybackNotification presentation,
    required Future<bool> Function(MediaItem) toggleFavorite,
  }) {
    unawaited(_backgroundFavorites?.cancel());
    _backgroundFavorites = null;
    _notification = presentation;
    _toggleFavorite = toggleFavorite;
    _handler?.refreshNotificationControls();
    if (dependencies.isIOS) {
      dependencies.notificationChannel.setMethodCallHandler((call) async {
        if (call.method == 'favorite') {
          await _handler?.customAction(PlaybackNotification.favoriteAction);
        }
      });
      unawaited(_publishNotificationFavorite());
    }
  }

  Future<bool?> toggleFavorite(MediaItem item) async =>
      _toggleFavorite?.call(item);

  void updateFavorite(MediaItem item, bool loved) {
    _notification = _notification.withFavorite(item, loved);
    _handler?.refreshNotificationControls();
    if (dependencies.isIOS) unawaited(_publishNotificationFavorite());
  }

  Future<void> _publishNotificationFavorite() async {
    try {
      await dependencies.notificationChannel.invokeMethod<void>('update', {
        'enabled': _notification.mornye && _notification.mediaId != null,
        'loved': _notification.loved,
        'label': _notification.favoriteActionLabel,
      });
    } on MissingPluginException {
      // Tests do not install the iOS remote-command bridge.
    } on PlatformException catch (error) {
      _log.w('Could not update the system favorite action: ${error.code}');
    }
  }

  void attach(MusicPlayerHandler handler) {
    if (_disposed) throw StateError('This playback runtime was disposed');
    final existing = _handler;
    if (existing != null && !identical(existing, handler)) {
      throw StateError('This playback runtime already owns a handler');
    }
    _handler = handler;
    if (!identical(existing, handler)) {
      _unsubscribeSourceDeletion = dependencies.sourceDeletionEvents.subscribe(
        handler.onSourceDeleted,
      );
      _unsubscribeSourceMetadata = dependencies.sourceMetadataEvents.subscribe(
        handler.onSourceMetadataChanged,
      );
    }
    if (!_initializing && !identical(existing, handler)) _handlers.add(handler);
  }

  void detach(MusicPlayerHandler handler) {
    if (!identical(_handler, handler)) return;
    _lastfm?.bind(null);
    _unsubscribeSourceDeletion?.call();
    _unsubscribeSourceDeletion = null;
    _unsubscribeSourceMetadata?.call();
    _unsubscribeSourceMetadata = null;
    _handler = null;
    _restoreFuture = null;
    if (!_handlers.isClosed) _handlers.add(null);
  }

  Future<MusicPlayerHandler> initialize() {
    if (_disposed) {
      return Future.error(StateError('This playback runtime was disposed'));
    }
    final pending = _initFuture;
    if (pending != null) return pending;
    final existing = _handler;
    if (existing != null) return Future.value(existing);
    return _initFuture = _initialize();
  }

  Future<MusicPlayerHandler> _initialize() async {
    _initializing = true;
    MusicPlayerHandler? created;
    try {
      // Defer even a synchronous test initializer until _initFuture is stored.
      await Future<void>.value();
      // Desktop decks start at the in-app volume the listener left.
      if (isDesktopPlatform) await PlaybackOutputVolumeStore.ensureRestored();
      final handler = await dependencies.initializeHandler(() {
        if (_disposed) throw StateError('This playback runtime was disposed');
        return created = MusicPlayerHandler(runtime: this);
      });
      if (_disposed || handler.isDisposed || !identical(_handler, handler)) {
        throw StateError(
          'Playback initialization returned an inactive handler',
        );
      }
      _initializing = false;
      _handlers.add(handler);
      if (dependencies.isAndroid || dependencies.isIOS) {
        PlayerWidgetService.instance.bind(handler);
      }
      // Desktop presence goes through the Rust IPC client instead of the SDK.
      if (dependencies.isAndroid || dependencies.isIOS || isDesktopPlatform) {
        DiscordPresenceService.instance.bind(handler);
      }
      if (isDesktopPlatform) {
        lastfm.bind(
          handler,
          unknownTitle: () => unknownTitle,
          unknownArtist: () => unknownArtist,
        );
      }
      return handler;
    } catch (error, stack) {
      _log.e('Failed to initialize playback', error, stack);
      await created?.dispose();
      rethrow;
    } finally {
      _initializing = false;
      _initFuture = null;
    }
  }

  Future<void> restoreSession() {
    if (_settings.playerMode != 'internal') return Future.value();
    return _restoreFuture ??= restorePlaybackSession(this).then<void>((_) {});
  }

  /// [MusicPlayerHandler.recoverRestoredArtwork] after [restoreSession].
  Future<void> recoverRestoredArtwork() async {
    await restoreSession();
    await handler?.recoverRestoredArtwork();
  }

  /// Plays the local file [path], still being written (a song a paired
  /// phone is sending), from [url] until [done] completes, so it starts
  /// before the file is whole.
  void streamWhileArriving(
    String path, {
    required String url,
    required Future<void> done,
  }) {
    final entry = (url: url, done: done);
    _arriving[path] = entry;
    unawaited(
      done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_arriving[path], entry)) _arriving.remove(path);
      }),
    );
  }

  /// The stream and completion of [path] while it is still arriving.
  ({String url, Future<void> done})? arrivingFile(String path) =>
      _arriving[path];

  /// Whether [url] streams a file that is still arriving.
  bool streamsArrivingFile(String url) =>
      _arriving.values.any((entry) => entry.url == url);

  /// Hands the system media session (notification, lock screen, headset and
  /// car buttons) to [remote] while it plays in this device's place, and
  /// back to this device's player when null. A Library song picked in the
  /// car plays here and takes the session back.
  Future<void> showRemote(RemotePlayback? remote) async {
    if (identical(remote, _remote)) return;
    _remote = remote;
    if (remote != null) {
      try {
        await initialize();
      } on Object {
        return;
      }
    }
    if (identical(remote, _remote) && !_disposed) _showSession(remote);
  }

  void _showSession(RemotePlayback? remote) {
    final system = _systemSession;
    if (system == null || !identical(system.local, _handler)) return;
    _remoteSession?.dispose();
    _remoteSession = null;
    system.session.inner = remote == null
        ? system.local
        : _remoteSession = RemoteMediaSession(
            remote,
            local: system.local,
            onLocal: () => _showSession(null),
          );
  }

  /// The default runtime lives for the app lifetime. Scoped runtimes close
  /// subscriptions and reject new initialization when their owner disposes.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _toggleFavorite = null;
    unawaited(_backgroundFavorites?.cancel());
    _backgroundFavorites = null;
    exclusiveAudioHook = null;
    _remoteSession?.dispose();
    _remoteSession = null;
    await _handler?.dispose();
    await _lastfm?.close();
    try {
      await _initFuture;
    } catch (_) {
      // Initialization may have failed because its pending handler was closed.
    }
    await _personalization?.dispose();
    await _taste?.dispose();
    await _ranker?.dispose();
    await _songAnalysis?.dispose();
    await _handlers.close();
    await _mutedPlaybackEvents.close();
  }

  Stream<T> _events<T>(
    Stream<T> Function(MusicPlayerHandler) select, {
    List<T> initial = const [],
  }) => Stream<T>.multi((listener) {
    StreamSubscription<T>? events;
    var revision = 0;
    void selectHandler(MusicPlayerHandler? handler) {
      final selectedRevision = ++revision;
      unawaited(events?.cancel());
      events = null;
      if (handler == null) {
        for (final value in initial) {
          listener.addSync(value);
        }
      } else {
        events = select(handler).listen((value) {
          if (selectedRevision == revision) listener.addSync(value);
        }, onError: listener.addErrorSync);
      }
    }

    // Register first: UI listeners can cancel immediately while initialization
    // is pending, and can follow a replacement handler after disposal.
    final ready = _handlers.stream.listen(
      selectHandler,
      onDone: listener.closeSync,
    );
    selectHandler(handler);
    listener.onCancel = () {
      revision++;
      unawaited(ready.cancel());
      unawaited(events?.cancel());
    };
  });

  Stream<MediaItem?> mediaItemEvents() =>
      _events((handler) => handler.mediaItem, initial: [null]);
  Stream<PlaybackState> playbackStateEvents() =>
      _events((handler) => handler.playbackState);
  Stream<List<MediaItem>> queueEvents() =>
      _events((handler) => handler.queue, initial: [const []]);
}

final musicPlayerRuntime = MusicPlayerRuntime();
