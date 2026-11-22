import 'package:material_ui/material_ui.dart';
import 'package:mornye/routes/now_playing_route.dart';

/// The page under the full player. While the player moves over it, the page
/// is drawn as one picture, so its glass and lists are not painted again on
/// every frame of the move. A touch on the page ends the picture early: the
/// page answers it live.
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

  // The page was touched during this move and is painted live until it ends.
  bool _touched = false;

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

  void _follow() {
    final moving = NowPlayingRoute.moving.value;
    if (!moving) _touched = false;
    _picture.allowSnapshotting = widget.enabled && moving && !_touched;
  }

  // The mini player hides or shows its cover under the picture.
  void _retake() => _picture.clear();

  // A closing player lets touches through to this page. A scrolled list
  // under a still picture would look stuck until the player is gone.
  void _touch(PointerDownEvent event) {
    if (!_picture.allowSnapshotting) return;
    _touched = true;
    _follow();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _touch,
    child: SnapshotWidget(
      controller: _picture,
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: widget.child,
    ),
  );
}
