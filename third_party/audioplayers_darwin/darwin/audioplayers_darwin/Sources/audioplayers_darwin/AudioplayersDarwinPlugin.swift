import AVFoundation
import AVKit

#if os(iOS)
  import Flutter
  import UIKit
  import MediaPlayer
#else
  import FlutterMacOS
  import AVFAudio
#endif

let channelName = "xyz.luan/audioplayers"

let globalChannelName = "xyz.luan/audioplayers.global"

public class AudioplayersDarwinPlugin: NSObject, FlutterPlugin {
  var registrar: FlutterPluginRegistrar
  var binaryMessenger: FlutterBinaryMessenger
  var methods: FlutterMethodChannel
  var globalMethods: FlutterMethodChannel
  var globalEvents: GlobalAudioPlayersStreamHandler

  var globalContext = AudioContext()
  var players = [String: WrappedMediaPlayer]()

  init(
    registrar: FlutterPluginRegistrar,
    binaryMessenger: FlutterBinaryMessenger,
    methodChannel: FlutterMethodChannel,
    globalMethodChannel: FlutterMethodChannel,
    globalEventChannel: FlutterEventChannel
  ) {
    self.registrar = registrar
    self.binaryMessenger = binaryMessenger
    self.methods = methodChannel
    self.globalMethods = globalMethodChannel
    self.globalEvents = GlobalAudioPlayersStreamHandler(channel: globalEventChannel)

    do {
      try globalContext.apply()
    } catch {
      // ignore error on initialization
    }

    super.init()

    self.globalMethods.setMethodCallHandler(handleGlobalMethodCall)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // apparently there is a bug in Flutter causing some inconsistency between Flutter and FlutterMacOS
    // See: https://github.com/flutter/flutter/issues/118103
    #if os(iOS)
      let binaryMessenger = registrar.messenger()
    #else
      let binaryMessenger = registrar.messenger
    #endif

    let methods = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    let globalMethods = FlutterMethodChannel(
      name: globalChannelName, binaryMessenger: binaryMessenger)
    let globalEvents = FlutterEventChannel(
      name: globalChannelName + "/events", binaryMessenger: binaryMessenger)

    let instance = AudioplayersDarwinPlugin(
      registrar: registrar,
      binaryMessenger: binaryMessenger,
      methodChannel: methods,
      globalMethodChannel: globalMethods,
      globalEventChannel: globalEvents)
    registrar.addMethodCallDelegate(instance, channel: methods)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    Task { @MainActor [weak self] in
      guard let self = self else {
        return
      }
      await disposePlayers()
      self.globalMethods.setMethodCallHandler(nil)
      self.globalEvents.dispose()
    }
  }

  private func disposePlayers() async {
    for (_, player) in self.players {
      await player.dispose()
    }
    self.players = [:]
  }

