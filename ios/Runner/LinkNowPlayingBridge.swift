import CryptoKit
import Flutter
import NowPlaying
import UIKit

/// Remote playback has its own iOS 27 session. It neither activates the
/// phone's audio session nor starts local audio to obtain a Lock Screen card.
@MainActor
final class LinkNowPlayingBridge {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/link_now_playing", binaryMessenger: messenger)
        if #available(iOS 27.0, *) {
            let controller = LinkNowPlayingController()
            channel.setMethodCallHandler { call, result in controller.handle(call, result) }
        } else {
            channel.setMethodCallHandler { call, result in
                result(call.method == "supported" ? false : nil)
            }
        }
    }

    deinit { channel.setMethodCallHandler(nil) }
}

@available(iOS 27.0, *)
@MainActor
private final class LinkNowPlayingController {
    private var binding: String?
    private var connection: LinkNowPlayingConnection?
    /// The shared Keychain refused the connection, so each session's
    /// attributes carry it to the extension.
    private var inlineConnection = false
    private var session: NowPlaying.RemoteMediaSession<LinkNowPlayingState>?
    private var pending: Task<Void, Never>?
    private var foreground: NSObjectProtocol?
    private var artworkSource: String?
    private var artworkFile: URL?

    init() {
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.promote() }
        }
    }

    deinit {
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if call.method == "supported" { result(true); return }
        // Serialize lifecycle calls across replacement Dart bindings. A slow
        // old start/end must never erase the new desktop's session.
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            do {
                guard let values = call.arguments as? [String: Any],
                      let token = values["binding"] as? String else {
                    throw LinkNowPlayingError.invalidConnection
                }
                switch call.method {
                case "configure":
                    let data = try JSONSerialization.data(withJSONObject: values)
                    let connection = try JSONDecoder().decode(LinkNowPlayingConnection.self, from: data)
                    guard connection.address.scheme == "https", connection.address.host != nil,
                          connection.fingerprint.count == 64,
                          connection.fingerprint.allSatisfy({ $0.isHexDigit }),
                          !connection.apiKey.isEmpty else { throw LinkNowPlayingError.invalidConnection }
                    try await self.end()
                    // An install without the app group has no shared
                    // Keychain; the session must still start without it.
                    self.inlineConnection = (try? connection.save()) == nil
                    self.connection = connection
                    self.binding = token
                    result(nil)
                case "update":
                    guard token == self.binding, let connection = self.connection,
                          let snapshot = values["state"] as? [String: Any] else { result(nil); return }
                    var state = try JSONDecoder().decode(
                        LinkNowPlayingState.self, from: JSONSerialization.data(withJSONObject: snapshot)
                    )
                    guard state.id == connection.id else { throw LinkNowPlayingError.invalidConnection }
                    state.artwork = try? self.sharedArtwork(state.artwork)
                    state.connection = self.inlineConnection ? connection : nil
                    if state.trackId.isEmpty {
                        try await self.session?.end()
                        self.session = nil
                    } else if let session = self.session {
                        try await session.update(state)
                    } else {
                        // Retire a card left by a terminated containing app.
                        for stale in try await NowPlaying.RemoteMediaSession<LinkNowPlayingState>.sessions() {
                            try await stale.end()
                        }
                        self.session = try await NowPlaying.RemoteMediaSession.start(attributes: state)
                        try await self.promote()
                    }
                    result(nil)
                case "end":
                    if token == self.binding { try await self.end() }
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                // URL/authentication details are intentionally absent from the
                // channel error: the Dart log needs only the failed operation.
                result(FlutterError(code: "link_now_playing", message: "Could not \(call.method) the remote media session", details: nil))
            }
        }
    }

    private func promote() async throws {
        guard UIApplication.shared.applicationState == .active else { return }
        try await session?.requestToBecomeSystemPrimary()
    }

    private func end() async throws {
        defer {
            session = nil
            if let connection { LinkNowPlayingConnection.remove(connection.id) }
            connection = nil
            inlineConnection = false
            binding = nil
        }
        try await session?.end()
    }

    private func sharedArtwork(_ source: String?) throws -> String? {
        guard let source, let url = URL(string: source) else { return nil }
        if !url.isFileURL {
            guard url.scheme == "https", var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil else { return nil }
            // The extension supplies Bearer authentication itself. Keep paired
            // API keys and Subsonic authentication out of session attributes.
            let privateKeys: Set<String> = ["apikey", "api_key", "token", "access_token", "password", "authorization", "u", "p", "t", "s"]
            components.queryItems = components.queryItems?.filter {
                !privateKeys.contains($0.name.lowercased()) && $0.value != connection?.apiKey
            }
            return components.url?.absoluteString
        }
        if source == artworkSource { return artworkFile?.absoluteString }
        guard let group = LinkNowPlayingConnection.group,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16 * 1024 * 1024 else { return nil }
        let directory = container.appendingPathComponent("LinkNowPlayingArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        try Data(contentsOf: url).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        if let old = artworkFile, old != file { try? FileManager.default.removeItem(at: old) }
        artworkSource = source
        artworkFile = file
        return file.absoluteString
    }
}
