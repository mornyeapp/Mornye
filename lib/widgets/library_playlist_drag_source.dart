import 'package:material_ui/material_ui.dart';

/// Owns the long press for both selection and playlist dragging. The card
/// inside must not register a competing onLongPress gesture while this is
/// [enabled].
class LibraryPlaylistDragSource<T extends Object> extends StatelessWidget {
  const LibraryPlaylistDragSource({
    super.key,
    required this.data,
    required this.onSelect,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.feedbackBuilder,
    required this.child,
    this.enabled = true,
  });

  /// False while the card inside takes the long press itself.
  final bool enabled;
  final T data;
  final VoidCallback onSelect;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final WidgetBuilder feedbackBuilder;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    onLongPress: enabled ? onSelect : null,
    child: LongPressDraggable<T>(
      data: data,
      maxSimultaneousDrags: enabled ? 1 : 0,
      hapticFeedbackOnStart: false,
      onDragStarted: () {
        onDragStarted();
        onSelect();
      },
      onDragEnd: (_) => onDragEnd(),
      // Build after onSelect so the feedback reflects the selected batch.
      feedback: Builder(builder: feedbackBuilder),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    ),
  );
}
