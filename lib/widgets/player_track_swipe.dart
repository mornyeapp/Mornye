import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EMotion;
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/swipe_commit_haptic.dart';

/// Shares one horizontal gesture between artwork and metadata. Only the
/// titles translate; artwork, menus and the rest of the player stay anchored.
class PlayerTrackSwipe extends StatefulWidget {
  const PlayerTrackSwipe({
    super.key,
    required this.queue,
    required this.currentIndex,
    required Future<void> Function(MediaItem) this.onSelected,
    required this.child,
  }) : onRelease = null;

  /// The titles follow the finger without showing a neighbor and return
  /// to rest on release; [onRelease] decides what the swipe does, from the
  /// drag's travel and its end details. A skip then lands as an ordinary
  /// track change. Reduced motion keeps the titles still.
  const PlayerTrackSwipe.follow({
    super.key,
    required void Function(DragEndDetails details, double travel)
    this.onRelease,
    required this.child,
  }) : queue = const [],
       currentIndex = -1,
       onSelected = null;

  /// Travel that commits a [PlayerTrackSwipe.follow] swipe. The titles
  /// follow one to one up to here and with resistance beyond.
  static const followCommitDistance = 48.0;

  final List<MediaItem> queue;
  final int currentIndex;
  final Future<void> Function(MediaItem)? onSelected;
  final void Function(DragEndDetails details, double travel)? onRelease;
  final Widget child;

  @override
  State<PlayerTrackSwipe> createState() => _PlayerTrackSwipeState();
}

class _PlayerTrackSwipeState extends State<PlayerTrackSwipe>
    with SingleTickerProviderStateMixin {
  static const _titleGap = 32.0;

  late final _offset = AnimationController.unbounded(vsync: this);
  double _width = 240;
  double get _pageExtent => _width + _titleGap;
  double _drag = 0;
  bool _settling = false;
  int _generation = 0;

  MediaItem? _neighbor(double direction) {
    if (widget.currentIndex < 0) return null;
    final at = widget.currentIndex + (direction < 0 ? 1 : -1);
    return at >= 0 && at < widget.queue.length ? widget.queue[at] : null;
  }

  @override
  void didUpdateWidget(PlayerTrackSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        !listEquals(oldWidget.queue, widget.queue)) {
      _reset();
    }
  }

  void _reset() {
    _generation++;
    _settling = false;
    _drag = 0;
    _offset.value = 0;
  }

  bool get _follows => widget.onRelease != null;
  double _travel = 0;

  /// Settled within half a pixel.
  static const _tolerance = Tolerance(distance: 0.5, velocity: 10);

  /// Material's default expressive spatial spring, critically damped so the
  /// titles never pass rest and show the neighbour on the other side.
  static final _materialSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: M3EMotion.expressiveSpatialDefault.stiffness,
    ratio: 1,
  );

  /// Moves the titles to [target] on the style's spring (Mornye's standard
  /// one has no bounce either), starting from the [velocity] they had when
  /// the finger let go, in pixels a second. Reduced motion puts them there
  /// at once.
  TickerFuture _settle(double target, double velocity) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _offset.value = target;
      return TickerFuture.complete();
    }
    final spring = context.isMornye
        ? MornyeMotion.standardSpring
        : _materialSpring;
    final offset = _offset.value;
    var start = velocity;
    if (target == 0 && offset != 0 && velocity.sign != offset.sign) {
      // A flick back toward rest is capped where the spring would carry
      // the titles past it.
      final limit = math.sqrt(spring.stiffness / spring.mass) * offset.abs();
      start = velocity.clamp(-limit, limit);
    }
    return _offset.animateWith(
      SpringSimulation(
        spring,
        offset,
        target,
        start,
        tolerance: _tolerance,
        snapToEnd: true,
      ),
    );
  }

  double _followOffset(double drag) {
    if (MediaQuery.disableAnimationsOf(context)) return 0;
    const linear = PlayerTrackSwipe.followCommitDistance;
    final distance = drag.abs();
    final offset = distance <= linear
        ? distance
        : linear + (distance - linear) * 0.35;
    return drag.sign * offset.clamp(0.0, _width);
  }

  /// How fast the titles move for a finger moving at [velocity] at the
  /// current drag: one to one, slower where the drag meets resistance, and
  /// not at all against a stop.
  double _titleVelocity(double velocity) {
    if (velocity == 0 || MediaQuery.disableAnimationsOf(context)) return 0;
    final distance = _drag.abs();
    if (_follows) {
      const linear = PlayerTrackSwipe.followCommitDistance;
      if (distance <= linear) return velocity;
      return linear + (distance - linear) * 0.35 < _width ? velocity * 0.35 : 0;
    }
    if (_neighbor(_drag) != null) {
      return distance < _pageExtent ? velocity : 0;
    }
    final stretch = 1 + distance / _width;
    return velocity * 0.18 / (stretch * stretch);
  }

  void _start(DragStartDetails details) {
    if (_follows) {
      // A new swipe takes over a title that is still returning to rest.
      _travel = 0;
    }
    // A swipe that commits runs to its end; one returning to rest is taken
    // over where it is.
    if (_settling) return;
    _generation++;
    _offset.stop();
    _drag = _dragFor(_offset.value);
  }

  /// The drag that puts the titles at [offset], so a swipe that takes them
  /// over mid-flight starts where they are drawn.
  double _dragFor(double offset) {
    final distance = offset.abs();
    if (_follows) {
      const linear = PlayerTrackSwipe.followCommitDistance;
      if (distance <= linear) return offset;
      return offset.sign * (linear + (distance - linear) / 0.35);
    }
    if (_neighbor(offset) != null) return offset;
    // The inverse of the resistance in [_update].
    final room = 0.18 - distance / _width;
    return room > 0 ? offset / room : offset;
  }

  void _update(DragUpdateDetails details) {
    if (_settling) return;
    final delta = details.primaryDelta ?? 0;
    _drag += delta;
    if (_follows) {
      _travel += delta;
      _offset.value = _followOffset(_drag);
      return;
    }
    _offset.value = _neighbor(_drag) == null
        ? _drag * 0.18 / (1 + _drag.abs() / _width)
        : _drag.clamp(-_pageExtent, _pageExtent);
  }

  Future<void> _finishFollow(DragEndDetails? details) async {
    final travel = _travel;
    _travel = 0;
    if (details != null) widget.onRelease!(details, travel);
    if (!mounted) return;
    final generation = ++_generation;
    try {
      await _settle(0, _titleVelocity(details?.primaryVelocity ?? 0)).orCancel;
    } on TickerCanceled {
      // A new swipe took the titles over.
    } finally {
      if (mounted && generation == _generation) _reset();
    }
  }

  Future<void> _finish([DragEndDetails? details]) async {
    if (_follows) return _finishFollow(details);
    if (_settling) return;
    final offset = _offset.value;
    final velocity = details?.primaryVelocity ?? 0;
    final target = _neighbor(offset);
    final commit =
        details != null &&
        target != null &&
        (offset.abs() > _width * 0.25 ||
            (velocity.abs() > 550 && velocity.sign == offset.sign));
    final generation = ++_generation;
    _settling = commit;
    try {
      await _settle(
        commit ? _pageExtent * offset.sign : 0,
        _titleVelocity(velocity),
      ).orCancel;
      if (!mounted || generation != _generation) return;
      if (commit) await widget.onSelected!(target);
    } on TickerCanceled {
      // A new song/queue or closing the player supersedes this gesture.
    } finally {
      if (mounted && generation == _generation) _reset();
    }
  }

  @override
  void dispose() {
    _generation++;
    _offset.dispose();
    super.dispose();
  }

  final _haptic = SwipeCommitHaptic();

  // Ticks each time the titles cross the distance where letting go skips.
  // A follow swipe has no neighbour; its commit point is the travel.
  void _updateHaptic() => _haptic.update(
    _follows
        ? _travel.abs() >= PlayerTrackSwipe.followCommitDistance
        : !_settling &&
              _neighbor(_offset.value) != null &&
              _offset.value.abs() > _width * 0.25,
  );

  @override
  Widget build(BuildContext context) =>
      _SwipeScope(state: this, child: widget.child);
}

