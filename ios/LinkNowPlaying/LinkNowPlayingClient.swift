import CryptoKit
import Foundation
import Security

/// The extension talks to the desktop directly, so transport buttons do not
/// depend on the containing Flutter app being awake behind the Lock Screen.
final class LinkNowPlayingClient: Sendable {
    private let connection: LinkNowPlayingConnection
    private let session: URLSession

    init(_ connection: LinkNowPlayingConnection) throws {
        guard connection.address.scheme == "https", connection.address.host != nil,
              connection.fingerprint.count == 64,
              connection.fingerprint.allSatisfy({ $0.isHexDigit }),
              !connection.apiKey.isEmpty else { throw LinkNowPlayingError.invalidConnection }
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration, delegate: LinkNowPlayingPin(connection), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func state() async throws -> [String: Any] {
        let data = try await request("state")
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinkNowPlayingError.invalidResponse
        }
        return state
    }

    func command(_ action: String, _ args: [String: Any] = [:]) async throws {
        _ = try await request("command", body: ["action": action, "args": args])
    }

    private func request(_ operation: String, body: [String: Any]? = nil) async throws -> Data {
        let url = connection.address.appendingPathComponent("mornye/v1/\(operation)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LinkNowPlayingError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw LinkNowPlayingError.status(response.statusCode) }
        guard data.count <= 1024 * 1024 else { throw LinkNowPlayingError.invalidResponse }
        return data
    }

    /// The cover of the computer's catalog song `songId`, which the computer
    /// serves while the containing app sleeps.
    func cover(_ songId: String) -> URL? {
        var components = URLComponents(url: connection.address.appendingPathComponent("rest/getCoverArt.view"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "Mornye"),
            URLQueryItem(name: "id", value: songId), URLQueryItem(name: "size", value: "600"),
        ]
        return components?.url
    }

    func artwork(_ url: URL) async throws -> Data {
        if url.isFileURL {
            guard let group = LinkNowPlayingConnection.group,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
                  url.standardizedFileURL.path.hasPrefix(container.standardizedFileURL.path + "/") else {
                throw LinkNowPlayingError.invalidResponse
            }
            return try Data(contentsOf: url)
        }
        guard url.scheme == "https" else { throw LinkNowPlayingError.invalidResponse }
        let sameOrigin = url.host == connection.address.host && url.port == connection.address.port
        var source = url
        // The desktop's Subsonic routes take the key as `apiKey`, which the
        // app strips from the shared URL; only `/mornye/v1` reads Bearer.
        if sameOrigin, url.path.hasPrefix("/rest/"),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "apiKey", value: connection.apiKey)]
            source = components.url ?? url
        }
        var request = URLRequest(url: source, timeoutInterval: 8)
        if sameOrigin { request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await (sameOrigin ? session : URLSession.shared).data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LinkNowPlayingError.invalidResponse }
        guard response.statusCode == 200 else { throw LinkNowPlayingError.status(response.statusCode) }
        guard data.count <= 16 * 1024 * 1024 else { throw LinkNowPlayingError.invalidResponse }
        return data
    }
}

private final class LinkNowPlayingPin: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let connection: LinkNowPlayingConnection

    init(_ connection: LinkNowPlayingConnection) { self.connection = connection }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == connection.address.host,
              space.port == (connection.address.port ?? 443),
              let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard fingerprint == connection.fingerprint.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
