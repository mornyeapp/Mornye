import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/recognized_song.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/music_recognition.dart';
import 'package:mornye/services/music_recognition_library.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('MusicRecognition');

/// Owned by the recognition screen: released when it closes.
final recognitionMicrophoneProvider =
    Provider.autoDispose<RecognitionMicrophone>((ref) {
      final microphone = RecordMicrophone();
      ref.onDispose(microphone.dispose);
      return microphone;
    });

final musicRecognizerProvider = Provider<MusicRecognizer>(
  (ref) => const NativeMusicRecognizer(),
);

final recognitionLibraryProvider = Provider<RecognitionLibrary>(
  _AppRecognitionLibrary.new,
);

final recognitionHistoryProvider =
    NotifierProvider<RecognitionHistoryNotifier, List<RecognizedSong>>(
      RecognitionHistoryNotifier.new,
    );

final musicRecognitionProvider =
    NotifierProvider.autoDispose<
      MusicRecognitionController,
      MusicRecognitionState
    >(MusicRecognitionController.new);

const recognitionHistoryLimit = 100;
const _historyKey = 'music_recognition_history';

/// Puts [song] first and drops an older entry for the same song.
List<RecognizedSong> addToRecognitionHistory(
  List<RecognizedSong> history,
  RecognizedSong song, {
  int limit = recognitionHistoryLimit,
}) => [
  song,
  ...history.where((entry) => entry.historyKey != song.historyKey),
].take(limit).toList(growable: false);

/// Recognized songs, newest first. A short JSON list in preferences: it is
/// written once per recognition and never queried.
class RecognitionHistoryNotifier extends Notifier<List<RecognizedSong>> {
  late Future<void> _loaded;

  @override
  List<RecognizedSong> build() {
    _loaded = _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _historyKey,
      );
      if (raw == null || !ref.mounted) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      var history = <RecognizedSong>[];
      for (final entry in decoded.reversed) {
        final song = RecognizedSong.fromJson(entry);
        if (song != null) history = addToRecognitionHistory(history, song);
      }
      // Songs added while loading stay on top.
      for (final song in state.reversed) {
        history = addToRecognitionHistory(history, song);
      }
      state = history;
    } on Object catch (error, stack) {
      _log.e('Failed to load recognition history', error, stack);
    }
  }

  Future<void> add(RecognizedSong song) async {
    state = addToRecognitionHistory(state, song);
    await _loaded;
    await _save();
  }

  Future<void> clear() async {
    await _loaded;
    state = const [];
    await _save();
  }

  Future<void> _save() async {
    if (!ref.mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (state.isEmpty) {
        await prefs.remove(_historyKey);
      } else {
        await prefs.setString(
          _historyKey,
          jsonEncode([for (final song in state) song.toJson()]),
        );
      }
    } on Object catch (error, stack) {
      _log.e('Failed to save recognition history', error, stack);
    }
  }
}

class _AppRecognitionLibrary implements RecognitionLibrary {
  _AppRecognitionLibrary(this.ref);

  final Ref ref;

  bool get _libraryEnabled => ref.read(settingsProvider).localLibraryEnabled;

  @override
  Future<RecognitionLibraryMatch?> byIsrc(String isrc) async {
    final downloaded = await ref
        .read(downloadHistoryProvider.notifier)
        .getByIsrcAsync(isrc);
    if (downloaded != null && await fileExists(downloaded.filePath)) {
      return _fromDownload(downloaded);
    }
    if (!_libraryEnabled) return null;
    final local = await ref
        .read(localLibraryProvider.notifier)
        .getByIsrcAsync(isrc);
    return local != null && await fileExists(local.filePath)
        ? _fromLibrary(local)
        : null;
  }

  @override
  Future<RecognitionLibraryMatch?> byTitleArtist(
    String title,
    String artist,
  ) async {
    final downloaded = await ref
        .read(downloadHistoryProvider.notifier)
        .findByTrackAndArtistAsync(title, artist);
    if (downloaded != null && await fileExists(downloaded.filePath)) {
      return _fromDownload(downloaded);
    }
    if (!_libraryEnabled) return null;
    final local = await ref
        .read(localLibraryProvider.notifier)
        .findByTrackAndArtistAsync(title, artist);
    return local != null && await fileExists(local.filePath)
        ? _fromLibrary(local)
        : null;
  }

