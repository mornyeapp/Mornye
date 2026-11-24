import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/audio_output_button.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/utils/android_tv.dart';

/// Landscape opens on the player. Lyrics can hide their bottom actions until
/// the user touches the player, while the cover and header stay in place.
class MornyeLandscapePlayer extends StatefulWidget {
  const MornyeLandscapePlayer({
    super.key,
    required this.artwork,
    required this.header,
    required this.lyrics,
    required this.queue,
    required this.controls,
    this.volume,
    required this.page,
    required this.isPlaying,
    required this.onPageChanged,
    this.lyricsOptions,
    this.controlsHeldOpen = false,
    this.autoHideLyricsControls = true,
    this.autoHideLyricsControlsWithAccessibility = false,
  });

  final Widget artwork;
  final Widget header;
  final Widget lyrics;
  final Widget queue;
  final Widget controls;

  /// Null when the person hid the volume from the player menu.
  final Widget? volume;
  final int page;
  final bool isPlaying;
  final bool controlsHeldOpen;
  final bool autoHideLyricsControls;
  final bool autoHideLyricsControlsWithAccessibility;
  final ValueChanged<int> onPageChanged;
  final Widget? lyricsOptions;

  @override
  State<MornyeLandscapePlayer> createState() => _MornyeLandscapePlayerState();
}

class _MornyeLandscapePlayerState extends State<MornyeLandscapePlayer> {
  Timer? _hideTimer;
  bool _actionsVisible = true;
  bool _audioOutputOpen = false;

