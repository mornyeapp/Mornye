import Foundation
import CryptoKit
import Darwin
import ffmpegkit
import MornyeBackend
import Flutter

struct CoreFFmpegCommand: Decodable {
    let command_id: String
    let arguments: [String]
    var output_path: String? = nil
}

final class CoreFFmpegExecution {
    let wait: (Int64) throws -> [CoreFFmpegCommand]
    let active: (String) throws -> Bool
    let complete: (String, Bool, String, String) throws -> Void
    let close: () -> Void
    private let lock = NSLock()
    private var running = true

    init(wait: @escaping (Int64) throws -> [CoreFFmpegCommand], active: @escaping (String) throws -> Bool,
         complete: @escaping (String, Bool, String, String) throws -> Void, close: @escaping () -> Void = {}) {
        self.wait = wait
        self.active = active
        self.complete = complete
        self.close = close
    }

    func run(execute: @escaping ([String], @escaping () -> Bool) -> (Bool, String) = executeCoreFFmpeg,
             block: () throws -> String) rethrows -> String {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.close() }
            while self.isRunning() {
                guard let commands = try? self.wait(1_000) else { return }
                // A different operation may own any command in this claimed batch.
                for command in commands {
                    let cancelled = { (try? self.active(command.command_id)) != true }
                    let result: (Bool, String)
                    if cancelled() { result = (false, "cancelled") }
                    else if command.arguments.isEmpty { result = (false, "FFmpeg arguments are empty") }
                    else { result = executeCoreFFmpegCommand(command: command, cancelled: cancelled, execute: execute) }
                    try? self.complete(command.command_id, result.0, result.1, result.0 ? "" : result.1)
                }
            }
        }
        defer {
            lock.lock()
            running = false
            lock.unlock()
        }
        return try block()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}

private enum CoreFFmpegStaging {
    static let lock = NSLock()
    static var directories = Set<String>()
    static let prefix = ".mornye-ffmpeg-\(Bundle.main.bundleIdentifier ?? "mornye")-"

    static func create(for target: URL) throws -> URL {
        let directory = target.deletingLastPathComponent().resolvingSymlinksInPath()
        lock.lock()
        defer { lock.unlock() }
        // One app process owns these stages. Sweep before its first command
        // in this directory; subsequent/concurrent commands may own live files.
        if !directories.contains(directory.path) {
            for file in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) where file.lastPathComponent.hasPrefix(prefix) {
                let suffix = file.lastPathComponent.dropFirst(prefix.count)
                let token = String(suffix.prefix(36))
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if UUID(uuidString: token) != nil, suffix.dropFirst(36).hasPrefix("."),
                   values.isRegularFile == true, values.isSymbolicLink != true {
                    try FileManager.default.removeItem(at: file)
                }
            }
            directories.insert(directory.path)
        }
        let staged = directory.appendingPathComponent("\(prefix)\(UUID().uuidString).\(target.pathExtension)")
        try Data().write(to: staged, options: .withoutOverwriting)
        return staged
    }
}

func executeCoreFFmpegCommand(command: CoreFFmpegCommand, cancelled: @escaping () -> Bool,
                              execute: ([String], @escaping () -> Bool) -> (Bool, String)) -> (Bool, String) {
    if cancelled() { return (false, "cancelled") }
    guard let output = command.output_path, !output.isEmpty else {
        return execute(command.arguments, cancelled)
    }
    guard command.arguments.last == output else { return (false, "FFmpeg output does not match command") }
    let target = URL(fileURLWithPath: output)
    do {
        let staged = try CoreFFmpegStaging.create(for: target)
        defer { try? FileManager.default.removeItem(at: staged) }
        var arguments = command.arguments
        arguments[arguments.count - 1] = staged.path
        let result = execute(arguments, cancelled)
        if cancelled() { return (false, "cancelled") }
        if !result.0 { return result }
        // POSIX rename replaces the destination atomically on the same filesystem.
        guard rename(staged.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return result
    } catch {
        return (false, error.localizedDescription)
    }
}

private func executeCoreFFmpeg(arguments: [String], cancelled: @escaping () -> Bool) -> (Bool, String) {
    if cancelled() { return (false, "cancelled") }
    let finished = DispatchSemaphore(value: 0)
    guard let session = FFmpegKit.execute(withArgumentsAsync: arguments, withCompleteCallback: { _ in finished.signal() }) else {
        return (false, "FFmpeg session could not start")
    }
    while finished.wait(timeout: .now() + 0.2) == .timedOut {
        if cancelled() {
            session.cancel()
            _ = finished.wait(timeout: .now() + 5)
            return (false, "cancelled")
        }
    }
    if cancelled() { return (false, "cancelled") }
    return (ReturnCode.isSuccess(session.getReturnCode()), session.getOutput() ?? "")
}

/// Owns one operation's directory access through finalization.
final class CoreDirectoryScope {
    private let lock = NSLock()
    private var release: (() -> Void)?

    init(_ release: @escaping () -> Void) { self.release = release }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        let action = release
        release = nil
        action?()
    }

    deinit { close() }
}

