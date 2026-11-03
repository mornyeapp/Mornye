import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var audioOpenChannel: FlutterMethodChannel?
  private var pendingAudio: [[String]] = []
  private var audioOpenReady = false

  func installAudioOpenChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.zarz.mornye/open_audio", binaryMessenger: messenger)
    audioOpenChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      guard call.method == "takePending" else { result(FlutterMethodNotImplemented); return }
      self.audioOpenReady = true
      result(self.pendingAudio)
      self.pendingAudio.removeAll()
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter(\.isFileURL).map(\.path)
    if !files.isEmpty {
      if audioOpenReady {
        audioOpenChannel?.invokeMethod("open", arguments: files)
      } else {
        if pendingAudio.count >= 32 { pendingAudio.removeFirst() }
        pendingAudio.append(files)
      }
      application.activate(ignoringOtherApps: true)
      application.windows.first?.makeKeyAndOrderFront(nil)
    }
    let links = urls.filter { !$0.isFileURL }
    if !links.isEmpty { super.application(application, open: links) }
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // macOS only keeps one instance per app copy. With a second copy (an
    // old download next to /Applications, a mounted dmg, a debug build next
    // to a release one), a notification or URL can start it too, and both
    // would share one set of databases; hand over to the running instance
    // instead, as Windows and Linux do.
    if let bundleId = Bundle.main.bundleIdentifier,
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleId
      ).first(where: { $0 != NSRunningApplication.current })
    {
      FileHandle.standardError.write(
        Data(
          "Mornye is already running (pid \(running.processIdentifier)); quit it first.\n"
            .utf8))
      running.activate()
      exit(0)
    }
    super.applicationWillFinishLaunching(notification)
    NotificationCenter.default.addObserver(
      forName: NSApplication.didUpdateNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.adoptWindowsMenu()
    }
  }

  /// Flutter's menu bar replaces the main menu, and its Window menu is not
  /// the app's windows menu, so macOS leaves out the window tiling items
  /// (Fill, Center, Move & Resize) and their shortcuts. The Window menu is
  /// the one holding Bring All to Front, whatever its localized title.
  private func adoptWindowsMenu() {
    guard let mainMenu = NSApp.mainMenu else { return }
    let menus = mainMenu.items.compactMap(\.submenu)
    if let current = NSApp.windowsMenu, menus.contains(where: { $0 === current }) {
      return
    }
    let arrange = #selector(NSApplication.arrangeInFront(_:))
    guard let menu = menus.first(where: { $0.items.contains { $0.action == arrange } })
    else { return }
    NSApp.windowsMenu = menu
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