  private func handleGlobalMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      await handleAsyncGlobalMethodCall(call: call, result: result)
    }
  }

  @MainActor
  private func handleAsyncGlobalMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult)
    async
  {
    let method = call.method

    guard let args = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "DarwinAudioError", message: "Failed to parse call.arguments from Flutter.",
          details: nil))
      return
    }

    // global handlers (no playerId)
    if method == "init" {
      await disposePlayers()
    } else if method == "setAudioContext" {
      #if os(iOS)
        do {
          guard let context = try AudioContext.parse(args: args) else {
            result(
              FlutterError(
                code: "DarwinAudioError",
                message: "Error calling setAudioContext, context could not be parsed",
                details: nil))
            return
          }
          globalContext = context

          try globalContext.apply()
        } catch let error {
          result(
            FlutterError(
              code: "DarwinAudioError", message: "Error configuring global audio session: \(error)",
              details: nil))
          return
        }
      #else
        globalEvents.onLog(message: "Setting AudioContext is not supported on this platform")
      #endif
    } else if method == "emitLog" {
      guard let message = args["message"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling emitLog, message cannot be null",
            details: nil))
        return
      }
      globalEvents.onLog(message: message)
    } else if method == "emitError" {
      guard let code = args["code"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling emitError, code cannot be null",
            details: nil))
        return
      }
      guard let message = args["message"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling emitError, message cannot be null",
            details: nil))
        return
      }
      globalEvents.onError(code: code, message: message, details: nil)
    } else {
      result(FlutterMethodNotImplemented)
      return
    }

    // default result (bypass by adding `return` to your branch)
    result(1)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      await handleAsync(call, result: result)
    }
  }

  @MainActor
  private func handleAsync(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    let method = call.method

    guard let args = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "DarwinAudioError", message: "Failed to parse call.arguments from Flutter.",
          details: nil))
      return
    }

    // player specific handlers
    guard let playerId = args["playerId"] as? String else {
      result(
        FlutterError(
          code: "DarwinAudioError", message: "Call missing mandatory parameter playerId.",
          details: nil))
      return
    }

    if method == "create" {
      self.createPlayer(playerId: playerId)
      result(1)
      return
    }

    guard let player = self.getPlayer(playerId: playerId) else {
      result(
        FlutterError(
          code: "DarwinAudioError",
          message: "Player has not yet been created or has already been disposed.", details: nil))
      return
    }

    if method == "setEqualizer" {
      guard let configuration = args["configuration"] as? [String: Any] else {
        result(FlutterError(code: "DarwinAudioError", message: "Missing equalizer configuration", details: nil))
        return
      }
      do { try await player.setEqualizer(configuration) }
      catch {
        result(FlutterError(code: "DarwinAudioError", message: "Equalizer is unavailable for this source", details: error.localizedDescription))
        return
      }
    } else if method == "setNextPlayer" {
      let nextId = args["nextPlayerId"] as? String
      player.next = nextId.flatMap { self.getPlayer(playerId: $0) }
    } else if method == "pause" {
      player.pause()
    } else if method == "resume" {
      player.resume()
    } else if method == "stop" {
      await player.stop()
    } else if method == "release" {
      await player.release()
    } else if method == "seek" {
      guard let position = args["position"] as? Int else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Null position received on seek", details: nil))
        return
      }
      let time = toCMTime(millis: position)
      await player.seek(time: time)
    } else if method == "setSourceUrl" {
      let url: String? = args["url"] as? String
      let mimeType: String? = args["mimeType"] as? String
      let isLocal: Bool = (args["isLocal"] as? Bool) ?? false

      if url == nil {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Null URL received on setSourceUrl", details: nil))
        return
      }

      do {
        try await player.setSourceUrl(
          url: url!, isLocal: isLocal,
          mimeType: mimeType
        )
      } catch is CancellationError {
        // Replacing or disposing a loading source completes its method call.
      } catch let error {
        player.eventHandler.onError(
          code: "DarwinAudioError",
          message: "Failed to set source. For troubleshooting, see "
            + "https://github.com/bluefireteam/audioplayers/blob/main/troubleshooting.md",
          details: "AVPlayerItem.Status.failed on setSourceUrl: \(error)")
      }

    } else if method == "setSourceBytes" {
      result(
        FlutterError(
          code: "DarwinAudioError", message: "setSourceBytes is not currently implemented on iOS",
          details: nil))
      return
    } else if method == "getDuration" {
      let duration = player.getDuration()
      result(duration)
      return
    } else if method == "setVolume" {
      guard let volume = args["volume"] as? Double else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling setVolume, volume cannot be null",
            details: nil))
        return
      }

      player.setVolume(volume: volume)
    } else if method == "setBalance" {
      player.eventHandler.onLog(message: "setBalance is not currently implemented on iOS")
      result(0)
      return
    } else if method == "getCurrentPosition" {
      let currentPosition = player.getCurrentPosition()
      result(currentPosition)
      return
    } else if method == "setPlaybackRate" {
      guard let playbackRate = args["playbackRate"] as? Double else {
        result(
          FlutterError(
            code: "DarwinAudioError",
            message: "Error calling setPlaybackRate, playbackRate cannot be null", details: nil))
        return
      }
      player.setPlaybackRate(playbackRate: playbackRate)
    } else if method == "setReleaseMode" {
      guard let releaseModeStr = args["releaseMode"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError",
            message: "Error calling setReleaseMode, releaseMode cannot be null", details: nil))
        return
      }
      player.releaseMode = ReleaseMode(rawValue: String(releaseModeStr.split(separator: ".")[1]))!
    } else if method == "setPlayerMode" {
      // no-op for darwin; only one player mode
    } else if method == "setAudioContext" {
      #if os(iOS)
        player.eventHandler.onLog(
          message:
            "iOS does not allow for player-specific audio contexts; `setAudioContext` will set the global audio context instead (like `global.setAudioContext`)."
        )
        do {
          guard let context = try AudioContext.parse(args: args) else {
            result(
              FlutterError(
                code: "DarwinAudioError",
                message: "Error calling setAudioContext, context could not be parsed",
                details: nil))
            return
          }
          globalContext = context

          try globalContext.apply()
        } catch let error {
          result(
            FlutterError(
              code: "DarwinAudioError", message: "Error configuring audio session: \(error)",
              details: nil))
          return
        }
      #else
        player.eventHandler.onLog(message: "Setting AudioContext is not supported on this platform")
      #endif
    } else if method == "emitLog" {
      guard let message = args["message"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling emitLog, message cannot be null",
            details: nil))
        return
      }
      player.eventHandler.onLog(message: message)
    } else if method == "emitError" {
      guard let code = args["code"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling emitError, code cannot be null",
            details: nil))
        return
      }
      guard let message = args["message"] as? String else {
        result(
          FlutterError(
            code: "DarwinAudioError", message: "Error calling emitError, message cannot be null",
            details: nil))
        return
      }
      player.eventHandler.onError(code: code, message: message, details: nil)
    } else if method == "dispose" {
      await player.dispose()
      self.players[playerId] = nil
    } else {
      result(FlutterMethodNotImplemented)
      return
    }

    // default result (bypass by adding `return` to your branch)
    result(1)
  }

  @MainActor
  func createPlayer(playerId: String) {
    let eventChannel = FlutterEventChannel(
      name: channelName + "/events/" + playerId, binaryMessenger: self.binaryMessenger)

    let eventHandler = AudioPlayersStreamHandler(channel: eventChannel)

    let newPlayer = WrappedMediaPlayer(
      reference: self,
      eventHandler: eventHandler
    )
    players[playerId] = newPlayer
  }

  func getPlayer(playerId: String) -> WrappedMediaPlayer? {
    return players[playerId]
  }

  @MainActor
  func controlAudioSession() {
    let anyIsPlaying = players.values.contains { player in
      player.isPlaying
    }

    do {
      try globalContext.activateAudioSession(active: anyIsPlaying)
    } catch let error {
      self.globalEvents.onError(
        code: "DarwinAudioError", message: "Error configuring audio session: \(error)", details: nil
      )
    }
  }
}

