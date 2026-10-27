import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
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
  int _subscriptionRevision = 0;
  Timer? _errorTimer;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _errorNotice;

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
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _subscriptionRevision++;
    _errorTimer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
