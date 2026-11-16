import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/features/link_auto_keep.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';

export 'package:mornye/services/link/features/link_auto_keep.dart'
    show linkKeptLoved, linkKeptPlaylist;

/// The More menu action of a playlist or Loved ([collection], a
/// [linkKeptPlaylist] id or [linkKeptLoved]) that keeps it on this phone or
/// stops keeping it. Shown on phones while a computer is paired, and while
/// the collection is kept so it can be stopped. Null otherwise.
ContextMenuAction? linkKeepAction(
  BuildContext context,
  WidgetRef ref,
  String collection,
) {
  if (isDesktopPlatform) return null;
  final kept =
      ref.read(linkKeptCollectionsProvider).value?.contains(collection) ??
      false;
  if (!kept && ref.read(linkPhoneClientProvider) == null) return null;
  final l10n = context.l10n;
  return ContextMenuAction(
    icon: Icons.phone_android,
    label: kept ? l10n.linkKeepOnPhoneStop : l10n.linkKeepOnPhone,
    onSelected: () => unawaited(
      ref.read(linkKeptCollectionsProvider.notifier).setKept(collection, !kept),
    ),
  );
}

/// A collection header's meta row ([items]), which ends with "Kept on this
/// phone" while [collection] is kept. The label fades in on the fast effects
/// spring and the row resizes on the spatial spring when it is kept from
/// the open page; both are still with reduced motion and in the Mornye
/// style, whose header meta never moves.
class LinkKeptMetaRow extends ConsumerStatefulWidget {
  const LinkKeptMetaRow({
    super.key,
    required this.collection,
    required this.items,
  });

  /// A [linkKeptPlaylist] id or [linkKeptLoved], or null for none.
  final String? collection;
  final List<Widget> items;

  @override
  ConsumerState<LinkKeptMetaRow> createState() => _LinkKeptMetaRowState();
}

class _LinkKeptMetaRowState extends ConsumerState<LinkKeptMetaRow> {
  /// Whether the label showed when the page opened, which it then does
  /// without fading in.
  bool? _keptAtStart;

  static const _still = AppMotionSpec(Duration.zero, Curves.linear);

  @override
  Widget build(BuildContext context) {
    final collection = widget.collection;
    // Null until the marks have loaded.
    final stored = collection == null || isDesktopPlatform
        ? false
        : ref.watch(
            linkKeptCollectionsProvider.select(
              (kept) => kept.hasValue ? kept.value!.contains(collection) : null,
            ),
          );
    final kept = stored ?? false;
    if (stored != null) {
      // Once hidden, keeping it again fades the label in.
      _keptAtStart = kept && (_keptAtStart ?? true);
    }
    final keptAtStart = _keptAtStart ?? false;
    final size = AppMotion.spatial(context, _still);
    final fade = AppMotion.effectsFast(context, _still);
    final moves = size.duration > Duration.zero;
    final row = HeaderMetaRow(
      items: [
        ...widget.items,
        if (kept)
          TweenAnimationBuilder<double>(
            key: const ValueKey('link-kept-on-phone'),
            tween: Tween(begin: keptAtStart || !moves ? 1 : 0, end: 1),
            duration: fade.duration,
            curve: fade.curve,
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: HeaderMetaItem(
              context.l10n.linkKeptOnPhone,
              icon: Icons.phone_android,
            ),
          ),
      ],
    );
    // A zero-length AnimatedSize re-dirties itself during layout.
    if (!moves) return row;
    return AnimatedSize(duration: size.duration, curve: size.curve, child: row);
  }
}
