import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:mornye/services/playback_notification.dart';
import 'package:audio_session/audio_session.dart'
    show
        AudioDevice,
        AudioSession,
        AudioSessionConfiguration,
        AudioInterruptionType;
import 'package:mornye/services/listening_statistics.dart' show ListeningTrack;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_normalization.dart';
import 'package:mornye/services/playback_automation.dart';
import 'package:mornye/services/playback_session_writer.dart';
import 'package:mornye/services/content_uri_playback_cache.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/network_storage_service.dart'
    show subsonicSongIdFromPath;
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/automix_phase_lock.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/automix_analyzer.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/automix_effect_renderer.dart';
import 'package:mornye/services/automix_status.dart';
import 'package:mornye/services/music_haptics.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/playback_artwork.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/file_access_check.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/playable_media.dart';

export 'autoplay_signal.dart';
export 'music_player_runtime.dart';
export 'playable_media.dart';
export 'playback_metadata.dart';
export 'playback_session_restore.dart';

part 'music_player_automix.dart';
part 'music_player_autoplay.dart';
part 'music_player_covers.dart';
part 'music_player_gapless.dart';

final _log = AppLogger('MusicPlayer');

/// Muted artwork shares the music session. Recover its Now Playing ownership
/// after video initialization, including failed or abandoned initialization.
Future<void> restoreMusicAudioSessionAfterVideo() async =>
    musicPlayerRuntime.handler?.restoreIosNowPlaying();

/// Gain and rate the player applies to the current track.
class PlaybackProcessing {
  const PlaybackProcessing({
    required this.normalizationGain,
    required this.direct,
    required this.autoMixRate,
  });

  /// Linear volume from ReplayGain normalization; 1 when none applies.
  final double normalizationGain;

  /// A direct USB or exclusive path that bypasses the system mixer and DSP.
  final bool direct;

  /// AutoMix tempo matching; 1 outside a transition.
  final double autoMixRate;
}

/// Refreshes gain tags after a successful file update, including SAF copies.
void refreshPlaybackNormalization(String source) {
  final handler = musicPlayerRuntime.handler;
  if (handler != null) unawaited(handler._refreshNormalizationSource(source));
}

Future<void> notifyPlaybackSourceRelocated(
  String previous,
  String replacement,
) async {
  await musicPlayerRuntime.handler?.onSourceRelocated(previous, replacement);
  await AppStateDatabase.instance.relocatePlaybackSource(previous, replacement);
}

List<int> buildShuffledQueueOrder({
  required int mediaCount,
  required int currentIndex,
  required Random random,
}) {
  final rest = [
    for (var i = 0; i < mediaCount; i++)
      if (i != currentIndex) i,
  ]..shuffle(random);
  return [
    if (currentIndex >= 0 && currentIndex < mediaCount) currentIndex,
    ...rest,
  ];
}

/// Returns a safe source-start position for restored playback. A completed
/// snapshot starts over instead of immediately completing again on resume.
Duration normalizedPlaybackResumePosition(
  Duration position, {
  Duration? duration,
}) {
  if (position <= Duration.zero) return Duration.zero;
  if (duration != null && duration > Duration.zero && position >= duration) {
    return Duration.zero;
  }
  return position;
}

class MusicPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler, WidgetsBindingObserver {
  final MusicPlayerRuntime _runtime;
  PlaybackDependencies get _dependencies => _runtime.dependencies;
  AppSettings get _settings => _runtime.settings;
  late PlaybackDeck _player;
  late final _MusicAutoMix _autoMix;
  late final _MusicGapless _gapless = _MusicGapless(this);
  late final _MusicCovers _covers = _MusicCovers(this);
  late final _MusicAutoplay _autoplay;
  late final MusicHaptics _haptics;
  bool _completing = false;
  double _normalizationVolume = 1;
  final _playerSubscriptions =
      <PlaybackDeck, List<StreamSubscription<dynamic>>>{};
  AudioSession? _audioSession;
  late final PlaybackAutomation _playbackAutomation;
  StreamSubscription<double>? _automationVolumeSubscription;
  StreamSubscription<Set<AudioDevice>>? _automationDevicesSubscription;
  bool _headphoneMonitoringRequested = false;
  int _headphoneMonitoringRevision = 0;
  final List<PlayableMedia> _media = [];
  final List<MediaItem> _queueItems = [];
  late final ContentUriPlaybackCache _sourceCache;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _index = -1;
  int _playRequestGeneration = 0;
  final _metadataChanges = <String, Object>{};
  String? _activeResolvedPath;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  bool _initialized = false;
  bool _sourceReady = false;
  Object? _playbackError;
  int? _checkingPlaybackErrorGeneration;

  /// Reloads of the current song after Android's media server died, and
  /// whether the next [_playIndex] is one of them.
  int _serverDiedReloads = 0;
  bool _reloadingAfterServerDied = false;
  Future<void>? _activePlayOperation;
  Future<void> _sourceChangeTail = Future<void>.value();
  Timer? _sleepTimer;
  Timer? _listeningTimer;
  DateTime? _sleepTimerEndsAt;

  bool _shuffle = false;
  List<MediaItem>? _originalQueueOrder;
  int _shuffleRequestGeneration = 0;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  final Random _random = Random();
  final List<int> _playHistory = [];

  bool _pausedByInterruption = false;
  bool _interruptionActive = false;
  bool _userPaused = false;
  // Position saved with the restored session; applied on the first play().
  Duration? _pendingRestorePosition;
  bool _restoringSession = false;
  int _switchingGeneration = 0;
  Duration _lastBroadcastPosition = Duration.zero;
  DateTime? _lastPositionBroadcastAt;
  DateTime? _lastPeriodicPersistAt;

  /// When the engine read the last published position, and when the last
  /// tick asked it for one, on a clock that wall-clock changes cannot move.
  final Stopwatch _positionClock = autoMixStopwatch()..start();
  Duration? _lastPositionReadAt;
  Duration? _positionQueriedAt;

  /// No engine position has arrived since a forced broadcast.
  bool _positionCheckDue = false;
  late final PlaybackSessionWriter _sessionWriter;
  int get _sessionQueueRevision => _sessionWriter.queueRevision;
  static const Duration _positionBroadcastInterval = Duration(
    milliseconds: 500,
  );
  static const Duration _positionPersistInterval = Duration(seconds: 10);

  /// How early a tick may ask the engine: the answer arrives a platform
  /// round trip later, which can carry it past an interval.
  static const Duration _positionQueryAllowance = Duration(milliseconds: 50);

  DateTime? get sleepTimerEndsAt => _sleepTimerEndsAt;
  bool get isDisposed => _disposed;
  int get playbackRequestGeneration => _playRequestGeneration;

  /// Reconcile only the playback fields affected by the new settings snapshot.
  void applySettings(AppSettings previous) {
    final settings = _settings;
    if (previous.autoplayPersonalization != settings.autoplayPersonalization ||
        previous.playerMode != settings.playerMode) {
      _configurePersonalization();
    }
    if (previous.playbackNormalization != settings.playbackNormalization ||
        previous.playbackNormalizationPreamp !=
            settings.playbackNormalizationPreamp ||
        previous.playbackNormalizationMode !=
            settings.playbackNormalizationMode) {
      reapplyNormalization();
    }
    if (previous.autoMix != settings.autoMix ||
        previous.autoMixOptions != settings.autoMixOptions ||
        previous.usbBitPerfect != settings.usbBitPerfect ||
        previous.exclusiveOutput != settings.exclusiveOutput) {
      unawaited(_autoMix.cancel());
    }
    if (previous.gaplessPlayback != settings.gaplessPlayback ||
        previous.autoMix != settings.autoMix ||
        previous.usbBitPerfect != settings.usbBitPerfect ||
        previous.exclusiveOutput != settings.exclusiveOutput) {
      unawaited(_gapless.cancel());
    }
    // USB changes apply at the next source boundary, without raising volume.
    if ((previous.playerMode == 'internal') !=
            (settings.playerMode == 'internal') ||
        previous.pauseOnMute != settings.pauseOnMute ||
        previous.playOnHeadphonesConnected !=
            settings.playOnHeadphonesConnected ||
        previous.usbBitPerfect != settings.usbBitPerfect) {
      _refreshPlaybackAutomation();
    }
    if (previous.musicHaptics != settings.musicHaptics ||
        previous.musicHapticsSensitivity != settings.musicHapticsSensitivity ||
        previous.musicHapticsStrength != settings.musicHapticsStrength ||
        previous.playerMode != settings.playerMode) {
      _updateHaptics();
    }
    if (previous.autoplay != settings.autoplay ||
        previous.autoplayPersonalization != settings.autoplayPersonalization ||
        previous.localLibraryEnabled != settings.localLibraryEnabled) {
      _autoplay.updateMode();
    }
  }

  MusicPlayerHandler({
    MusicPlayerRuntime? runtime,
    AutoMixAnalyzer? autoMixAnalyzer,
    AutoMixEffectRenderer? autoMixEffectRenderer,
    AutoplayLibraryLoader? autoplayLibraryLoader,
    MusicHapticsAnalyzer? hapticsAnalyzer,
    HapticPulse? hapticPulse,
  }) : _runtime = runtime ?? musicPlayerRuntime {
    // Switching back from a remote session restores phone volume handling.
    androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
    _haptics = MusicHaptics(
      state: () => playbackState.value,
      analyzer: hapticsAnalyzer,
      pulse: hapticPulse,
    );
    _sourceCache = ContentUriPlaybackCache(
      copy: PlatformBridge.copyContentUriToTemp,
      isDisposed: () => _disposed,
      isPinned: (path) =>
          path == _activeResolvedPath ||
          _autoMix.pinnedPaths.contains(path) ||
          _gapless.pinnedPaths.contains(path),
      onResolveError: (error) =>
          _log.e('Failed to resolve content URI for playback: $error'),
      onDeleteError: (error) =>
          _log.w('Failed to delete SAF playback temp file: $error'),
    );
    _sessionWriter = PlaybackSessionWriter(
      database: _dependencies.sessionDatabase,
      onError: (error) =>
          _log.w('Failed to update persisted playback session: $error'),
    );
    _player = _dependencies.createDeck('music-player');
    _normalizationCache = PlaybackNormalizationCache(
      readMetadata: _dependencies.readMetadata,
      onReadError: (error) =>
          _log.w('Failed to read gain tags for normalization: $error'),
    );
    _playbackAutomation = PlaybackAutomation(
      isPlaying: () =>
          _player.state == PlaybackDeckState.playing ||
          playbackState.value.playing,
      canResume: () =>
          !_disposed &&
          !_interruptionActive &&
          _index >= 0 &&
          _index < _media.length,
      pause: _pausePlayback,
      play: play,
      onError: (error) => _log.w('Automatic playback failed: $error'),
      onMutedPause: _runtime.notifyMutedPlayback,
    );
    _autoMix = _MusicAutoMix(
      this,
      autoMixAnalyzer ?? AutoMixAnalyzer(),
      autoMixEffectRenderer ?? AutoMixEffectRenderer(),
    );
    _autoplay = _MusicAutoplay(
      this,
      autoplayLibraryLoader ?? (seed) => loadAutoplayLibrary(seed, _runtime),
    );
    try {
      _init();
      _runtime.attach(this);
    } catch (_) {
      unawaited(dispose());
      rethrow;
    }
  }

