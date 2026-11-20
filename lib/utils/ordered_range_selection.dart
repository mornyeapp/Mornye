/// Adds every visible item between [anchor] and [target] to [selected].
///
/// Dart's default [Set] preserves insertion order, so walking backwards also
/// preserves the direction chosen by the user when results are later copied,
/// shared, or batch processed.
T addOrderedSelectionRange<T>({
  required Set<T> selected,
  required List<T> visibleItems,
  required T target,
  T? anchor,
}) {
  final anchorIndex = anchor == null ? -1 : visibleItems.indexOf(anchor);
  final targetIndex = visibleItems.indexOf(target);
  if (anchorIndex < 0 || targetIndex < 0) {
    selected.add(target);
    return target;
  }

  final step = targetIndex >= anchorIndex ? 1 : -1;
  for (var index = anchorIndex; ; index += step) {
    selected.add(visibleItems[index]);
    if (index == targetIndex) break;
  }
  return target;
}

/// Sets [selected] to [base] plus every visible item between [anchor] and
/// [target]: the selection of a finger sliding from one row to another, where
/// sliding back releases the rows it had passed but none of [base].
void applySlideSelection<T>({
  required Set<T> selected,
  required Set<T> base,
  required List<T> visibleItems,
  required T anchor,
  required T target,
}) {
  final anchorIndex = visibleItems.indexOf(anchor);
  final targetIndex = visibleItems.indexOf(target);
  if (anchorIndex < 0 || targetIndex < 0) return;
  selected
    ..clear()
    ..addAll(base);
  final step = targetIndex >= anchorIndex ? 1 : -1;
  for (var index = anchorIndex; ; index += step) {
    selected.add(visibleItems[index]);
    if (index == targetIndex) break;
  }
}

/// Toggles one item and returns the next range-selection anchor.
T? toggleOrderedSelection<T>({required Set<T> selected, required T target}) {
  if (selected.add(target)) return target;
  selected.remove(target);
  return selected.isEmpty ? null : selected.last;
}