/// Native boundary to the Rust backend; each process holds one stateful instance.
protocol CoreBackend {
    var implementation: String { get }
    func prepareApplicationArguments(method: String, arguments: Any?) throws -> Any?
    func invokeApplication(method: String, arguments: Any?) throws -> Any?
    func completeAuthCallback(state: String, code: String, sessionGrant: Bool, onResolved: (String) -> Void) throws
    func openDownloadProgress() throws -> CoreDownloadProgress
    func cancelActiveDownloads() throws -> String
    func downloadByStrategy(requestJson: String) throws -> String
    func runPostProcessing(inputJson: String, metadataJson: String) throws -> String
    func buildFilename(template: String, metadataJson: String) throws -> String
    func sanitizeFilename(filename: String) -> String
    func fileMetadataImplementation(path: String) -> String
    func readFileMetadata(path: String, hint: String) throws -> String
    func checkHiResAuthenticity(path: String, optionsJson: String) throws -> String
    func editFileMetadata(path: String, metadataJson: String) throws -> String
    func reEnrichFile(requestJson: String) throws -> String
    func rewriteSplitArtistTags(path: String, artist: String, albumArtist: String) throws -> String
    func extractCoverToFile(audioPath: String, outputPath: String) throws
    func writeM4aFreeformTags(path: String, metadataJson: String) throws -> String
    func ensureAc4Config(path: String, reference: String) throws -> String
    func writeAc4Metadata(path: String, metadataJson: String, coverPath: String) throws -> String
    func setLibraryCoverCacheDirectory(path: String) throws
    func scanLibraryFolderToNdjsonFile(folder: String, output: String) throws -> Int
    func scanLibraryFolderIncremental(folder: String, existing: String) throws -> String
    func getLibraryScanProgress() throws -> String
    func cancelLibraryScan() throws
    func pauseLibraryScan() throws
    func resumeLibraryScan() throws
    func parseCueSheet(path: String, audioDirectory: String) throws -> String
    func openDownloadDirectory(path: String) throws -> CoreDirectoryScope
    func createTemporaryMediaFile(prefix: String, suffix: String) throws -> URL
    func downloadCoverToFileSized(url: String, outputPath: String, maxDimension: Int64) throws
    func releaseIdleResources() throws
    func releaseMemoryUnderPressure() throws
}

final class RustCoreBackend: CoreBackend {
    static let shared = RustCoreBackend()
    let implementation = "rust"
    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("rust-core-pilot", isDirectory: true)
    private let ownerLock = NSLock()
    private var manager: ExtensionManager?
    private var repository: ExtensionRepository?
    private var requests: CancellationRegistry?
    private let dataJobs = CancellationRegistry(domain: .extensionRequest)
    private let dataJobLock = NSLock()
    private var activeDataJobs: [String: Int] = [:]
    private var identity: [String]?
    private var loggingEnabled = false
    private var allowPrivateNetwork = false
    private var allowHttpFallback = false
    private var fallbackProviders: [String]?
    private var directoryScopes: [String: CoreDirectoryScope] = [:]
    private var libraryCoverScope: CoreDirectoryScope?

    private init() {}

    private func withFFmpegCommands(_ current: ExtensionManager, block: () throws -> String) throws -> String {
        let commands = try current.environment().ffmpegCommands()
        let execution = CoreFFmpegExecution(wait: { timeout in
            try JSONDecoder().decode([CoreFFmpegCommand].self, from: Data(commands.waitPending(timeoutMs: timeout).utf8))
        }, active: { id in
            try !commands.getCommand(commandId: id).isEmpty
        }, complete: { id, success, output, error in
            _ = try commands.complete(commandId: id, success: success, output: output, error: error)
        })
        return try execution.run(block: block)
    }

    func downloadByStrategy(requestJson: String) throws -> String {
        let current = try owner()
        return try withFFmpegCommands(current) { try current.downloadByStrategy(requestJson: requestJson) }
    }

    func runPostProcessing(inputJson: String, metadataJson: String) throws -> String {
        let current = try owner()
        return try withFFmpegCommands(current) {
            try current.runPostProcessing(inputJson: inputJson, metadataJson: metadataJson, timeoutMs: 120_000)
        }
    }

    private func owner() throws -> ExtensionManager {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        guard let manager = manager else { throw failure("Rust backend is not initialized") }
        return manager
    }

    private func managerSnapshot() -> ExtensionManager? {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        return manager
    }

    private func requestRegistryLocked() -> CancellationRegistry {
        if let requests = requests { return requests }
        let created = CancellationRegistry(domain: .extensionRequest)
        requests = created
        return created
    }

    private func acquireRequest(_ id: String) throws -> (ExtensionManager, RequestLease) {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        guard let manager = manager else { throw failure("Rust backend is not initialized") }
        return (manager, try requestRegistryLocked().acquire(id: id))
    }

