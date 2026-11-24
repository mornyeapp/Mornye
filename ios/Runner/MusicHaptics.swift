import CoreHaptics
import Flutter

/// Renders one music pulse at a time; Dart owns timing against playback.
final class MusicHapticsBridge {
    private let channel: FlutterMethodChannel
    private let queue = DispatchQueue(label: "com.zarz.mornye.haptics", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var isEngineRunning = false
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/haptics", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "pulse" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let arguments = call.arguments as? [String: Any]
            let intensity = (arguments?["intensity"] as? Double) ?? 0
            let sharpness = (arguments?["sharpness"] as? Double) ?? 0
            let clampedIntensity = Float(min(max(intensity, 0), 1))
            let clampedSharpness = Float(min(max(sharpness, 0), 1))
            self?.queue.async { [weak self] in
                self?.pulse(intensity: clampedIntensity, sharpness: clampedSharpness)
            }
            result(nil)
        }
    }

    private func pulse(intensity: Float, sharpness: Float, retry: Bool = true) {
        guard supported, intensity > 0 else { return }
        do {
            let engine = try self.engine ?? start()
            if !isEngineRunning {
                // Auto-shutdown leaves the engine reusable but stopped. Restart
                // only when stopped rather than on every beat.
                try engine.start()
                isEngineRunning = true
            }
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0
            )
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            if retry && isEngineRunning {
                // The engine may have idled out before its stop was seen: restart once.
                isEngineRunning = false
                pulse(intensity: intensity, sharpness: sharpness, retry: false)
                return
            }
            // A stopped or interrupted engine is recreated on the next beat.
            engine = nil
            isEngineRunning = false
        }
    }

    private func start() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        // Music already owns the audio session; never route audio here.
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { [weak self, weak engine] reason in
            self?.queue.async {
                guard let self, self.engine === engine else { return }
                self.isEngineRunning = false
                if reason != .idleTimeout {
                    self.engine = nil
                }
            }
        }
        engine.resetHandler = { [weak self, weak engine] in
            self?.queue.async {
                guard let self, self.engine === engine else { return }
                self.isEngineRunning = false
                self.engine = nil
            }
        }
        try engine.start()
        self.engine = engine
        self.isEngineRunning = true
        return engine
    }
}
