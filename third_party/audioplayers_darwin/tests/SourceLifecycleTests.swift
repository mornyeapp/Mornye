import AVFoundation
import Foundation

// Only Flutter's channel boundary is stubbed. Holding an item outside a real
// AVPlayer keeps its status unknown so cancellation is deterministic.
@MainActor final class AudioplayersDarwinPlugin {
  func controlAudioSession() {}
}

final class AudioPlayersStreamHandler {
  var preparedCount = 0
  var completedCount = 0

  func onSeekComplete() {}
  func onPrepared(isPrepared: Bool) { if isPrepared { preparedCount += 1 } }
  func onLog(message: String) {}
  func onDuration(millis: Int) {}
  func onComplete() { completedCount += 1 }
  func dispose() {}
}

final class DeferredPlayer: AVPlayer {
  private var item: AVPlayerItem?

  override var currentItem: AVPlayerItem? { item }

  override func replaceCurrentItem(with item: AVPlayerItem?) {
    self.item = item
  }
}

@main struct SourceLifecycleTests {
  enum Failure: Error {
    case message(String)
  }

  @MainActor final class Preparation {
    var result: Result<Void, Error>?

    init(_ wrapper: WrappedMediaPlayer, url: String) {
      Task { @MainActor in
        do {
          try await wrapper.setSourceUrl(url: url, isLocal: true)
          result = .success(())
        } catch {
          result = .failure(error)
        }
      }
    }
  }

  @MainActor static func waitFor(_ message: String, until condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw Failure.message(message)
  }

  @MainActor static func requireCancelled(_ preparation: Preparation) async throws {
    try await waitFor("A cancelled source never completed") { preparation.result != nil }
    guard case .failure = preparation.result else {
      throw Failure.message("A cancelled source was reported as prepared")
    }
  }

  static func writeSilence(to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  @MainActor static func testNativePreparationAndStaleCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.wav")
    let secondURL = root.appendingPathComponent("second.wav")
    try writeSilence(to: firstURL)
    try writeSilence(to: secondURL)

    let native = AVPlayer()
    native.isMuted = true
    let events = AudioPlayersStreamHandler()
    let wrapper = WrappedMediaPlayer(
      reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)
    let first = Preparation(wrapper, url: firstURL.path)
    try await waitFor("Native source did not finish preparation") { first.result != nil }
    guard case .success = first.result, events.preparedCount == 1,
      let oldItem = native.currentItem
    else { throw Failure.message("Native source did not prepare successfully") }

    wrapper.resume()
    // Delivery queues a MainActor task. Replace the item before that task runs.
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
    try await wrapper.setSourceUrl(url: secondURL.path, isLocal: true)
    try await Task.sleep(nanoseconds: 50_000_000)
    guard events.completedCount == 0, native.currentItem != nil else {
      throw Failure.message("The old item's queued completion affected its replacement")
    }
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: native.currentItem)
    try await waitFor("The current item's completion was not delivered and released") {
      events.completedCount == 1 && native.currentItem == nil
    }

    let failed = Preparation(wrapper, url: root.appendingPathComponent("missing.wav").path)
    try await waitFor("Missing native source did not fail preparation") { failed.result != nil }
    guard case .failure(let error) = failed.result, !(error is CancellationError),
      native.currentItem == nil, events.preparedCount == 2
    else {
      throw Failure.message("Missing native source was not reported as a preparation failure")
    }
    await wrapper.dispose()
  }

  @MainActor static func main() async {
    do {
      let native = DeferredPlayer()
      let events = AudioPlayersStreamHandler()
      let wrapper = WrappedMediaPlayer(
        reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)

      let first = Preparation(wrapper, url: "/first.wav")
      try await waitFor("First source was not installed") { native.currentItem != nil }
      let firstItem = native.currentItem
      let replacement = Preparation(wrapper, url: "/second.wav")
      try await waitFor("Replacement source was not installed") {
        native.currentItem != nil && native.currentItem !== firstItem
      }
      let replacementItem = native.currentItem
      try await requireCancelled(first)
      guard native.currentItem === replacementItem else {
        throw Failure.message("Finishing the old source changed its replacement")
      }

      await wrapper.dispose()
      try await requireCancelled(replacement)
      guard native.currentItem == nil, events.preparedCount == 0 else {
        throw Failure.message("Disposal left a source or emitted a prepared event")
      }
      print("PASS: replacing and disposing loading sources completes cancelled preparation")
      try await testNativePreparationAndStaleCompletion()
      print("PASS: native preparation succeeds or fails once, and ignores old completion events")
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
