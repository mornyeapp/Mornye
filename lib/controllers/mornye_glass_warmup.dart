import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show LiquidGlassWidgets;
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/utils/logger.dart';

/// Prepares the actual backdrop pipeline, not just the fragment asset. The
/// detached scene is rasterized once and discarded without presenting a frame.
class MornyeGlassWarmup {
  static Future<void>? _pending;
  static bool _ready = false;
  static final _log = AppLogger('MornyeGlass');

  /// Whether the one-time warmup has finished.
  static bool get isReady => _ready;

  static Future<void> prepare(ui.FlutterView view) {
    if (!ui.ImageFilter.isShaderFilterSupported) return Future<void>.value();
    return _pending ??= _prepare(view).catchError((Object error) {
      // Preparation is optional; keep the package's existing lazy fallback.
      _log.w('Glass preparation failed: $error');
    });
  }

  static Future<void> _prepare(ui.FlutterView view) async {
    // GLES needs the view's initialized graphics context. A first-frame
    // callback only means painting was submitted, not that rasterization ran.
    await Future.wait<void>([
      // The package's monitor reports slow frames as errors in debug builds.
      LiquidGlassWidgets.initialize(enablePerformanceMonitor: false),
      WidgetsBinding.instance.waitUntilFirstFrameRasterized,
    ]);
    // Do not compete with an entrance, theme switch or scrolling animation.
    await SchedulerBinding.instance.scheduleTask(
      () async {
        final binding = WidgetsBinding.instance;
        if (binding.lifecycleState != AppLifecycleState.resumed ||
            !binding.platformDispatcher.views.contains(view)) {
          _pending = null;
          return;
        }
        await _rasterize(view);
        _ready = true;
      },
      Priority.idle,
      debugLabel: 'Prepare Mornye glass backdrop',
    );
  }
}

Future<void> _rasterize(ui.FlutterView view) async {
  const size = Size(240, 180);
  final boundary = RenderRepaintBoundary();
  final pipeline = PipelineOwner();
  final focus = FocusManager();
  final owner = BuildOwner(focusManager: focus);
  final renderView = RenderView(
    view: view,
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * view.devicePixelRatio),
      devicePixelRatio: view.devicePixelRatio,
    ),
    child: boundary,
  );
  pipeline.rootNode = renderView;
  renderView.prepareInitialFrame();
  RenderObjectToWidgetElement<RenderBox>? root;
  try {
    root = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: ProviderScope(
        overrides: [
          mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.liquid),
        ],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              devicePixelRatio: view.devicePixelRatio,
            ),
            child: Theme(
              data: MornyeTheme.build(Brightness.dark),
              child: const Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xff76534b), Color(0xff385763)],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: MornyeGlassPanel.overlay(
                      child: Center(child: Text('Download')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).attachToRenderTree(owner);
    owner.buildScope(root);
    owner.finalizeTree();
    pipeline.flushLayout();
    pipeline.flushCompositingBits();
    pipeline.flushPaint();
    final image = await boundary.toImage(pixelRatio: view.devicePixelRatio);
    image.dispose();
  } finally {
    if (root != null) {
      RenderObjectToWidgetAdapter<RenderBox>(
        container: boundary,
      ).attachToRenderTree(owner, root);
      owner.buildScope(root);
      owner.finalizeTree();
    }
    pipeline.rootNode = null;
    renderView.child = null;
    renderView.dispose();
    boundary.dispose();
    pipeline.dispose();
    focus.dispose();
  }
}
