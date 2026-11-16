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
    private let bridge = LinkBridge()
    private let lock = NSLock()
    private var polling = false
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

    /// The method is the `link*` name; the arguments are its JSON text.
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? String ?? "{}"
        queue.async { [bridge] in
            do {
                let reply = try bridge.call(method: call.method, argsJson: arguments)
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
    private func poll() {
        while true {
            guard let text = bridge.nextEvent(timeoutMs: 1_000) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.sink?(text)
            }
        }
    }

    func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        sink = eventSink
        lock.lock()
        defer { lock.unlock() }
        if !polling {
            polling = true
            Thread.detachNewThread { [weak self] in self?.poll() }
        }
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