class _SwipeScope extends InheritedWidget {
  const _SwipeScope({required this.state, required super.child});

  final _PlayerTrackSwipeState state;

  @override
  bool updateShouldNotify(_SwipeScope oldWidget) => true;
}

/// Multiple hit regions can drive the same titles without moving their child.
class PlayerTrackSwipeRegion extends StatelessWidget {
  const PlayerTrackSwipeRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_SwipeScope>()
        ?.state;
    if (state == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Keep the initial movement when a cover/title tap competes with a swipe.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: state._start,
      onHorizontalDragUpdate: (details) {
        state._update(details);
        state._updateHaptic();
      },
      onHorizontalDragEnd: state._finish,
      onHorizontalDragCancel: state._finish,
      child: child,
    );
  }
}

class PlayerTrackSwipeTitles extends StatelessWidget {
  const PlayerTrackSwipeTitles({
    super.key,
    required this.current,
    required this.builder,
  });

  final MediaItem current;
  final Widget Function(MediaItem item) builder;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_SwipeScope>()
        ?.state;
    if (state == null) return builder(current);
    return PlayerTrackSwipeRegion(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          state._width = width > 0 ? width : 1;
          MediaItem? cachedNeighbor;
          double? cachedDirection;
          Widget? neighborTitle;
          return ClipRect(
            child: AnimatedBuilder(
              animation: state._offset,
              child: ClipRect(child: builder(current)),
              builder: (context, child) {
                final offset = state._offset.value;
                final next = state._neighbor(offset);
                if (offset != 0 && next != null) {
                  if (!identical(next, cachedNeighbor) ||
                      offset.sign != cachedDirection) {
                    cachedNeighbor = next;
                    cachedDirection = offset.sign;
                    neighborTitle = builder(next);
                  }
                }
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Transform.translate(
                      offset: Offset(offset, 0),
                      child: child,
                    ),
                    if (offset != 0 && next != null)
                      Positioned(
                        left: offset - state._pageExtent * offset.sign,
                        top: 0,
                        width: width,
                        child: ExcludeSemantics(
                          child: IgnorePointer(
                            child: ClipRect(child: neighborTitle),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}
