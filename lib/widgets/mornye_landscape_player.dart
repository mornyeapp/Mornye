import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/audio_output_button.dart';
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
  final ValueChanged<int> onPageChanged;
  final Widget? lyricsOptions;

  @override
  State<MornyeLandscapePlayer> createState() => _MornyeLandscapePlayerState();
}

class _MornyeLandscapePlayerState extends State<MornyeLandscapePlayer> {
  Timer? _hideTimer;
  bool _actionsVisible = true;
  bool _audioOutputOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.autoHideLyricsControls ||
        isAndroidTv ||
        MediaQuery.accessibleNavigationOf(context)) {
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
        oldWidget.autoHideLyricsControls != widget.autoHideLyricsControls) {
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
        MediaQuery.accessibleNavigationOf(context)) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
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

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      _hideTimer?.cancel();
      if (!_actionsVisible) setState(() => _actionsVisible = true);
    },
    onPointerUp: (_) => _scheduleHide(),
    onPointerCancel: (_) => _scheduleHide(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Row(
        children: [
          Expanded(child: widget.artwork),
          Expanded(
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
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
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
                                              controlsVisible: _actionsVisible,
                                              child: widget.lyrics,
                                            ),
                                            if (widget.lyricsOptions != null)
                                              PositionedDirectional(
                                                start: 20,
                                                bottom: 52,
                                                child: IgnorePointer(
                                                  ignoring: !_actionsVisible,
                                                  child: AnimatedOpacity(
                                                    opacity: _actionsVisible
                                                        ? 1
                                                        : 0,
                                                    duration:
                                                        MediaQuery.disableAnimationsOf(
                                                          context,
                                                        )
                                                        ? Duration.zero
                                                        : const Duration(
                                                            milliseconds: 180,
                                                          ),
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
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 180),
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
                                              ? context.l10n.nowPlayingTabPlayer
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
                                          onPressed: () => widget.onPageChanged(
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
                                          onPressed: () => widget.onPageChanged(
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
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        child: child,
        builder: (context, progress, child) => Stack(
          fit: StackFit.expand,
          children: [
            ShaderMask(
              blendMode: BlendMode.dstIn,
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
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
