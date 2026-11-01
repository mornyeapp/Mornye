import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/track_card.dart';

/// Editing has its own drag gestures, leaving normal track selection intact.
class CollectionReorderSliver extends StatefulWidget {
  const CollectionReorderSliver({
    super.key,
    required this.entries,
    required this.onReorder,
    required this.onDraggingChanged,
    this.enabled = true,
  });

  final List<CollectionTrackEntry> entries;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<bool> onDraggingChanged;
  final bool enabled;

  @override
  State<CollectionReorderSliver> createState() =>
      _CollectionReorderSliverState();
}

class _CollectionReorderSliverState extends State<CollectionReorderSliver> {
  int? _dragStartIndex;

  void _finishDragging() {
    _dragStartIndex = null;
    if (mounted) widget.onDraggingChanged(false);
  }

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
    sliver: SliverReorderableList(
      itemCount: widget.entries.length,
      onReorderItem: (oldIndex, newIndex) {
        widget.onReorder(oldIndex, newIndex);
        _finishDragging();
      },
      onReorderStart: (index) {
        _dragStartIndex = index;
        HapticFeedback.selectionClick();
        widget.onDraggingChanged(true);
      },
      onReorderEnd: (index) {
        final start = _dragStartIndex;
        if (start == null) return;
        final destination = index > start ? index - 1 : index;
        // Changed drops commit after the proxy finishes returning to its row.
        if (destination == start) _finishDragging();
      },
      itemBuilder: (context, index) {
        final entry = widget.entries[index];
        final track = entry.track;
        final size = context.tokens.coverCompact;
        return ReorderableDelayedDragStartListener(
          key: ValueKey(entry.key),
          enabled: widget.enabled,
          index: index,
          child: Listener(
            onPointerCancel: (_) {
              if (_dragStartIndex == index) _finishDragging();
            },
            child: Semantics(
              customSemanticsActions: {
                if (widget.enabled && index > 0)
                  CustomSemanticsAction(label: context.l10n.queueMoveUp): () =>
                      widget.onReorder(index, index - 1),
                if (widget.enabled && index < widget.entries.length - 1)
                  CustomSemanticsAction(
                    label: context.l10n.queueMoveDown,
                  ): () =>
                      widget.onReorder(index, index + 1),
              },
              child: TrackCard(
                style: TrackCardStyle.flat,
                leadingArtwork: true,
                leading: ClipRRect(
                  borderRadius: context.tokens.borderRadiusThumb,
                  child: track.coverUrl?.isNotEmpty == true
                      ? LocalOrNetworkCoverImage(
                          url: track.coverUrl!,
                          width: size,
                          height: size,
                          networkCacheWidth: (size * 2).toInt(),
                          placeholder: (_) => TrackCoverPlaceholder(size: size),
                        )
                      : TrackCoverPlaceholder(size: size),
                ),
                title: track.name,
                subtitle: Text(
                  track.artistName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: ReorderableDragStartListener(
                  enabled: widget.enabled,
                  index: index,
                  child: SizedBox.square(
                    key: ValueKey('collection-order-handle-${entry.key}'),
                    dimension: context.tokens.minTouchTarget,
                    child: AppIcon.adaptive(
                      Icons.drag_handle,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
