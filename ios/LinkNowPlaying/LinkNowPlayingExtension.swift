import ExtensionFoundation
import Foundation
import NowPlaying
import Observation
import os

private let log = Logger(subsystem: "com.zarz.mornye.LinkNowPlaying", category: "session")

/// An error's kind for the device log, without the URLs or keys it may carry.
private func describe(_ error: Error) -> String {
    if let error = error as? LinkNowPlayingError { return "\(error)" }
    let error = error as NSError
    var kind = "\(error.domain) \(error.code)"
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        kind += " < \(underlying.domain) \(underlying.code)"
    }
    // A refused path names its reason, such as local network access.
    if let path = error.userInfo["_NSURLErrorNWPathKey"].map(String.init(describing:)),
       let reason = path.split(separator: "(", maxSplits: 1).dropFirst().first?.split(separator: ")").first {
        kind += " (\(reason))"
    }
    return kind
}

/// Errors cross XPC back to the system, and a URL error's details hold
/// objects it cannot encode, which abort the extension. Only the kind crosses.
private func crossable(_ error: Error) -> Error {
    let error = error as NSError
    return NSError(domain: error.domain, code: error.code)
}

@main
struct LinkNowPlayingExtension: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: LinkNowPlayingState) async throws -> LinkNowPlayingSession {
        do {
            let session = try LinkNowPlayingSession(attributes)
            await session.refresh()
            return session
        } catch {
            log.error("Could not start the session: \(describe(error), privacy: .public)")
            throw crossable(error)
        }
    }
}

@Observable
@MainActor
final class LinkNowPlayingSession: RemoteMediaSessionRepresentable {
    let id: String
    private var state: LinkNowPlayingState
    @ObservationIgnored private let client: LinkNowPlayingClient
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    init(_ state: LinkNowPlayingState) throws {
        id = state.id
        self.state = state
        client = try LinkNowPlayingClient(state.connection ?? LinkNowPlayingConnection.read(state.id))
        // Refresh while the system keeps this extension alive. The containing
        // app also supplies live Link updates, without creating a second
        // WebSocket that would replace the phone's authenticated connection.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                await self?.refresh()
            }
        }
    }

    deinit { refreshTask?.cancel() }

    func update(_ attributes: LinkNowPlayingState) {
        guard attributes.id == id else { return }
        revision += 1
        state = attributes
    }

    func refresh() async {
        // A LAN interruption must not turn the desktop's playback into a
        // stopped local session. Its last snapshot continues to extrapolate.
        revision += 1
        let current = revision
        do {
            let snapshot = try await client.state()
            if current == revision { state.apply(snapshot) }
        } catch {
            log.error("Could not read the computer's playback: \(describe(error), privacy: .public)")
        }
    }

    private func command(_ action: String, _ args: [String: Any] = [:]) async throws {
        do {
            try await client.command(action, args)
        } catch {
            log.error("Could not send \(action, privacy: .public): \(describe(error), privacy: .public)")
            throw crossable(error)
        }
        await refresh()
    }

    var content: (any MediaContentRepresentable)? {
        guard !state.trackId.isEmpty else { return nil }
        // The computer serves a catalog song's cover itself. The app's own
        // cover is a loopback URL or a file the extension cannot read.
        let source = state.songId.flatMap(client.cover) ?? state.artwork.flatMap(URL.init(string:))
        let artwork = source.map { url in
            Artwork(id: url.absoluteString) { [client] _ in
                do {
                    return try ArtworkRepresentation(data: try await client.artwork(url))
                } catch {
                    log.error("Could not load the cover: \(describe(error), privacy: .public)")
                    throw crossable(error)
                }
            }
        }
        return MusicContent(id: state.trackId, songTitle: state.title, artistName: state.artist,
                            albumName: state.album, type: .audio,
                            duration: state.duration.map(MediaDuration.finite), artwork: artwork)
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(state: state.trackId.isEmpty ? .stopped : state.playing ? .playing() : .paused,
                              elapsedTime: state.position, timestamp: Date(timeIntervalSince1970: state.updatedAt))
    }

    var commands: [MediaCommand] {
        [
            .play { try await self.command("play") },
            .pause { try await self.command("pause") },
            .togglePlayPause { try await self.command("toggle") },
            .next { try await self.command("next") },
            .previous { try await self.command("previous") },
            .seekToPosition { time in
                guard time.isFinite, time >= 0, time < Double(Int.max / 1000) else { return }
                try await self.command("seek", ["positionMs": Int(time * 1000)])
            },
        ]
    }

    var devices: [MediaDevice] {
        [MediaDevice(id: id, name: state.deviceName, type: .desktop, capabilities: [
            .absoluteVolume(Float(state.volume)) { value in
                try await self.command("volume", ["value": Double(value)])
            },
        ])]
    }
}
