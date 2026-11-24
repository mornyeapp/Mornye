import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

/// Cover schemes for [PlayerArtworkTheme]: [CoverPalette] with the neutral
/// scheme for black and white covers.
class PlayerArtworkPalette {
  const PlayerArtworkPalette();

  ColorScheme? peek(String source, Brightness brightness) =>
      CoverPalette.peek(source, brightness, neutralGrayscale: true);

  Future<ColorScheme?> resolve(String source, Brightness brightness) =>
      CoverPalette.resolve(source, brightness, neutralGrayscale: true);
}

/// Gives a Material player surface the colour scheme of the current track's
/// artwork through a local [Theme], so the app chrome around it keeps the
/// app scheme. The Material desktop detail header scopes its cover or artist
/// image the same way.
///
/// A cover whose scheme is cached shows it from the first frame. While the
/// next cover's scheme resolves, the previous one stays; then the whole
/// scheme moves at once on the effects spring, or swaps under reduced
/// motion and in a hidden scope, such as the shell under the full player.
/// Tracks without readable artwork use the app scheme. With AMOLED
/// on, the page background stays pure black.
///
/// A large page or a player bar sets [fadesSurfaceOnly]: moving the whole
/// scheme rebuilds everything under it on every frame, so its scheme swaps
/// in one step and only the background, painted by [PlayerArtworkSurface],
/// moves. A song row turns off [animates] and swaps in one step too.
class PlayerArtworkTheme extends StatefulWidget {
  const PlayerArtworkTheme({
    super.key,
    required this.artUri,
    required this.child,
    this.fadesSurfaceOnly = false,
    this.background = _surfaceOf,
    this.animates = true,
  });

  /// The track's artwork, in any form `PlayerArtwork` shows: an HTTP(S)
  /// URL, a file URI or an absolute local path.
  final String? artUri;

  final Widget child;

  /// Swaps the scheme in one step and moves only the page background to
  /// the next track's surface colour. The page paints that background with
  /// [PlayerArtworkSurface] instead of the scheme's surface.
  final bool fadesSurfaceOnly;

  /// The scheme colour the moving background follows with
  /// [fadesSurfaceOnly]: a page's surface, or a bar's container.
  final Color Function(ColorScheme scheme) background;

  static Color _surfaceOf(ColorScheme scheme) => scheme.surface;

  /// Whether the scheme moves on the effects spring. A song row swaps it in
  /// one step: its card fades its own fill, and a move rebuilt the whole row
  /// on every frame.
  final bool animates;

  /// The moving background of the nearest [PlayerArtworkTheme] when it sets
  /// [fadesSurfaceOnly]. Null elsewhere, where the whole scheme moves.
  static Animation<Color>? surfaceOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ArtworkSurface>()?.surface;

  static PlayerArtworkPalette _palette = const PlayerArtworkPalette();

  /// Replaces [CoverPalette] in tests, whose fake clock cannot finish a real
  /// decode. Null restores it.
  @visibleForTesting
  static set debugPalette(PlayerArtworkPalette? palette) =>
      _palette = palette ?? const PlayerArtworkPalette();

  /// Resolves [artUri]'s scheme ahead, so a scope that reaches it later
  /// shows that scheme from its first frame.
  static void warm(String? artUri, Brightness brightness) {
    final source = coverImageSource(artUri);
    if (source == null || _palette.peek(source, brightness) != null) return;
    _palette.resolve(source, brightness).ignore();
  }

  @override
  State<PlayerArtworkTheme> createState() => _PlayerArtworkThemeState();
}