    func prepareApplicationArguments(method: String, arguments: Any?) throws -> Any? {
        guard method == "runNativeDataJob" else { return arguments }
        guard var args = arguments as? [String: Any], let id = args["request_id"] as? String,
              !id.isEmpty else { throw failure("Missing native data job ID") }
        // Only acquire the cancellation lease here. JSON, file I/O and native
        // processing remain on the background queue. This preserves queued
        // cancellation without retaining sentinels for already-finished jobs.
        dataJobLock.lock()
        defer { dataJobLock.unlock() }
        let lease = try dataJobs.acquire(id: id)
        activeDataJobs[id, default: 0] += 1
        args["_native_data_job_lease"] = lease
        return args
    }

    private func finishDataJob(_ id: String, _ lease: RequestLease) {
        dataJobLock.lock()
        defer { dataJobLock.unlock() }
        lease.release()
        let remaining = (activeDataJobs[id] ?? 1) - 1
        activeDataJobs[id] = remaining > 0 ? remaining : nil
    }

    private func cancelDataJob(_ id: String) throws {
        dataJobLock.lock()
        defer { dataJobLock.unlock() }
        if activeDataJobs[id] != nil { try dataJobs.cancel(id: id) }
    }

    private func runDataJob(_ args: [String: Any]) throws -> String {
        guard let id = args["request_id"] as? String,
              let lease = args["_native_data_job_lease"] as? RequestLease else {
            throw failure("Missing native data job lease")
        }
        defer { finishDataJob(id, lease) }
        guard let raw = args["request_json"] as? String,
              var request = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw failure("Missing native data job request")
        }
        let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
        if request["operation"] as? String == "library_scan_incremental" {
            guard let folder = request["folder_path"] as? String else { throw failure("Missing library folder") }
            return try withLibraryDirectories([folder]) { current in
                let staged = root.appendingPathComponent("files", isDirectory: true)
                    .appendingPathComponent("library_snapshot_\(UUID().uuidString).tsv")
                defer { try? FileManager.default.removeItem(at: staged) }
                if let snapshot = request["snapshot_path"] as? String, !snapshot.isEmpty {
                    try FileManager.default.copyItem(atPath: snapshot, toPath: staged.path)
                    request["snapshot_path"] = staged.path
                }
                request["folder_path"] = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
                let encoded = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
                return try current.runNativeDataJob(requestJson: encoded, bytes: bytes, lease: lease)
            }
        }
        return try MornyeBackend.runNativeDataJob(requestJson: raw, bytes: bytes, lease: lease)
    }

    private func repositoryOwner() throws -> ExtensionRepository {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        guard let repository = repository else { throw failure("Extension repository is not initialized") }
        return repository
    }

    private func initializeRepository(_ cachePath: String) throws {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        guard let manager = manager else { throw failure("Rust backend is not initialized") }
        if repository != nil { return }
        guard cachePath.hasPrefix("/") else { throw failure("Repository cache directory must be absolute") }
        let cache = URL(fileURLWithPath: cachePath).resolvingSymlinksInPath().standardizedFileURL.path
        repository = try ExtensionRepository(manager: manager, cacheDirectory: cache)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "RustCoreBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func directoryAliases(_ value: String, sources: String, data: String) throws -> [String] {
        guard value.hasPrefix("/") else { throw failure("Output directories must be absolute") }
        let url = URL(fileURLWithPath: value)
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != "/", ![sources, data].contains(where: {
            path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
        }) else { throw failure("Output directory overlaps extension storage") }
        let original = url.standardizedFileURL.path
        return path == original ? [path] : [path, original]
    }

    private func openDownloadDirectoryLocked(path: String) throws -> CoreDirectoryScope {
        guard let manager = manager, let storage = identity else { throw failure("Rust backend is not initialized") }
        let paths = try directoryAliases(path, sources: storage[0], data: storage[1])
        let scope = try manager.environment().grantDownloadDirectories(directories: paths)
        return CoreDirectoryScope { scope.release() }
    }

    func openDownloadDirectory(path: String) throws -> CoreDirectoryScope {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        return try openDownloadDirectoryLocked(path: path)
    }

    private func withLibraryDirectories<T>(_ paths: [String], block: (ExtensionManager) throws -> T) throws -> T {
        let (current, scope): (ExtensionManager, CoreDirectoryScope) = try {
            ownerLock.lock()
            defer { ownerLock.unlock() }
            guard let manager = manager, let storage = identity else { throw failure("Rust backend is not initialized") }
            let aliases = try paths.flatMap { try directoryAliases($0, sources: storage[0], data: storage[1]) }
            let grant = try manager.environment().grantDownloadDirectories(directories: Array(Set(aliases)))
            return (manager, CoreDirectoryScope { grant.release() })
        }()
        defer { scope.close() }
        // Progress and cancellation must remain available while the scan runs.
        return try block(current)
    }

    private func withMediaFiles<T>(_ paths: [String], block: (ExtensionManager) throws -> T) throws -> T {
        let directories = try paths.filter { !$0.isEmpty }.map { path -> String in
            guard path.hasPrefix("/") else { throw failure("Media paths must be absolute") }
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return try withLibraryDirectories(Array(Set(directories)), block: block)
    }

    func setLibraryCoverCacheDirectory(path: String) throws {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        guard let manager = manager else { throw failure("Rust backend is not initialized") }
        guard path.isEmpty || path.hasPrefix("/") else { throw failure("Library cover directory must be absolute") }
        let directory = path.isEmpty ? nil : URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        if let directory = directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let next = try directory.map { try openDownloadDirectoryLocked(path: $0.path) }
        do { try manager.setLibraryCoverCacheDirectory(directory: directory?.path ?? "") }
        catch { next?.close(); throw error }
        libraryCoverScope?.close()
        libraryCoverScope = next
    }

    func scanLibraryFolderToNdjsonFile(folder: String, output: String) throws -> Int {
        guard output.hasPrefix("/"), URL(fileURLWithPath: output).pathExtension.lowercased() == "ndjson" else {
            throw failure("Library scan output must be an absolute NDJSON path")
        }
        return try withLibraryDirectories([folder]) { current in
            // Application support also contains extension storage. Stage inside
            // the existing private root instead of granting that whole directory.
            let staged = root.appendingPathComponent("files", isDirectory: true)
                .appendingPathComponent("library_scan_\(UUID().uuidString).ndjson")
            defer { try? FileManager.default.removeItem(at: staged) }
            let count = try current.scanLibraryFolderToNdjsonFile(
                folder: URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path,
                output: staged.resolvingSymlinksInPath().path, lease: nil)
            guard rename(staged.path, output) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return Int(count)
        }
    }

    func scanLibraryFolderIncremental(folder: String, existing: String) throws -> String {
        try withLibraryDirectories([folder]) {
            try $0.scanLibraryFolderIncremental(folder: URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path,
                existingJson: existing, lease: nil)
        }
    }

    func getLibraryScanProgress() throws -> String {
        let current = managerSnapshot()
        return try current?.getLibraryScanProgress() ?? "{}"
    }

    func cancelLibraryScan() throws {
        let current = managerSnapshot()
        try current?.cancelLibraryScan()
    }

    func pauseLibraryScan() throws {
        let current = managerSnapshot()
        try current?.pauseLibraryScan()
    }

    func resumeLibraryScan() throws {
        let current = managerSnapshot()
        try current?.resumeLibraryScan()
    }

    func parseCueSheet(path: String, audioDirectory: String) throws -> String {
        let cue = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let audio = audioDirectory.isEmpty ? cue.deletingLastPathComponent() : URL(fileURLWithPath: audioDirectory).resolvingSymlinksInPath().standardizedFileURL
        return try withLibraryDirectories([cue.deletingLastPathComponent().path, audio.path]) {
            try $0.parseCueFileJson(path: cue.path, audioDirectory: audio.path, lease: nil)
        }
    }

    func createTemporaryMediaFile(prefix: String, suffix: String) throws -> URL {
        _ = try owner()
        let file = root.appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
        try Data().write(to: file, options: .withoutOverwriting)
        return file
    }

    func downloadCoverToFileSized(url: String, outputPath: String, maxDimension: Int64) throws {
        try owner().downloadCoverToFileSized(url: url,
            outputPath: URL(fileURLWithPath: outputPath).resolvingSymlinksInPath().standardizedFileURL.path,
            maxDimension: maxDimension, lease: nil)
    }

    func releaseIdleResources() throws {
        try owner().releaseMemory(underPressure: false)
    }

    func releaseMemoryUnderPressure() throws {
        try owner().releaseMemory(underPressure: true)
    }

    private func initializeOwner(_ arguments: [String: Any]) throws {
        guard let sourcePath = arguments["extensions_dir"] as? String,
              let dataPath = arguments["data_dir"] as? String,
              let key = arguments["master_key"] as? String else {
            throw failure("Extension storage arguments are required")
        }
        guard sourcePath.hasPrefix("/"), dataPath.hasPrefix("/") else {
            throw failure("Extension storage directories must be absolute")
        }
        let sources = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL.path
        let data = URL(fileURLWithPath: dataPath).resolvingSymlinksInPath().standardizedFileURL.path
        let keyHash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let requested = [sources, data, keyHash]
        ownerLock.lock()
        defer { ownerLock.unlock() }
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        guard arguments["allowed_directories"] == nil || arguments["allowed_directories"] is [String] else {
            throw failure("Invalid output directories")
        }
        var allowedDirectories = [files.resolvingSymlinksInPath().path, files.standardizedFileURL.path]
        for value in arguments["allowed_directories"] as? [String] ?? [] {
            for alias in try directoryAliases(value, sources: sources, data: data) where !allowedDirectories.contains(alias) {
                allowedDirectories.append(alias)
            }
        }
        if manager != nil {
            guard identity == requested else { throw failure("Rust backend is already initialized with different storage") }
            try manager!.environment().setAllowedDownloadDirectories(directories: allowedDirectories)
            return
        }
        let created = try ExtensionManager.withLyricsSettings(
            sourceDirectory: sources,
            dataDirectory: data,
            masterKey: key,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            timeoutMs: 30000,
            providersJson: arguments["lyrics_providers_json"] as? String ?? "[]",
            optionsJson: arguments["lyrics_options_json"] as? String ?? "{}"
        )
        do {
            let environment = created.environment()
            try environment.setAllowedDownloadDirectories(directories: allowedDirectories)
            try environment.setAllowPrivateNetwork(allow: allowPrivateNetwork)
            try environment.setNetworkCompatibilityOptions(allowHttp: allowHttpFallback, insecureTls: false)
            try environment.logBuffer().setEnabled(enabled: loggingEnabled)
            try created.setFallbackProviders(ids: fallbackProviders)
        } catch {
            created.shutdown()
            throw error
        }
        identity = requested
        manager = created
    }

    private func shutdownOwner() {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        requests?.shutdown()
        requests = nil
        repository?.shutdown()
        repository = nil
        manager?.shutdown()
        manager = nil
        directoryScopes.values.forEach { $0.close() }
        directoryScopes.removeAll()
        libraryCoverScope?.close()
        libraryCoverScope = nil
        identity = nil
    }

    func fileMetadataImplementation(path: String) -> String { "rust" }

    func readFileMetadata(path: String, hint: String) throws -> String {
        try MornyeBackend.readFileMetadata(path: path, hint: hint, lease: nil)
    }

    func checkHiResAuthenticity(path: String, optionsJson: String) throws -> String {
        try MornyeBackend.checkHiresAuthenticity(path: path, optionsJson: optionsJson, lease: nil)
    }

    func editFileMetadata(path: String, metadataJson: String) throws -> String {
        let fields = try JSONSerialization.jsonObject(with: Data(metadataJson.utf8), options: [.fragmentsAllowed]) as? [String: Any]
        return try withMediaFiles([path, fields?["cover_path"] as? String ?? ""]) {
            try $0.editFileMetadata(path: mediaPath(path), metadataJson: metadataJson, lease: nil)
        }
    }

    private func mediaPath(_ path: String) -> String {
        path.isEmpty ? "" : URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func reEnrichFile(requestJson: String) throws -> String {
        guard var request = try JSONSerialization.jsonObject(with: Data(requestJson.utf8)) as? [String: Any] else {
            throw failure("Re-enrich request must be an object")
        }
        if request["preview_only"] as? Bool != true,
           let path = request["file_path"] as? String, path.hasPrefix("/") {
            request["file_path"] = mediaPath(path)
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        let resolved = String(decoding: data, as: UTF8.self)
        if request["preview_only"] as? Bool != true, let path = request["file_path"] as? String, !path.isEmpty {
            return try withMediaFiles([path]) { try $0.reenrichFile(requestJson: resolved, lease: nil) }
        }
        return try owner().reenrichFile(requestJson: resolved, lease: nil)
    }

    func rewriteSplitArtistTags(path: String, artist: String, albumArtist: String) throws -> String {
        try withMediaFiles([path]) {
            try $0.rewriteSplitArtistTags(path: mediaPath(path), artist: artist, albumArtist: albumArtist, lease: nil)
        }
    }

    func extractCoverToFile(audioPath: String, outputPath: String) throws {
        try withMediaFiles([audioPath, outputPath]) {
            try $0.extractCoverToFile(audioPath: mediaPath(audioPath), outputPath: mediaPath(outputPath), lease: nil)
        }
    }

    func writeM4aFreeformTags(path: String, metadataJson: String) throws -> String {
        try withMediaFiles([path]) {
            try $0.writeM4aFreeformTags(path: mediaPath(path), metadataJson: metadataJson, lease: nil)
        }
    }

    func ensureAc4Config(path: String, reference: String) throws -> String {
        try owner().ensureAc4Config(path: mediaPath(path), reference: mediaPath(reference), lease: nil)
    }

    func writeAc4Metadata(path: String, metadataJson: String, coverPath: String) throws -> String {
        try owner().writeAc4Metadata(path: mediaPath(path), metadataJson: metadataJson, coverPath: mediaPath(coverPath), lease: nil)
    }

    func completeAuthCallback(state: String, code: String, sessionGrant: Bool, onResolved: (String) -> Void) throws {
        let current = try owner()
        let environment = current.environment()
        let id = try (sessionGrant ? environment.resolveCallbackState(state: state) : environment.consumeCallbackState(state: state))
        onResolved(id)
        if sessionGrant {
            try completeSessionGrant(current, id: id, grant: code)
        } else {
            try environment.setAuthCode(extensionId: id, code: code)
            _ = try current.invokeAction(extensionId: id, action: "completeSpotifyLogin")
        }
    }

    func openDownloadProgress() throws -> CoreDownloadProgress {
        let subscription = try owner().environment().downloadState().subscribeProgress()
        return CoreDownloadProgress(
            wait: { try subscription.waitDelta(since: $0, timeoutMs: $1) },
            close: { subscription.stop() }
        )
    }

    func cancelActiveDownloads() throws -> String {
        let ids = try owner().environment().downloadState().cancelActiveDownloads()
        return String(decoding: try JSONSerialization.data(withJSONObject: ids), as: UTF8.self)
    }

    private func completeSessionGrant(_ current: ExtensionManager, id: String, grant: String) throws {
        try current.environment().setSessionGrant(extensionId: id, grant: grant)
        let response = try current.invokeAction(extensionId: id, action: "completeGrant")
        try requireSuccessfulExtensionAction(extensionId: id, actionName: "completeGrant", response: response)
    }

    func invokeApplication(method: String, arguments: Any?) throws -> Any? {
        let args = arguments as? [String: Any] ?? [:]
        func string(_ key: String, _ fallback: String = "") -> String { args[key] as? String ?? fallback }
        func ids(_ raw: String) throws -> [String] {
            guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else {
                throw failure("Expected an array of extension IDs")
            }
            return value
        }
        switch method {
        case "runNativeDataJob": return try runDataJob(args)
        case "cancelNativeDataJob":
            try cancelDataJob(string("request_id"))
            return nil
        case "cancelExtensionRequest":
            ownerLock.lock()
            defer { ownerLock.unlock() }
            try requestRegistryLocked().cancel(id: string("request_id"))
            return nil
        case "customSearchWithExtension", "getExtensionHomeFeed", "getExtensionRelatedTracks":
            let (current, lease) = try acquireRequest(string("request_id"))
            defer { lease.release() }
            if method == "customSearchWithExtension" {
                return try current.customSearchJson(extensionId: string("extension_id"), query: string("query"), optionsJson: string("options"), lease: lease)
            }
            if method == "getExtensionRelatedTracks" {
                return try current.getExtensionRelatedTracksJson(extensionId: string("extension_id"), seedsJson: string("seeds"), optionsJson: string("options"), lease: lease)
            }
            return try current.getExtensionHomeFeedJson(extensionId: string("extension_id"), lease: lease)
        case "initExtensionSystem": try initializeOwner(args); return nil
        case "setDownloadDirectory":
            ownerLock.lock()
            defer { ownerLock.unlock() }
            guard let manager = manager, let storage = identity else { throw failure("Rust backend is not initialized") }
            let files = root.appendingPathComponent("files", isDirectory: true)
            var paths = [files.resolvingSymlinksInPath().path, files.standardizedFileURL.path]
            let path = string("path")
            if !path.isEmpty { paths += try directoryAliases(path, sources: storage[0], data: storage[1]) }
            try manager.environment().setAllowedDownloadDirectories(directories: paths)
            return nil
        case "acquireDownloadDirectory":
            ownerLock.lock()
            defer { ownerLock.unlock() }
            let scope = try openDownloadDirectoryLocked(path: string("path"))
            let token = UUID().uuidString
            directoryScopes[token] = scope
            return token
        case "releaseDownloadDirectory":
            ownerLock.lock()
            let scope = directoryScopes.removeValue(forKey: string("token"))
            ownerLock.unlock()
            scope?.close()
            return nil
        case "initExtensionRepo": try initializeRepository(string("cache_dir")); return nil
        case "getRepoRegistryUrl": return try repositoryOwner().registryUrl()
        case "setRepoRegistryUrl": try repositoryOwner().setRegistryUrl(url: string("registry_url")); return nil
        case "clearRepoRegistryUrl": try repositoryOwner().clearRegistryUrl(); return nil
        case "getRepoExtensions": return try repositoryOwner().extensions(forceRefresh: args["force_refresh"] as? Bool ?? false)
        case "downloadRepoExtension": return try repositoryOwner().download(extensionId: string("extension_id"), destinationDirectory: string("dest_dir"))
        case "cleanupExtensions": shutdownOwner(); return nil
        case "buildFilename": return try buildFilename(template: string("template"), metadataJson: string("metadata", "{}"))
        case "sanitizeFilename": return sanitizeFilename(filename: string("filename"))
        case "readFileMetadata": return try readFileMetadata(path: string("file_path"), hint: string("display_name"))
        case "editFileMetadata": return try editFileMetadata(path: string("file_path"), metadataJson: string("metadata_json", "{}"))
        case "getLogsSince":
            ownerLock.lock()
            defer { ownerLock.unlock() }
            return try manager?.environment().logBuffer().since(index: (args["index"] as? NSNumber)?.int64Value ?? 0) ?? "{\"logs\":[],\"next_index\":0}"
        case "clearLogs":
            ownerLock.lock()
            defer { ownerLock.unlock() }
            try manager?.environment().logBuffer().clear()
            return nil
        case "setLoggingEnabled", "setAllowPrivateNetwork", "setDownloadFallbackExtensionIds", "setLyricsProviders", "setLyricsFetchOptions", "setNetworkCompatibilityOptions":
            ownerLock.lock()
            defer { ownerLock.unlock() }
            switch method {
            case "setLoggingEnabled":
                let enabled = args["enabled"] as? Bool ?? false
                try manager?.environment().logBuffer().setEnabled(enabled: enabled)
                loggingEnabled = enabled
            case "setAllowPrivateNetwork":
                let allowed = args["allowed"] as? Bool ?? false
                try manager?.environment().setAllowPrivateNetwork(allow: allowed)
                allowPrivateNetwork = allowed
            case "setNetworkCompatibilityOptions":
                let allowed = args["allow_http"] as? Bool ?? false
                let insecureTLS = args["insecure_tls"] as? Bool ?? false
                try manager?.environment().setNetworkCompatibilityOptions(allowHttp: allowed, insecureTls: insecureTLS)
                allowHttpFallback = allowed
            case "setDownloadFallbackExtensionIds":
                let raw = string("extension_ids").trimmingCharacters(in: .whitespacesAndNewlines)
                let value = raw.isEmpty || raw == "null" ? nil : try ids(raw)
                try manager?.setFallbackProviders(ids: value)
                fallbackProviders = value
            case "setLyricsProviders":
                let raw = string("providers_json", "[]")
                if let manager = manager { try manager.setLyricsProvidersJson(providersJson: raw) }
                else { _ = try ids(raw) }
                return "{\"success\":true}"
            case "setLyricsFetchOptions":
                let raw = string("options_json", "{}")
                if let manager = manager { try manager.setLyricsFetchOptionsJson(optionsJson: raw) }
                else { _ = try JSONSerialization.jsonObject(with: Data(raw.utf8)) }
                return "{\"success\":true}"
            default: break
            }
            return nil
        default: break
        }
        let current = try owner()
        switch method {
        case "loadExtensionsFromDir":
            let path = URL(fileURLWithPath: string("dir_path")).resolvingSymlinksInPath().standardizedFileURL.path
            ownerLock.lock()
            let matches = identity?.first == path
            ownerLock.unlock()
            guard matches else { throw failure("Extension source directory does not match the initialized owner") }
            return try current.loadAll()
        case "loadExtensionFromPath": return try current.install(packagePath: string("file_path"))
        case "upgradeExtension": return try current.upgrade(packagePath: string("file_path"))
        case "checkExtensionUpgrade": return try current.checkUpgrade(packagePath: string("file_path"))
        case "getInstalledExtensions": return try current.installed()
        case "setExtensionEnabled": try current.setEnabled(extensionId: string("extension_id"), enabled: args["enabled"] as? Bool ?? false); return nil
        case "removeExtension": try current.remove(extensionId: string("extension_id")); return nil
        case "getExtensionSettings": return try current.environment().settings(extensionId: string("extension_id"))
        case "setExtensionSettings": try current.updateSettings(extensionId: string("extension_id"), settingsJson: string("settings", "{}")); return nil
        case "invokeExtensionAction":
            if args["arguments_json"] != nil {
                // Transient form input bypasses persistent extension settings.
                return try current.call(extensionId: string("extension_id"), method: string("action"), argumentsJson: string("arguments_json", "[]"), lease: nil, timeoutMs: 120000)
            }
            return try current.invokeAction(extensionId: string("extension_id"), action: string("action"))
        case "checkExtensionHealth": return try current.checkExtensionHealthJson(extensionId: string("extension_id"))
        case "searchTracksWithMetadataProviders":
            return try current.searchMetadataProviders(query: string("query"), limit: (args["limit"] as? NSNumber)?.int64Value ?? 20, includeExtensions: args["include_extensions"] as? Bool ?? true, itemId: "", timeoutMs: 30000)
        case "searchTracksWithMetadataProvider":
            return try current.searchMetadataProvider(extensionId: string("extension_id"), query: string("query"), limit: (args["limit"] as? NSNumber)?.int64Value ?? 20, timeoutMs: 30000)
        case "getProviderMetadata":
            return try current.getProviderMetadataJson(providerId: string("provider_id"), resourceType: string("resource_type"), resourceId: string("resource_id"), lease: nil)
        case "findCollectionAcrossExtensions":
            return try current.findCollectionAcrossExtensionsJson(requestJson: arguments as? String ?? "{}", lease: nil)
        case "handleURLWithExtension": return try current.handleUrlJson(url: string("url"))
        case "findURLHandler": return try current.findUrlHandler(url: string("url")) ?? ""
        case "searchDeezerByISRC": return try current.searchDeezerByIsrcForItemId(isrc: string("isrc"), itemId: string("item_id"), lease: nil)
        case "getDeezerExtendedMetadata": return try current.getDeezerExtendedMetadata(trackId: string("track_id"), lease: nil)
        case "convertSpotifyToDeezer": return try current.convertSpotifyToDeezer(resourceType: string("resource_type"), spotifyId: string("spotify_id"), lease: nil)
        case "getTrackPlatformLinks": return try current.getTrackPlatformLinksJson(spotifyId: string("spotify_id"), isrc: string("isrc"), lease: nil)
        case "fetchMusicBrainzTags":
            let genre = (try? current.fetchMusicBrainzGenreByIsrc(isrc: string("isrc"), lease: nil)) ?? ""
            let albumArtist = (try? current.fetchMusicBrainzAlbumArtistByIsrc(isrc: string("isrc"), albumName: string("album_name"), lease: nil)) ?? ""
            return String(decoding: try JSONSerialization.data(withJSONObject: ["genre": genre, "album_artist": albumArtist]), as: UTF8.self)
        case "getTrackCacheSize": return Int(try current.getTrackCacheSize())
        case "readAudioMetadata":
            let path = string("file_path")
            return try withMediaFiles([path]) {
                try $0.readAudioMetadata(path: mediaPath(path), hint: "", cacheKey: "", lease: nil)
            }
        case "clearTrackCache": try current.clearTrackIdCache(); return nil
        case "setMetadataLanguage": try current.setMetadataLanguage(tag: string("tag")); return nil
        case "downloadByStrategy":
            guard let request = arguments as? String else {
                throw NSError(domain: "CoreBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download request must be a JSON string"])
            }
            return try withFFmpegCommands(current) {
                return try current.downloadByStrategy(requestJson: request)
            }
        case "getAllDownloadProgress": return try current.environment().downloadState().allProgress()
        case "cleanupConnections": try current.environment().cleanupConnections(); return nil
        case "clearItemProgress": try current.environment().downloadState().clearItemProgress(itemId: string("item_id")); return nil
        case "cancelDownload": try current.environment().downloadState().cancelDownload(itemId: string("item_id")); return nil
        case "resetDownloadCancel": try current.environment().downloadState().resetDownloadCancel(itemId: string("item_id")); return nil
        case "resetDownloadCancels", "cancelDownloads":
            guard let itemIds = args["item_ids"] as? [String] else {
                throw failure("Expected item_ids string list")
            }
            if method == "cancelDownloads" {
                try current.environment().downloadState().cancelDownloads(itemIds: itemIds)
            } else {
                try current.environment().downloadState().resetDownloadCancels(itemIds: itemIds)
            }
            return nil
        case "getExtensionPendingAuth": return try current.getExtensionPendingAuthJson(extensionId: string("extension_id"))
        case "getLyricsFromProvider":
            let request = LyricsRequest(
                spotifyId: string("spotify_id"),
                track: string("track_name"),
                artist: string("artist_name"),
                filePath: "",
                durationMs: (args["duration_ms"] as? NSNumber)?.int64Value ?? 0
            )
            return try current.getLyricsFromProvider(provider: string("provider"), request: request, lease: nil)
        case "getEnabledLyricsProviders": return try current.getEnabledLyricsProvidersJson()
        case "completeExtensionSessionGrant":
            try completeSessionGrant(current, id: string("extension_id"), grant: string("grant"))
            return true
        case "getLyricsLRC", "getLyricsLRCWithSource", "fetchAndSaveLyrics":
            let source = string(method == "fetchAndSaveLyrics" ? "audio_file_path" : "file_path")
            let output = method == "fetchAndSaveLyrics" ? string("output_path") : ""
            return try withMediaFiles([source, output]) { manager -> Any? in
                let request = LyricsRequest(
                    spotifyId: string("spotify_id"),
                    track: string("track_name"),
                    artist: string("artist_name"),
                    filePath: mediaPath(source),
                    durationMs: (args["duration_ms"] as? NSNumber)?.int64Value ?? 0
                )
                if method == "getLyricsLRC" { return try manager.getLyricsLrc(request: request, lease: nil) }
                if method == "getLyricsLRCWithSource" { return try manager.getLyricsLrcWithSource(request: request, lease: nil) }
                try manager.fetchAndSaveLyrics(request: request, outputPath: mediaPath(output), lease: nil)
                return "{\"success\":true}"
            }
        case "runPostProcessingV2":
            return try withFFmpegCommands(current) {
                try current.runPostProcessing(inputJson: string("input"), metadataJson: string("metadata"), timeoutMs: 120_000)
            }
        case "embedLyricsToFile":
            let path = string("file_path")
            return try withMediaFiles([path]) {
                try $0.embedLyricsToFile(path: mediaPath(path), lyrics: string("lyrics"), lease: nil)
            }
        case "setProviderPriority", "setMetadataProviderPriority":
            try current.setProviderPriority(kind: method == "setProviderPriority" ? "download" : "metadata", ids: ids(string("priority", "[]")))
            return nil
        case "getProviderPriority", "getMetadataProviderPriority":
            let priorities = try JSONSerialization.jsonObject(with: Data(current.providerPriorities().utf8)) as! [String: Any]
            let value = priorities[method == "getProviderPriority" ? "download" : "metadata"] as? [String] ?? []
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        default: throw failure("Rust application method is not connected yet: \(method)")
        }
    }

    func buildFilename(template: String, metadataJson: String) throws -> String {
        try MornyeBackend.buildFilename(template: template, metadataJson: metadataJson)
    }

    func sanitizeFilename(filename: String) -> String {
        MornyeBackend.sanitizeFilename(filename: filename)
    }
}

func requireSuccessfulExtensionAction(extensionId: String, actionName: String, response: String?) throws {
    let text = response ?? ""
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "Mornye",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Extension \(actionName) for \(extensionId) returned invalid JSON: \(String(text.prefix(240)))"]
        )
    }
    if (obj["success"] as? Bool) == true { return }
    let error =
        (obj["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
        (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
        String(text.prefix(240))
    throw NSError(
        domain: "Mornye",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Extension \(actionName) failed for \(extensionId): \(error)"]
    )
}

func createCoreBackend() -> CoreBackend {
    return RustCoreBackend.shared
}
