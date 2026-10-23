import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PreviewPlayer');

enum PreviewStatus { idle, loading, playing, paused }

class PreviewPlayerState {
  final String? activeUrl;
  final PreviewStatus status;
  final Duration position;
  final Duration duration;

  const PreviewPlayerState({
    this.activeUrl,
    this.status = PreviewStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  bool get isActive => activeUrl != null && activeUrl!.isNotEmpty;

  bool isActiveUrl(String? url) =>
      url != null && url.isNotEmpty && url == activeUrl;

  PreviewPlayerState copyWith({
    String? activeUrl,
    bool clearActiveUrl = false,
    PreviewStatus? status,
    Duration? position,
    Duration? duration,
  }) {
    return PreviewPlayerState(
      activeUrl: clearActiveUrl ? null : (activeUrl ?? this.activeUrl),
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }
}

/// Plays previews through the runtime's preview deck, so desktop previews
/// use the same engine and in-app volume as the main player.
class PreviewPlayerController extends Notifier<PreviewPlayerState> {
  PlaybackDeck? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  AppLifecycleListener? _lifecycleListener;

  @override
  PreviewPlayerState build() {
    _lifecycleListener = AppLifecycleListener(
      onStateChange: _handleAppLifecycleState,
    );
    final runtime = ref.read(musicPlayerRuntimeProvider);
    Future<void> stopPreview() async {
      if (state.isActive) await stop();
    }

    runtime.exclusiveAudioHook = stopPreview;
    ref.onDispose(() {
      if (identical(runtime.exclusiveAudioHook, stopPreview)) {
        runtime.exclusiveAudioHook = null;
      }
      _disposePlayer();
    });
    return const PreviewPlayerState();
  }

  void _handleAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.detached) {
      if (state.isActive) {
        unawaited(stop());
      }
    }
  }

  PlaybackDeck _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;

    final player = ref
        .read(musicPlayerRuntimeProvider)
        .dependencies
        .createPreviewDeck('preview-player');
    player.startPositionUpdates(const Duration(milliseconds: 200));
    _attachListeners(player);
    _player = player;
    return player;
  }

  void _attachListeners(PlaybackDeck player) {
    _subscriptions.add(
      player.onPlayerStateChanged.listen(
        _handlePlayerStateChanged,
        onError: (Object error) => _log.w('Preview playback error: $error'),
      ),
    );
    _subscriptions.add(
      player.onPositionChanged.listen((position) {
        if (state.status == PreviewStatus.playing ||
            state.status == PreviewStatus.paused) {
          state = state.copyWith(position: position);
        }
      }),
    );
    _subscriptions.add(
      player.onDurationChanged.listen((duration) {
        state = state.copyWith(duration: duration);
      }),
    );
    _subscriptions.add(
      player.onPlayerComplete.listen((_) {
        state = const PreviewPlayerState();
      }),
    );
  }

  void _discardActivePlayer() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(
        player.dispose().catchError(
          (Object error) => _log.w('Failed to release preview: $error'),
        ),
      );
    }
  }

  void _handlePlayerStateChanged(PlaybackDeckState playerState) {
    switch (playerState) {
      case PlaybackDeckState.playing:
        state = state.copyWith(status: PreviewStatus.playing);
        break;
      case PlaybackDeckState.paused:
        if (state.isActive) {
          state = state.copyWith(status: PreviewStatus.paused);
        }
        break;
      case PlaybackDeckState.stopped:
      case PlaybackDeckState.completed:
        break;
      case PlaybackDeckState.disposed:
        break;
    }
  }

  Future<void> toggle(String? url) async {
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return;

    if (state.isActiveUrl(trimmed)) {
      if (state.status == PreviewStatus.playing) {
        await pause();
      } else if (state.status == PreviewStatus.paused) {
        await resume();
      }
      return;
    }

    await play(trimmed);
  }

  Future<void> play(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    try {
      await ref.read(musicPlayerRuntimeProvider).handler?.pause();
    } catch (_) {}

    state = PreviewPlayerState(
      activeUrl: trimmed,
      status: PreviewStatus.loading,
    );

    try {
      await _playOnPlayer(_ensurePlayer(), trimmed);
    } catch (e) {
      _log.w('Preview playback failed, recreating player and retrying: $e');
      _discardActivePlayer();
      try {
        await _playOnPlayer(_ensurePlayer(), trimmed);
      } catch (retryError) {
        _log.e('Preview playback failed after retry', retryError);
        _discardActivePlayer();
        state = const PreviewPlayerState();
        rethrow;
      }
    }
  }

  Future<void> _playOnPlayer(PlaybackDeck player, String url) async {
    // Applies the in-app volume; previews have no normalization gain.
    await player.setVolume(1);
    await player.setNetworkSource(url);
    await player.resume();
  }

  Future<void> pause() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.pause();
      state = state.copyWith(status: PreviewStatus.paused);
    } catch (e) {
      _log.w('Failed to pause preview: $e');
    }
  }

  Future<void> resume() async {
    final player = _player;
    if (player == null || !state.isActive) return;
    try {
      await player.resume();
      state = state.copyWith(status: PreviewStatus.playing);
    } catch (e) {
      _log.w('Failed to resume preview: $e');
    }
  }

  Future<void> stop() async {
    final player = _player;
    if (player == null) {
      state = const PreviewPlayerState();
      return;
    }
    try {
      await player.stop();
    } catch (e) {
      _log.w('Failed to stop preview: $e');
    }
    state = const PreviewPlayerState();
  }

  void _disposePlayer() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _discardActivePlayer();
  }
}

final previewPlayerProvider =
    NotifierProvider<PreviewPlayerController, PreviewPlayerState>(
      PreviewPlayerController.new,
    );