class _PlayerArtworkThemeState extends State<PlayerArtworkTheme>
    with SingleTickerProviderStateMixin {
  /// Made by the first move that animates: a scope that only ever follows
  /// the app scheme, like a song row that is not playing, never needs one.
  AnimationController? _controller;

  AnimationController get _animation =>
      _controller ??= AnimationController(vsync: this, value: 1);

  /// The page background for [PlayerArtworkTheme.fadesSurfaceOnly].
  late final _surface = _SurfaceAnimation(_animation);

  /// The current cover's scheme. Null follows the app scheme.
  ColorScheme? _artwork;

  /// The scheme on screen when the running transition started.
  ColorScheme? _from;
  ColorScheme? _shown;
  Curve _curve = Curves.linear;

  String? _source;
  Brightness? _brightness;
  int _generation = 0;

  /// Whether the scope showed when it last checked. A cover that changes
  /// while it is hidden, or as it shows again, swaps without a transition.
  bool _onScreen = false;

  ThemeData? _base;
  ColorScheme? _scheme;
  ThemeData? _theme;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
    _onScreen = TickerMode.valuesOf(context).enabled;
  }

  @override
  void didUpdateWidget(PlayerArtworkTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artUri != widget.artUri) _sync();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Starts one palette job when the cover or the brightness changes.
  void _sync() {
    final source = coverImageSource(widget.artUri);
    final brightness = Theme.of(context).brightness;
    if (source == _source && brightness == _brightness) return;
    // The first frame and a brightness change have no scheme worth keeping.
    final keepPrevious = brightness == _brightness;
    final animate = keepPrevious && _onScreen;
    _source = source;
    _brightness = brightness;
    final generation = ++_generation;
    if (source == null) {
      _moveTo(null, animate: animate);
      return;
    }
    final palette = PlayerArtworkTheme._palette;
    final cached = palette.peek(source, brightness);
    if (cached != null || !keepPrevious) {
      _moveTo(cached, animate: animate);
    }
    palette
        .resolve(source, brightness)
        .then(
          (scheme) => _resolved(generation, scheme),
          onError: (Object _) => _resolved(generation, null),
        );
  }

  /// Moves to a resolved scheme unless a newer cover replaced its request.
  /// Null, for unreadable artwork, returns to the app scheme.
  void _resolved(int generation, ColorScheme? scheme) {
    if (!mounted || generation != _generation || scheme == _artwork) return;
    setState(() => _moveTo(scheme, animate: _onScreen));
  }

  void _moveTo(ColorScheme? artwork, {required bool animate}) {
    if (artwork == _artwork) return;
    _artwork = artwork;
    _from = _shown;
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    if (!animate ||
        !widget.animates ||
        _from == null ||
        motion.duration == Duration.zero) {
      _from = null;
      _controller?.value = 1;
      return;
    }
    if (widget.fadesSurfaceOnly) {
      final nextSurface = widget.background(
        _targetFor(Theme.of(context), artwork),
      );
      final currentSurface = _surface.value;
      if (currentSurface == nextSurface) {
        _from = null;
        _surface.to = nextSurface;
        _controller?.value = 1;
        return;
      }
      // From the colour on screen, which may be partway through a move.
      _surface
        ..from = currentSurface
        ..to = nextSurface
        ..curve = motion.curve;
    }
    _curve = motion.curve;
    _animation
      ..duration = motion.duration
      ..forward(from: 0);
  }

  /// AMOLED dark mode paints the app's page background pure black.
  static bool _isAmoled(ThemeData base) =>
      base.brightness == Brightness.dark &&
      base.colorScheme.surface == Colors.black;

  /// The scheme a move goes to, shared by [_moveTo] and [_themeFor].
  static ColorScheme _targetFor(ThemeData base, ColorScheme? artwork) =>
      artwork == null
      ? base.colorScheme
      : _isAmoled(base)
      ? artwork.copyWith(
          surface: Colors.black,
          surfaceContainerLowest: Colors.black,
        )
      : artwork;

  ThemeData _themeFor(ThemeData base) {
    final target = _targetFor(base, _artwork);
    final from = _from;
    final progress = _controller?.value ?? 1;
    final scheme = widget.fadesSurfaceOnly || from == null || progress >= 1
        ? target
        : ColorScheme.lerp(from, target, _curve.transform(progress));
    if (widget.fadesSurfaceOnly) _surface.to = widget.background(target);
    _shown = scheme;
    if (!identical(base, _base) || scheme != _scheme) {
      _base = base;
      _scheme = scheme;
      _theme = identical(scheme, base.colorScheme)
          ? base
          : _scopedTheme(base, scheme);
    }
    return _theme!;
  }

  /// [base] with [scheme], including the component colours the app theme
  /// bakes from its own scheme.
  static ThemeData _scopedTheme(ThemeData base, ColorScheme scheme) {
    final appBar = base.appBarTheme;
    final progress = base.progressIndicatorTheme;
    final navBar = base.navigationBarTheme;
    final slider = base.sliderTheme;
    return base.copyWith(
      colorScheme: scheme,
      canvasColor: scheme.surface,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: appBar.copyWith(
        backgroundColor: appBar.backgroundColor == null ? null : scheme.surface,
        foregroundColor: appBar.foregroundColor == null
            ? null
            : scheme.onSurface,
        titleTextStyle: appBar.titleTextStyle?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: navBar.copyWith(
        backgroundColor: navBar.backgroundColor == null
            ? null
            : scheme.surfaceContainer,
        indicatorColor: navBar.indicatorColor == null
            ? null
            : scheme.secondaryContainer,
      ),
      sliderTheme: slider.copyWith(
        activeTrackColor: slider.activeTrackColor == null
            ? null
            : scheme.primary,
        inactiveTrackColor: slider.inactiveTrackColor == null
            ? null
            : scheme.secondaryContainer,
        thumbColor: slider.thumbColor == null ? null : scheme.primary,
      ),
      progressIndicatorTheme: progress.copyWith(
        color: progress.color == null ? null : scheme.primary,
        linearTrackColor: progress.linearTrackColor == null
            ? null
            : scheme.surfaceContainerHighest,
        circularTrackColor: progress.circularTrackColor == null
            ? null
            : scheme.surfaceContainerHighest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    if (widget.fadesSurfaceOnly) {
      final theme = _themeFor(base);
      return _ArtworkSurface(
        surface: _surface,
        target: _surface.to,
        child: Theme(data: theme, child: widget.child),
      );
    }
    // Its own scheme paints the fills below, not an outer moving background.
    return _ArtworkSurface(
      surface: null,
      target: null,
      child: AnimatedBuilder(
        // Stands still until a move makes the controller, in the same build.
        animation: _controller ?? kAlwaysCompleteAnimation,
        builder: (context, child) =>
            Theme(data: _themeFor(base), child: child!),
        child: widget.child,
      ),
    );
  }
}

/// The page background moving from [from] to [to] with the theme's
/// transition, at [to] while none runs.
class _SurfaceAnimation extends Animation<Color>
    with AnimationWithParentMixin<double> {
  _SurfaceAnimation(this.parent);

  @override
  final Animation<double> parent;

  Color from = Colors.transparent;
  Color to = Colors.transparent;
  Curve curve = Curves.linear;

  @override
  Color get value {
    final progress = parent.value;
    if (progress >= 1) return to;
    return Color.lerp(from, to, curve.transform(progress))!;
  }
}

/// Hands [PlayerArtworkSurface] the moving background. The animation keeps
/// its identity, so only a new resting colour, such as a brightness change
/// without a transition, rebuilds the surfaces.
class _ArtworkSurface extends InheritedWidget {
  const _ArtworkSurface({
    required this.surface,
    required this.target,
    required super.child,
  });

  /// Null under a scope that moves the whole scheme.
  final Animation<Color>? surface;
  final Color? target;

  @override
  bool updateShouldNotify(_ArtworkSurface oldWidget) =>
      target != oldWidget.target || surface != oldWidget.surface;
}

/// Paints a Material player's background: [surface], or the moving
/// background of a [PlayerArtworkTheme] with
/// [PlayerArtworkTheme.fadesSurfaceOnly]. Only this box repaints while that
/// background moves.
class PlayerArtworkSurface extends StatelessWidget {
  const PlayerArtworkSurface({
    super.key,
    required this.surface,
    this.overlay,
    this.opacity = 1,
    this.child,
  });

  /// The scheme colour the theme's background follows, used outside a
  /// surface-moving theme.
  final Color surface;

  /// Laid over the background, as the Material group tint is.
  final Color? overlay;

  /// Opacity of the background over what lies below it.
  final double opacity;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final moving = PlayerArtworkTheme.surfaceOf(context);
    final overlay = this.overlay;
    Color tint(Color color) {
      final fill = overlay == null ? color : Color.alphaBlend(overlay, color);
      return opacity == 1 ? fill : fill.withValues(alpha: fill.a * opacity);
    }

    if (moving == null) {
      return ColoredBox(color: tint(surface), child: child);
    }
    return AnimatedBuilder(
      animation: moving,
      builder: (context, child) =>
          ColoredBox(color: tint(moving.value), child: child),
      child: child,
    );
  }
}
