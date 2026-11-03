import AVFoundation
import Flutter
import MornyeBackend

/// Google Cast on iOS through the Rust sender (`CastBridge`), on the channels
/// Android's plugin uses, so the Dart player drives both the same way.
/// Methods run off the main thread; events (session snapshots and the
/// discovered device list) are pulled from Rust and forwarded as they come.
///
/// The TV streams from a server inside this app, so the app must keep
/// running while it plays: a silent, mixable loop holds the audio session
/// while a session is connected, as the background audio mode allows.
final class CastOutputPlugin: NSObject, FlutterStreamHandler {
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel
    private let queue = DispatchQueue(label: "com.zarz.mornye.cast", qos: .userInitiated)
    private let lock = NSLock()
    private var bridge: CastBridge?
    private var polling = false
    private var sink: FlutterEventSink?
    private var keepAlive: AVAudioPlayer?

    init(messenger: FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "com.zarz.mornye/cast", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "com.zarz.mornye/cast/events", binaryMessenger: messenger)
        super.init()
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        events.setStreamHandler(self)
    }

    private func service() throws -> CastBridge {
        lock.lock()
        defer { lock.unlock() }
        if let bridge { return bridge }
        let created = try CastBridge()
        bridge = created
        if !polling {
            polling = true
            Thread.detachNewThread { [weak self] in self?.poll(created) }
        }
        return created
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "show" {
            // Google's dialog is Android only; Dart draws the device list.
            result(false)
            return
        }
        let arguments = call.arguments ?? [String: Any]()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let json = try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed])
                let reply = try self.service().call(method: call.method, argsJson: String(decoding: json, as: UTF8.self))
                let value = try JSONSerialization.jsonObject(with: Data(reply.utf8), options: [.fragmentsAllowed])
                DispatchQueue.main.async { result(value is NSNull ? nil : value) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CAST_UNAVAILABLE", message: Self.message(error), details: nil))
                }
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if case let CastBridgeError.Failed(message) = error { return message }
        return error.localizedDescription
    }

    private func poll(_ bridge: CastBridge) {
        while true {
            guard let text = bridge.nextEvent(timeoutMs: 1_000) else { continue }
            guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any]
            else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if event["event"] as? String == "castStatus" {
                    self.setKeepAlive(payload["connected"] as? Bool == true)
                }
                self.sink?(payload)
            }
        }
    }

    private func setKeepAlive(_ on: Bool) {
        if !on {
            keepAlive?.stop()
            keepAlive = nil
            return
        }
        guard keepAlive == nil, let player = try? AVAudioPlayer(data: Self.silence) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        keepAlive = player
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    private static let silence: Data = {
        let samples = 8_000
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }()

    func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        sink = eventSink
        // Start the service so its first snapshot reaches the new listener.
        queue.async { [weak self] in _ = try? self?.service() }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    deinit {
        methods.setMethodCallHandler(nil)
        events.setStreamHandler(nil)
    }
}
