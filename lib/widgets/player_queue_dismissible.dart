import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoColors, CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/queue_swipe.dart';
import 'package:mornye/widgets/swipe_commit_haptic.dart';

/// Removing a row affects the queue only, never the song on disk.
///
/// The row swipes toward its start to remove the song. With [playNext] it
/// also swipes toward its end to play a copy of the song next, as song rows
/// swipe to play next ([QueueSwipe]), mirrored right to left.
class PlayerQueueDismissible extends StatefulWidget {
  const PlayerQueueDismissible({
    super.key,
    required this.onRemove,
    required this.child,
    this.enabled = true,
    this.playNext,
  });

  final VoidCallback onRemove;
  final Widget child;

  /// False (the current song, a locked queue) turns both swipes off.
  final bool enabled;

  /// The swipe toward the row's end, from [queueEntrySwipe]; null offers
  /// none.
  final QueueSwipeActions? playNext;

  @override
  State<PlayerQueueDismissible> createState() => _PlayerQueueDismissibleState();
}

class _PlayerQueueDismissibleState extends State<PlayerQueueDismissible>
    with SingleTickerProviderStateMixin {
  final _progress = ValueNotifier<double>(0);
  final _haptic = SwipeCommitHaptic();

  // Closes the row's gap before the song leaves, so the rows below follow
  // instead of jumping. An exit, so it is short and accelerates.
  late final _collapse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final _height = Tween<double>(
    begin: 1,
    end: 0,
  ).animate(CurvedAnimation(parent: _collapse, curve: Curves.easeIn));

  @override
  void dispose() {
    _collapse.dispose();
    _progress.dispose();
    super.dispose();
  }

  // The row never stays dismissed in the tree: Dismissible only ever hears
  // false, so a row the queue keeps (it became the playing song, or a
  // remote queue answers late) slides back. The service resolves the entry
  // by identity, and a row whose song left the queue during the collapse is
  // disposed before it can remove anything.
  Future<bool> _confirmRemove() async {
    if (!MediaQuery.disableAnimationsOf(context)) {
      try {
        await _collapse.forward().orCancel;
      } on TickerCanceled {
        return false;
      }
      if (!mounted) return false;
      if (!widget.enabled) {
        _collapse.reverse();
        return false;
      }
    }
    widget.onRemove();
    // A removed row leaves the list on the queue's next rebuild.
    await SchedulerBinding.instance.endOfFrame;
    if (mounted) await SchedulerBinding.instance.endOfFrame;
    if (mounted) _collapse.reverse();
    return false;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _height,
    builder: (context, child) => ClipRect(
      clipBehavior: _collapse.isDismissed ? Clip.none : Clip.hardEdge,
      child: Align(heightFactor: _height.value, widthFactor: 1, child: child),
    ),
    child: _buildDismissible(context),
  );

  Widget _buildDismissible(BuildContext context) => Dismissible(
    key: const ValueKey('queue-dismiss'),
    direction: widget.enabled
        ? DismissDirection.endToStart
        : DismissDirection.none,
    dismissThresholds: context.isMornye
        ? const {DismissDirection.endToStart: 0.5}
        : const {},
    onUpdate: (details) {
      _haptic.update(details.reached);
      if (context.isMornye) _progress.value = details.progress;
    },
    confirmDismiss: (_) => _confirmRemove(),
    background: context.isMornye
        ? _buildMornyeBackground(context)
        : Container(
            alignment: AlignmentDirectional.centerEnd,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              // Matches the queue sheet's row corners.
              borderRadius: BorderRadius.circular(16),
            ),
            child: AppIcon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.onError,
              semanticLabel: MaterialLocalizations.of(
                context,
              ).deleteButtonTooltip,
            ),
          ),
    child: _withPlayNext(context, widget.child),
  );

  /// Inside the row, so its recognizer sees a drag first: it takes the
  /// swipe toward the end and leaves the one toward the start to removal.
  Widget _withPlayNext(BuildContext context, Widget row) {
    final actions = widget.playNext;
    if (actions == null) return row;
    return QueueSwipe(
      actions: actions,
      enabled: widget.enabled,
      // Matches the queue sheet's row corners, as the removal strip does.
      borderRadius: BorderRadius.circular(context.isMornye ? 12 : 16),
      // One node, so screen readers find Play next on the row itself.
      child: MergeSemantics(
        child: Stack(
          children: [
            const Positioned.fill(child: QueueSwipeSemantics()),
            row,
          ],
        ),
      ),
    );
  }

  Widget _buildMornyeBackground(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemRed.resolveFrom(context),
      borderRadius: BorderRadius.circular(12),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<double>(
        valueListenable: _progress,
        child: Icon(
          CupertinoIcons.trash,
          color: Colors.white,
          size: 24,
          semanticLabel: context.l10n.dialogRemove,
        ),
        builder: (context, progress, icon) {
          final revealedWidth = constraints.maxWidth * progress;
          // Center in the revealed area first, then follow the song's edge.
          // Dismissible drives this during dragging, completion and reversal.
          final follow = Curves.easeOut.transform(
            ((progress - 0.5) / 0.25).clamp(0.0, 1.0),
          );
          final center = revealedWidth / 2;
          final inset = center + (center - 36).clamp(0.0, center) * follow;
          return Stack(
            children: [
              PositionedDirectional(
                end: inset - 12,
                top: 0,
                bottom: 0,
                child: icon!,
              ),
            ],
          );
        },
      ),
    ),
  );
}