  static RecognitionLibraryMatch _fromDownload(DownloadHistoryItem item) =>
      RecognitionLibraryMatch(
        path: item.filePath,
        title: item.trackName,
        artist: item.artistName,
        album: item.albumName,
        coverUrl: item.coverUrl ?? '',
      );

  static RecognitionLibraryMatch _fromLibrary(LocalLibraryItem item) =>
      RecognitionLibraryMatch(
        path: item.filePath,
        title: item.trackName,
        artist: item.artistName,
        album: item.albumName,
        coverUrl: item.coverPath ?? '',
      );
}

enum RecognitionPhase {
  idle,
  listening,

  /// The microphone is off and the last answer is on its way.
  processing,
  result,
  noMatch,
  failed,
  permissionDenied,
}

class MusicRecognitionState {
  const MusicRecognitionState({
    this.phase = RecognitionPhase.idle,
    this.song,
    this.failure,
    this.canOpenSettings = false,
    this.progress = 0,
    this.level = 0,
  });

  final RecognitionPhase phase;
  final RecognizedSong? song;
  final RecognitionFailure? failure;

  /// Access is blocked and the system settings can turn it back on.
  final bool canOpenSettings;

  /// The share of the longest listen captured so far, 0 to 1.
  final double progress;

  /// The microphone level, 0 to 1.
  final double level;

  bool get isBusy =>
      phase == RecognitionPhase.listening ||
      phase == RecognitionPhase.processing;
}

