import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

class PlayerArtwork extends StatelessWidget {
  /// Shared decode for the mini player and the full player's blurred cover.
  static const miniCacheWidth = 132;

  /// An HTTP(S) URL, file URI, absolute local artwork path, or `network://`
  /// cover reference.
  final String? artUri;
  final ColorScheme colorScheme;
  final int? cacheWidth;
  final double iconSize;

  /// Fades a new cover in over the previous one once the new image has a
  /// frame, so a track change never shows an empty or half-decoded cover.
  /// Null, a zero duration or reduced motion swap the cover at once.
  final AppMotionSpec? crossfade;

  const PlayerArtwork({
    super.key,
    required this.artUri,
    required this.colorScheme,
    this.cacheWidth,
    this.iconSize = 40,
    this.crossfade,
  });

  /// Share one full-size decode while artwork moves between player panels.
  static int transitionCacheWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).shortestSide *
              MediaQuery.devicePixelRatioOf(context))
          .round();

  Widget _placeholder() => Container(
    color: colorScheme.surfaceContainerHighest,
    child: AppIcon(
      Icons.music_note,
      size: iconSize,
      color: colorScheme.onSurfaceVariant,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final motion = crossfade;
    if (motion != null &&
        motion.duration > Duration.zero &&
        !MediaQuery.disableAnimationsOf(context)) {
      return _ArtworkCrossfade(artUri: artUri, motion: motion, builder: _layer);
    }
    final placeholder = _placeholder();

    final uri = artUri;
    if (isHttpCoverUrl(uri)) {
      return CachedNetworkImage(
        imageUrl: uri!,
        fit: BoxFit.cover,
        cacheManager: CoverCacheManager.instance,
        memCacheWidth: cacheWidth,
        fadeInDuration: Duration.zero,
        fadeOutDuration: const Duration(milliseconds: 0),
        useOldImageOnUrlChange: true,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    final image = coverImageProvider(uri, cacheWidth: cacheWidth);
    if (image == null) {
      return pendingCover(uri, placeholder: placeholder, builder: build);
    }
    return Image(
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
    );
  }

  /// One cover of a crossfade. [onShown] runs once it shows something final:
  /// its first frame, an error or the placeholder of a cover without image.
  Widget _layer(BuildContext context, String? uri, VoidCallback onShown) {
    final placeholder = _placeholder();
    final image = coverImageProvider(uri, cacheWidth: cacheWidth);
    if (image == null) {
      if (!CoverStore.fetches(uri)) onShown();
      return pendingCover(
        uri,
        placeholder: placeholder,
        builder: (context) => _layer(context, uri, onShown),
      );
    }
    return Image(
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, synchronous) {
        if (frame == null && !synchronous) return placeholder;
        onShown();
        return child;
      },
      errorBuilder: (_, _, _) {
        onShown();
        return placeholder;
      },
    );
  }
}

class _ArtworkLayer {
  _ArtworkLayer(this.uri, this.opacity);

  final String? uri;
  final AnimationController opacity;
  final key = UniqueKey();
  bool shown = false;
}

/// Keeps the previous cover under the new one until the new one has a frame,
/// then fades the new one in over it.
class _ArtworkCrossfade extends StatefulWidget {
  const _ArtworkCrossfade({
    required this.artUri,
    required this.motion,
    required this.builder,
  });

  final String? artUri;
  final AppMotionSpec motion;
  final Widget Function(BuildContext, String?, VoidCallback onShown) builder;

  @override
  State<_ArtworkCrossfade> createState() => _ArtworkCrossfadeState();
}

class _ArtworkCrossfadeState extends State<_ArtworkCrossfade>
    with TickerProviderStateMixin {
  late _ArtworkLayer _current = _ArtworkLayer(widget.artUri, _opacity(1));
  _ArtworkLayer? _previous;

  AnimationController _opacity(double value) => AnimationController(
    vsync: this,
    value: value,
    duration: widget.motion.duration,
  );

  @override
  void didUpdateWidget(_ArtworkCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.artUri == _current.uri) return;
    // A cover that never showed is dropped, so rapid skips fade from the
    // last cover on screen rather than from a placeholder.
    if (_current.shown || _previous == null) {
      _previous?.opacity.dispose();
      _previous = _current..opacity.value = 1;
    } else {
      _current.opacity.dispose();
    }
    _current = _ArtworkLayer(widget.artUri, _opacity(0));
  }

  void _show(_ArtworkLayer layer) {
    if (layer.shown) return;
    layer.shown = true;
    // Runs during build: start the fade once this frame is done.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(layer, _current)) return;
      final fade = layer.opacity.animateTo(1, curve: widget.motion.curve);
      fade.whenCompleteOrCancel(() {
        if (!mounted || !identical(layer, _current) || _previous == null) {
          return;
        }
        if (!layer.opacity.isCompleted) return;
        setState(() {
          _previous!.opacity.dispose();
          _previous = null;
        });
      });
    });
  }

  @override
  void dispose() {
    _previous?.opacity.dispose();
    _current.opacity.dispose();
    super.dispose();
  }

  Widget _build(BuildContext context, _ArtworkLayer layer) => KeyedSubtree(
    key: layer.key,
    child: FadeTransition(
      opacity: layer.opacity,
      child: widget.builder(context, layer.uri, () => _show(layer)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final previous = _previous;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (previous != null) _build(context, previous),
        _build(context, _current),
      ],
    );
  }
}