  bool get _accessibilityBlocksAutoHide =>
      MediaQuery.accessibleNavigationOf(context) &&
      !widget.autoHideLyricsControlsWithAccessibility;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.autoHideLyricsControls ||
        isAndroidTv ||
        _accessibilityBlocksAutoHide) {
      _actionsVisible = true;
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  @override
  void didUpdateWidget(MornyeLandscapePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page ||
        oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.autoHideLyricsControls != widget.autoHideLyricsControls ||
        oldWidget.autoHideLyricsControlsWithAccessibility !=
            widget.autoHideLyricsControlsWithAccessibility) {
      _actionsVisible = true;
      _scheduleHide();
    } else if (oldWidget.controlsHeldOpen != widget.controlsHeldOpen) {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (widget.page != 1 ||
        !widget.autoHideLyricsControls ||
        isAndroidTv ||
        !widget.isPlaying ||
        widget.controlsHeldOpen ||
        !_actionsVisible ||
        _audioOutputOpen ||
        _accessibilityBlocksAutoHide ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!TickerMode.valuesOf(context).enabled) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _scheduleHide();
        return;
      }
      setState(() => _actionsVisible = false);
    });
  }

  void _reveal() {
    if (!_actionsVisible) setState(() => _actionsVisible = true);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  // Pages dissolve on Mornye's effects spring and the actions on its fast
  // one; reduced motion cuts.
  static const _still = AppMotionSpec(Duration.zero, Curves.linear);
  AppMotionSpec get _pageFade =>
      MediaQuery.disableAnimationsOf(context) ? _still : MornyeMotion.effects;
  AppMotionSpec get _actionsFade => MediaQuery.disableAnimationsOf(context)
      ? _still
      : MornyeMotion.effectsFast;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _hideTimer?.cancel(),
    onPointerUp: (_) => _scheduleHide(),
    onPointerCancel: (_) => _scheduleHide(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap:
                  widget.page == 1 &&
                      !isAndroidTv &&
                      !_accessibilityBlocksAutoHide
                  ? () {
                      setState(() => _actionsVisible = !_actionsVisible);
                      _scheduleHide();
                    }
                  : null,
              child: widget.artwork,
            ),
          ),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                if (!_actionsVisible) {
                  setState(() => _actionsVisible = true);
                }
              },
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: widget.header,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        fit: StackFit.expand,
                        children: [
                          AnimatedSwitcher(
                            duration: _pageFade.duration,
                            switchInCurve: _pageFade.curve,
                            switchOutCurve: _pageFade.leaving,
                            layoutBuilder: (current, previous) => Stack(
                              fit: StackFit.expand,
                              children: [
                                for (final child in [...previous, ?current])
                                  IgnorePointer(
                                    key: child.key,
                                    ignoring: child != current,
                                    child: ExcludeSemantics(
                                      excluding: child != current,
                                      child: child,
                                    ),
                                  ),
                              ],
                            ),
                            child: widget.page == 0
                                ? SingleChildScrollView(
                                    key: const ValueKey('landscape-controls'),
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        minHeight: constraints.maxHeight,
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: [
                                          widget.controls,
                                          ?widget.volume,
                                          const SizedBox(height: 48),
                                        ],
                                      ),
                                    ),
                                  )
                                : Padding(
                                    key: ValueKey(widget.page),
                                    padding: EdgeInsets.only(
                                      bottom: widget.page == 2 ? 48 : 0,
                                    ),
                                    child: widget.page == 2
                                        ? widget.queue
                                        : Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              _LandscapeLyricsViewport(
                                                controlsVisible:
                                                    _actionsVisible,
                                                child: widget.lyrics,
                                              ),
                                              if (widget.lyricsOptions != null)
                                                PositionedDirectional(
                                                  end: 20,
                                                  bottom: 52,
                                                  child: IgnorePointer(
                                                    ignoring: !_actionsVisible,
                                                    child: AnimatedOpacity(
                                                      opacity: _actionsVisible
                                                          ? 1
                                                          : 0,
                                                      duration:
                                                          _actionsFade.duration,
                                                      curve: _actionsFade.curve,
                                                      child:
                                                          widget.lyricsOptions!,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                  ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 48,
                            child: GestureDetector(
                              key: const ValueKey('landscape-actions-reveal'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _reveal,
                              child: IgnorePointer(
                                ignoring: !_actionsVisible,
                                child: ExcludeSemantics(
                                  excluding: !_actionsVisible,
                                  child: AnimatedOpacity(
                                    opacity: _actionsVisible ? 1 : 0,
                                    duration: _actionsFade.duration,
                                    curve: _actionsFade.curve,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          IconButton(
                                            tooltip: widget.page == 1
                                                ? context
                                                      .l10n
                                                      .nowPlayingTabPlayer
                                                : context
                                                      .l10n
                                                      .nowPlayingTabLyrics,
                                            isSelected: widget.page == 1,
                                            color: Colors.white,
                                            style: IconButton.styleFrom(
                                              backgroundColor: widget.page == 1
                                                  ? Colors.white.withValues(
                                                      alpha: 0.16,
                                                    )
                                                  : Colors.transparent,
                                            ),
                                            icon: const Icon(
                                              CupertinoIcons.quote_bubble,
                                            ),
                                            onPressed: () =>
                                                widget.onPageChanged(
                                                  widget.page == 1 ? 0 : 1,
                                                ),
                                          ),
                                          AudioOutputButton(
                                            color: Colors.white,
                                            onPickerChanged: (open) {
                                              if (!mounted) return;
                                              setState(
                                                () => _audioOutputOpen = open,
                                              );
                                              _scheduleHide();
                                            },
                                          ),
                                          IconButton(
                                            tooltip:
                                                context.l10n.nowPlayingUpNext,
                                            icon: const Icon(
                                              CupertinoIcons.list_bullet,
                                            ),
                                            isSelected: widget.page == 2,
                                            color: Colors.white,
                                            style: IconButton.styleFrom(
                                              backgroundColor: widget.page == 2
                                                  ? Colors.white.withValues(
                                                      alpha: 0.16,
                                                    )
                                                  : Colors.transparent,
                                            ),
                                            onPressed: () =>
                                                widget.onPageChanged(
                                                  widget.page == 2 ? 0 : 2,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Let lyrics pass behind the footer without leaving readable text underneath
/// its controls. A single opacity mask recedes when those controls hide.
class _LandscapeLyricsViewport extends ConsumerWidget {
  const _LandscapeLyricsViewport({
    required this.controlsVisible,
    required this.child,
  });

  final bool controlsVisible;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRect(
      key: const ValueKey('landscape-lyrics-viewport'),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: controlsVisible ? 1 : 0),
        // Follows the actions it makes room for.
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : MornyeMotion.effectsFast.duration,
        curve: MornyeMotion.effectsFast.curve,
        child: child,
        builder: (context, progress, child) => Stack(
          fit: StackFit.expand,
          children: [
            MornyeLyricsFadeMask(
              opaque: progress == 0,
              maskKey: progress,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white,
                  Colors.white,
                  Colors.white.withValues(alpha: 1 - progress),
                  Colors.white.withValues(alpha: 1 - progress),
                ],
                stops: [
                  0,
                  (1 - 112 / bounds.height).clamp(0, 1),
                  (1 - 48 / bounds.height).clamp(0, 1),
                  1,
                ],
              ).createShader(bounds),
              child: LyricsMaskEdgeClip(child: child!),
            ),
          ],
        ),
      ),
    );
  }
}

/// A lyrics fade that paints its child directly while [opaque] says the
/// whole gradient is opaque, which [BlendMode.dstIn] leaves unchanged. It
/// stays in the tree in both states, so the lyric list never remounts.
class MornyeLyricsFadeMask extends ShaderMask {
  const MornyeLyricsFadeMask({
    super.key,
    required this.opaque,
    this.maskKey,
    this.clipBottom,
    required super.shaderCallback,
    super.child,
  }) : super(blendMode: BlendMode.dstIn);

  final bool opaque;

  /// When provided, unchanged rebuilds with a fresh [shaderCallback] closure
  /// keep the retained shader layer instead of marking the mask dirty.
  final Object? maskKey;

  /// Caps the offscreen mask height when everything below [clipBottom] is
  /// fully transparent, shrinking the [ShaderMaskLayer] render target.
  final double? clipBottom;

  @override
  RenderShaderMask createRenderObject(BuildContext context) =>
      _RenderLyricsFadeMask(
        opaque: opaque,
        maskKey: maskKey,
        clipBottom: clipBottom,
        shaderCallback: shaderCallback,
      );

  @override
  void updateRenderObject(BuildContext context, RenderShaderMask renderObject) {
    final mask = renderObject as _RenderLyricsFadeMask;
    mask
      ..opaque = opaque
      ..clipBottom = clipBottom
      ..blendMode = blendMode
      ..updateShader(shaderCallback, maskKey: maskKey);
  }
}

class _RenderLyricsFadeMask extends RenderShaderMask {
  _RenderLyricsFadeMask({
    required bool opaque,
    required Object? maskKey,
    required double? clipBottom,
    required super.shaderCallback,
  }) : _opaque = opaque,
       _maskKey = maskKey,
       _clipBottom = clipBottom,
       super(blendMode: BlendMode.dstIn);

  bool _opaque;
  Object? _maskKey;
  double? _clipBottom;
  final _clip = LayerHandle<ClipRectLayer>();

  set opaque(bool value) {
    if (_opaque == value) return;
    _opaque = value;
    markNeedsPaint();
  }

  set clipBottom(double? value) {
    if (_clipBottom == value) return;
    _clipBottom = value;
    markNeedsPaint();
  }

  void updateShader(ShaderCallback callback, {Object? maskKey}) {
    if (maskKey != null && _maskKey == maskKey) return;
    _maskKey = maskKey;
    shaderCallback = callback;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final lyrics = child;
    if (_opaque && lyrics != null) {
      // Drop the layer retained from a frame that faded the lyrics.
      layer = null;
      _clip.layer = null;
      context.paintChild(lyrics, offset);
      return;
    }
    final clipBottom = _clipBottom;
    if (lyrics == null || clipBottom == null || clipBottom >= size.height) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }
    final visible = Rect.fromLTWH(
      0,
      0,
      size.width,
      clipBottom.clamp(0.0, size.height),
    );
    layer = (layer ?? ShaderMaskLayer())
      ..shader = shaderCallback(Offset.zero & size)
      ..maskRect = visible.shift(offset)
      ..blendMode = blendMode;
    context.pushLayer(layer!, (context, offset) {
      _clip.layer = context.pushClipRect(
        lyrics.needsCompositing,
        offset,
        visible,
        (context, offset) => context.paintChild(lyrics, offset),
        oldLayer: _clip.layer,
      );
    }, offset);
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
