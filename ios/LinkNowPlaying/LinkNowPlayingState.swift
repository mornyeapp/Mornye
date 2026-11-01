import Foundation
import NowPlaying
import Security

/// Session attributes carry playback facts. Pairing credentials stay in the
/// shared Keychain, except on an install without the app group (and so
/// without that Keychain), where [connection] carries them instead.
@available(iOS 27.0, *)
struct LinkNowPlayingState: RemoteMediaSessionAttributes {
    var id: String
    var deviceName: String
    var trackId: String
    var title: String
    var artist: String
    var album: String
    var duration: Double?
    var position: Double
    var updatedAt: Double
    var playing: Bool
    var volume: Double
    var artwork: String?
    /// A catalog song of this computer, whose id names its cover too.
    var songId: String?
    var connection: LinkNowPlayingConnection?

    mutating func apply(_ state: [String: Any]) {
        guard let track = state["track"] as? [String: Any] else {
            playing = false
            trackId = ""
            return
        }
        let nextId = track["songId"] as? String ?? track["fileId"] as? String
            ?? "\(track["title"] as? String ?? "")|\(track["artist"] as? String ?? "")"
        if nextId != trackId { artwork = nil }
        trackId = nextId
        songId = track["serverId"] as? String == id ? track["songId"] as? String : nil
        title = track["title"] as? String ?? title
        artist = track["artist"] as? String ?? artist
        album = track["album"] as? String ?? ""
        duration = (state["durationMs"] as? NSNumber ?? track["durationMs"] as? NSNumber)
            .map { max(0, $0.doubleValue / 1000) }
        position = max(0, (state["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
        updatedAt = ((state["updatedMs"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000) / 1000
        playing = state["playing"] as? Bool ?? false
        volume = min(1, max(0, (state["volume"] as? NSNumber)?.doubleValue ?? volume))
    }
}

struct LinkNowPlayingConnection: Codable, Sendable {
    let id: String
    let address: URL
    let fingerprint: String
    let apiKey: String

    static var group: String? {
        Bundle.main.object(forInfoDictionaryKey: "PlayerWidgetAppGroup") as? String
    }

    private static func query(_ id: String) throws -> [String: Any] {
        guard let group, !group.isEmpty else { throw LinkNowPlayingError.missingGroup }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zarz.mornye.link-now-playing",
            kSecAttrAccount as String: id,
            kSecAttrAccessGroup as String: group,
        ]
    }

    func save() throws {
        let query = try Self.query(id)
        let value = [kSecValueData as String: try JSONEncoder().encode(self)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LinkNowPlayingError.keychain(status) }
    }

    static func read(_ id: String) throws -> LinkNowPlayingConnection {
        var query = try query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw LinkNowPlayingError.keychain(status)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func remove(_ id: String) {
        if let query = try? query(id) { SecItemDelete(query as CFDictionary) }
    }
}

enum LinkNowPlayingError: Error {
    case missingGroup
    case keychain(OSStatus)
    case invalidConnection
    case invalidResponse
    case status(Int)
}
