import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Overrides [desktopTitleBarInContent] in tests.
bool? debugDesktopTitleBarInContentOverride;

/// Whether the window content reaches under a transparent title bar, with
/// the window controls over the top of the sidebar. The macOS
/// window does this (`macos/Runner/MainFlutterWindow.swift`); Windows and
/// Linux keep their native frame.
bool get desktopTitleBarInContent =>
    debugDesktopTitleBarInContentOverride ??
    (isDesktopPlatform &&
        Platform.isMacOS &&
        desktopWindowMode.value == DesktopWindowMode.windowed);

class DesktopWindowModeScope
    extends InheritedNotifier<ValueNotifier<DesktopWindowMode>> {
  DesktopWindowModeScope({super.key, required super.child})
    : super(notifier: desktopWindowMode);
}

bool desktopTitleBarInContentFor(BuildContext context) {
  context.dependOnInheritedWidgetOfExactType<DesktopWindowModeScope>();
  return desktopTitleBarInContent;
}

/// Height of the title bar row at the top of the window content. The
/// traffic lights sit centered in it, so the sidebar starts below it. Keep
/// in sync with `titleBarHeight` in `MainFlutterWindow.swift`.
const double desktopTitleBarHeight = 52;

/// Width the traffic lights take at the leading edge of the title bar row.
const double desktopWindowControlsWidth = 78;

const _windowChannel = MethodChannel('com.zarz.mornye/window');

enum DesktopWindowMode { windowed, fullscreen, borderless }

final desktopWindowMode = ValueNotifier(DesktopWindowMode.windowed);
DesktopWindowMode _beforeFullScreen = DesktopWindowMode.windowed;
bool _changingWindowMode = false;
int _windowModeRevision = 0;

/// Actual native state, also used by the full screen lyrics presentation.
final desktopWindowFullScreen = ValueNotifier<bool>(false);

void _receiveWindowMode(DesktopWindowMode mode) {
  _windowModeRevision++;
  if (mode == DesktopWindowMode.fullscreen &&
      desktopWindowMode.value != DesktopWindowMode.fullscreen) {
    _beforeFullScreen = desktopWindowMode.value;
  }
  desktopWindowMode.value = mode;
  desktopWindowFullScreen.value = mode == DesktopWindowMode.fullscreen;
}

DesktopWindowMode? _parseWindowMode(Object? value) {
  for (final mode in DesktopWindowMode.values) {
    if (value == mode.name) return mode;
  }
  return null;
}

/// Follows the window in and out of full screen. Call once at startup.
void listenDesktopWindowFullScreen() {
  if (!isDesktopPlatform) return;
  final revision = _windowModeRevision;
  _windowChannel.setMethodCallHandler((call) async {
    if (call.method == 'windowModeChanged') {
      final mode = _parseWindowMode(call.arguments);
      if (mode != null) _receiveWindowMode(mode);
    } else if (call.method == 'fullScreenChanged') {
      final fullScreen = call.arguments == true;
      if (fullScreen || desktopWindowFullScreen.value) {
        _receiveWindowMode(
          fullScreen ? DesktopWindowMode.fullscreen : _beforeFullScreen,
        );
      }
    }
  });
  unawaited(() async {
    try {
      final mode = _parseWindowMode(
        await _windowChannel.invokeMethod<String>('getWindowMode'),
      );
      if (mode != null && revision == _windowModeRevision) {
        _receiveWindowMode(mode);
      }
    } on MissingPluginException {
      // Older runners only expose the fullscreen query.
      try {
        final fullScreen = await _windowChannel.invokeMethod<bool>(
          'isFullScreen',
        );
        if (revision == _windowModeRevision) {
          _receiveWindowMode(
            fullScreen == true
                ? DesktopWindowMode.fullscreen
                : DesktopWindowMode.windowed,
          );
        }
      } on MissingPluginException {
        // A runner without window state support.
      } on PlatformException {
        // The window may close while the call is in flight.
      }
    } on PlatformException {
      // The window may close while the call is in flight.
    }
  }());
}

/// Changes native mode and waits for its acknowledgement, including AppKit
/// and window-manager transitions. A rejected request never changes UI state.
Future<bool> setDesktopWindowMode(DesktopWindowMode mode) async {
  if (!isDesktopPlatform || _changingWindowMode) return false;
  if (desktopWindowMode.value == mode) return true;
  _changingWindowMode = true;
  final changed = Completer<void>();
  void receive() {
    if (desktopWindowMode.value == mode && !changed.isCompleted) {
      changed.complete();
    }
  }

  desktopWindowMode.addListener(receive);
  try {
    final accepted = await _windowChannel.invokeMethod<bool>('setWindowMode', {
      'mode': mode.name,
    });
    if (accepted != true) return false;
    receive();
    await changed.future.timeout(const Duration(seconds: 4));
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  } on TimeoutException {
    try {
      final actualMode = _parseWindowMode(
        await _windowChannel.invokeMethod<String>('getWindowMode'),
      );
      if (actualMode != null) {
        _receiveWindowMode(actualMode);
        return actualMode == mode;
      }
    } on MissingPluginException {
      // The runner closed during the transition.
    } on PlatformException {
      // Keep the last state reported by the runner.
    }
    return false;
  } finally {
    desktopWindowMode.removeListener(receive);
    _changingWindowMode = false;
  }
}