  MediaItem _toMediaItem(PlayableMedia media, {String? resolvedSource}) =>
      media.toMediaItem(
        resolvedSource: resolvedSource,
        unknownTitle: _runtime.unknownTitle,
        unknownArtist: _runtime.unknownArtist,
        covers: _dependencies.coverStore,
      );

  void _init() {
    if (_initialized) return;
    _initialized = true;
    _configurePersonalization();
    void recordListening() {
      final item = mediaItem.value;
      final state = playbackState.value;
      _runtime.personalization.updatePlayback(
        source: item?.extras?['source'] as String?,
        duration: item?.duration,
        playing:
            state.playing &&
            state.processingState == AudioProcessingState.ready,
      );
      _dependencies.recorder.update(
        item == null
            ? null
            : ListeningTrack(
                key: item.extras?['source']?.toString() ?? item.id,
                title: item.title,
                artist: item.artist ?? '',
                album: item.album ?? '',
                // A reference that outlasts this run, never a loopback URL
                // or a temporary file.
                artwork: _covers.reference(item),
              ),
        playing:
            state.playing &&
            state.processingState == AudioProcessingState.ready,
        ended:
            state.processingState == AudioProcessingState.completed ||
            state.processingState == AudioProcessingState.idle,
      );
      _scheduleListeningFlushes();
    }

    _subscriptions.add(mediaItem.listen((_) => recordListening()));
    _subscriptions.add(
      playbackState
          .map(
            (state) => (
              state.playing &&
                  state.processingState == AudioProcessingState.ready,
              state.processingState == AudioProcessingState.completed ||
                  state.processingState == AudioProcessingState.idle,
            ),
          )
          .distinct()
          .listen((_) => recordListening()),
    );
    _subscriptions.add(
      playbackState.map((state) => state.playing).distinct().listen((playing) {
        if (playing) unawaited(_playbackAutomation.playbackStarted());
      }),
    );
    _subscriptions.add(mediaItem.listen((_) => _updateHaptics()));
    _subscriptions.add(playbackState.listen((_) => _updateHaptics()));
    _subscriptions.add(
      _dependencies.coverStore.changes.listen(_covers.changed),
    );
    unawaited(_player.configureOutput());
    unawaited(_configureAudioSession());
    _refreshPlaybackAutomation();

    _listenToPlayer(_player);
    if (_dependencies.isIOS) WidgetsBinding.instance.addObserver(this);
  }

