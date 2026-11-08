import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/swipe_commit_haptic.dart';

/// What a sideways swipe on a song row queues.
///
/// The swipe toward the end of the row (rightward in a left-to-right layout)
/// plays the song next and the swipe toward its start adds it to the end of
/// the queue, in both styles.
class QueueSwipeActions {
  const QueueSwipeActions(this.enqueue);

  /// Queues the row's song next ([playNext]) or last. Resolves false when
  /// it found nothing to queue, so no confirmation shows.
  final Future<bool> Function({required bool playNext}) enqueue;
}

/// Phones and tablets offer the swipe and its setting. Desktop and Android
/// TV keep their pointer and remote menus only.
bool get queueSwipeOffered => !isDesktopPlatform && !isAndroidTv;

/// Whether song rows take the queue swipe: where it is offered, with the
/// setting on, while the menus offer Play next and Add to queue.
bool queueSwipeEnabled(WidgetRef ref) =>
    queueSwipeOffered &&
    ref.watch(settingsProvider.select((s) => s.swipeToQueue)) &&
    ref.watch(playerUiEnabledProvider);

/// The swipe for a library song, running the menus' own queue actions.
QueueSwipeActions? libraryItemQueueSwipe(
  WidgetRef ref,
  UnifiedLibraryItem item,
) => resolvedLibraryItemQueueSwipe(ref, () async => item);

/// The swipe for a library song that a row resolves on demand, such as a
/// search result. Nothing queues when [resolve] finds no song.
QueueSwipeActions? resolvedLibraryItemQueueSwipe(
  WidgetRef ref,
  Future<UnifiedLibraryItem?> Function() resolve,
) {
  if (!queueSwipeEnabled(ref)) return null;
  final controller = ref.read(musicPlayerControllerProvider);
  return QueueSwipeActions(({required playNext}) async {
    final item = await resolve();
    if (item == null) return false;
    await controller.enqueueLibraryItems([item], playNext: playNext);
    return true;
  });
}

/// The swipe for a row whose files resolve on demand, such as a playlist
/// song matched to a download or a local file.
QueueSwipeActions? mediaQueueSwipe(
  WidgetRef ref,
  Future<List<PlayableMedia>> Function() resolve,
) {
  if (!queueSwipeEnabled(ref)) return null;
  final controller = ref.read(musicPlayerControllerProvider);
  return QueueSwipeActions(({required playNext}) async {
    final media = await resolve();
    if (media.isEmpty) return false;
    await controller.enqueueMedia(media, playNext: playNext);
    return true;
  });
}

/// A partial sideways swipe on a song row that plays the song next or adds
/// it to the queue, then springs back; the row is never removed.
///
/// The row slides over a strip that names the action. Letting go past
/// [commitDistance], or flinging past half of it, runs the action and
/// confirms it with a snackbar; a haptic tick marks the point where letting
/// go would commit. The drag must be clearly sideways, so vertical scrolling
/// keeps every diagonal drag, and touches that start at a screen edge stay
/// with the system and the iOS back swipe. Rows inside a sideways scroller
/// (a pager, tabs, a carousel) skip the swipe so it never fights the page
/// swipe. A [QueueSwipeSemantics] inside the row offers both actions to
/// screen readers; the row's menus keep them reachable without a swipe.
class QueueSwipe extends StatefulWidget {
  const QueueSwipe({
    super.key,
    required this.actions,
    required this.child,
    this.enabled = true,
    this.margin = EdgeInsets.zero,
    this.borderRadius = BorderRadius.zero,
  });

  /// Null leaves the row without the swipe.
  final QueueSwipeActions? actions;

  /// Turns the swipe off (selection mode) without rebuilding [child].
  final bool enabled;

  /// The row's outer margin, which the Material strip stays inside.
  final EdgeInsetsGeometry margin;

  /// The row's corners, which the Material strip takes.
  final BorderRadius borderRadius;

  final Widget child;

  /// Travel that commits a swipe on a row [width] wide.
  static double commitDistance(double width) =>
      (width * 0.25).clamp(72.0, 128.0);

  /// Width at each screen edge where a touch never starts the swipe.
  static const edgeExclusion = 24.0;

  /// Release speed that commits a swipe past half of [commitDistance].
  static const flingVelocity = 700.0;

  @override
  State<QueueSwipe> createState() => _QueueSwipeState();
}

