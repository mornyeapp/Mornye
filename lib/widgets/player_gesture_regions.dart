import 'package:material_ui/material_ui.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/widgets/player_track_swipe.dart';

/// The footer opens the queue upwards and dismisses the route downwards.
class PlayerQueueSwipeRegion extends StatefulWidget {
  const PlayerQueueSwipeRegion({
    super.key,
    required this.onOpenQueue,
    required this.child,
  });

  final VoidCallback onOpenQueue;
  final Widget child;

  @override
  State<PlayerQueueSwipeRegion> createState() => _PlayerQueueSwipeRegionState();
}

class _PlayerQueueSwipeRegionState extends State<PlayerQueueSwipeRegion> {
  bool _forwarding = false;
  double _total = 0;

  @override
  Widget build(BuildContext context) {
    final route = NowPlayingRoute.routeOf(context);
    final playerRoute = route is NowPlayingRoute ? route : null;
    final pageHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) {
        _forwarding = false;
        _total = 0;
      },
      onVerticalDragUpdate: (details) {
        if (_forwarding) {
          playerRoute?.updateDrag(details, pageHeight);
          return;
        }
        _total += details.primaryDelta ?? 0;
        if (_total > 12 && playerRoute != null) {
          playerRoute.startDrag();
          _forwarding = true;
        }
      },
      onVerticalDragEnd: (details) {
        if (_forwarding) {
          playerRoute?.endDrag(details, pageHeight);
        } else if ((details.primaryVelocity ?? 0) < -300 || _total < -40) {
          widget.onOpenQueue();
        }
      },
      onVerticalDragCancel: () {
        if (_forwarding) playerRoute?.cancelDrag();
      },
      child: widget.child,
    );
  }
}

/// Artwork forwards vertical drags inside scroll views to the player route.
class PlayerArtworkDragRegion extends StatelessWidget {
  const PlayerArtworkDragRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final route = NowPlayingRoute.routeOf(context);
    if (route is! NowPlayingRoute) return PlayerTrackSwipeRegion(child: child);
    final pageHeight = MediaQuery.sizeOf(context).height;
    return PlayerTrackSwipeRegion(
      child: GestureDetector(
        onVerticalDragStart: (_) => route.startDrag(),
        onVerticalDragUpdate: (details) =>
            route.updateDrag(details, pageHeight),
        onVerticalDragEnd: (details) => route.endDrag(details, pageHeight),
        onVerticalDragCancel: route.cancelDrag,
        child: child,
      ),
    );
  }
}

/// Hides the live cover while the route paints its captured dismissal cover.
class PlayerTransitionArtwork extends StatelessWidget {
  const PlayerTransitionArtwork({
    super.key,
    required this.artworkKey,
    required this.child,
  });

  final GlobalKey artworkKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final route = NowPlayingRoute.routeOf(context);
    return AnimatedBuilder(
      animation: route?.animation ?? kAlwaysCompleteAnimation,
      child: child,
      builder: (_, child) => Opacity(
        key: artworkKey,
        opacity: route is NowPlayingRoute && route.hasDismissArtwork ? 0 : 1,
        child: child,
      ),
    );
  }
}
