import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A vertical lazy list whose section headers pin and push one another away.
///
/// Only the active header is retained outside the viewport. Headers and rows
/// share one delegate, so offscreen sections do not build a sample track.
class PinnedSectionSliverList extends SliverList {
  const PinnedSectionSliverList({
    super.key,
    required super.delegate,
    required this.headerIndexes,
  });

  /// Sorted indexes of header children in [delegate].
  final List<int> headerIndexes;

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderPinnedSectionList(
        childManager: context as SliverMultiBoxAdaptorElement,
        headerIndexes: headerIndexes,
      );

  @override
  void updateRenderObject(BuildContext context, RenderSliverList renderObject) {
    (renderObject as _RenderPinnedSectionList).headerIndexes = headerIndexes;
  }
}

class _RenderPinnedSectionList extends RenderSliverList
    implements RenderAbstractViewport {
  _RenderPinnedSectionList({
    required super.childManager,
    required List<int> headerIndexes,
  }) : _headerIndexes = headerIndexes;

  List<int> _headerIndexes;
  RenderBox? _header;
  double? _pinnedOffset;

  set headerIndexes(List<int> value) {
    if (listEquals(value, _headerIndexes)) return;
    _headerIndexes = value;
    markNeedsLayout();
  }

  int? _sectionAt(int childIndex) {
    var low = 0;
    var high = _headerIndexes.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_headerIndexes[middle] <= childIndex) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? null : _headerIndexes[low - 1];
  }

  @override
  void performLayout() {
    assert(constraints.axisDirection == AxisDirection.down);
    assert(constraints.growthDirection == GrowthDirection.forward);
    _pinnedOffset = null;
    super.performLayout();
    if (geometry!.scrollOffsetCorrection != null) return;
    final oldHeader = _header?.parent == this ? _header : null;
    final pin = math.max(0.0, constraints.overlap);
    final leadingOffset = constraints.scrollOffset + pin;
    RenderBox? firstVisible;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (childScrollOffset(child)! + child.size.height > leadingOffset) {
        firstVisible = child;
        break;
      }
    }
    final headerIndex = firstVisible == null
        ? null
        : _sectionAt(indexOf(firstVisible));
    RenderBox? header;
    if (headerIndex != null) {
      for (var child = firstChild; child != null; child = childAfter(child)) {
        if (indexOf(child) == headerIndex) {
          header = child;
          break;
        }
      }
      if (header == null &&
          oldHeader != null &&
          indexOf(oldHeader) == headerIndex) {
        header = oldHeader;
      }
      if (header == null) {
        // Reverse scrolling can enter a section whose header was discarded.
        // Materialize only that header, then move it to the keep-alive bucket
        // before the list's next layout so its normal children stay contiguous.
        invokeLayoutCallback<SliverConstraints>((_) {
          childManager.createChild(headerIndex, after: null);
          final created = firstChild;
          if (created == null || indexOf(created) != headerIndex) return;
          final data = created.parentData! as SliverMultiBoxAdaptorParentData;
          // Its natural offset is unknown. A keyed replacement must not
          // inherit a synthetic offset and shift the list after a rebuild.
          data
            ..keepAlive = true
            ..layoutOffset = null;
          header = created;
        });
        if (header != null) super.collectGarbage(1, 0);
      }
    }
    if (oldHeader != null && oldHeader != header) {
      (oldHeader.parentData! as SliverMultiBoxAdaptorParentData).keepAlive =
          false;
    }
    _header = header;
    if (header != null) {
      final data = header!.parentData! as SliverMultiBoxAdaptorParentData;
      data.keepAlive = true;
      if (data.keptAlive || !header!.hasSize) {
        header!.layout(constraints.asBoxConstraints(), parentUsesSize: true);
      }
      final natural = data.keptAlive
          ? -header!.size.height
          : childScrollOffset(header!)! - constraints.scrollOffset;
      if (natural < pin) {
        var offset = math.min(
          pin,
          geometry!.scrollExtent -
              constraints.scrollOffset -
              header!.size.height,
        );
        for (var child = firstChild; child != null; child = childAfter(child)) {
          if (indexOf(child) > headerIndex! &&
              _sectionAt(indexOf(child)) == indexOf(child)) {
            offset = math.min(
              offset,
              childScrollOffset(child)! -
                  constraints.scrollOffset -
                  header!.size.height,
            );
            break;
          }
        }
        _pinnedOffset = offset;
      }
    }
    // Release the previous retained header, including after sorting/filtering.
    super.collectGarbage(0, 0);
  }

  @override
  double childMainAxisPosition(RenderBox child) =>
      child == _header && _pinnedOffset != null
      ? _pinnedOffset!
      : super.childMainAxisPosition(child);

  @override
  double? childScrollOffset(RenderObject child) =>
      child == _header && _pinnedOffset != null
      ? constraints.scrollOffset + _pinnedOffset!
      : super.childScrollOffset(child);

  RenderBox? _directChild(RenderObject target) {
    var child = target;
    while (child.parent != this) {
      final parent = child.parent;
      if (parent == null) return null;
      child = parent;
    }
    return child is RenderBox ? child : null;
  }

  double _revealObstruction(RenderObject target) {
    final child = _directChild(target);
    if (child == null) return 0;
    final headerIndex = _sectionAt(indexOf(child));
    if (headerIndex == null || headerIndex == indexOf(child)) return 0;
    final header = _header;
    if (header != null && indexOf(header) == headerIndex) {
      return header.size.height;
    }
    for (var item = firstChild; item != null; item = childAfter(item)) {
      if (indexOf(item) == headerIndex) return item.size.height;
    }
    return 0;
  }

  @override
  RevealedOffset getOffsetToReveal(
    RenderObject target,
    double alignment, {
    Rect? rect,
    Axis? axis,
  }) {
    final viewport = RenderAbstractViewport.of(parent);
    final revealed = viewport.getOffsetToReveal(
      target,
      alignment,
      rect: rect,
      axis: axis,
    );
    if (_directChild(target) == _header &&
        _pinnedOffset != null &&
        viewport is RenderViewportBase) {
      final correction = math.min(
        0.0,
        _pinnedOffset! - math.max(0.0, constraints.overlap),
      );
      final targetRect = MatrixUtils.transformRect(
        target.getTransformTo(viewport),
        rect ?? target.paintBounds,
      );
      return RevealedOffset(
        offset: viewport.offset.pixels + correction,
        rect: targetRect.translate(0, -correction),
      );
    }
    // Only rows in this list are obstructed. Advertising a sliver-wide
    // obstruction would also classify every row as pinned and affect later
    // slivers, so apply the header inset to this target's reveal instead.
    final inset = _revealObstruction(target) * (1 - alignment);
    return RevealedOffset(
      offset: revealed.offset - inset,
      rect: revealed.rect.translate(0, inset),
    );
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    final child = descendant == null ? null : _directChild(descendant);
    final inset = descendant == null ? 0.0 : _revealObstruction(descendant);
    if (child != null && inset > 0) {
      final targetRect = MatrixUtils.transformRect(
        descendant!.getTransformTo(child),
        rect ?? descendant.paintBounds,
      );
      super.showOnScreen(
        descendant: child,
        rect: Rect.fromLTRB(
          targetRect.left,
          targetRect.top - inset,
          targetRect.right,
          targetRect.bottom,
        ),
        duration: duration,
        curve: curve,
      );
      return;
    }
    super.showOnScreen(
      descendant: descendant,
      rect: rect,
      duration: duration,
      curve: curve,
    );
  }

  @override
  bool paintsChild(RenderBox child) =>
      (child == _header && _pinnedOffset != null) || super.paintsChild(child);

  @override
  void paint(PaintingContext context, Offset offset) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (child == _header && _pinnedOffset != null) continue;
      final y = childMainAxisPosition(child);
      if (y < constraints.remainingPaintExtent && y + child.size.height > 0) {
        context.paintChild(child, offset + Offset(0, y));
      }
    }
    final header = _header;
    final y = _pinnedOffset;
    if (header != null && y != null && y + header.size.height > 0) {
      context.paintChild(header, offset + Offset(0, y));
    }
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    final header = _header;
    if (header != null &&
        _pinnedOffset != null &&
        hitTestBoxChild(
          BoxHitTestResult.wrap(result),
          header,
          mainAxisPosition: mainAxisPosition,
          crossAxisPosition: crossAxisPosition,
        )) {
      return true;
    }
    return super.hitTestChildren(
      result,
      mainAxisPosition: mainAxisPosition,
      crossAxisPosition: crossAxisPosition,
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    super.visitChildrenForSemantics(visitor);
    final header = _header;
    if (header != null &&
        _pinnedOffset != null &&
        (header.parentData! as SliverMultiBoxAdaptorParentData).keptAlive) {
      visitor(header);
    }
  }
}