class _QueueSwipeState extends State<QueueSwipe>
    with SingleTickerProviderStateMixin {
  /// Critically damped, so the row never passes its rest position and
  /// flashes the other action.
  static final _returnSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: M3EMotion.expressiveSpatialFast.stiffness,
    ratio: 1,
  );

  late final _offset = AnimationController.unbounded(vsync: this);
  final _haptic = SwipeCommitHaptic();
  double _drag = 0;
  double _width = 0;
  bool? _insidePager;

  bool get _active =>
      widget.enabled && widget.actions != null && !(_insidePager ?? false);

  double get _threshold => QueueSwipe.commitDistance(_width);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _insidePager ??= _insideSidewaysScroller(context);
  }

  @override
  void didUpdateWidget(QueueSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active && (_drag != 0 || _offset.value != 0)) _reset();
  }

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  /// A row inside a horizontal scroller that the user can drag: its page
  /// swipe wins. Ancestors do not change while the row is mounted.
  static bool _insideSidewaysScroller(BuildContext context) {
    var found = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == Axis.horizontal &&
          _userScrollable(widget.physics)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  static bool _userScrollable(ScrollPhysics? physics) {
    for (var p = physics; p != null; p = p.parent) {
      if (p is NeverScrollableScrollPhysics) return false;
    }
    return true;
  }

  bool _allowStart(Offset position) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return true;
    final left = math.max(
      QueueSwipe.edgeExclusion,
      math.max(media.systemGestureInsets.left, media.padding.left),
    );
    final right = math.max(
      QueueSwipe.edgeExclusion,
      math.max(media.systemGestureInsets.right, media.padding.right),
    );
    return position.dx >= left && position.dx <= media.size.width - right;
  }

  /// Whether a drag of [drag] logical pixels (positive is rightward) plays
  /// next: the swipe toward the end of the row.
  bool _playsNext(double drag) =>
      Directionality.of(context) == TextDirection.rtl ? drag < 0 : drag > 0;

  /// The row follows the finger up to the threshold and with resistance
  /// beyond, never further than half its width.
  double _visualOffset(double drag) {
    final threshold = _threshold;
    final distance = drag.abs();
    final travel = distance <= threshold
        ? distance
        : threshold + (distance - threshold) * 0.3;
    return drag.sign * math.min(travel, _width / 2);
  }

  void _onStart(DragStartDetails details) {
    _offset.stop();
    _width = context.size?.width ?? 0;
    _drag = _offset.value;
  }

  void _onUpdate(DragUpdateDetails details) {
    _drag += details.primaryDelta ?? 0;
    _offset.value = _visualOffset(_drag);
    _haptic.update(_drag.abs() >= _threshold);
  }

  void _onEnd(DragEndDetails details) {
    final drag = _drag;
    final velocity = details.primaryVelocity ?? 0;
    final commit =
        drag.abs() >= _threshold ||
        (velocity.abs() >= QueueSwipe.flingVelocity &&
            velocity.sign == drag.sign &&
            drag.abs() >= _threshold / 2);
    _settle();
    if (commit && drag != 0) _run(playNext: _playsNext(drag));
  }

  void _settle() {
    _haptic.update(false);
    _drag = 0;
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _offset.value = 0;
      return;
    }
    // The spring stops within half a pixel; land exactly on rest unless a
    // new drag took the row over.
    _offset
        .animateWith(
          SpringSimulation(
            _returnSpring,
            _offset.value,
            0,
            0,
            tolerance: const Tolerance(distance: 0.5, velocity: 10),
          ),
        )
        .then((_) {
          if (mounted && _drag == 0) _offset.value = 0;
        });
  }

  void _reset() {
    _haptic.update(false);
    _drag = 0;
    _offset.stop();
    _offset.value = 0;
  }

  Future<void> _run({required bool playNext}) async {
    final actions = widget.actions;
    if (actions == null) return;
    try {
      final queued = await actions.enqueue(playNext: playNext);
      if (!queued || !mounted) return;
      showAppSnackBar(
        context,
        content: Text(
          playNext
              ? context.l10n.snackbarPlayingNext
              : context.l10n.snackbarAddedToQueueGeneric,
        ),
      );
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return _QueueSwipeScope(
      run: active ? _run : null,
      child: RawGestureDetector(
        gestures: active
            ? {
                _QueueSwipeRecognizer:
                    GestureRecognizerFactoryWithHandlers<_QueueSwipeRecognizer>(
                      () => _QueueSwipeRecognizer(debugOwner: this),
                      (recognizer) => recognizer
                        ..allowStart = _allowStart
                        ..onStart = _onStart
                        ..onUpdate = _onUpdate
                        ..onEnd = _onEnd
                        ..onCancel = _settle,
                    ),
              }
            : const {},
        child: AnimatedBuilder(
          animation: _offset,
          child: widget.child,
          builder: (context, child) {
            final offset = _offset.value;
            return Stack(
              children: [
                if (offset != 0)
                  Positioned.fill(
                    child: ExcludeSemantics(child: _strip(context, offset)),
                  ),
                Transform.translate(offset: Offset(offset, 0), child: child),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The strip the row uncovers: it fills the gap between the row's edge
  /// and where the row now starts, and names the action.
  Widget _strip(BuildContext context, double offset) {
    final playNext = _playsNext(offset);
    final reached = _drag.abs() >= _threshold;
    final progress = (_drag.abs() / _threshold).clamp(0.0, 1.0);
    final fromLeft = offset > 0;
    final label = playNext
        ? context.l10n.trackPlayNext
        : context.l10n.trackAddToQueue;
    final icon = playNext ? Icons.playlist_play : Icons.queue_music;
    final align = fromLeft ? Alignment.centerLeft : Alignment.centerRight;

    if (context.isMornye) {
      // Mornye follows the iOS row actions: a full-height system colour
      // with a white symbol over its title.
      final color = CupertinoDynamicColor.resolve(
        playNext ? CupertinoColors.systemIndigo : CupertinoColors.systemOrange,
        context,
      );
      return Align(
        alignment: align,
        child: SizedBox(
          width: offset.abs(),
          child: ClipRect(
            child: ColoredBox(
              color: color,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                alignment: align,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon.adaptive(icon, color: CupertinoColors.white),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        style: const TextStyle(
                          color: CupertinoColors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Material: a tonal strip in the row's own shape, inside its margin.
    // With expressive motion the icon grows with the swipe and the fill
    // deepens once letting go would commit.
    final colorScheme = Theme.of(context).colorScheme;
    final expressive = materialExpressiveEnabled(context);
    final fill = playNext
        ? (reached ? colorScheme.primary : colorScheme.primaryContainer)
        : (reached ? colorScheme.tertiary : colorScheme.tertiaryContainer);
    final onFill = playNext
        ? (reached ? colorScheme.onPrimary : colorScheme.onPrimaryContainer)
        : (reached ? colorScheme.onTertiary : colorScheme.onTertiaryContainer);
    final scale = expressive ? 0.7 + 0.45 * progress : 1.0;
    return Padding(
      padding: widget.margin,
      child: Align(
        alignment: align,
        child: SizedBox(
          width: offset.abs(),
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: AnimatedContainer(
              duration: expressive
                  ? const Duration(milliseconds: 150)
                  : Duration.zero,
              color: fill,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                alignment: align,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: scale,
                        child: AppIcon(icon, color: onFill),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        maxLines: 1,
                        style: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(color: onFill),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueSwipeScope extends InheritedWidget {
  const _QueueSwipeScope({required this.run, required super.child});

  /// Runs an action with the swipe's confirmation; null while inactive.
  final Future<void> Function({required bool playNext})? run;

  @override
  bool updateShouldNotify(_QueueSwipeScope oldWidget) =>
      (run == null) != (oldWidget.run == null);
}

/// Offers the enclosing [QueueSwipe]'s actions to screen readers as custom
/// actions. Place it inside the row's own semantics node (inside its card,
/// filling it), so the actions join the row rather than the list around it.
class QueueSwipeSemantics extends StatelessWidget {
  const QueueSwipeSemantics({super.key});

  @override
  Widget build(BuildContext context) {
    final run = context
        .dependOnInheritedWidgetOfExactType<_QueueSwipeScope>()
        ?.run;
    final l10n = context.l10n;
    return Semantics(
      customSemanticsActions: run == null
          ? null
          : {
              CustomSemanticsAction(label: l10n.trackPlayNext): () =>
                  run(playNext: true),
              CustomSemanticsAction(label: l10n.trackAddToQueue): () =>
                  run(playNext: false),
            },
      child: const SizedBox.expand(),
    );
  }
}

/// A horizontal drag that only wins a clearly sideways movement (at least
/// twice as wide as it is tall) and ignores touches that start where
/// [allowStart] says no. Mice and trackpads never start it.
class _QueueSwipeRecognizer extends HorizontalDragGestureRecognizer {
  _QueueSwipeRecognizer({super.debugOwner})
    : super(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      );

  bool Function(Offset position)? allowStart;
  final _origins = <int, Offset>{};
  Offset _travel = Offset.zero;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (allowStart?.call(event.position) ?? true) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origins[event.pointer] = event.position;
    _travel = Offset.zero;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (_origins[event.pointer] case final origin?) {
        _travel = event.position - origin;
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _origins.remove(event.pointer);
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind,
        deviceTouchSlop,
      ) &&
      _travel.dx.abs() >= _travel.dy.abs() * 2;
}