/// Listens for up to [maxListen] of audio and asks the service after
/// [checkpoints] of it, each time with everything heard so far, stopping at
/// the first match. Cancelling or leaving the screen stops the microphone at
/// once.
class MusicRecognitionController extends Notifier<MusicRecognitionState> {
  static const checkpoints = [
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 12),
  ];
  static const maxListen = Duration(seconds: 12);

  /// Wall-clock limit for a microphone that delivers audio slowly or not at
  /// all.
  static const listenTimeout = Duration(seconds: 15);

  static int _bytes(Duration duration) =>
      duration.inMilliseconds * recognitionBytesPerSecond ~/ 1000;

  late RecognitionMicrophone _microphone;
  late MusicRecognizer _recognizer;
  int _session = 0;
  StreamSubscription<Uint8List>? _audio;
  Timer? _timeout;
  bool _micOpen = false;
  final _captured = BytesBuilder();
  int _sentBytes = 0;
  String? _pendingRequest;
  RecognitionMiss? _lastMiss;

  @override
  MusicRecognitionState build() {
    _microphone = ref.watch(recognitionMicrophoneProvider);
    _recognizer = ref.watch(musicRecognizerProvider);
    ref.onDispose(() {
      _session++;
      unawaited(_closeMicrophone());
      _cancelPending();
    });
    return const MusicRecognitionState();
  }

  Future<void> start() async {
    if (state.isBusy) return;
    final session = ++_session;
    _captured.clear();
    _sentBytes = 0;
    _lastMiss = null;
    state = const MusicRecognitionState(phase: RecognitionPhase.listening);
    final access = await _microphone.requestAccess();
    if (session != _session) return;
    if (access != MicrophoneAccess.granted) {
      state = MusicRecognitionState(
        phase: RecognitionPhase.permissionDenied,
        canOpenSettings:
            access == MicrophoneAccess.blocked && _microphone.canOpenSettings,
      );
      return;
    }
    final Stream<Uint8List> audio;
    try {
      audio = await _microphone.start();
    } on Object catch (error) {
      _log.w('Microphone did not start (${error.runtimeType})');
      if (session == _session) {
        await _closeMicrophone();
        _fail(RecognitionFailure.microphone);
      }
      return;
    }
    if (session != _session) {
      await _microphone.stop();
      return;
    }
    _micOpen = true;
    _audio = audio.listen(
      (chunk) => _onAudio(session, chunk),
      onError: (Object error) {
        _log.w('Microphone stream failed (${error.runtimeType})');
        if (session == _session) unawaited(_finishListening(session));
      },
      onDone: () {
        if (session == _session) unawaited(_finishListening(session));
      },
    );
    _timeout = Timer(listenTimeout, () => _finishListening(session));
  }

  /// Stops listening and any request without showing a result.
  Future<void> cancel() async {
    _session++;
    _cancelPending();
    await _closeMicrophone();
    state = const MusicRecognitionState();
  }

  /// Shows a song from the history.
  void show(RecognizedSong song) {
    if (state.isBusy) return;
    state = MusicRecognitionState(phase: RecognitionPhase.result, song: song);
  }

  Future<void> openSettings() => _microphone.openSettings();

  void _onAudio(int session, Uint8List chunk) {
    if (session != _session || !_micOpen) return;
    final room = _bytes(maxListen) - _captured.length;
    _captured.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
    state = MusicRecognitionState(
      phase: RecognitionPhase.listening,
      progress: _captured.length / _bytes(maxListen),
      level: pcmLevel(chunk),
    );
    if (_captured.length >= _bytes(maxListen)) {
      unawaited(_finishListening(session));
    } else {
      _attemptIfDue(session);
    }
  }

  Future<void> _finishListening(int session) async {
    if (session != _session || !_micOpen) return;
    await _closeMicrophone();
    if (session != _session) return;
    if (_captured.isEmpty) {
      _fail(RecognitionFailure.microphone);
      return;
    }
    if (_pendingRequest != null) {
      state = const MusicRecognitionState(phase: RecognitionPhase.processing);
      return;
    }
    _attemptIfDue(session);
  }

  /// Sends the audio so far when the next checkpoint is reached, or the
  /// rest once listening is over; concludes when nothing is left to send.
  void _attemptIfDue(int session) {
    if (_pendingRequest != null) return;
    final captured = _captured.length;
    if (_micOpen) {
      final due = checkpoints
          .map(_bytes)
          .where((bytes) => bytes > _sentBytes)
          .firstOrNull;
      if (due == null || captured < due) return;
    } else if (captured <= _sentBytes) {
      _conclude();
      return;
    }
    unawaited(_attempt(session));
  }

  Future<void> _attempt(int session) async {
    // Whole samples only.
    final pcm = Uint8List.fromList(
      _captured.toBytes().sublist(0, _captured.length & ~1),
    );
    _sentBytes = _captured.length;
    final requestId = 'music-recognition-$session-${pcm.length}';
    _pendingRequest = requestId;
    if (!_micOpen) {
      state = const MusicRecognitionState(phase: RecognitionPhase.processing);
    }
    final response = await _recognizer.recognize(pcm, requestId: requestId);
    if (session != _session) return;
    _pendingRequest = null;
    switch (response) {
      case RecognitionMatched(:final song):
        _session++;
        await _closeMicrophone();
        state = MusicRecognitionState(
          phase: RecognitionPhase.result,
          song: song,
        );
        unawaited(ref.read(recognitionHistoryProvider.notifier).add(song));
      case RecognitionFailed(:final failure):
        _session++;
        await _closeMicrophone();
        _fail(failure);
      case RecognitionMissed(:final miss):
        _lastMiss = miss;
        _attemptIfDue(session);
      case RecognitionCancelled():
        break;
    }
  }

  void _conclude() {
    _session++;
    state = _lastMiss == RecognitionMiss.noMatch
        ? const MusicRecognitionState(phase: RecognitionPhase.noMatch)
        : const MusicRecognitionState(
            phase: RecognitionPhase.failed,
            failure: RecognitionFailure.notEnoughAudio,
          );
  }

  void _fail(RecognitionFailure failure) {
    _session++;
    state = MusicRecognitionState(
      phase: RecognitionPhase.failed,
      failure: failure,
    );
  }

  void _cancelPending() {
    final request = _pendingRequest;
    _pendingRequest = null;
    if (request != null) unawaited(_recognizer.cancel(request));
  }

  Future<void> _closeMicrophone() async {
    _timeout?.cancel();
    _timeout = null;
    final wasOpen = _micOpen;
    _micOpen = false;
    // Stopping the recorder ends the stream; nothing waits on the listener.
    unawaited(_audio?.cancel());
    _audio = null;
    if (wasOpen) await _microphone.stop();
  }
}
