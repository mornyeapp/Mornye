import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Shares one horizontal gesture between the artwork and track metadata.
/// Both surfaces preview the adjacent queue item before playback is committed.
class PlayerTrackSwipe extends StatefulWidget {
  const PlayerTrackSwipe({
    super.key,
    required this.queue,
    required this.currentIndex,
    required this.onSelected,
    required this.child,
  });

  final List<MediaItem> queue;
  final int currentIndex;
  final Future<void> Function(MediaItem) onSelected;
  final Widget child;

  @override
  State<PlayerTrackSwipe> createState() => _PlayerTrackSwipeState();
}

class _PlayerTrackSwipeState extends State<PlayerTrackSwipe>
    with SingleTickerProviderStateMixin {
  static const _titleGap = 32.0;

  late final _offset = AnimationController.unbounded(vsync: this);
  double _width = 240;
  double? _artworkWidth;
  double get _pageExtent =>
      ((_artworkWidth ?? 0) > _width ? _artworkWidth! : _width) + _titleGap;
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

  void _start(DragStartDetails details) {
    if (_settling) return;
    _offset.stop();
    _drag = _offset.value;
  }

  void _update(DragUpdateDetails details) {
    if (_settling) return;
    _drag += details.primaryDelta ?? 0;
    _offset.value = _neighbor(_drag) == null
        ? _drag * 0.18 / (1 + _drag.abs() / _width)
        : _drag.clamp(-_pageExtent, _pageExtent);
  }

  Future<void> _finish([DragEndDetails? details]) async {
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
    _settling = true;
    try {
      await _offset
          .animateTo(
            commit ? _pageExtent * offset.sign : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
      if (!mounted || generation != _generation) return;
      if (commit) await widget.onSelected(target);
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
      onHorizontalDragUpdate: state._update,
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

/// Slides the artwork with the track metadata while a queue swipe is in
/// progress. The neighbor is built lazily and is not interactive or announced
/// to accessibility services until it becomes the current track.
class PlayerTrackSwipeArtwork extends StatelessWidget {
  const PlayerTrackSwipeArtwork({
    super.key,
    required this.builder,
    required this.child,
  });

  final Widget Function(MediaItem item) builder;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_SwipeScope>()
        ?.state;
    if (state == null) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (state._artworkWidth ?? state._width);
        if (width > 0) state._artworkWidth = width;
        MediaItem? cachedNeighbor;
        double? cachedDirection;
        Widget? neighborArtwork;
        return AnimatedBuilder(
          animation: state._offset,
          child: child,
          builder: (context, currentArtwork) {
            final offset = state._offset.value;
            final next = state._neighbor(offset);
            if (offset != 0 && next != null) {
              if (!identical(next, cachedNeighbor) ||
                  offset.sign != cachedDirection) {
                cachedNeighbor = next;
                cachedDirection = offset.sign;
                neighborArtwork = builder(next);
              }
            }
            return ClipRect(
              // Keep the resting artwork's shadow and Hero flight intact.
              clipBehavior: offset == 0 ? Clip.none : Clip.hardEdge,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Transform.translate(
                    offset: Offset(offset, 0),
                    child: currentArtwork,
                  ),
                  if (offset != 0 && next != null)
                    Positioned(
                      left: offset - state._pageExtent * offset.sign,
                      top: 0,
                      bottom: 0,
                      width: width,
                      child: ExcludeSemantics(
                        child: IgnorePointer(child: neighborArtwork),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
