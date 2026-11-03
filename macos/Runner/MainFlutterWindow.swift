import Cocoa
import FlutterMacOS
import QuartzCore

class MainFlutterWindow: NSWindow {
  /// Height of the title bar row the Flutter content leaves for the window
  /// controls. Keep in sync with `desktopTitleBarHeight` in
  /// lib/widgets/desktop/desktop_window.dart.
  private static let titleBarHeight: CGFloat = 52

  /// Distance from the leading window edge to the close button.
  private static let windowControlsInset: CGFloat = 20

  private var windowChannel: FlutterMethodChannel?
  private var borderless = false
  private var windowedStyle: NSWindow.StyleMask?
  private var fullScreenReturnMode = "windowed"
  private var modeAfterFullScreen: String?
  private var requestedFullScreen = false
  private var fullScreenRestoreFrame: NSRect?
  private var resizeMonitor: Any?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// The full window's frame and minimum size while the mini player shows.
  private var miniPlayerRestore: (frame: NSRect, minSize: NSSize)?

  /// Where the mini player last sat, by its top-left corner.
  private static let miniPlayerOriginKey = "MornyeMiniPlayerTopLeft"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.contentMinSize = NSSize(width: 800, height: 600)
    self.center()

    // Like Music, the content reaches the top of the window: the sidebar
    // runs under the traffic lights and the content pane's controls share
    // their row. Flutter draws drag areas there (DesktopWindowDragArea).
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerWindowChannel(flutterViewController.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.installAudioOpenChannel(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    // AppKit puts the title bar controls back after resizing, full screen
    // and key changes, so center them in the taller row again each time.
    for name in [
      NSWindow.didResizeNotification,
      NSWindow.didEndLiveResizeNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didChangeBackingPropertiesNotification,
    ] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowControlsNeedLayout),
        name: name,
        object: self
      )
    }
    layoutWindowControls()

    // Music swaps its lyrics panel for a full-window player in full screen,
    // so the Flutter side follows the window in and out of it.
    for name in [
      NSWindow.willEnterFullScreenNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ] {
      NotificationCenter.default.addObserver(
        forName: name,
        object: self,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        if name == NSWindow.willEnterFullScreenNotification {
          if !self.requestedFullScreen {
            self.fullScreenReturnMode = self.borderless ? "borderless" : "windowed"
            self.fullScreenRestoreFrame = self.frame
          }
          return
        }
        self.requestedFullScreen = false
        if name == NSWindow.didExitFullScreenNotification {
          self.applyBorderless(
            (self.modeAfterFullScreen ?? self.fullScreenReturnMode) == "borderless")
          self.modeAfterFullScreen = nil
          if let restore = self.fullScreenRestoreFrame {
            self.setFrame(self.constrainFrameRect(restore, to: self.screen), display: true)
          }
          self.fullScreenRestoreFrame = nil
        }
        self.notifyWindowMode()
      }
    }

    // Quitting from the mini player leaves the full window for the next
    // launch to restore.
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.closeMiniPlayer(animate: false)
    }
  }

  /// Shrinks the window into a small floating panel of [size], or resizes
  /// the panel when it already shows. It stays above other windows and on
  /// every Space, keeps its top-left corner when it resizes, and opens
  /// where it last sat (first at the top right of the screen).
  private func openMiniPlayer(size: NSSize, completion: @escaping (Bool) -> Void) {
    if styleMask.contains(.fullScreen) {
      completion(false)
      return
    }
    let opening = miniPlayerRestore == nil
    if opening {
      miniPlayerRestore = (frame, contentMinSize)
      styleMask.remove(.resizable)
      level = .floating
      collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
      for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        standardWindowButton(button)?.isHidden = true
      }
    }
    contentMinSize = size
    var target = frameRect(forContentRect: NSRect(origin: .zero, size: size))
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
    var topLeft: NSPoint
    if !opening {
      topLeft = NSPoint(x: frame.minX, y: frame.maxY)
    } else if let saved = UserDefaults.standard.string(forKey: Self.miniPlayerOriginKey) {
      topLeft = NSPointFromString(saved)
    } else {
      topLeft = NSPoint(x: visible.maxX - target.width - 16, y: visible.maxY - 16)
    }
    // Keep the whole panel on the screen it opens on.
    topLeft.x = min(max(topLeft.x, visible.minX), visible.maxX - target.width)
    topLeft.y = min(max(topLeft.y, visible.minY + target.height), visible.maxY)
    target.origin = NSPoint(x: topLeft.x, y: topLeft.y - target.height)
    animateMiniPlayerFrame(to: target, animate: true) {
      completion(true)
    }
  }

  /// Returns the window to the size, place and behavior it had before the
  /// mini player.
  private func closeMiniPlayer(animate: Bool, completion: @escaping () -> Void = {}) {
    guard let restore = miniPlayerRestore else {
      completion()
      return
    }
    UserDefaults.standard.set(
      NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)),
      forKey: Self.miniPlayerOriginKey
    )
    animateMiniPlayerFrame(to: restore.frame, animate: animate) { [self] in
      miniPlayerRestore = nil
      level = .normal
      collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
      styleMask.insert(.resizable)
      // Raising the minimum before the animation forces an immediate jump
      // from the panel size to the full window's minimum size.
      contentMinSize = restore.minSize
      for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        standardWindowButton(button)?.isHidden = false
      }
      layoutWindowControls()
      completion()
    }
  }

  private func animateMiniPlayerFrame(
    to target: NSRect,
    animate: Bool,
    completion: @escaping () -> Void
  ) {
    guard animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      setFrame(target, display: true)
      completion()
      return
    }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.36
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animator().setFrame(target, display: true)
    }, completionHandler: completion)
  }

  @objc private func windowControlsNeedLayout(_ notification: Notification) {
    if notification.name == NSWindow.didResignKeyNotification {
      stopWindowResize()
    }
    layoutWindowControls()
  }

  /// Centers the traffic lights vertically in a [titleBarHeight] row.
  private func layoutWindowControls() {
    guard !styleMask.contains(.fullScreen),
      let close = standardWindowButton(.closeButton),
      let miniaturize = standardWindowButton(.miniaturizeButton),
      let zoom = standardWindowButton(.zoomButton),
      let titleBar = close.superview,
      let container = titleBar.superview
    else { return }
    let height = Self.titleBarHeight
    var containerFrame = container.frame
    containerFrame.size.height = height
    containerFrame.origin.y = frame.height - height
    container.frame = containerFrame
    titleBar.frame = container.bounds
    let spacing = miniaturize.frame.minX - close.frame.minX
    for (index, button) in [close, miniaturize, zoom].enumerated() {
      button.setFrameOrigin(
        NSPoint(
          x: Self.windowControlsInset + CGFloat(index) * spacing,
          y: ((height - button.frame.height) / 2).rounded()
        )
      )
    }
  }

  /// Window actions for the Flutter drag areas in the title bar row.
  private func registerWindowChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.zarz.mornye/window",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "startDrag":
        if let event = self.currentEvent ?? NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "titleBarDoubleClick":
        self.performTitleBarDoubleClick()
        result(nil)
      case "isFullScreen":
        result(self.styleMask.contains(.fullScreen))
      case "getWindowMode":
        result(self.windowMode)
      case "setWindowMode":
        let args = call.arguments as? [String: Any]
        result(self.setWindowMode(args?["mode"] as? String ?? ""))
      case "minimizeWindow":
        self.miniaturize(nil)
        result(nil)
      case "zoomWindow":
        self.zoom(nil)
        result(nil)
      case "closeWindow":
        result(nil)
        self.stopWindowResize()
        self.performClose(nil)
      case "startResize":
        let args = call.arguments as? [String: Any]
        self.startWindowResize(fromLeft: args?["edge"] as? String == "bottomLeft")
        result(nil)
      case "openMiniPlayer":
        let args = call.arguments as? [String: Any]
        let width = (args?["width"] as? NSNumber)?.doubleValue ?? 360
        let height = (args?["height"] as? NSNumber)?.doubleValue ?? 140
        self.openMiniPlayer(size: NSSize(width: width, height: height)) { opened in
          result(opened)
        }
      case "closeMiniPlayer":
        self.closeMiniPlayer(animate: true) {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel
  }

  private var windowMode: String {
    if styleMask.contains(.fullScreen) { return "fullscreen" }
    return borderless ? "borderless" : "windowed"
  }

  private func stopWindowResize() {
    if let monitor = resizeMonitor { NSEvent.removeMonitor(monitor) }
    resizeMonitor = nil
  }

  private func startWindowResize(fromLeft: Bool) {
    guard borderless, miniPlayerRestore == nil, !styleMask.contains(.fullScreen) else { return }
    stopWindowResize()
    let origin = NSEvent.mouseLocation
    let bounds = frame
    let minimum = frameRect(forContentRect: NSRect(origin: .zero, size: contentMinSize)).size
    resizeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) {
      [weak self] event in
      guard let self else { return event }
      if event.type == .leftMouseUp {
        self.stopWindowResize()
      } else {
        let pointer = NSEvent.mouseLocation
        let delta = NSPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        let width = max(minimum.width, bounds.width + (fromLeft ? -delta.x : delta.x))
        let height = max(minimum.height, bounds.height - delta.y)
        let x = fromLeft ? bounds.maxX - width : bounds.minX
        self.setFrame(
          NSRect(x: x, y: bounds.maxY - height, width: width, height: height), display: true)
      }
      return event
    }
  }

  private func notifyWindowMode() {
    windowChannel?.invokeMethod("windowModeChanged", arguments: windowMode)
  }

  private func applyBorderless(_ enabled: Bool) {
    guard borderless != enabled else { return }
    let bounds = frame
    if enabled {
      windowedStyle = styleMask
      styleMask = [.borderless, .resizable, .closable, .miniaturizable]
    } else if let restore = windowedStyle {
      styleMask = restore
    }
    borderless = enabled
    setFrame(bounds, display: true)
    layoutWindowControls()
    makeKeyAndOrderFront(nil)
  }

  private func setWindowMode(_ mode: String) -> Bool {
    guard miniPlayerRestore == nil,
      ["windowed", "fullscreen", "borderless"].contains(mode)
    else { return false }
    if mode == windowMode {
      notifyWindowMode()
      return true
    }
    if styleMask.contains(.fullScreen) {
      modeAfterFullScreen = mode
      toggleFullScreen(nil)
    } else if mode == "fullscreen" {
      fullScreenReturnMode = borderless ? "borderless" : "windowed"
      fullScreenRestoreFrame = frame
      // AppKit's native fullscreen transition requires a titled window.
      applyBorderless(false)
      requestedFullScreen = true
      toggleFullScreen(nil)
    } else {
      applyBorderless(mode == "borderless")
      notifyWindowMode()
    }
    return true
  }

  /// Follows the Desktop & Dock setting for double-clicking a title bar.
  private func performTitleBarDoubleClick() {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      performMiniaturize(nil)
    case "None":
      break
    default:
      if borderless {
        zoom(nil)
      } else {
        performZoom(nil)
      }
    }
  }
}
