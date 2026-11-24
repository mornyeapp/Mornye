import Flutter
import MornyeBackend

/// Carries the `link*` calls and events of the phone's own Mornye Link
/// server (`LinkBridge`), used while "Share with other phones" is on, on the
/// channels Android's plugin uses. Dart decides when the server runs and
/// advertises it through Bonjour, so no multicast entitlement is needed.
final class LinkHostPlugin: NSObject, FlutterStreamHandler {
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel
    // Concurrent, so a slow catalog load or server start does not hold back
    // the replies other phones are waiting for.
    private let queue = DispatchQueue(
        label: "com.zarz.mornye.link",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var bridge: LinkBridge?
    private let lock = NSLock()
    private var polling = false
    private var stopped = false
    private var sink: FlutterEventSink?

    init(messenger: FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "com.zarz.mornye/link", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "com.zarz.mornye/link/events", binaryMessenger: messenger)
        super.init()
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        events.setStreamHandler(self)
    }

    private func ensureBridge() -> LinkBridge {
        lock.lock()
        defer { lock.unlock() }
        if let existing = bridge { return existing }
        let created = LinkBridge()
        bridge = created
        if !polling && !stopped && sink != nil {
            polling = true
            Thread.detachNewThread { [weak self] in self?.poll(created) }
        }
        return created
    }

    /// The method is the `link*` name; the arguments are its JSON text.
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? String ?? "{}"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let reply = try self.ensureBridge().call(method: call.method, argsJson: arguments)
                DispatchQueue.main.async { result(reply) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "LINK_HOST", message: Self.message(error), details: nil))
                }
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if case let LinkBridgeError.Failed(message) = error { return message }
        return error.localizedDescription
    }

    /// Each event is the JSON text `{"method","arguments"}`.
    private func poll(_ bridge: LinkBridge) {
        while true {
            lock.lock()
            let shouldStop = stopped || sink == nil
            if shouldStop { polling = false }
            lock.unlock()
            if shouldStop { return }
            guard let text = bridge.nextEvent(timeoutMs: 1_000) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.sink?(text)
            }
        }
    }

    func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock()
        sink = eventSink
        let existing = bridge
        let shouldStart = existing != nil && !polling && !stopped
        if shouldStart { polling = true }
        lock.unlock()
        if shouldStart, let existing {
            Thread.detachNewThread { [weak self] in self?.poll(existing) }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock()
        sink = nil
        lock.unlock()
        return nil
    }

    deinit {
        lock.lock()
        stopped = true
        sink = nil
        lock.unlock()
        methods.setMethodCallHandler(nil)
        events.setStreamHandler(nil)
    }
}
