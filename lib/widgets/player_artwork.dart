import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

class PlayerArtwork extends StatelessWidget {
  /// Shared decode for the mini player and the full player's blurred cover.
  static const miniCacheWidth = 132;

  static const _grownFrom = 0.94;

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

  /// With [crossfade], the new cover also grows from 0.94 on this motion
  /// while it fades in.
  final AppMotionSpec? crossfadeScale;

  const PlayerArtwork({
    super.key,
    required this.artUri,
    required this.colorScheme,
    this.cacheWidth,
    this.iconSize = 40,
    this.crossfade,
    this.crossfadeScale,
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
      return _ArtworkCrossfade(
        artUri: artUri,
        motion: motion,
        scale: crossfadeScale,
        builder: _layer,
      );
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
    required this.scale,
    required this.builder,
  });

  final String? artUri;
  final AppMotionSpec motion;
  final AppMotionSpec? scale;
  final Widget Function(BuildContext, String?, VoidCallback onShown) builder;

  @override
  State<_ArtworkCrossfade> createState() => _ArtworkCrossfadeState();
}

class _ArtworkCrossfadeState extends State<_ArtworkCrossfade>
    with TickerProviderStateMixin {
  /// Bottom to top; the last is the current cover. A cover still fading in
  /// when the next one arrives keeps fading from where it is, so a skip in
  /// the middle of a fade never jumps.
  late final _layers = [_ArtworkLayer(widget.artUri, _opacity(1))];
  _ArtworkLayer get _current => _layers.last;

  /// The opaque base, one cover still fading in and the newest one.
  static const _maxLayers = 3;

  /// One linear timeline per cover: the fade and the growth each run their
  /// own curve over their own share of it.
  Duration get _total {
    final scale = widget.scale?.duration ?? Duration.zero;
    return scale > widget.motion.duration ? scale : widget.motion.duration;
  }

  Animation<double> _part(_ArtworkLayer layer, AppMotionSpec motion) {
    final total = _total.inMicroseconds;
    final share = total == 0 ? 1.0 : motion.duration.inMicroseconds / total;
    return layer.opacity.drive(
      CurveTween(curve: Interval(0, share, curve: motion.curve)),
    );
  }

  AnimationController _opacity(double value) =>
      AnimationController(vsync: this, value: value, duration: _total);

  @override
  void didUpdateWidget(_ArtworkCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.artUri == _current.uri) return;
    // A cover that never showed is dropped, so rapid skips fade from the
    // last cover on screen rather than from a placeholder.
    if (!_current.shown && _layers.length > 1) {
      _layers.removeLast().opacity.dispose();
    }
    if (_layers.length >= _maxLayers) {
      // Skips faster than a fade: settle the newest cover on screen into
      // the base before the next one fades in over it.
      final base = _current..opacity.value = 1;
      for (final layer in _layers.take(_layers.length - 1)) {
        layer.opacity.dispose();
      }
      _layers
        ..clear()
        ..add(base);
    }
    _layers.add(_ArtworkLayer(widget.artUri, _opacity(0)));
    _showWhenUnavailable(_current);
  }

  /// Covers under a fully faded-in one no longer show.
  void _dropBelow(_ArtworkLayer layer) {
    final index = _layers.indexOf(layer);
    if (index <= 0) return;
    setState(() {
      for (final hidden in _layers.take(index)) {
        hidden.opacity.dispose();
      }
      _layers.removeRange(0, index);
    });
  }

  /// A network cover the store cannot fetch never draws a frame: fade its
  /// placeholder in once the fetch fails, so the previous song's cover does
  /// not stay on screen.
  void _showWhenUnavailable(_ArtworkLayer layer) {
    final uri = layer.uri;
    if (!CoverStore.fetches(uri) || coverFilePath(uri) != null) return;
    void show([Object? _]) {
      if (!mounted || !identical(layer, _current)) return;
      _show(layer);
      SchedulerBinding.instance.ensureVisualUpdate();
    }

    unawaited(
      CoverStore.instance.file(uri).then((path) {
        if (path == null) show();
      }, onError: show),
    );
  }

  void _show(_ArtworkLayer layer) {
    if (layer.shown) return;
    layer.shown = true;
    // Runs during build: start the fade once this frame is done.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_layers.contains(layer)) return;
      final fade = layer.opacity.animateTo(1);
      fade.whenCompleteOrCancel(() {
        if (!mounted || !_layers.contains(layer)) return;
        if (layer.opacity.isCompleted) _dropBelow(layer);
      });
    });
  }

  @override
  void dispose() {
    for (final layer in _layers) {
      layer.opacity.dispose();
    }
    super.dispose();
  }

  Widget _build(BuildContext context, _ArtworkLayer layer) {
    Widget child = widget.builder(context, layer.uri, () => _show(layer));
    if (widget.scale case final scale?) {
      child = ScaleTransition(
        scale: _part(
          layer,
          scale,
        ).drive(Tween(begin: PlayerArtwork._grownFrom, end: 1.0)),
        child: child,
      );
    }
    return KeyedSubtree(
      key: layer.key,
      child: FadeTransition(opacity: _part(layer, widget.motion), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [for (final layer in _layers) _build(context, layer)],
    );
  }
}