Future<bool> toggleDesktopFullScreen() => setDesktopWindowMode(
  desktopWindowMode.value == DesktopWindowMode.fullscreen
      ? _beforeFullScreen
      : DesktopWindowMode.fullscreen,
);

Future<bool> toggleDesktopBorderless() => setDesktopWindowMode(
  desktopWindowMode.value == DesktopWindowMode.borderless
      ? DesktopWindowMode.windowed
      : DesktopWindowMode.borderless,
);

Future<bool> leaveDesktopWindowMode() => setDesktopWindowMode(
  desktopWindowMode.value == DesktopWindowMode.fullscreen
      ? _beforeFullScreen
      : DesktopWindowMode.windowed,
);

Future<void> minimizeDesktopWindow() => _invokeWindow('minimizeWindow');
Future<void> zoomDesktopWindow() => _invokeWindow('zoomWindow');
Future<void> closeDesktopWindow() => _invokeWindow('closeWindow');
Future<void> resizeDesktopWindow({required bool fromLeft}) => _invokeWindow(
  'startResize',
  {'edge': fromLeft ? 'bottomLeft' : 'bottomRight'},
);

/// Whether the window can turn into the mini player. Every desktop runner
/// implements it: `MainFlutterWindow.swift` on macOS, `flutter_window.cpp`
/// on Windows and `my_application.cc` on Linux.
bool get desktopMiniPlayerSupported => isDesktopPlatform;

/// Shrinks the window into the floating mini player panel of [size], or
/// resizes the panel. Returns false when the window cannot, such as in full
/// screen.
Future<bool> openDesktopMiniPlayerWindow(Size size) async {
  if (_changingWindowMode) return false;
  try {
    final opened = await _windowChannel.invokeMethod<bool>('openMiniPlayer', {
      'width': size.width,
      'height': size.height,
    });
    return opened ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Returns the window from the mini player to its full size and place.
Future<void> closeDesktopMiniPlayerWindow() => _invokeWindow('closeMiniPlayer');

Future<void> _invokeWindow(String method, [Object? arguments]) async {
  try {
    await _windowChannel.invokeMethod<void>(method, arguments);
  } on MissingPluginException {
    // A runner without the window channel.
  } on PlatformException {
    // The window may close while the call is in flight.
  }
}

/// Part of the title bar row: dragging it moves the window and, with
/// [zoomOnDoubleClick], a double click zooms it like a native title bar.
/// Widgets inside or behind it keep their clicks. Without a title bar in
/// the content ([desktopTitleBarInContent]) it only shows [child], unless
/// the window has no frame at all ([frameless]).
class DesktopWindowDragArea extends StatefulWidget {
  const DesktopWindowDragArea({
    super.key,
    this.child,
    this.zoomOnDoubleClick = false,
    this.frameless = false,
  });

  final Widget? child;

  /// The window has no frame to drag (the mini player), so the area moves
  /// it on every desktop platform.
  final bool frameless;

  /// Zooms (or minimizes, per the system setting) on a double click. Leave
  /// it off where buttons share the area, so their clicks never wait for a
  /// second one.
  final bool zoomOnDoubleClick;

  @override
  State<DesktopWindowDragArea> createState() => _DesktopWindowDragAreaState();
}

class _DesktopWindowDragAreaState extends State<DesktopWindowDragArea> {
  Duration? _lastDown;
  Offset? _lastPosition;

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    final lastDown = _lastDown;
    final lastPosition = _lastPosition;
    if (lastDown != null &&
        lastPosition != null &&
        event.timeStamp - lastDown <= kDoubleTapTimeout &&
        (event.position - lastPosition).distance <= kDoubleTapSlop) {
      _lastDown = null;
      _lastPosition = null;
      unawaited(_invokeWindow('titleBarDoubleClick'));
      return;
    }
    _lastDown = event.timeStamp;
    _lastPosition = event.position;
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (!desktopTitleBarInContentFor(context) && !widget.frameless) {
      return child ?? const SizedBox.shrink();
    }
    Widget area = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(_invokeWindow('startDrag')),
      child: child,
    );
    if (widget.zoomOnDoubleClick) {
      area = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        child: area,
      );
    }
    return area;
  }
}
