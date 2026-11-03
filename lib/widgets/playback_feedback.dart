import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_runtime.dart' show UnplayableSong;
import 'package:mornye/widgets/app_snack_bar.dart';

/// Receives transient playback feedback across all foreground app routes.
class PlaybackFeedback extends ConsumerStatefulWidget {
  const PlaybackFeedback({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlaybackFeedback> createState() => _PlaybackFeedbackState();
}

class _PlaybackFeedbackState extends ConsumerState<PlaybackFeedback> {
  StreamSubscription<void>? _subscription;
  StreamSubscription<UnplayableSong>? _unplayableSubscription;
  int _subscriptionRevision = 0;
  Timer? _errorTimer;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _errorNotice;

  /// Names the format of the song playback stopped on; that failure needs
  /// no other notice while it shows.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _formatNotice;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      playbackStateProvider.select((state) => state.value?.errorMessage),
      (previous, message) {
        if (message == previous || !mounted) return;
        _errorTimer?.cancel();
        _errorNotice?.close();
        _errorNotice = null;
        if (message == null) return;
        // A quick track change can replace a failed preparation immediately.
        // Report only an error that still belongs to the current playback.
        _errorTimer = Timer(const Duration(milliseconds: 350), () {
          if (!mounted ||
              _formatNotice != null ||
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed ||
              ref.read(playbackStateProvider).value?.errorMessage != message) {
            return;
          }
          final notice = _errorNotice = showAppSnackBar(
            context,
            content: Text(
              context.l10n.snackbarCannotOpenFile(
                context.friendlyError(message),
              ),
            ),
          );
          unawaited(
            notice.closed.then((_) {
              if (identical(_errorNotice, notice)) _errorNotice = null;
            }),
          );
        });
      },
    );
    ref.listenManual(musicPlayerRuntimeProvider, (_, runtime) {
      final revision = ++_subscriptionRevision;
      unawaited(_subscription?.cancel());
      _subscription = runtime.mutedPlaybackEvents.listen((_) {
        if (!mounted ||
            revision != _subscriptionRevision ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarPlaybackMuted),
        );
      });
      unawaited(_unplayableSubscription?.cancel());
      _unplayableSubscription = runtime.unplayableSongs.listen((song) {
        if (!mounted ||
            revision != _subscriptionRevision ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        _errorTimer?.cancel();
        _errorNotice?.close();
        _errorNotice = null;
        final l10n = context.l10n;
        final notice = showAppSnackBar(
          context,
          content: Text(
            song.skipped
                ? l10n.snackbarPlaybackFormatUnsupportedSkipped(song.format)
                : l10n.snackbarPlaybackFormatUnsupported(song.format),
          ),
        );
        // A skipped song leaves no error; the next one may report its own.
        _formatNotice = song.skipped ? null : notice;
        unawaited(
          notice.closed.then((_) {
            if (identical(_formatNotice, notice)) _formatNotice = null;
          }),
        );
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _subscriptionRevision++;
    _errorTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_unplayableSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
