import AVFoundation
import Foundation

// Only Flutter's channel boundary is stubbed. A real AVPlayer plays generated
// sine files (muted) through the production wrapper and tap.
@MainActor final class AudioplayersDarwinPlugin {
  func controlAudioSession() {}
}

final class AudioPlayersStreamHandler {
  var logs: [String] = []

  func onSeekComplete() {}
  func onPrepared(isPrepared: Bool) {}
  func onLog(message: String) { logs.append(message) }
  func onDuration(millis: Int) {}
  func onComplete() {}
  func dispose() {}
}

@main struct PitchPlaybackTests {
  enum Failure: Error {
    case message(String)
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.message(message) }
  }

  static func writeSine(to url: URL, frequency: Double, seconds: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let frames = AVAudioFrameCount(44_100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
      for index in 0..<Int(frames) {
        buffer.floatChannelData![channel][index] = Float(0.4 * sin(Double(index) * 2 * .pi * frequency / 44_100))
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  /// The wrapper's current tap, read through reflection so the production
  /// type needs no test hook.
  @MainActor static func tap(_ wrapper: WrappedMediaPlayer) -> EqualizerAudioTap {
    Mirror(reflecting: wrapper).children.first { $0.label == "equalizer" }!.value as! EqualizerAudioTap
  }

  @MainActor static func tapAttached(_ wrapper: WrappedMediaPlayer) -> Bool {
    Mirror(reflecting: wrapper).children.first { $0.label == "tapAttached" }!.value as! Bool
  }

  /// Frequency of the shifter's latest output block, after the item settles.
  /// The block is only read while no rebuild is pending. A read can overlap
  /// the render thread refilling the block, so the median of several counts.
  @MainActor static func shiftedFrequency(_ wrapper: WrappedMediaPlayer) async throws -> Double {
    try await Task.sleep(nanoseconds: 1_200_000_000)
    var estimates: [Double] = []
    for _ in 0..<7 {
      let pitch = tap(wrapper).pitch
      try require(pitch.capacity > 0, "The tap never prepared the shifter")
      let samples = Array(UnsafeBufferPointer(start: pitch.block[0], count: pitch.capacity))
      var crossings = 0
      for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
      estimates.append(Double(crossings) / 2 / (Double(samples.count) / 44_100))
      try await Task.sleep(nanoseconds: 37_000_000)
    }
    return estimates.sorted()[estimates.count / 2]
  }

  @MainActor static func requireFrequency(_ wrapper: WrappedMediaPlayer, _ expected: Double, _ step: String) async throws {
    let measured = try await shiftedFrequency(wrapper)
    try require(abs(measured - expected) < expected * 0.04, "\(step): \(measured) Hz, expected \(expected)")
  }

  @MainActor static func main() async {
    do {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let first = root.appendingPathComponent("first.wav")
      let second = root.appendingPathComponent("second.wav")
      try writeSine(to: first, frequency: 440, seconds: 12)
      try writeSine(to: second, frequency: 440, seconds: 12)

      let native = AVPlayer()
      native.isMuted = true
      let events = AudioPlayersStreamHandler()
      let wrapper = WrappedMediaPlayer(
        reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)
      try await wrapper.setSourceUrl(url: first.path, isLocal: true)
      try require(native.currentItem?.audioTimePitchAlgorithm == .spectral, "New items must default to spectral")
      try require(!tapAttached(wrapper), "No tap without the equalizer or a shift")

      try await wrapper.setPitch(semitones: 12, followsRate: false)
      try require(tapAttached(wrapper), "A shift must attach the tap")
      try await Task.sleep(nanoseconds: 300_000_000)
      try require(!wrapper.isPlaying && native.rate == 0, "Setting the pitch must not start playback")
      wrapper.resume()
      try await requireFrequency(wrapper, 880, "+12 semitones")
      print("PASS: a shift set while paused attaches the tap without playing, then plays +12 semitones")

      let running = tap(wrapper)
      try await wrapper.setPitch(semitones: -12, followsRate: false)
      try await requireFrequency(wrapper, 220, "-12 semitones while playing")
      try require(tap(wrapper) === running, "Changing the shift must keep the running tap")
      print("PASS: a shift changed while playing updates the running tap")

      wrapper.setPlaybackRate(playbackRate: 1.5)
      try await requireFrequency(wrapper, 220, "Spectral at 1.5x keeps the pitch")
      try await wrapper.setPitch(semitones: -12, followsRate: true)
      try require(native.currentItem?.audioTimePitchAlgorithm == .varispeed, "followsRate must select varispeed")
      try await requireFrequency(wrapper, 330, "Varispeed at 1.5x follows the rate")
      try require(wrapper.isPlaying && native.rate == 1.5, "Switching the algorithm must keep playing")
      print("PASS: spectral keeps the pitch at 1.5x; varispeed set while playing follows the rate at once")

      wrapper.pause()
      try await wrapper.setPitch(semitones: 0, followsRate: false)
      wrapper.setPlaybackRate(playbackRate: 1.25)
      try await Task.sleep(nanoseconds: 300_000_000)
      try require(!wrapper.isPlaying && native.rate == 0, "Paused changes must not start playback")
      try require(native.currentItem?.audioTimePitchAlgorithm == .spectral, "The algorithm must apply while paused")
      print("PASS: pitch and rate changes while paused stay paused")

      wrapper.setPlaybackRate(playbackRate: 1)
      try await wrapper.setPitch(semitones: 0, followsRate: true)
      try require(native.currentItem?.audioTimePitchAlgorithm == .spectral, "At 1x the playing item keeps its algorithm")
      wrapper.setPlaybackRate(playbackRate: 2)
      try require(native.currentItem?.audioTimePitchAlgorithm == .varispeed, "A rate change must apply the algorithm")
      print("PASS: the algorithm waits for a rate that needs it")

      try await wrapper.setSourceUrl(url: second.path, isLocal: true)
      try require(native.currentItem?.audioTimePitchAlgorithm == .varispeed, "New items must use the current algorithm")
      try require(!tapAttached(wrapper), "A new source without a shift must not get a tap")
      try await wrapper.setPitch(semitones: 7, followsRate: false)
      try await wrapper.setSourceUrl(url: first.path, isLocal: true)
      try require(tapAttached(wrapper), "A new source must keep the shift")
      wrapper.setPlaybackRate(playbackRate: 1)
      wrapper.resume()
      try await requireFrequency(wrapper, 440 * pow(2, 7.0 / 12), "+7 semitones on a later source")
      print("PASS: later sources keep the algorithm and the shift")

      // Equalizer and shift share one tap.
      try await wrapper.setEqualizer([
        "enabled": true, "gains": [Double](repeating: 0, count: 10),
        "frequencies": [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000], "limiter": false,
      ])
      try await requireFrequency(wrapper, 440 * pow(2, 7.0 / 12), "Equalizer then shift")
      await wrapper.dispose()
      print("PASS: the equalizer and the shift share the tap")
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