  /// Writes listening time every 10 s from the start of playback until a
  /// flush finds the recorder idle, so a failed write, this timer's or
  /// another caller's, is retried within 10 s.
  void _scheduleListeningFlushes() {
    if (_disposed || _dependencies.recorder.idle) return;
    _listeningTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_flushListening());
    });
  }

  Future<void> _flushListening() async {
    final recorder = _dependencies.recorder;
    await recorder.flush();
    if (_disposed || !recorder.idle) return;
    _listeningTimer?.cancel();
    _listeningTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_runtime.personalization.flush());
      unawaited(_runtime.taste.flush());
      unawaited(_runtime.ranker.flush());
    }
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(restoreIosNowPlaying());
    }
  }

  /// Haptics follow only decodable local files; streams have no full copy.
  void _updateHaptics() {
    if (_disposed) return;
    final extras = mediaItem.value?.extras;
    final source = extras?['source']?.toString() ?? '';
    final resolved = extras?['resolvedSource']?.toString().trim() ?? '';
    final document = source.startsWith('content://');
    // Use a stable document identity for both direct playback and AutoMix.
    // Haptics opens its own SAF input; the player's descriptor is short-lived.
    final path = document ? source : (resolved.isNotEmpty ? resolved : source);
    // Desktop has no vibration motor.
    final local =
        !isDesktopPlatform &&
        path.isNotEmpty &&
        (document || !path.contains('://')) &&
        _settings.musicHaptics &&
        _settings.playerMode == 'internal';
    _haptics.configure(
      sensitivity: _settings.musicHapticsSensitivity,
      strength: _settings.musicHapticsStrength,
    );
    _haptics.update(local ? path : null);
  }

  void _configurePersonalization() {
    final enabled =
        _settings.autoplayPersonalization && _settings.playerMode == 'internal';
    _runtime.personalization.setEnabled(enabled);
    if (enabled && _index >= 0 && _index < _media.length) {
      _runtime.personalization.begin(_learningTrack(_media[_index]));
      final state = playbackState.value;
      _runtime.personalization.updatePlayback(
        source: mediaItem.value?.extras?['source'] as String?,
        duration: mediaItem.value?.duration,
        playing:
            state.playing &&
            state.processingState == AudioProcessingState.ready,
      );
    }
  }

  /// Recover system controls without reloading, seeking or restarting audio.
  /// Never reclaim audio focus for a paused/interrupted/stopped player.
  Future<void> restoreIosNowPlaying() async {
    final generation = _playRequestGeneration;
    bool canRestore() =>
        _dependencies.isIOS &&
        !_disposed &&
        generation == _playRequestGeneration &&
        !_interruptionActive &&
        !_userPaused &&
        playbackState.value.playing &&
        playbackState.value.processingState == AudioProcessingState.ready &&
        mediaItem.value != null;
    if (!canRestore()) return;
    try {
      final session = _audioSession ?? await _dependencies.audioSession();
      if (!canRestore()) return;
      await session.configure(const AudioSessionConfiguration.music());
      if (!canRestore()) return;
      if (!await session.setActive(true) || !canRestore()) return;
      await AudioService.refreshNowPlayingInfo();
    } catch (error) {
      _log.w('Could not restore iOS playback controls: $error');
    }
  }

  void _listenToPlayer(PlaybackDeck player) {
    // Position updates must continue with the display asleep. UI progress is
    // interpolated between updates; querying native playback every frame is
    // unnecessary and would stop preparing AutoMix when there are no frames.
    player.startPositionUpdates(
      const Duration(milliseconds: 200),
      wanted: () => _wantsPosition(player),
    );
    _playerSubscriptions[player] = [
      player.onPlayerStateChanged.listen(
        (state) {
          if (!identical(player, _player)) return;
          if (state == PlaybackDeckState.paused && player.needsSourceReload) {
            _userPaused = true;
            _pausedByInterruption = false;
            _playbackAutomation.cancelPendingActions();
          }
          if (_switchingGeneration != 0 &&
              (state == PlaybackDeckState.stopped ||
                  state == PlaybackDeckState.completed ||
                  state == PlaybackDeckState.disposed)) {
            return;
          }
          if (state == PlaybackDeckState.completed && _shouldIgnoreComplete) {
            if (_userPaused || _interruptionActive) {
              _broadcastState(playerState: PlaybackDeckState.paused);
            }
            return;
          }
          _broadcastState(playerState: state);
        },
        onError: (Object error, StackTrace stackTrace) {
          // Preparation errors are handled by _loadIndex, including the SAF
          // fallback. Runtime failures must not look like successful completion.
          if (_sourceReady || _switchingGeneration == 0) {
            _reportPlaybackError(player, error, stackTrace);
          }
        },
      ),
      player.onPositionChanged.listen((position) {
        if (identical(player, _player)) _handlePositionChanged(position);
      }),
      player.onDurationChanged.listen((duration) {
        if (!identical(player, _player) || !_sourceReady) return;
        final current = mediaItem.value;
        if (current != null && duration > Duration.zero) {
          mediaItem.add(current.copyWith(duration: duration));
        }
      }),
      player.onPlayerComplete.listen((_) {
        if (identical(player, _player)) unawaited(_handlePlayerComplete());
      }),
    ];
  }

  /// A decoder's unavailable-file error is ambiguous: it can also mean a
  /// provider refused access. Only skip after the source itself is confirmed
  /// missing by the filesystem or storage provider.
  bool _mayBeMissingSourceError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('audio file is unavailable') ||
        message.contains('cannot open file') ||
        message.contains('no such file or directory') ||
        message.contains('file does not exist') ||
        message.contains('file not found') ||
        message.contains('path not found')) {
      return true;
    }
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      return code == 2 || code == (Platform.isWindows ? 3 : 20);
    }
    return false;
  }

  Future<bool> _skipConfirmedMissingSource(
    PlayableMedia media,
    int generation,
    Object error,
  ) async {
    if (!_isCurrentPlayRequest(generation, media)) return true;
    if (media.isNetwork ||
        media.source.startsWith('network://') ||
        _runtime.arrivingFile(media.source) != null ||
        !_mayBeMissingSourceError(error)) {
      return false;
    }

    final result = await checkFileAccess(media.source);
    if (!_isCurrentPlayRequest(generation, media)) return true;
    if (result is! FileAccessMissing) return false;

    _log.w('Skipping missing track: ' + media.title);
    try {
      await onSourceDeleted(media.source);
      return true;
    } catch (failure) {
      _log.w('Could not advance past missing track: $failure');
      return false;
    }
  }

  void _reportPlaybackError(
    PlaybackDeck player,
    Object error,
    StackTrace stackTrace,
  ) {
    if (_disposed || !identical(player, _player) || _playbackError != null) {
      return;
    }
    if (_reloadAfterServerDied(error)) return;
    final generation = _playRequestGeneration;
    if (_checkingPlaybackErrorGeneration == generation) return;
    _checkingPlaybackErrorGeneration = generation;
    final media = _index >= 0 && _index < _media.length ? _media[_index] : null;
    unawaited(
      _handlePlaybackError(player, media, generation, error, stackTrace),
    );
  }

  Future<void> _handlePlaybackError(
    PlaybackDeck player,
    PlayableMedia? media,
    int generation,
    Object error,
    StackTrace stackTrace,
  ) async {
    try {
      if (media != null &&
          await _skipConfirmedMissingSource(media, generation, error)) {
        return;
      }
      if (_disposed ||
          !identical(player, _player) ||
          generation != _playRequestGeneration ||
          _playbackError != null) {
        return;
      }
      _sourceReady = false;
      _playbackError = error;
      _userPaused = true;
      _pausedByInterruption = false;
      _playbackAutomation.cancelPendingActions();
      _log.e('Playback failed: ' + (mediaItem.value?.title ?? 'unknown'), error, stackTrace);
      _broadcastState(playerState: PlaybackDeckState.stopped);
      await _serializeSourceChange(() async {
        if (_disposed || generation != _playRequestGeneration) return;
        await _cancelTransitions();
        if (_disposed || generation != _playRequestGeneration) return;
        await player.stop();
      });
    } catch (failure) {
      _log.w('Could not handle playback failure: $failure');
    } finally {
      if (_checkingPlaybackErrorGeneration == generation) {
        _checkingPlaybackErrorGeneration = null;
      }
    }
  }

  static const _serverDiedReloadLimit = 2;
  static const _serverDiedReloadDelay = Duration(milliseconds: 500);

  /// Android restarts its media server shortly after it dies, which fails
  /// the playing song on every MediaPlayer. Plays the song again from where
  /// it was, as pressing Play once or twice does, before reporting it.
  bool _reloadAfterServerDied(Object error) {
    if (!'$error'.contains('MEDIA_ERROR_SERVER_DIED') ||
        _serverDiedReloads >= _serverDiedReloadLimit ||
        _index < 0 ||
        _index >= _media.length) {
      return false;
    }
    _serverDiedReloads++;
    final generation = _playRequestGeneration;
    final index = _index;
    final position = playbackState.value.position;
    _log.w('The media server died; reloading ${mediaItem.value?.title}');
    unawaited(
      Future<void>.delayed(_serverDiedReloadDelay, () {
        if (_disposed || generation != _playRequestGeneration) return null;
        _reloadingAfterServerDied = true;
        return _playIndex(index, recordHistory: false, startPosition: position);
      }),
    );
    return true;
  }

  /// Drops a prepared AutoMix or gapless transition.
  Future<void> _cancelTransitions() async {
    await _autoMix.cancel();
    await _gapless.cancel();
  }

  Future<void> _disposeDeck(PlaybackDeck player) async {
    final subscriptions = _playerSubscriptions.remove(player);
    if (subscriptions == null) return;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }

  /// Configures the OS audio session and reacts to interruptions (e.g. another
  /// app like PowerAmp taking audio focus, or headphones unplugged) so playback
  /// pauses and the UI/notification reflect the real state instead of staying
  /// stuck on "playing".
  Future<void> _configureAudioSession() async {
    // audio_session models mobile audio focus; desktop has no equivalent.
    if (isDesktopPlatform) return;
    try {
      final session = await _dependencies.audioSession();
      _audioSession = session;
      await session.configure(const AudioSessionConfiguration.music());
      if (_disposed) return;
      _refreshPlaybackAutomation();

      _subscriptions.add(
        session.interruptionEventStream.listen((event) {
          _log.d(
            'Audio interruption ${event.begin ? 'began' : 'ended'} '
            'type=${event.type} player=${_player.state} '
            'playing=${playbackState.value.playing}',
          );
          if (event.begin) {
            if (event.type == AudioInterruptionType.duck) {
              return;
            }

            _interruptionActive = true;
            _pausedByInterruption =
                _player.state == PlaybackDeckState.playing ||
                playbackState.value.playing;
            unawaited(_pauseForFocusLoss(reason: 'audio interruption'));
          } else {
            if (event.type == AudioInterruptionType.duck) {
              return;
            }

            _interruptionActive = false;
            if (_pausedByInterruption &&
                event.type == AudioInterruptionType.pause &&
                !_playbackAutomation.blocksPlayback) {
              _pausedByInterruption = false;
              unawaited(play());
            } else {
              _pausedByInterruption = false;
            }
          }
        }),
      );

      _subscriptions.add(
        session.becomingNoisyEventStream.listen((_) {
          // Headphones unplugged / output route lost.
          _pausedByInterruption = false;
          unawaited(_pauseForFocusLoss(reason: 'becoming noisy'));
        }),
      );
    } catch (e) {
      _log.w('Failed to configure audio session: $e');
    }
  }

  void _refreshPlaybackAutomation() {
    if (_disposed) return;
    // Both follow mobile system volume and audio_session routes, which
    // desktop does not use.
    final pauseOnMute =
        !isDesktopPlatform &&
        _settings.playerMode == 'internal' &&
        _settings.pauseOnMute &&
        !_settings.usbBitPerfect;
    final playOnHeadphonesConnected =
        !isDesktopPlatform &&
        _settings.playerMode == 'internal' &&
        _settings.playOnHeadphonesConnected;
    unawaited(
      _playbackAutomation.configure(
        pauseOnMute: pauseOnMute,
        playOnHeadphonesConnected: playOnHeadphonesConnected,
      ),
    );
    if (pauseOnMute && _automationVolumeSubscription == null) {
      _automationVolumeSubscription = _dependencies.volumeChanges.listen(
        (volume) => unawaited(_playbackAutomation.volumeChanged(volume)),
        onError: (Object error) =>
            _log.w('Could not monitor media volume: $error'),
      );
    } else if (!pauseOnMute) {
      final subscription = _automationVolumeSubscription;
      _automationVolumeSubscription = null;
      if (subscription != null) unawaited(subscription.cancel());
    }
    final session = _audioSession;
    if (playOnHeadphonesConnected &&
        session != null &&
        !_headphoneMonitoringRequested) {
      _headphoneMonitoringRequested = true;
      unawaited(
        _startHeadphoneMonitoring(session, ++_headphoneMonitoringRevision),
      );
    } else if (!playOnHeadphonesConnected) {
      _headphoneMonitoringRequested = false;
      _headphoneMonitoringRevision++;
      final subscription = _automationDevicesSubscription;
      _automationDevicesSubscription = null;
      if (subscription != null) unawaited(subscription.cancel());
    }
  }

  Future<void> _startHeadphoneMonitoring(
    AudioSession session,
    int revision,
  ) async {
    try {
      // Query a fresh baseline. devicesStream can replay an old inventory
      // after monitoring was disabled, which would look like a new connection.
      final devices = await session.getDevices();
      if (_disposed || revision != _headphoneMonitoringRevision) return;
      unawaited(_playbackAutomation.devicesChanged(devices));
      _automationDevicesSubscription = session.devicesChangedEventStream
          .asyncMap((_) => session.getDevices())
          .listen(
            (devices) => unawaited(_playbackAutomation.devicesChanged(devices)),
            onError: (Object error) =>
                _log.w('Could not monitor headphone connections: $error'),
          );
    } catch (error) {
      _log.w('Could not monitor headphone connections: $error');
    }
  }

  bool get _shouldIgnoreComplete =>
      _switchingGeneration != 0 ||
      _interruptionActive ||
      _userPaused ||
      _playbackError != null;

  Future<void> _pauseForFocusLoss({required String reason}) async {
    _log.i('Pausing internal player because of $reason');
    _playbackAutomation.cancelPendingActions();
    try {
      await _pausePlayback();
    } catch (e) {
      _log.w('Failed to pause after audio focus loss: $e');
      if (!_disposed) _broadcastState(playerState: PlaybackDeckState.paused);
    }
  }

  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero) return;
    _sleepTimer?.cancel();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      _sleepTimer = null;
      _sleepTimerEndsAt = null;
      if (_disposed) return;
      _log.i('Sleep timer elapsed; pausing playback');
      unawaited(pause());
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
  }

  Future<bool> _activateAudioSession(int generation) async {
    if (isDesktopPlatform) return true;
    try {
      // Android 15+ rejects background focus requests without an active
      // foreground service. Publishing Dart state alone does not await it.
      if (_dependencies.isAndroid) {
        await _dependencies.synchronizePlaybackState();
      }
      if (generation != _playRequestGeneration || _disposed) return false;
      final session = _audioSession ?? await _dependencies.audioSession();
      _audioSession = session;
      // Other media plugins can change the process-wide iOS category/options
      // after initialization. Mixing makes us ineligible for Now Playing.
      if (_dependencies.isIOS) {
        await session.configure(const AudioSessionConfiguration.music());
      }
      if (generation != _playRequestGeneration || _disposed) return false;
      final granted = await session.setActive(true);
      if (!granted) {
        _log.w('Audio focus request was not granted');
      }
      return granted;
    } catch (e) {
      _log.w('Failed to activate audio session: $e');
      return false;
    }
  }

  // Required on some Android builds because audio_session manages focus.
  Future<void> _claimHardwareMediaButtons() async {
    if (!_dependencies.isAndroid) return;
    try {
      await AudioService.androidForceEnableMediaButtons();
    } catch (e) {
      _log.w('Failed to claim Android media-button routing: $e');
    }
  }

  AudioProcessingState _mapProcessingState(PlaybackDeckState state) {
    switch (state) {
      case PlaybackDeckState.playing:
      case PlaybackDeckState.paused:
        return AudioProcessingState.ready;
      case PlaybackDeckState.completed:
        return AudioProcessingState.completed;
      case PlaybackDeckState.stopped:
      case PlaybackDeckState.disposed:
        return AudioProcessingState.idle;
    }
  }

  void _broadcastState({PlaybackDeckState? playerState, bool? loading}) {
    final state = playerState ?? _player.state;
    final failed = _playbackError != null;
    final playing = !failed && state == PlaybackDeckState.playing;

    playbackState.add(
      playbackState.value.copyWith(
        controls: _runtime.notification.controls(
          playing: playing,
          item: mediaItem.value,
          shuffle: _shuffle,
        ),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToPrevious,
          MediaAction.skipToNext,
        },
        androidCompactActionIndices: const [1, 2, 3],
        processingState: failed
            ? AudioProcessingState.error
            : (loading == true)
            ? AudioProcessingState.loading
            : _mapProcessingState(state),
        errorCode: failed ? 1 : null,
        errorMessage: _playbackError?.toString(),
        playing: playing,
        queueIndex: _index >= 0 ? _index : null,
        speed: _autoMix.rate,
        shuffleMode: _shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: _repeatMode,
      ),
    );
  }

  void refreshNotificationControls() {
    if (_disposed) return;
    final state = playbackState.value;
    playbackState.add(
      state.copyWith(
        // copyWith creates a fresh updateTime; keep the extrapolated position
        // so changing a star or theme cannot pull the scrubber backwards.
        updatePosition: state.position,
        controls: _runtime.notification.controls(
          playing: state.playing,
          item: mediaItem.value,
          shuffle: _shuffle,
        ),
        androidCompactActionIndices: const [1, 2, 3],
      ),
    );
  }

  bool _savingNotificationFavorite = false;
  bool _changingNotificationShuffle = false;

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == PlaybackNotification.favoriteAction) {
      final item = mediaItem.value;
      if (item == null || _savingNotificationFavorite) return;
      _savingNotificationFavorite = true;
      try {
        final loved = await _runtime.toggleFavorite(item);
        final current = mediaItem.value;
        if (!_disposed &&
            loved != null &&
            current?.id == item.id &&
            current?.extras?['source'] == item.extras?['source']) {
          // Widget/provider rebuilds may wait for a frame while the app is
          // backgrounded. Publish the persisted result directly to the OS.
          _runtime.updateFavorite(item, loved);
        }
      } catch (error) {
        _log.w('Notification favorite failed: $error');
      } finally {
        _savingNotificationFavorite = false;
      }
    } else if (name == PlaybackNotification.shuffleAction) {
      if (mediaItem.value == null || _changingNotificationShuffle) return;
      _changingNotificationShuffle = true;
      try {
        await setShuffleMode(
          _shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all,
        );
      } catch (error) {
        _log.w('Notification shuffle failed: $error');
      } finally {
        _changingNotificationShuffle = false;
      }
    } else {
      return super.customAction(name, extras);
    }
  }

  void _broadcastPosition(
    Duration position, {
    bool force = false,
    Duration? readAt,
  }) {
    final now = DateTime.now();
    final lastAt = _lastPositionBroadcastAt;
    final elapsed = lastAt == null ? null : now.difference(lastAt);
    final moved = (position - _lastBroadcastPosition).abs();
    if (!force &&
        elapsed != null &&
        elapsed < _positionBroadcastInterval &&
        moved < _positionBroadcastInterval) {
      return;
    }
    _lastPositionBroadcastAt = now;
    _lastPositionReadAt = readAt ?? _positionClock.elapsed;
    _lastBroadcastPosition = position;
    if (force) _positionCheckDue = true;
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
        speed: _autoMix.rate,
      ),
    );
  }

  /// Whether a position tick of [player] can change anything. The handler
  /// ignores other decks and songs still switching. The gate above passes
  /// a position [_positionBroadcastInterval] after the engine read the last
  /// one (which arrived a round trip later), and the session is saved every
  /// [_positionPersistInterval]. After a forced broadcast the next tick
  /// still reads the engine, which may be far from the published position.
  /// AutoMix, gapless playback and Autoplay get every tick they act on.
  bool _wantsPosition(PlaybackDeck player) {
    if (!identical(player, _player) ||
        !_sourceReady ||
        _switchingGeneration != 0) {
      return false;
    }
    final now = _positionClock.elapsed;
    final readAt = _lastPositionReadAt;
    final persistedAt = _lastPeriodicPersistAt;
    if (!_positionCheckDue &&
        readAt != null &&
        now - readAt < _positionBroadcastInterval - _positionQueryAllowance &&
        persistedAt != null &&
        DateTime.now().difference(persistedAt) <
            _positionPersistInterval - _positionQueryAllowance &&
        !_autoMix.wantsPosition &&
        !_gapless.wantsPosition(
          _lastBroadcastPosition + (now - readAt) * _autoMix.rate,
        ) &&
        !_autoplay.wouldFill) {
      return false;
    }
    _positionQueriedAt = now;
    return true;
  }

  void _handlePositionChanged(Duration position) {
    if (!_sourceReady || _switchingGeneration != 0) return;
    final readAt = _positionQueriedAt;
    _positionQueriedAt = null;
    _positionCheckDue = false;
    _broadcastPosition(position, readAt: readAt);
    _autoMix.onPosition(position);
    _gapless.onPosition(position);
    unawaited(_autoplay.fill());
    if (_restoringSession ||
        _player.state != PlaybackDeckState.playing ||
        _media.isEmpty ||
        _index < 0 ||
        _index >= _media.length) {
      return;
    }

    final now = DateTime.now();
    final lastPersistAt = _lastPeriodicPersistAt;
    if (lastPersistAt != null &&
        now.difference(lastPersistAt) < _positionPersistInterval) {
      return;
    }
    _lastPeriodicPersistAt = now;
    unawaited(_persistSession(position: position));
  }

  late final PlaybackNormalizationCache _normalizationCache;
  int _normalizationGeneration = 0;

  Future<void> _refreshNormalizationSource(String source) async {
    _normalizationGeneration++;
    _normalizationCache.invalidate(source);
    await _sourceCache.invalidate(source, waitForPending: true);
    if (_disposed) return;
    if (_index >= 0 &&
        _index < _media.length &&
        _media[_index].source == source) {
      reapplyNormalization();
    }
  }

  Future<double> _normalizationVolumeFor(
    String path, {
    String? cacheKey,
    String? displayName,
  }) async {
    if (const {
          'network',
          'http',
          'https',
        }.contains(Uri.tryParse(path)?.scheme) ||
        !_settings.playbackNormalization ||
        _settings.usbBitPerfect ||
        _player.isDirect) {
      return 1.0;
    }
    return _normalizationCache.volumeFor(
      path,
      cacheKey: cacheKey,
      displayName: displayName,
      preampDb: _settings.playbackNormalizationPreamp,
      preferAlbumGain: _settings.playbackNormalizationMode == 'album',
    );
  }

  /// What the active output path applies to the playing track, for the
  /// audio information sheet.
  PlaybackProcessing get processing => PlaybackProcessing(
    normalizationGain: _normalizationVolume,
    direct: _player.isDirect,
    autoMixRate: _autoMix.rate,
  );

  /// Re-applies normalization to the playing track when the setting flips.
  void reapplyNormalization() {
    final index = _index;
    final generation = _playRequestGeneration;
    final normalizationGeneration = ++_normalizationGeneration;
    if (index < 0 || index >= _media.length) return;
    unawaited(() async {
      await _cancelTransitions();
      if (generation != _playRequestGeneration ||
          index != _index ||
          index >= _media.length ||
          _disposed) {
        return;
      }
      final media = _media[index];
      var resolved = media.isContentUri
          ? _sourceCache.cachedPath(media.source)
          : media.source;
      ContentUriPlaybackLease? playbackLease;
      if (resolved == null && media.isContentUri) {
        try {
          playbackLease = await PlatformBridge.openContentUriPlaybackLease(
            media.source,
          );
          resolved = playbackLease?.path;
        } catch (_) {}
        resolved ??= await _resolveSource(media);
      }
      if (resolved == null) return;
      final volume = await _normalizationVolumeFor(
        resolved,
        cacheKey: media.isContentUri ? media.source : null,
        displayName: playbackLease?.displayName,
      );
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      if (_index != index ||
          generation != _playRequestGeneration ||
          normalizationGeneration != _normalizationGeneration) {
        return;
      }
      try {
        await _player.setVolume(volume);
        _normalizationVolume = volume;
      } catch (e) {
        _log.w('Failed to apply normalization volume: $e');
      }
    }());
  }

  Future<String?> _resolveSource(PlayableMedia media) async {
    if (media.source.startsWith('network://')) {
      try {
        return await _dependencies.resolveNetworkSource(media.source);
      } catch (_) {
        _log.w('Network source is unavailable');
        return null;
      }
    }
    if (!media.isContentUri) {
      if (_runtime.arrivingFile(media.source) case final arriving?) {
        return arriving.url;
      }
      // A song a paired phone sent whose received copy is gone: the phone
      // sends it again, else it is unavailable.
      try {
        return await _dependencies.recoverMissingFile(media.source) ??
            media.source;
      } catch (error) {
        _log.w('Song file is gone and could not be fetched again: $error');
        return null;
      }
    }
    return _sourceCache.resolve(media.source);
  }

  Future<void> _cleanupPendingResolvedPaths() => _sourceCache.releaseUnpinned();

  void _markSessionQueueChanged() => _sessionWriter.queueChanged();

  PlaybackSessionQueue _sessionQueue() {
    final media = List.of(_media);
    final original = _originalQueueOrder;
    if (original == null) return (media: media, originalIndices: null);
    final ranks = Map<MediaItem, int>.identity();
    for (var i = 0; i < original.length; i++) {
      ranks[original[i]] = i;
    }
    return (
      media: media,
      originalIndices: [
        for (var i = 0; i < _media.length; i++) ranks[_queueItems[i]] ?? i,
      ],
    );
  }

  void _applyQueueOrder(List<MediaItem> order) {
    final current = _index >= 0 && _index < _queueItems.length
        ? _queueItems[_index]
        : null;
    final media = Map<MediaItem, PlayableMedia>.identity();
    for (var i = 0; i < _media.length; i++) {
      media[_queueItems[i]] = _media[i];
    }
    _queueItems
      ..clear()
      ..addAll(order);
    _media
      ..clear()
      ..addAll(order.map((item) => media[item]!));
    _index = current == null
        ? -1
        : order.indexWhere((item) => identical(item, current));
    _playHistory.clear();
    if (_index >= 0) _playHistory.add(_index);
  }

  /// Shuffles the queue so that [first] (the current song by default) opens
  /// it. Autoplay additions keep their order after the chosen songs.
  void _shuffleQueue([int? first]) {
    _originalQueueOrder ??= List.of(_queueItems);
    final start = first ?? _index;
    final manual = [
      for (var i = 0; i < _media.length; i++)
        if (i == start || !_media[i].autoplay) i,
    ];
    final order = buildShuffledQueueOrder(
      mediaCount: manual.length,
      currentIndex: manual.indexOf(start),
      random: _random,
    );
    _applyQueueOrder([
      ...order.map((index) => _queueItems[manual[index]]),
      for (var i = 0; i < _media.length; i++)
        if (i != start && _media[i].autoplay) _queueItems[i],
    ]);
  }

  /// The queue index that opens the next repeat-all pass. In shuffle mode it
  /// is a random queued song, not an Autoplay addition, other than the one
  /// that just finished.
  int _repeatPassStart() {
    if (!_shuffle) return 0;
    final candidates = [
      for (var i = 0; i < _media.length; i++)
        if (i != _index && !_media[i].autoplay) i,
    ];
    if (candidates.isEmpty) return 0;
    return candidates[_random.nextInt(candidates.length)];
  }

  /// Returns to the start for repeat all and gives the index to play. In
  /// shuffle mode each pass plays in a new order that opens with [start],
  /// so the queue does not loop through the same order again.
  int _beginRepeatPass(int start) {
    if (!_shuffle || start < 0 || start >= _media.length) return 0;
    _shuffleQueue(start);
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    return 0;
  }

  void _rememberEnqueued(List<MediaItem> items, {required bool playNext}) {
    final original = _originalQueueOrder;
    if (original == null) return;
    final current = _queueItems[_index];
    final at = original.indexWhere((item) => identical(item, current));
    final firstAutoplay = original.indexWhere(
      (item) => item.extras?['autoplay'] == true && !identical(item, current),
      max(0, at + 1),
    );
    original.insertAll(
      playNext && at >= 0
          ? at + 1
          : firstAutoplay >= 0
          ? firstAutoplay
          : original.length,
      items,
    );
  }

  /// Persists the queue only when it changed. Periodic position updates write
  /// fixed-size scalar columns, avoiding full queue JSON serialization every
  /// ten seconds for large playback sessions.
  Future<void> _persistSession({Duration? position}) {
    if (_restoringSession) return Future<void>.value();
    if (_media.isEmpty || _index < 0 || _index >= _media.length) {
      return _sessionWriter.clear();
    }
    return _sessionWriter.persist(
      queue: _sessionQueue,
      index: _index,
      position: position ?? Duration.zero,
      shuffle: _shuffle,
      repeatMode: _repeatMode.name,
    );
  }

  Future<Duration> _currentPositionForPersist() async {
    // During restore/source preparation the engine may report a stale zero (or
    // the previous source). The broadcast position already represents the
    // intended start point for the current queue item.
    if (!_sourceReady) return playbackState.value.position;
    try {
      final position = await _player.getCurrentPosition();
      if (position != null) return position;
    } catch (_) {}
    return playbackState.value.position;
  }

  /// Flushes the live engine position and every older queued session write.
  /// Called when the app leaves the foreground so a normal restart resumes at
  /// the latest audible point rather than the beginning of the track.
  Future<void> persistCurrentSession() async {
    if (_media.isEmpty || _index < 0 || _index >= _media.length) return;
    final position = await _currentPositionForPersist();
    _lastPeriodicPersistAt = DateTime.now();
    await _persistSession(position: position);
  }

  /// Restores a persisted session paused: queue and current track become
  /// visible (mini player included) without loading any source; the first
  /// play() prepares the source directly at the saved position.
  Future<void> restoreSession({
    required List<PlayableMedia> items,
    required int index,
    required Duration position,
    required bool shuffle,
    List<int>? originalOrder,
    bool queueNeedsRewrite = false,
    bool replaceStoppedQueue = false,
    AudioServiceRepeatMode repeatMode = AudioServiceRepeatMode.none,
  }) async {
    if (items.isEmpty) return;
    // Network songs show their stored covers from the first item.
    if (items.any(
      (item) => item.coverReference != null || CoverStore.fetches(item.source),
    )) {
      await _dependencies.coverStore.warmUp();
      if (_disposed) return;
    }
    // Never clobber a session the user already started this launch.
    if (_index >= 0 || (_media.isNotEmpty && !replaceStoppedQueue)) return;
    _restoringSession = true;
    try {
      _media
        ..clear()
        ..addAll(items);
      _queueItems
        ..clear()
        ..addAll(items.map(_toMediaItem));
      _index = index.clamp(0, items.length - 1);
      _shuffle = shuffle;
      _originalQueueOrder = null;
      if (shuffle) {
        final order = [for (var i = 0; i < items.length; i++) i];
        if (originalOrder?.length == items.length) {
          order.sort((a, b) => originalOrder![a].compareTo(originalOrder[b]));
        }
        _originalQueueOrder = order.map((i) => _queueItems[i]).toList();
      }
      _repeatMode = repeatMode;
      _pendingRestorePosition = position > Duration.zero ? position : null;
      _sourceReady = false;
      _lastPeriodicPersistAt = null;
      _sessionWriter.queueRestored(needsRewrite: queueNeedsRewrite);
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      mediaItem.add(_toMediaItem(_media[_index]));
      _covers.fetchFor(_media[_index]);
      if (position > Duration.zero) {
        playbackState.add(
          playbackState.value.copyWith(updatePosition: position),
        );
      }
      _broadcastState(playerState: PlaybackDeckState.paused);
    } finally {
      _restoringSession = false;
    }
    if (queueNeedsRewrite) {
      await _persistSession(position: position);
    }
    _autoplay.updateMode();
  }

  /// Shows the restored song's cover from its file when the saved session
  /// kept none, as playing it would. The desktop backend reads files only
  /// once extensions are ready, which may be after the restore.
  Future<void> recoverRestoredArtwork() async {
    if (_index < 0 || _index >= _media.length) return;
    final media = _media[_index];
    if (media.isNetwork) return;
    await _recoverEmbeddedArtwork(media, _playRequestGeneration);
  }

  bool _isCurrentPlayRequest(int generation, PlayableMedia media) {
    return !_disposed &&
        generation == _playRequestGeneration &&
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].id == media.id &&
        _media[_index].source == media.source;
  }

  Future<void> setQueueAndPlay(
    List<PlayableMedia> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool? shuffle,
  }) async {
    if (items.isEmpty) return;
    _autoplay.reset();
    _playRequestGeneration++;
    _media
      ..clear()
      ..addAll(items);
    _queueItems
      ..clear()
      ..addAll(items.map(_toMediaItem));
    _originalQueueOrder = null;
    _index = initialIndex.clamp(0, items.length - 1);
    // An explicit mode accompanies a queue already in play order, as when
    // playback moves between devices. Adopt it without shuffling a second time.
    if (shuffle != null) _shuffle = shuffle;
    if (_shuffle && shuffle == null) _shuffleQueue();
    _markSessionQueueChanged();
    _playHistory.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    await _playIndex(_index, startPosition: initialPosition);
  }

  Future<void> enqueue(PlayableMedia item, {bool playNext = false}) async {
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay([item]);
      return;
    }
    final insertAt = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _autoplay.manualInsertIndex;
    _media.insert(insertAt, item);
    final queueItem = _toMediaItem(item);
    _queueItems.insert(insertAt, queueItem);
    _rememberEnqueued([queueItem], playNext: playNext);
    _markSessionQueueChanged();

    for (var i = 0; i < _playHistory.length; i++) {
      if (_playHistory[i] >= insertAt) _playHistory[i]++;
    }

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> enqueueAll(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    if (items.isEmpty) return;
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay(items);
      return;
    }
    var at = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _autoplay.manualInsertIndex;
    final queued = <MediaItem>[];
    for (final item in items) {
      _media.insert(at, item);
      final queueItem = _toMediaItem(item);
      _queueItems.insert(at, queueItem);
      queued.add(queueItem);
      for (var i = 0; i < _playHistory.length; i++) {
        if (_playHistory[i] >= at) _playHistory[i]++;
      }
      at++;
    }
    _rememberEnqueued(queued, playNext: playNext);
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _media.length ||
        newIndex < 0 ||
        newIndex >= _media.length ||
        oldIndex == newIndex) {
      return;
    }
    final media = _media.removeAt(oldIndex);
    final qi = _queueItems.removeAt(oldIndex);
    _media.insert(newIndex, media);
    _queueItems.insert(newIndex, qi);
    _markSessionQueueChanged();

    if (_index == oldIndex) {
      _index = newIndex;
    } else {
      if (oldIndex < _index && newIndex >= _index) {
        _index--;
      } else if (oldIndex > _index && newIndex <= _index) {
        _index++;
      }
    }

    _playHistory.clear();

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  /// Removes one queued occurrence, including when the same song is queued
  /// twice. The current source is protected if playback advances mid-gesture.
  void removeQueuedItem(MediaItem item) {
    final at = _queueItems.indexWhere((entry) => identical(entry, item));
    if (_disposed || at < 0 || at == _index) return;
    _autoplay.dismiss(_media[at]);
    _queueItems.removeAt(at);
    _media.removeAt(at);
    _originalQueueOrder?.removeWhere((entry) => identical(entry, item));
    if (at < _index) _index--;
    final history = [
      for (final index in _playHistory)
        if (index != at) index > at ? index - 1 : index,
    ];
    _playHistory
      ..clear()
      ..addAll(history);
    _markSessionQueueChanged();
    unawaited(_cancelTransitions());
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> _playIndex(
    int index, {
    bool recordHistory = true,
    bool userSkip = false,
    Duration startPosition = Duration.zero,
  }) async {
    if (_disposed || index < 0 || index >= _media.length) return;
    if (_reloadingAfterServerDied) {
      _reloadingAfterServerDied = false;
    } else {
      _serverDiedReloads = 0;
    }
    _runtime.personalization.finish(
      skipped:
          userSkip &&
          mediaItem.value?.extras?['source'] != _media[index].source,
    );
    _playbackAutomation.cancelPendingActions();
    // A normal track change supersedes a pending restore. A restored start
    // keeps it until the source is actually ready so a transient failure can
    // be retried from the same position.
    if (startPosition <= Duration.zero) {
      _pendingRestorePosition = null;
    }
    final generation = ++_playRequestGeneration;
    _sourceReady = false;
    _playbackError = null;
    // Advance the requested index synchronously so consecutive Next taps do
    // not all target the same song while AutoMix/source preparation awaits.
    _index = index;
    unawaited(_autoplay.fill());
    final media = _media[index];
    _switchingGeneration = generation;
    await _player.cancelPreparation();
    await _serializeSourceChange(() async {
      try {
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _cancelTransitions();
        if (!_isCurrentPlayRequest(generation, media)) return;
        // Retire the audible source before publishing another song's title.
        await _player.stop();
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _loadIndex(
          generation,
          media,
          recordHistory: recordHistory,
          startPosition: startPosition,
        );
      } finally {
        if (_switchingGeneration == generation) _switchingGeneration = 0;
      }
    });
  }

  Future<void> _serializeSourceChange(Future<void> Function() action) {
    final operation = _sourceChangeTail.then((_) => action());
    // A failed operation must not poison later transport requests.
    _sourceChangeTail = operation.catchError((Object _) {});
    return operation;
  }

  static bool _requiresDsd(PlayableMedia media) =>
      media.bitDepth == 1 ||
      const ['dsf', 'dff'].contains(media.format?.toLowerCase()) ||
      media.source.toLowerCase().endsWith('.dsf') ||
      media.source.toLowerCase().endsWith('.dff');

  Future<void> _startResolvedSource(
    String path,
    int generation,
    PlayableMedia media,
    Duration? position,
  ) async {
    // AudioPlayer.play combines prepare/seek/resume without a cancellation
    // boundary. A late prepare from an old request could resume the wrong
    // source. Serialize preparation and recheck before making it audible.
    // Link may resolve a network song to its completed local copy.
    // A file still arriving resolves to its HTTP stream instead.
    if (const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme)) {
      await _player.setNetworkSource(
        path,
        arriving: _runtime.streamsArrivingFile(path),
      );
    } else {
      await _player.setFileSource(
        path,
        preferBitPerfect: _settings.usbBitPerfect,
        directUsb: _settings.usbDirect,
        allowFixedVolume: _settings.usbAllowFixedVolume,
        dapExclusive: _settings.dapExclusive,
        allowDop: _settings.usbDsdOverPcm,
        requiresDsd: _requiresDsd(media),
      );
    }
    if (!_isCurrentPlayRequest(generation, media)) return;
    if (position != null) {
      await _player.seek(position);
      if (!_isCurrentPlayRequest(generation, media)) return;
    }
    await _player.resume();
    if (!_isCurrentPlayRequest(generation, media)) await _player.pause();
  }

  Future<void> _loadIndex(
    int generation,
    PlayableMedia media, {
    required bool recordHistory,
    required Duration startPosition,
  }) async {
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;

    if (recordHistory) _recordPlayHistory(_index);

    final effectiveStartPosition = normalizedPlaybackResumePosition(
      startPosition,
      duration: media.duration,
    );
    _runtime.personalization.begin(_learningTrack(media));
    mediaItem.add(_toMediaItem(media));
    _lastBroadcastPosition = Duration.zero;
    _lastPositionBroadcastAt = null;
    _broadcastPosition(effectiveStartPosition, force: true);
    // Claim the playing state up front (while the app is still in the
    // foreground window) so audio_service can start its foreground service
    // before the async source resolve below.
    _broadcastState(playerState: PlaybackDeckState.playing, loading: true);
    await _claimHardwareMediaButtons();
    if (!_isCurrentPlayRequest(generation, media)) return;
    if (_dependencies.isAndroid && !media.isNetwork) {
      try {
        final recovered = await _dependencies.recoverMovedDownload(
          media.source,
          media.id,
          _settings,
        );
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (recovered != null && recovered != media.source) {
          _relocateQueuedSource(media.source, recovered);
          media = _media[_index];
          mediaItem.add(_toMediaItem(media));
        }
      } catch (error) {
        _log.w('Could not resolve a moved download: $error');
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
    }
    if (!media.isNetwork) {
      unawaited(_recoverEmbeddedArtwork(media, generation));
    }
    _covers
      ..fetchFor(media)
      ..fetchAhead();

    // Android opens SAF files through a short-lived file-descriptor lease.
    // MediaPlayer duplicates that descriptor, so the original can be closed
    // immediately after play() without retaining a full-file cache copy.
    ContentUriPlaybackLease? playbackLease;
    if (_dependencies.isAndroid && media.isContentUri) {
      try {
        playbackLease = await PlatformBridge.openContentUriPlaybackLease(
          media.source,
        );
      } catch (e) {
        _log.w('Failed to open direct SAF playback lease: $e');
      }
    }
    var resolved = playbackLease?.path ?? await _resolveSource(media);
    var usingLocalSafCopy = media.isContentUri && playbackLease == null;
    if (!_isCurrentPlayRequest(generation, media)) {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      return;
    }
    if (resolved == null) {
      _reportPlaybackError(
        _player,
        StateError('Audio file is unavailable'),
        StackTrace.current,
      );
      return;
    }

    try {
      await _runtime.exclusiveAudioHook?.call();
    } catch (_) {}
    if (!_isCurrentPlayRequest(generation, media)) {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      return;
    }

    _switchingGeneration = generation;
    try {
      // Set before play() so the track never starts at the wrong loudness;
      // always set (1.0 when disabled/untagged) so a previous track's
      // attenuation can't leak into the next one.
      var normalizationVolume = await _normalizationVolumeFor(
        resolved,
        cacheKey: media.isContentUri ? media.source : null,
        displayName: playbackLease?.displayName,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.configureOutput();
      if (!_isCurrentPlayRequest(generation, media)) return;
      final focusGranted = await _activateAudioSession(generation);
      if (!_isCurrentPlayRequest(generation, media)) return;
      if (!focusGranted) {
        _sourceReady = false;
        _pendingRestorePosition = effectiveStartPosition;
        await _player.pause();
        if (_isCurrentPlayRequest(generation, media)) {
          _broadcastState(playerState: PlaybackDeckState.paused);
        }
        return;
      }
      await _player.stop();
      _sourceReady = false;
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.setVolume(normalizationVolume);
      _normalizationVolume = normalizationVolume;
      if (!_isCurrentPlayRequest(generation, media)) return;
      final startAt = effectiveStartPosition > Duration.zero
          ? effectiveStartPosition
          : null;
      try {
        await _startResolvedSource(resolved, generation, media, startAt);
        if (playbackLease != null) {
          await PlatformBridge.closeContentUriPlaybackLease(
            playbackLease.token,
          );
          playbackLease = null;
        }
      } catch (directError) {
        if (directError is UsbOutputUnavailable ||
            playbackLease == null ||
            !_isCurrentPlayRequest(generation, media)) {
          rethrow;
        }
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
        playbackLease = null;
        _log.w(
          'Direct SAF playback unavailable; using bounded local fallback: '
          '$directError',
        );
        final fallback = await _resolveSource(media);
        if (fallback == null || !_isCurrentPlayRequest(generation, media)) {
          rethrow;
        }
        resolved = fallback;
        usingLocalSafCopy = true;
        normalizationVolume = await _normalizationVolumeFor(
          fallback,
          cacheKey: media.source,
        );
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _player.setVolume(normalizationVolume);
        if (!_isCurrentPlayRequest(generation, media)) return;
        _normalizationVolume = normalizationVolume;
        await _startResolvedSource(fallback, generation, media, startAt);
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
      _sourceReady = true;
      if (media.source.startsWith('network://')) {
        unawaited(_loadNetworkMetadata(media, generation));
      }
      _pendingRestorePosition = null;
      _activeResolvedPath = usingLocalSafCopy ? resolved : null;
      await _cleanupPendingResolvedPaths();
      if (!_isCurrentPlayRequest(generation, media)) return;
      // Plain file paths were already published before loading. Re-publishing
      // them with an identical resolved path made Now Playing clear and probe
      // the same metadata twice on every Next. SAF needs this second event so
      // the UI can inspect its temporary local copy.
      if (usingLocalSafCopy) {
        mediaItem.add(_toMediaItem(_media[_index], resolvedSource: resolved));
      }
      _broadcastPosition(effectiveStartPosition, force: true);
      _broadcastState();
      _lastPeriodicPersistAt = DateTime.now();
      unawaited(_persistSession(position: effectiveStartPosition));
      // Some files do not emit onDurationChanged reliably (stuck at 0:00);
      // poll the engine for the real duration as a fallback.
      unawaited(_ensureDurationKnown(media, generation));
    } catch (e, stackTrace) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      _reportPlaybackError(_player, e, stackTrace);
    } finally {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      if (_switchingGeneration == generation) {
        _switchingGeneration = 0;
      }
    }
  }

  Future<void> _recoverEmbeddedArtwork(
    PlayableMedia media,
    int generation,
  ) async {
    if (_runtime.arrivingFile(media.source) case final arriving?) {
      try {
        await arriving.done;
      } on Object {
        return;
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
    }
    final artwork = await resolveEmbeddedArtworkUri(
      media.source,
      media.artUri,
      extract: (source) =>
          DownloadedEmbeddedCoverResolver.resolveOrExtract(source),
    );
    if (artwork == null || !_isCurrentPlayRequest(generation, media)) return;
    final current = mediaItem.value;
    if (current == null) return;
    final updated = current.copyWith(artUri: Uri.parse(artwork));
    mediaItem.add(updated);
    _media[_index] = PlayableMedia.fromJson({
      ..._media[_index].toJson(),
      'artUri': artwork,
    })!;
    final old = _queueItems[_index];
    _queueItems[_index] = updated;
    final original = _originalQueueOrder;
    if (original != null) {
      final i = original.indexWhere((item) => identical(item, old));
      if (i >= 0) original[i] = updated;
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> _loadNetworkMetadata(PlayableMedia media, int generation) async {
    try {
      final metadata = await _dependencies.readNetworkMetadata(media.source);
      if (!_isCurrentPlayRequest(generation, media)) return;
      final cover = await _covers.readTagCover(
        media,
        metadata['cover_path'] as String?,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      final current = mediaItem.value;
      if (current == null) return;
      String text(String key, String fallback) {
        final value = metadata[key]?.toString().trim() ?? '';
        return value.isEmpty ? fallback : value;
      }

      final updated = current.copyWith(
        title: text('title', current.title),
        artist: text('artist', current.artist ?? ''),
        album: text('album', current.album ?? ''),
        artUri: cover ?? current.artUri,
        extras: {
          ...?current.extras,
          for (final key in ['bit_depth', 'sample_rate', 'bitrate', 'format'])
            if (metadata[key] != null) key: metadata[key],
        },
      );
      mediaItem.add(updated);
      _media[_index] = PlayableMedia.fromJson({
        ...media.toJson(),
        'title': updated.title,
        'artist': updated.artist,
        'album': updated.album,
        'bitDepth': metadata['bit_depth'] ?? media.bitDepth,
        'sampleRate': metadata['sample_rate'] ?? media.sampleRate,
        'bitrate': metadata['bitrate'] ?? media.bitrate,
        'format': metadata['format'] ?? media.format,
      })!;
      // Keep the saved shuffle order paired with the updated queue entry.
      final old = _queueItems[_index];
      _queueItems[_index] = updated;
      final original = _originalQueueOrder;
      if (original != null) {
        final i = original.indexWhere((item) => identical(item, old));
        if (i >= 0) original[i] = updated;
      }
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      unawaited(_persistSession(position: playbackState.value.position));
    } catch (_) {
      _log.w('Network tags unavailable; keeping playback metadata');
    }
  }

  /// Resolves the real track duration when the initial metadata had none and
  /// the duration-changed event did not fire, so the seek bar and total time
  /// do not get stuck at 0:00.
  Future<void> _ensureDurationKnown(PlayableMedia media, int generation) async {
    for (var attempt = 0; attempt < 15; attempt++) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      final current = mediaItem.value;
      final existing = current?.duration;
      if (existing != null && existing > Duration.zero) return;

      try {
        final d = await _player.getDuration();
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (d != null && d > Duration.zero) {
          final item = mediaItem.value;
          if (item != null) {
            mediaItem.add(item.copyWith(duration: d));
          }
          return;
        }
      } catch (_) {
        // Duration probing is best-effort; retry until the bounded loop ends.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void _recordPlayHistory(int index) {
    _playHistory.add(index);
    if (_playHistory.length > 200) _playHistory.removeAt(0);
  }

  Future<void> _onComplete() async {
    if (_repeatMode == AudioServiceRepeatMode.one &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(_index, recordHistory: false);
      return;
    }
    if (_index == _media.length - 1 &&
        _repeatMode == AudioServiceRepeatMode.none) {
      final generation = _playRequestGeneration;
      await _autoplay.fill();
      if (_disposed ||
          generation != _playRequestGeneration ||
          _shouldIgnoreComplete) {
        return;
      }
    }
    if (_index >= 0 && _index < _media.length - 1) {
      await _playIndex(_index + 1);
    } else if (_repeatMode == AudioServiceRepeatMode.all && _media.isNotEmpty) {
      await _playIndex(_beginRepeatPass(_repeatPassStart()));
    } else {
      _broadcastState(playerState: PlaybackDeckState.completed);
    }
  }

  Future<void> _handlePlayerComplete() async {
    if (_completing) return;
    if (_shouldIgnoreComplete) {
      // A natively chained next song must not keep playing unseen.
      unawaited(_gapless.cancel());
      if (_userPaused || _interruptionActive) {
        _broadcastState(playerState: PlaybackDeckState.paused);
      }
      return;
    }

    _completing = true;
    try {
      _runtime.personalization.finish();
      if (await _gapless.handoff()) return;
      await _onComplete();
    } finally {
      _completing = false;
    }
  }

  @override
  Future<void> play() async {
    _playbackAutomation.manualPlaybackRequested();
    final activeOperation = _activePlayOperation;
    if (activeOperation != null) {
      await activeOperation;
      return;
    }

    final operation = _playInternal();
    _activePlayOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_activePlayOperation, operation)) {
        _activePlayOperation = null;
      }
    }
  }

  Future<void> _playInternal() async {
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    if (_player.needsSourceReload) {
      final generation = _playRequestGeneration;
      final index = _index;
      final position =
          await _player.getCurrentPosition() ?? playbackState.value.position;
      if (generation != _playRequestGeneration || _disposed) return;
      await _playIndex(index, recordHistory: false, startPosition: position);
      return;
    }
    if ((!_sourceReady ||
            _player.state == PlaybackDeckState.stopped ||
            _player.state == PlaybackDeckState.completed) &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(
        _index,
        recordHistory: false,
        startPosition: _pendingRestorePosition ?? Duration.zero,
      );
      return;
    }
    final generation = _playRequestGeneration;
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      if (_dependencies.isAndroid) {
        _broadcastState(playerState: PlaybackDeckState.playing, loading: true);
      }
      final focusGranted = await _activateAudioSession(generation);
      if (generation != _playRequestGeneration || _disposed) return;
      if (!focusGranted) {
        await _player.pause();
        if (generation == _playRequestGeneration && !_disposed) {
          _broadcastState(playerState: PlaybackDeckState.paused);
        }
        return;
      }
      await _claimHardwareMediaButtons();
      if (generation != _playRequestGeneration || _disposed) return;
      try {
        await _player.resume();
      } catch (error, stackTrace) {
        if (generation != _playRequestGeneration || _disposed) return;
        if (_player.needsSourceReload) {
          _broadcastState(playerState: PlaybackDeckState.paused);
        } else {
          _reportPlaybackError(_player, error, stackTrace);
        }
        return;
      }
      if (generation != _playRequestGeneration || _disposed) {
        await _player.pause();
        return;
      }
      _broadcastState(playerState: PlaybackDeckState.playing);
    });
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.value.playing) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  Future<void> pause() async {
    _playbackAutomation.cancelPendingActions();
    _pausedByInterruption = false;
    await _pausePlayback();
  }

  Future<void> _pausePlayback() async {
    _runtime.personalization.updatePlayback(
      source: mediaItem.value?.extras?['source'] as String?,
      playing: false,
    );
    unawaited(_runtime.personalization.flush());
    unawaited(_runtime.taste.flush());
    unawaited(_runtime.ranker.flush());
    final generation = ++_playRequestGeneration;
    _switchingGeneration = 0;
    _userPaused = true;
    await _player.cancelPreparation();
    await _cancelTransitions();
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      await _player.pause();
      if (generation != _playRequestGeneration || _disposed) return;
      _broadcastState(playerState: PlaybackDeckState.paused);
      await _persistSession(position: await _currentPositionForPersist());
    });
  }

  @override
  Future<void> seek(Duration position) async {
    final generation = _playRequestGeneration;
    await _autoMix.cancel();
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      if (!_sourceReady) {
        // Restored sessions have no engine source yet. Retain the requested
        // position, including zero, for the first play instead of the old save.
        _pendingRestorePosition = position;
        _broadcastPosition(position, force: true);
        await _persistSession(position: position);
        return;
      }
      await _player.seek(position);
      if (generation != _playRequestGeneration || _disposed) return;
      _broadcastPosition(position, force: true);
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final generation = ++_shuffleRequestGeneration;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _cancelTransitions();
    if (generation != _shuffleRequestGeneration ||
        _disposed ||
        enabled == _shuffle) {
      return;
    }
    _shuffle = enabled;
    if (enabled) {
      _shuffleQueue();
    } else {
      final original = _originalQueueOrder;
      if (original != null) _applyQueueOrder(List.of(original));
      _originalQueueOrder = null;
    }
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _cancelTransitions();
    // Group repeat has no meaning for a flat queue; treat it as all.
    _repeatMode = repeatMode == AudioServiceRepeatMode.group
        ? AudioServiceRepeatMode.all
        : repeatMode;
    _autoplay.updateMode();
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> stop({bool keepResume = false}) async {
    _runtime.personalization.finish();
    unawaited(_runtime.personalization.flush());
    unawaited(_runtime.taste.flush());
    unawaited(_runtime.ranker.flush());
    _playbackAutomation.cancelPendingActions();
    _autoplay.reset();
    cancelSleepTimer();
    final generation = ++_playRequestGeneration;
    _switchingGeneration = 0;
    _userPaused = true;
    await _player.cancelPreparation();
    await _cancelTransitions();
    await _serializeSourceChange(
      () => _stopSession(generation, keepResume: keepResume),
    );
  }

  Future<void> _stopSession(int generation, {bool keepResume = false}) async {
    if (generation != _playRequestGeneration || _disposed) return;
    Map<String, dynamic>? resumeMedia;
    if (keepResume && _index >= 0 && _index < _media.length) {
      final position = await _currentPositionForPersist();
      if (generation != _playRequestGeneration || _disposed) return;
      await _persistSession(position: position);
      if (generation != _playRequestGeneration || _disposed) return;
      resumeMedia = _media[_index].toJson();
    }
    await _player.stop();
    if (generation != _playRequestGeneration || _disposed) return;
    _sourceReady = false;
    _playbackError = null;
    _activeResolvedPath = null;
    await _cleanupPendingResolvedPaths();
    if (generation != _playRequestGeneration || _disposed) return;
    _index = -1;
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    _playHistory.clear();
    _pendingRestorePosition = null;
    await _sessionWriter.clear(resumeMedia: resumeMedia);
    if (generation != _playRequestGeneration || _disposed) return;
    // A stopped session has no current item; this also hides the mini player.
    mediaItem.add(null);
    _broadcastState(playerState: PlaybackDeckState.stopped);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_index >= 0 && _index == _media.length - 1) {
      final generation = _playRequestGeneration;
      await _autoplay.fill();
      if (_disposed || generation != _playRequestGeneration) return;
    }
    if (_index < _media.length - 1) {
      await _playIndex(_index + 1, userSkip: true);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    await _cancelTransitions();
    if (playbackState.value.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      _broadcastPosition(Duration.zero, force: true);
      _runtime.personalization.replayed();
      return;
    }
    if (_shuffle) {
      if (_playHistory.length >= 2) {
        _playHistory.removeLast();
        final prev = _playHistory.last;
        await _playIndex(prev, recordHistory: false, userSkip: true);
      } else {
        await _player.seek(Duration.zero);
        _broadcastPosition(Duration.zero, force: true);
      }
      _runtime.personalization.replayed();
      return;
    }
    if (_index > 0) {
      await _playIndex(_index - 1, userSkip: true);
      _runtime.personalization.replayed();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _playIndex(index, userSkip: true);

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    // Media resumption asks for the song to resume, which a cold start has
    // only once the saved session is back.
    if (parentMediaId == AudioService.recentRootId) {
      await _runtime.restoreSession();
      final item = mediaItem.value;
      return item == null ? const [] : [item];
    }
    return _runtime.browser.children(parentMediaId, options);
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) => _runtime.browser.search(query);

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index < 0) return null;
    return _queueItems[index];
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    if (MediaLibraryBrowser.isBrowserId(mediaId)) {
      await _playBrowserQueue(await _runtime.browser.queueFor(mediaId));
      return;
    }
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index >= 0) await _playIndex(index);
  }

  /// Plays a spoken request. Without words it resumes the queue, or shuffles
  /// the Library when there is none.
  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (query.trim().isEmpty) {
      await _runtime.restoreSession();
      if (_media.isNotEmpty) return play();
    }
    await _playBrowserQueue(
      await _runtime.browser.queueForSearch(query, extras),
    );
  }

  Future<void> _playBrowserQueue(BrowserQueue? queue) async {
    if (queue == null || _disposed) return;
    if (queue.shuffle) await setShuffleMode(AudioServiceShuffleMode.all);
    await setQueueAndPlay(queue.items, initialIndex: queue.index);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  void _relocateQueuedSource(String previous, String replacement) {
    _normalizationCache.invalidate(previous);
    unawaited(_sourceCache.invalidate(previous));
    for (var i = 0; i < _media.length; i++) {
      final media = _media[i];
      if (media.source != previous) continue;
      _media[i] = PlayableMedia.fromJson({
        ...media.toJson(),
        'source': replacement,
      })!;
      final old = _queueItems[i];
      final next = old.copyWith(
        extras: {...?old.extras, 'source': replacement, 'resolvedSource': null},
      );
      _queueItems[i] = next;
      final original = _originalQueueOrder?.indexWhere(
        (item) => identical(item, old),
      );
      if (original != null && original >= 0) {
        _originalQueueOrder![original] = next;
      }
    }
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
  }

  /// Updates queued and persisted sources without restarting the decoder.
  Future<void> onSourceRelocated(String previous, String replacement) async {
    if (_disposed || !_media.any((item) => item.source == previous)) return;
    _relocateQueuedSource(previous, replacement);
    if (_index >= 0 && _index < _queueItems.length) {
      mediaItem.add(_queueItems[_index]);
    }
    await _persistSession(position: playbackState.value.position);
  }

  /// Refreshes every occurrence without reopening the decoder or seeking.
  Future<void> onSourceMetadataChanged(String source) async {
    if (_disposed || !_media.any((item) => item.source == source)) return;
    final token = Object();
    _metadataChanges[source] = token;
    try {
      final metadata = source.startsWith('network://')
          ? await _dependencies.readNetworkMetadata(source)
          : await _dependencies.readMetadata(source);
      if (metadata['error'] != null) return;
      final cover = metadata['cover_path'] as String?;
      String? artwork;
      Uri? networkCover;
      if (source.startsWith('network://')) {
        final media = _media.where((item) => item.source == source).firstOrNull;
        // The song left the queue, or a newer change reads its tags again.
        if (media == null ||
            _disposed ||
            !identical(_metadataChanges[source], token)) {
          return;
        }
        // The store keeps a network song's covers, which its items show.
        networkCover = await _covers.readTagCover(media, cover);
        _covers.invalidate(media.coverReference);
      } else if (cover != null && cover.isNotEmpty) {
        artwork = normalizeArtUri(cover);
      }
      if (_disposed || !identical(_metadataChanges[source], token)) return;
      var changed = false;
      for (var i = 0; i < _media.length; i++) {
        final previous = _media[i];
        if (previous.source != source) continue;
        final duration = readPositiveInt(metadata['duration']);
        final updated = PlayableMedia.fromJson({
          ...previous.toJson(),
          for (final field in const ['title', 'artist', 'album', 'genre'])
            if (metadata[field] != null) field: metadata[field].toString(),
          if (duration != null) 'durationMs': duration * 1000,
          'artUri': ?(artwork ?? previous.artUri),
          'bitDepth': metadata['bit_depth'] ?? previous.bitDepth,
          'sampleRate': metadata['sample_rate'] ?? previous.sampleRate,
          'bitrate': metadata['bitrate'] ?? previous.bitrate,
          'format': metadata['format'] ?? previous.format,
          'explicit': metadata['explicit'] ?? previous.explicit,
        })!;
        final facts = _toMediaItem(updated);
        MediaItem replace(MediaItem item) => item.copyWith(
          title: facts.title,
          artist: facts.artist,
          album: facts.album,
          duration: facts.duration ?? item.duration,
          artUri:
              networkCover ?? (artwork == null ? item.artUri : facts.artUri),
          extras: {
            ...?item.extras,
            ...?facts.extras,
            'explicit': updated.explicit,
          },
        );
        final old = _queueItems[i];
        final next = replace(old);
        _media[i] = updated;
        _queueItems[i] = next;
        final originalIndex = _originalQueueOrder?.indexWhere(
          (item) => identical(item, old),
        );
        if (originalIndex != null && originalIndex >= 0) {
          _originalQueueOrder![originalIndex] = next;
        }
        final current = mediaItem.value;
        if (i == _index && current != null) {
          mediaItem.add(replace(current));
        }
        changed = true;
      }
      if (changed) {
        _markSessionQueueChanged();
        queue.add(List.unmodifiable(_queueItems));
        await _persistSession(position: playbackState.value.position);
      }
    } finally {
      if (identical(_metadataChanges[source], token)) {
        _metadataChanges.remove(source);
      }
    }
  }

  /// Called when a file is deleted from disk. Removes it from the queue and, if
  /// it is the track currently playing, stops or advances so a deleted song can
  /// no longer be played.
  Future<void> onSourceDeleted(String source) async {
    final target = source.trim();
    if (_disposed || target.isEmpty) return;

    final hadPendingResolution = await _sourceCache.invalidate(target);

    final wasCurrent =
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].source == target;

    var removedBeforeCurrent = 0;
    final kept = <PlayableMedia>[];
    final keptQueue = <MediaItem>[];
    for (var i = 0; i < _media.length; i++) {
      if (_media[i].source == target) {
        if (i < _index) removedBeforeCurrent++;
        continue;
      }
      kept.add(_media[i]);
      keptQueue.add(_queueItems[i]);
    }

    if (kept.length == _media.length) return;

    _media
      ..clear()
      ..addAll(kept);
    _queueItems
      ..clear()
      ..addAll(keptQueue);
    final keptSet = Set<MediaItem>.identity()..addAll(keptQueue);
    _originalQueueOrder?.removeWhere((item) => !keptSet.contains(item));
    _markSessionQueueChanged();
    _playHistory.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));

    Future<void>? reaction;
    if (_media.isEmpty) {
      reaction = stop();
    } else if (wasCurrent) {
      final nextIndex = _index.clamp(0, _media.length - 1);
      reaction = _playIndex(nextIndex);
    } else {
      _index = (_index - removedBeforeCurrent).clamp(0, _media.length - 1);
      _broadcastState();
      unawaited(_persistSession(position: playbackState.value.position));
    }
    if (!hadPendingResolution) {
      await reaction;
    } else {
      // Queue invalidation must not wait behind an unavailable SAF provider.
      unawaited(
        reaction?.catchError((Object error) {
          _log.w('Could not update playback after source deletion: $error');
        }),
      );
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _autoplay.reset();
    _disposed = true;
    _runtime.personalization.finish();
    await _runtime.personalization.flush();
    if (_dependencies.isIOS) WidgetsBinding.instance.removeObserver(this);
    if (identical(musicPlayerRuntime.handler, this)) {
      autoMixStatus.value = AutoMixStatus.idle;
    }
    _runtime.detach(this);
    cancelSleepTimer();
    _listeningTimer?.cancel();
    _dependencies.recorder.update(null, playing: false, ended: true);
    await _dependencies.recorder.flush();
    _playRequestGeneration++;
    _headphoneMonitoringRevision++;
    await _automationVolumeSubscription?.cancel();
    await _automationDevicesSubscription?.cancel();
    await _playbackAutomation.dispose();
    await _player.cancelPreparation();
    await _sourceChangeTail;
    await _autoMix.dispose();
    await _gapless.dispose();
    _haptics.dispose();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _sourceReady = false;
    for (final player in _playerSubscriptions.keys.toList()) {
      await _disposeDeck(player);
    }
    _activeResolvedPath = null;
    await _sourceCache.dispose();
  }
}

Future<MusicPlayerHandler> initMusicPlayer() => musicPlayerRuntime.initialize();

/// Restores the last persisted playback session (if any) into a freshly
/// initialized handler, paused. Entries whose plain file paths no longer
/// exist are dropped; content URIs are kept and fail gracefully at play time.
Future<void> restorePersistedPlaybackSession() =>
    musicPlayerRuntime.restoreSession();
