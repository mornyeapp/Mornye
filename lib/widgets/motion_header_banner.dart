import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/music_player_service.dart';

final _log = AppLogger('MotionHeaderBanner');

class MotionHeaderBanner extends ConsumerStatefulWidget {
  final String videoUrl;
  final Widget fallback;
  final ValueChanged<double>? onAspectRatioChanged;
  final VoidCallback? onError;
  final VideoPlayerController? controller;
  final Duration fadeDuration;

  const MotionHeaderBanner({
    super.key,
    required this.videoUrl,
    required this.fallback,
    this.onAspectRatioChanged,
    this.onError,
    this.controller,
    this.fadeDuration = const Duration(milliseconds: 400),
  });

  @override
  ConsumerState<MotionHeaderBanner> createState() => _MotionHeaderBannerState();
}

class _MotionHeaderBannerState extends ConsumerState<MotionHeaderBanner>
    with WidgetsBindingObserver {
  /// Banners showing each borrowed controller. It plays while any of them is
  /// visible, so an outgoing copy (a cover fading out as the player rotates)
  /// cannot pause the video the incoming one shows.
  static final _borrowers =
      <VideoPlayerController, Set<_MotionHeaderBannerState>>{};

  VideoPlayerController? _controller;
  bool _ownsController = true;
  bool _ready = false;
  bool _failed = false;
  bool _headerVisible = true;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(settingsProvider.select((s) => s.motionArtworkEnabled), (
      _,
      enabled,
    ) {
      _disposeController();
      _ready = false;
      _failed = false;
      if (enabled) _initialize();
    });
    _initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final header = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    // A collapsed FlexibleSpaceBar hides its background with opacity only;
    // its TickerMode remains enabled while the pinned toolbar is visible.
    _headerVisible = header == null || header.currentExtent > header.minExtent;
    // TickerMode is off while this subtree is hidden: covered by an opaque
    // route (Navigator offstages it) or on an inactive shell tab. Follow it
    // so the decoder doesn't keep running behind other screens.
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_syncPlayback);
      _tickerMode = notifier;
      notifier.addListener(_syncPlayback);
    }
    _syncPlayback();
  }

  bool get _visible {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final appVisible =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    return appVisible && _headerVisible && (_tickerMode?.value.enabled ?? true);
  }

  void _syncPlayback() {
    final controller = _controller;
    if (controller == null || !_ready) return;
    final shouldPlay = _ownsController
        ? _visible
        : _borrowers[controller]?.any((banner) => banner._visible) ?? false;
    if (controller.value.isPlaying == shouldPlay) return;
    if (shouldPlay) {
      controller.play();
    } else {
      controller.pause();
    }
  }

  @override
  void didUpdateWidget(MotionHeaderBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.controller != widget.controller) {
      _disposeController();
      _ready = false;
      _failed = false;
      _initialize();
    }
  }

  Future<void> _initialize() async {
    if (!ref.read(settingsProvider).motionArtworkEnabled) return;
    final prepared = widget.controller;
    if (prepared != null && prepared.value.isInitialized) {
      _ownsController = false;
      _controller = prepared;
      _borrowers.putIfAbsent(prepared, () => {}).add(this);
      _ready = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(prepared, _controller)) return;
        widget.onAspectRatioChanged?.call(prepared.value.aspectRatio);
        _syncPlayback();
      });
      return;
    }
    _ownsController = true;
    final url = widget.videoUrl.trim();
    if (url.isEmpty) {
      setState(() => _failed = true);
      return;
    }

    final uri = Uri.tryParse(url);
    final options = VideoPlayerOptions(mixWithOthers: true);
    final controller = uri?.scheme == 'file' || url.startsWith('/')
        ? VideoPlayerController.file(
            uri?.scheme == 'file' ? File.fromUri(uri!) : File(url),
            videoPlayerOptions: options,
          )
        : VideoPlayerController.networkUrl(
            Uri.parse(url),
            formatHint: uri?.path.toLowerCase().endsWith('.m3u8') == true
                ? VideoFormat.hls
                : null,
            videoPlayerOptions: options,
          );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted || !identical(controller, _controller)) return;
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted || !identical(controller, _controller)) return;
      setState(() => _ready = true);
      widget.onAspectRatioChanged?.call(controller.value.aspectRatio);
      _syncPlayback();
    } catch (e) {
      _log.w('Failed to play motion banner: $e');
      if (!mounted || !identical(controller, _controller)) return;
      _disposeController();
      setState(() => _failed = true);
      widget.onError?.call();
    } finally {
      await restoreMusicAudioSessionAfterVideo();
    }
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    if (_ownsController) {
      controller.dispose();
      return;
    }
    final borrowers = _borrowers[controller]?..remove(this);
    if (borrowers == null || borrowers.isEmpty) {
      _borrowers.remove(controller);
      controller.pause();
    } else {
      borrowers.first._syncPlayback();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncPlayback();
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_syncPlayback);
    WidgetsBinding.instance.removeObserver(this);
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
      return widget.fallback;
    }
    final controller = _controller;
    final showVideo = _ready && !_failed && controller != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.fallback,
        AnimatedOpacity(
          opacity: showVideo ? 1.0 : 0.0,
          duration: widget.fadeDuration,
          child: showVideo
              ? FittedBox(
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
