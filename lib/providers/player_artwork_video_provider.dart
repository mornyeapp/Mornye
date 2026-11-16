import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:video_player/video_player.dart';

/// The artwork video a widget has on screen: the current track's once it is
/// prepared, and the outgoing one until then.
class ShownArtworkVideo {
  String? source;
  VideoPlayerController? controller;

  void clear() {
    source = null;
    controller = null;
  }

  /// Follows [videoUrl] from a build method and reports whether it failed
  /// to prepare. While [resolving], a missing or failed video keeps the one
  /// on screen.
  bool watch(WidgetRef ref, String? videoUrl, {required bool resolving}) {
    final prepared = videoUrl == null
        ? null
        : ref.watch(playerArtworkVideoProvider(videoUrl));
    final failed = prepared?.hasError == true;
    if (prepared?.value case final ready?) {
      source = videoUrl;
      controller = ready;
    } else if (!resolving && (videoUrl == null || failed)) {
      clear();
    }
    // Retain the outgoing decoder only while it is still displayed. Watching
    // it before accepting the new frame keeps its heap alive until a later
    // unrelated rebuild, even after the old banner has been removed.
    final shown = source;
    if (shown != null && shown != videoUrl) {
      ref.watch(playerArtworkVideoProvider(shown));
    }
    return failed;
  }
}

/// The mini player prepares the current offline cover, paused and silent.
/// The full player borrows it so opening the route does not restart decoding.
final playerArtworkVideoProvider = FutureProvider.autoDispose
    .family<VideoPlayerController, String>((ref, source) async {
      final uri = Uri.parse(source);
      if (uri.scheme != 'file') {
        throw ArgumentError('Player artwork must be saved locally');
      }
      final controller = VideoPlayerController.file(
        File.fromUri(uri),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      Future<void>? disposal;
      Future<void> disposeController() => disposal ??= controller.dispose();
      ref.onDispose(() => unawaited(disposeController()));
      try {
        await controller.initialize();
        if (!ref.mounted) return controller;
        await controller.setVolume(0);
        if (!ref.mounted) return controller;
        await controller.setLooping(true);
        return controller;
      } catch (_) {
        unawaited(disposeController());
        rethrow;
      } finally {
        await restoreMusicAudioSessionAfterVideo();
      }
    });
