import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart'
    show desktopWindowFullScreen;
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';
import 'package:mornye/widgets/no_scrollbars.dart';

enum DesktopInspectorPanel { lyrics, upNext }

/// Width of the trailing inspector.
const double desktopInspectorWidth = 340;

/// Width of Mornye's floating glass inspector.
const double mornyeGlassInspectorWidth = 260;

/// Window width from which the inspector sits beside the content pane.
/// Narrower windows show it as a panel over the content.
const double desktopInspectorBesideBreakpoint = 1200;

/// Whether Now Playing covers the desktop window, sidebar included.
final desktopNowPlayingOpen = ValueNotifier<bool>(false);

/// The panel shown in the trailing inspector, or null while it is closed.
final desktopInspectorPanel = ValueNotifier<DesktopInspectorPanel?>(null);

/// Shows [panel] in the inspector, or closes the inspector when it already
/// shows [panel].
void toggleDesktopInspector(DesktopInspectorPanel panel) {
  desktopInspectorPanel.value = desktopInspectorPanel.value == panel
      ? null
      : panel;
}

bool _wasFullScreen = false;
DesktopInspectorPanel? _lastPanel;
bool _fullScreenLyricsBound = false;

/// Opens Now Playing when lyrics open in a full screen window, or when the
/// window enters full screen with lyrics open. Call once at startup.
void bindDesktopFullScreenLyrics() {
  if (_fullScreenLyricsBound) return;
  _fullScreenLyricsBound = true;
  desktopWindowFullScreen.addListener(_syncFullScreenLyrics);
  desktopInspectorPanel.addListener(_syncFullScreenLyrics);
  _syncFullScreenLyrics();
}

void _syncFullScreenLyrics() {
  final fullScreen = desktopWindowFullScreen.value;
  final panel = desktopInspectorPanel.value;
  final lyricsOpened =
      panel == DesktopInspectorPanel.lyrics &&
      (!_wasFullScreen || _lastPanel != DesktopInspectorPanel.lyrics);
  _wasFullScreen = fullScreen;
  _lastPanel = panel;
  if (fullScreen && lyricsOpened) desktopNowPlayingOpen.value = true;
}

/// Closes Now Playing back to the shell. In full screen the lyrics panel
/// closes with it, so the next lyrics toggle opens the player again rather
/// than a panel beside the content.
void closeDesktopNowPlaying() {
  desktopNowPlayingOpen.value = false;
  if (desktopWindowFullScreen.value) desktopInspectorPanel.value = null;
}

/// Whether the inspector floats over the content in a window [windowWidth]
/// wide. Mornye's floats at any width until the window goes full screen.
bool desktopInspectorOverlays(double windowWidth, {required bool mornye}) =>
    desktopInspectorOverlaysWhen(
      besideFits: windowWidth >= desktopInspectorBesideBreakpoint,
      mornye: mornye,
    );

/// [desktopInspectorOverlays] for a window known only by whether it is at
/// least [desktopInspectorBesideBreakpoint] wide ([besideFits]).
bool desktopInspectorOverlaysWhen({
  required bool besideFits,
  required bool mornye,
}) => !besideFits || (mornye && !desktopWindowFullScreen.value);

/// Whether Escape or Back has a player layer to close in a window
/// [windowWidth] wide.
bool canDismissDesktopPlayerLayer(double windowWidth, {required bool mornye}) =>
    desktopNowPlayingOpen.value ||
    (desktopInspectorPanel.value != null &&
        desktopInspectorOverlays(windowWidth, mornye: mornye));

/// Closes the top player layer: Now Playing, which covers the window, then
/// the inspector while it floats over the content. Returns whether a layer
/// closed.
bool dismissDesktopPlayerLayer(double windowWidth, {required bool mornye}) {
  if (desktopNowPlayingOpen.value) {
    closeDesktopNowPlaying();
    return true;
  }
  if (desktopInspectorPanel.value != null &&
      desktopInspectorOverlays(windowWidth, mornye: mornye)) {
    desktopInspectorPanel.value = null;
    return true;
  }
  return false;
}

/// Returns from Now Playing to the content pane when a destination opens a
/// page, such as an album or artist opened from the player, so the page is
/// not hidden behind it.
class DesktopNowPlayingCloser extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null || route is! PageRoute<dynamic>) return;
    if (!desktopNowPlayingOpen.value) return;
    // A push can run during a build; close on the next frame instead.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => desktopNowPlayingOpen.value = false,
    );
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

/// Lyrics or Up Next beside the content pane. [overlay] adds the elevation
/// of a panel that floats over the content in narrow windows.
class DesktopInspector extends ConsumerWidget {
  const DesktopInspector({
    super.key,
    required this.panel,
    this.overlay = false,
  });

