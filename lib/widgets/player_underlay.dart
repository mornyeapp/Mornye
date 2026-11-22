import 'package:material_ui/material_ui.dart';
import 'package:mornye/routes/now_playing_route.dart';

/// The page under the full player. While the player moves over it, the page
/// is drawn as one picture, so its glass and lists are not painted again on
/// every frame of the move.
class PlayerUnderlay extends StatefulWidget {
  const PlayerUnderlay({super.key, this.enabled = true, required this.child});

  /// False always paints the page live.
  final bool enabled;
  final Widget child;

  @override
  State<PlayerUnderlay> createState() => _PlayerUnderlayState();
}

class _PlayerUnderlayState extends State<PlayerUnderlay> {
  final _picture = SnapshotController();

  @override
  void initState() {
    super.initState();
    NowPlayingRoute.moving.addListener(_follow);
    NowPlayingRoute.coverLanding.addListener(_retake);
    _follow();
  }

  @override
  void didUpdateWidget(PlayerUnderlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) _follow();
  }

  @override
  void dispose() {
    NowPlayingRoute.moving.removeListener(_follow);
    NowPlayingRoute.coverLanding.removeListener(_retake);
    _picture.dispose();
    super.dispose();
  }

  void _follow() => _picture.allowSnapshotting =
      widget.enabled && NowPlayingRoute.moving.value;

  // The mini player hides or shows its cover under the picture.
  void _retake() => _picture.clear();

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _picture,
    mode: SnapshotMode.permissive,
    autoresize: true,
    child: widget.child,
  );
}
