import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';

class MornyePlayerFavoriteButton extends ConsumerStatefulWidget {
  const MornyePlayerFavoriteButton({
    super.key,
    required this.mediaItem,
    this.compact = false,
    this.color,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
  });

  final MediaItem mediaItem;
  final bool compact;
  final Color? color;
  final double? iconSize;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<MornyePlayerFavoriteButton> createState() =>
      _MornyePlayerFavoriteButtonState();
}

class _MornyePlayerFavoriteButtonState
    extends ConsumerState<MornyePlayerFavoriteButton> {
  bool _saving = false;

  Future<void> _toggle() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final provider = playerCollectionTrackProvider(widget.mediaItem);
      if (ref.read(provider).hasError) ref.invalidate(provider);
      final track = await ref.read(provider.future);
      if (!mounted) return;
      await ref.read(libraryCollectionsProvider.notifier).toggleLoved(track);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = ref
        .watch(playerCollectionTrackProvider(widget.mediaItem))
        .value;
    final loved = ref.watch(
      libraryCollectionsProvider.select(
        (state) => track != null && state.isLoved(track),
      ),
    );
    return Semantics(
      toggled: loved,
      child: MornyePlaybackButton(
        icon: loved ? CupertinoIcons.star_fill : CupertinoIcons.star,
        tooltip: loved
            ? context.l10n.trackOptionRemoveFromLoved
            : context.l10n.trackOptionAddToLoved,
        color: widget.color ?? Theme.of(context).colorScheme.onSurface,
        iconSize: widget.iconSize ?? (widget.compact ? 28 : 24),
        padding: widget.padding,
        onPressed: _saving ? null : _toggle,
      ),
    );
  }
}