  final DesktopInspectorPanel panel;
  final bool overlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mornye = context.isMornye;
    final glass = mornye && overlay;
    final l10n = context.l10n;
    final (:hasTrack, :artUri) = ref.watch(
      currentMediaItemProvider.select(
        (s) => (
          hasTrack: s.value != null,
          artUri: mornye && !overlay ? s.value?.artUri : null,
        ),
      ),
    );
    final title = switch (panel) {
      DesktopInspectorPanel.lyrics => l10n.nowPlayingTabLyrics,
      DesktopInspectorPanel.upNext => l10n.nowPlayingUpNext,
    };

    Widget content(BuildContext context) {
      final colorScheme = Theme.of(context).colorScheme;
      final header = Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            AppIconButton(
              key: const ValueKey('desktop-inspector-close'),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              color: colorScheme.onSurfaceVariant,
              icon: AppIcon(mornye ? CupertinoIcons.xmark : Icons.close),
              onPressed: () => desktopInspectorPanel.value = null,
            ),
          ],
        ),
      );
      final Widget body;
      if (!hasTrack) {
        body = Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.nowPlayingNothingPlaying,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      } else {
        body = switch (panel) {
          DesktopInspectorPanel.lyrics => _InspectorLyrics(
            colorScheme: colorScheme,
          ),
          DesktopInspectorPanel.upNext =>
            mornye
                ? MornyePlayerQueue(colorScheme: colorScheme)
                : DesktopMaterialQueue(colorScheme: colorScheme),
        };
      }
      // The player capsule's toggles close the glass panel.
      if (glass) {
        return Padding(padding: const EdgeInsets.only(top: 12), child: body);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: body),
        ],
      );
    }

    final Widget panelSurface;
    if (mornye) {
      // Lyrics and Up Next keep the player's dark artwork backdrop, as the
      // full player draws them in white over it.
      final theme = MornyeTheme.fromContext(
        context,
        brightness: Brightness.dark,
      );
      final blur = ref.watch(mornyeBlurEnabledProvider);
      final overlayContent = Material(
        type: MaterialType.transparency,
        child: Builder(builder: content),
      );
      panelSurface = Theme(
        data: theme,
        child: overlay
            ? MornyeGlassPanel.overlay(
                radius: 0,
                blurEnabled: blur,
                tintColor: const Color(0xff363636),
                tintOpacity: blur ? 0.74 : 0.97,
                child: overlayContent,
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  MornyePlayerBackground(artUri: artUri),
                  overlayContent,
                ],
              ),
      );
    } else {
      final colorScheme = Theme.of(context).colorScheme;
      panelSurface = Material(
        color: colorScheme.surfaceContainerLow,
        child: Builder(builder: content),
      );
    }

    final divider = BorderSide(
      color: mornye
          ? MornyeTheme.metadataDividerColor(context)
          : Theme.of(context).colorScheme.outlineVariant,
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: Container(
        key: ValueKey('desktop-inspector-${panel.name}'),
        width: glass ? mornyeGlassInspectorWidth : desktopInspectorWidth,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          border: overlay && !mornye
              ? null
              : BorderDirectional(
                  start: overlay
                      ? BorderSide(color: Colors.white.withValues(alpha: 0.1))
                      : divider,
                ),
          // The shadow falls toward the content the Mornye glass pane floats
          // over; Material relies on its container tier.
          boxShadow: overlay && mornye
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: Offset(
                      Directionality.of(context) == TextDirection.rtl ? 4 : -4,
                      0,
                    ),
                  ),
                ]
              : null,
        ),
        // Lyrics and Up Next scroll without a bar, as in the full player.
        child: NoScrollbars(child: panelSurface),
      ),
    );
  }
}

/// Motion for opening the inspector: the default spatial spring of the
/// style, Material's expressive one or Mornye's standard one.
AppMotionSpec desktopInspectorMotion(BuildContext context) => AppMotion.spatial(
  context,
  const AppMotionSpec(Duration(milliseconds: 300), Curves.easeOutCubic),
);

/// [desktopInspectorMotion]'s spring, for an opening that goes on from the
/// pane's own velocity.
SpringDescription _inspectorSpring(BuildContext context) => context.isMornye
    ? MornyeMotion.standardSpring
    : MotionPace.spring(M3EMotion.expressiveSpatialDefault.toDescription());

/// Opens and closes [panel] with motion, keeping the last panel on screen
/// while it leaves. Beside the content the pane grows from the trailing
/// edge and pushes the content aside; as an [overlay] it slides in over it.
/// Switching between panels cross-fades.
class DesktopInspectorTransition extends StatefulWidget {
  const DesktopInspectorTransition({
    super.key,
    required this.panel,
    required this.builder,
    this.overlay = false,
  });

  final DesktopInspectorPanel? panel;

  /// Called once per panel shown; it must depend on nothing but the panel.
  final Widget Function(BuildContext context, DesktopInspectorPanel panel)
  builder;
  final bool overlay;

  @override
  State<DesktopInspectorTransition> createState() =>
      _DesktopInspectorTransitionState();
}

