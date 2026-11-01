import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
