import AVKit
import Flutter
import MediaPlayer
import UIKit

/// iOS owns the lock-screen layout, transport glyphs and AirPlay button.
/// Supply its favorite command with the same state/action as the Mornye player.
final class PlaybackNotificationBridge {
    private let channel: FlutterMethodChannel
    private var target: Any?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/playback_notification", binaryMessenger: messenger)
        let command = MPRemoteCommandCenter.shared().likeCommand
        target = command.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.channel.invokeMethod("favorite", arguments: nil)
            return .success
        }
        command.isEnabled = false
        channel.setMethodCallHandler { call, result in
            guard call.method == "update", let values = call.arguments as? [String: Any] else {
                result(FlutterMethodNotImplemented)
                return
            }
            command.isEnabled = values["enabled"] as? Bool ?? false
            command.isActive = values["loved"] as? Bool ?? false
            command.localizedTitle = values["label"] as? String ?? "Favorite"
            result(nil)
        }
    }

    deinit {
        if let target { MPRemoteCommandCenter.shared().likeCommand.removeTarget(target) }
        channel.setMethodCallHandler(nil)
    }
}

/// Read-only route and stream facts for the player's audio information sheet.
final class AudioRouteInfoBridge {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/audio_route", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "read" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let path = (call.arguments as? [String: Any])?["path"] as? String
            Task {
                var info = Self.route()
                if let path { info["stream"] = await Self.stream(path) }
                let payload = info
                await MainActor.run { result(payload) }
            }
        }
    }

    private static func route() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        var info: [String: Any] = [
            "platform": "ios",
            "mixerSampleRate": Int(session.sampleRate.rounded()),
            "ioBufferMs": session.ioBufferDuration * 1000,
            "outputLatencyMs": session.outputLatency * 1000,
            "outputChannels": session.outputNumberOfChannels,
            "maxOutputChannels": session.maximumOutputNumberOfChannels,
            "volume": Double(session.outputVolume),
        ]
        if let output = session.currentRoute.outputs.first {
            info["device"] = [
                "type": portType(output.portType),
                "name": output.portName,
                "channelCounts": [output.channels?.count ?? 0].filter { $0 > 0 },
                "spatial": output.isSpatialAudioEnabled,
            ] as [String: Any]
        }
        return info
    }

    private static func portType(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "earpiece"
        case .headphones: return "wired_headphones"
        case .bluetoothA2DP, .bluetoothHFP: return "bluetooth"
        case .bluetoothLE: return "bluetooth_le"
        case .airPlay: return "airplay"
        case .usbAudio: return "usb"
        case .HDMI: return "hdmi"
        case .lineOut: return "line"
        case .carAudio: return "car"
        default: return "other"
        }
    }

    private static func stream(_ path: String) async -> [String: Any]? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path)
        guard let url, url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let formats = try? await track.load(.formatDescriptions),
              let description = formats.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        let id = basic.mFormatID
        let fourCC = String(
            bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xff) },
            encoding: .ascii
        )?.trimmingCharacters(in: .whitespaces) ?? ""
        return [
            "mime": fourCC,
            "sampleRate": Int(basic.mSampleRate.rounded()),
            "channels": Int(basic.mChannelsPerFrame),
            "pcmBits": Int(basic.mBitsPerChannel),
            "bitrate": Int(rate.rounded()),
        ].filter { ($0.value as? Int).map { $0 > 0 } ?? !(($0.value as? String)?.isEmpty ?? true) }
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}

/// `show` opens the system route picker (AirPlay, Bluetooth, this iPhone)
/// from the app's own Audio output sheet, the counterpart of Android's
/// output switcher on the same channel. It answers once the picker closes,
/// false when it could not open.
final class AudioOutputBridge: NSObject, AVRoutePickerViewDelegate {
    private let channel: FlutterMethodChannel
    private let window: () -> UIWindow?
    private var picker: AVRoutePickerView?
    private var pending: FlutterResult?

    init(messenger: FlutterBinaryMessenger, window: @escaping () -> UIWindow?) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/audio_output", binaryMessenger: messenger)
        self.window = window
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "show", let self else {
                result(FlutterMethodNotImplemented)
                return
            }
            self.show(result)
        }
    }

    private func show(_ result: @escaping FlutterResult) {
        guard pending == nil, let window = window() else {
            result(false)
            return
        }
        // The picker has no public way to open; its button does, so it sits
        // invisibly in the window while the system sheet is up.
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.prioritizesVideoDevices = false
        picker.alpha = 0.01
        picker.delegate = self
        window.addSubview(picker)
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            picker.removeFromSuperview()
            result(false)
            return
        }
        self.picker = picker
        pending = result
        button.sendActions(for: .touchUpInside)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        picker?.removeFromSuperview()
        picker = nil
        pending?(true)
        pending = nil
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}
