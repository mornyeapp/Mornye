import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';
import 'package:mornye/widgets/no_scrollbars.dart';

/// A panel of the desktop trailing inspector.
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
    windowWidth < desktopInspectorBesideBreakpoint ||
    (mornye && !desktopWindowFullScreen.value);

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
    final mediaItem = ref.watch(currentMediaItemProvider).value;
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
      if (mediaItem == null) {
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
      panelSurface = Theme(
        data: theme,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The floating panel samples the content beneath it; the full
            // screen panel keeps the artwork backdrop.
            if (overlay) ...[
              if (blur)
                BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: const SizedBox.expand(),
                ),
              ColoredBox(
                color: const Color(
                  0xff363636,
                ).withValues(alpha: blur ? 0.74 : 0.97),
              ),
            ] else
              MornyePlayerBackground(artUri: mediaItem?.artUri),
            Material(
              type: MaterialType.transparency,
              child: Builder(builder: content),
            ),
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
          // The shadow falls toward the content the pane floats over.
          boxShadow: overlay
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

/// Motion for opening the inspector: the Material spatial spring, or an
/// iOS-like ease for Mornye.
AppMotionSpec desktopInspectorMotion(BuildContext context) => AppMotion.spatial(
  context,
  const AppMotionSpec(Duration(milliseconds: 300), Curves.easeOutCubic),
);

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
  final Widget Function(BuildContext context, DesktopInspectorPanel panel)
  builder;
  final bool overlay;

  @override
  State<DesktopInspectorTransition> createState() =>
      _DesktopInspectorTransitionState();
}

class _DesktopInspectorTransitionState extends State<DesktopInspectorTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.panel == null ? 0 : 1,
  );
  late DesktopInspectorPanel? _shown = widget.panel;
  Curve _curve = Curves.linear;

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
      final motion = desktopInspectorMotion(context);
      _shown = panel;
      _curve = motion.curve;
      _controller.animateTo(
        1,
        duration: reduce ? Duration.zero : motion.duration,
      );
    } else {
      // Leaving uses a short ease without overshoot, so the pane never
      // grows again on its way out.
      _curve = Curves.easeInCubic;
      _controller
          .animateBack(
            0,
            duration: reduce
                ? Duration.zero
                : const Duration(milliseconds: 220),
          )
          .whenCompleteOrCancel(() {
            if (mounted && widget.panel == null && _controller.value == 0) {
              setState(() => _shown = null);
            }
          });
    }
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
    final content = AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      // Panels keep their fixed width while they cross-fade.
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(
        key: ValueKey(shown),
        child: widget.builder(context, shown),
      ),
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: _controller,
      child: content,
      builder: (context, child) {
        // The open spring may overshoot; the pane can briefly grow past its
        // width, but never below nothing.
        final value = math.max(0.0, _curve.transform(_controller.value));
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

/// The Material Up Next list in a desktop panel.
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