class _DesktopInspectorTransitionState extends State<DesktopInspectorTransition>
    with SingleTickerProviderStateMixin {
  // Created up front: a lazy controller first read when the panel opens
  // would start at the open value and skip the first opening. Its value is
  // the pane's openness on screen, which the open spring may carry past 1,
  // so a reversal always goes on from where the pane is.
  late final AnimationController _controller;
  late DesktopInspectorPanel? _shown = widget.panel;

  /// The shown panel as last built, kept through the parent's rebuilds (a
  /// resize frame) so the lyrics or queue are not built again for each.
  Widget? _panelView;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      value: widget.panel == null ? 0 : 1,
    );
  }

  @override
  void didUpdateWidget(DesktopInspectorTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final panel = widget.panel;
    if ((panel == null) == (oldWidget.panel == null)) {
      if (panel != null) _shown = panel;
      return;
    }
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (panel != null) {
      _shown = panel;
      if (reduce) {
        _controller.value = 1;
      } else {
        // A pane closing when it opens again turns on its own velocity.
        _controller.animateWith(
          SpringSimulation(
            _inspectorSpring(context),
            _controller.value,
            1,
            _controller.velocity,
            snapToEnd: true,
          ),
        );
      }
    } else {
      void finish() {
        if (mounted && widget.panel == null && _controller.value == 0) {
          setState(() => _shown = null);
        }
      }

      if (reduce) {
        _controller.value = 0;
        finish();
      } else if (context.isMornye) {
        // Mornye retreats on Apple's critically damped fast spring from the
        // panel's current velocity, with no bounce back into the content.
        _controller
            .animateWith(
              SpringSimulation(
                MornyeMotion.fastSpring,
                _controller.value,
                0,
                _controller.velocity,
                snapToEnd: true,
              ),
            )
            .whenCompleteOrCancel(finish);
      } else {
        // Material exits on M3's standard accelerate curve with no overshoot.
        _controller
            .animateBack(
              0,
              duration: MotionPace.duration(const Duration(milliseconds: 220)),
              curve: Easing.standardAccelerate,
            )
            .whenCompleteOrCancel(finish);
      }
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _panelView = null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    // Switching panels cross-fades on the effects spring of the style.
    final crossFade = AppMotion.effects(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
      mornye: MornyeMotion.effects,
    );
    final content = AnimatedSwitcher(
      duration: crossFade.duration,
      switchInCurve: crossFade.curve,
      switchOutCurve: crossFade.leaving,
      // Panels keep their fixed width while they cross-fade.
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, ?current],
      ),
      child: _panelView?.key == ValueKey(shown)
          ? _panelView
          : _panelView = KeyedSubtree(
              key: ValueKey(shown),
              child: widget.builder(context, shown),
            ),
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: _controller,
      child: RepaintBoundary(child: content),
      builder: (context, child) {
        // The open spring may overshoot. A floating panel can slide a little
        // past its place, but the pane beside the content stops at its
        // width: growing past it would narrow the content below its final
        // size, flip its layout breakpoints and flip them back.
        final spring = _controller.value;
        final value = widget.overlay
            ? math.max(0.0, spring)
            : spring.clamp(0.0, 1.0);
        if (widget.overlay) {
          final translation = Offset((1 - value) * (rtl ? -1 : 1), 0);
          // An opacity layer would hide the backdrop from Mornye's glass.
          return FractionalTranslation(
            translation: translation,
            child: context.isMornye
                ? child
                : Opacity(opacity: value.clamp(0.0, 1.0), child: child),
          );
        }
        return ClipRect(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: value,
            child: child,
          ),
        );
      },
    );
  }
}

/// The current track's lyrics, loaded on their own so the inspector works
/// without the full player.
class _InspectorLyrics extends ConsumerStatefulWidget {
  const _InspectorLyrics({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  ConsumerState<_InspectorLyrics> createState() => _InspectorLyricsState();
}

class _InspectorLyricsState extends ConsumerState<_InspectorLyrics> {
  final _metadata = PlayerMetadataController();
  final _seekPreview = PlaybackSeekPreview();
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;
  late final LyricsTranslationController _lyricsTranslation;

  @override
  void initState() {
    super.initState();
    _lyricsTranslation = ref.read(lyricsTranslationProvider.notifier);
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id == next.value?.id) return;
        unawaited(
          _metadata.load(next.value, inspectUnresolvedContentUri: true),
        );
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _mediaItemSub?.close();
    _lyricsTranslation.cancel(owner: this);
    _metadata.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlayerLyricsSection(
    metadata: _metadata,
    seekPreview: _seekPreview,
    colorScheme: widget.colorScheme,
    isActive: true,
    options: LyricsOptionsButton(
      metadata: _metadata,
      colorScheme: widget.colorScheme,
      translationOwner: this,
    ),
  );
}

class DesktopMaterialQueue extends StatefulWidget {
  const DesktopMaterialQueue({super.key, required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  State<DesktopMaterialQueue> createState() => _DesktopMaterialQueueState();
}

class _DesktopMaterialQueueState extends State<DesktopMaterialQueue> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlayerQueueSheet(
    colorScheme: widget.colorScheme,
    scrollController: _scrollController,
    embedded: true,
  );
}