class AudioPlayersStreamHandler: NSObject, FlutterStreamHandler {
  var eventChannel: FlutterEventChannel
  var sink: FlutterEventSink?
  // When calling dispose, we must emit a FlutterEndOfEventStream, then wait for onCancel to be called by Flutter, in order to release the stream handler.
  // Otherwise an error is thrown, that the "cancel" method is not implemented.
  private var isDisposed = false

  init(channel: FlutterEventChannel) {
    self.eventChannel = channel
    super.init()
    eventChannel.setStreamHandler(self)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.sink = events
    // events(FlutterEndOfEventStream) // when stream is over
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.sink = nil
    return nil
  }

  private func sendEvent(_ event: Any?) {
    if let eventSink = self.sink {
      DispatchQueue.main.async {
        eventSink(event)
      }
    }
  }

  func onSeekComplete() {
    sendEvent(["event": "audio.onSeekComplete"])
  }

  func onComplete() {
    sendEvent(["event": "audio.onComplete"])
  }

  func onDuration(millis: Int) {
    sendEvent(["event": "audio.onDuration", "value": millis] as [String: Any])
  }

  func onPrepared(isPrepared: Bool) {
    sendEvent(["event": "audio.onPrepared", "value": isPrepared] as [String: Any])
  }

  func onLog(message: String) {
    sendEvent(["event": "audio.onLog", "value": message])
  }

  func onError(code: String, message: String, details: Any?) {
    sendEvent(FlutterError(code: code, message: message, details: details))
  }

  func dispose() {
    onError(
      code: "DarwinAudioError",
      message:
        "Stream was still listened to before disposing. Ensure to cancel all subscriptions before calling dispose.",
      details: nil)
    sendEvent(FlutterEndOfEventStream)
    eventChannel.setStreamHandler(nil)
  }
}

class GlobalAudioPlayersStreamHandler: NSObject, FlutterStreamHandler {
  var eventChannel: FlutterEventChannel
  var sink: FlutterEventSink?

  init(channel: FlutterEventChannel) {
    self.eventChannel = channel
    super.init()
    eventChannel.setStreamHandler(self)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.sink = nil
    return nil
  }

  private func sendEvent(_ event: Any?) {
    if let eventSink = self.sink {
      DispatchQueue.main.async {
        eventSink(event)
      }
    }
  }

  func onLog(message: String) {
    sendEvent(["event": "audio.onLog", "value": message])
  }

  func onError(code: String, message: String, details: Any?) {
    sendEvent(FlutterError(code: code, message: message, details: details))
  }

  func dispose() {
    onError(
      code: "DarwinAudioError",
      message:
        "Stream was still listened to before disposing. Ensure to cancel all subscriptions before calling dispose.",
      details: nil)
    sendEvent(FlutterEndOfEventStream)
    eventChannel.setStreamHandler(nil)
  }
}
