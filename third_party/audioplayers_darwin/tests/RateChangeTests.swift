import AVFoundation
import Foundation
import QuartzCore

// Only Flutter's channel boundary is stubbed. A real AVPlayer plays a
// generated sine file (muted) through the production wrapper while its rate
// moves between 1, 1.02 and 0.98, as Mornye Link Play together nudges it.
@MainActor final class AudioplayersDarwinPlugin {
  func controlAudioSession() {}
}

final class AudioPlayersStreamHandler {
  func onSeekComplete() {}
  func onPrepared(isPrepared: Bool) {}
  func onLog(message: String) {}
  func onDuration(millis: Int) {}
  func onComplete() {}
  func dispose() {}
}

@main struct RateChangeTests {
  enum Failure: Error {
    case message(String)
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.message(message) }
  }

  static func writeSine(to url: URL, seconds: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let frames = AVAudioFrameCount(44_100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
      for index in 0..<Int(frames) {
        buffer.floatChannelData![channel][index] = Float(0.4 * sin(Double(index) * 2 * .pi * 440 / 44_100))
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  /// Plays [rates] for [segment] seconds each and returns how far each change
  /// moved the item's clock against the rates asked for, in milliseconds
  /// (negative: the song fell behind).
  @MainActor static func shifts(
    _ wrapper: WrappedMediaPlayer, _ native: AVPlayer, rates: [Double], segment: Double = 1.2
  ) async throws -> [Double] {
    var changes: [(host: Double, rate: Double)] = []
    var samples: [(host: Double, position: Double)] = []
    let start = CACurrentMediaTime()
    changes.append((start, Double(native.rate)))
    var next = 0
    while CACurrentMediaTime() - start < segment * Double(rates.count + 1) {
      if next < rates.count && CACurrentMediaTime() - start >= segment * Double(next + 1) {
        wrapper.setPlaybackRate(playbackRate: rates[next])
        try require(native.rate == Float(rates[next]), "The player must take rate \(rates[next])")
        changes.append((CACurrentMediaTime(), rates[next]))
        next += 1
      }
      samples.append((CACurrentMediaTime(), CMTimeGetSeconds(native.currentItem!.currentTime())))
      try await Task.sleep(nanoseconds: 2_000_000)
    }
    // Where the clock would be from the first sample at the rates asked for.
    func expected(_ host: Double) -> Double {
      var result = 0.0
      for (index, change) in changes.enumerated() {
        let from = max(change.host, samples[0].host)
        let until = min(host, index + 1 < changes.count ? changes[index + 1].host : .infinity)
        if until > from { result += (until - from) * change.rate }
      }
      return result
    }
    var settled: [Double] = []
    for (index, change) in changes.enumerated() {
      let until = index + 1 < changes.count ? changes[index + 1].host : samples.last!.host
      let offsets = samples.filter { $0.host >= change.host + 0.5 && $0.host < until }
        .map { ($0.position - samples[0].position - expected($0.host)) * 1000 }.sorted()
      try require(!offsets.isEmpty, "No samples after change \(index)")
      settled.append(offsets[offsets.count / 2])
    }
    return zip(settled.dropFirst(), settled).map { $0 - $1 }
  }

  @MainActor static func main() async {
    do {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let song = root.appendingPathComponent("song.wav")
      try writeSine(to: song, seconds: 40)
      let rates = [1.02, 1, 0.98, 1, 1.02, 1]

      let native = AVPlayer()
      native.isMuted = true
      let wrapper = WrappedMediaPlayer(
        reference: AudioplayersDarwinPlugin(), eventHandler: AudioPlayersStreamHandler(), player: native)
      try await wrapper.setSourceUrl(url: song.path, isLocal: true)
      wrapper.resume()
      try await Task.sleep(nanoseconds: 1_000_000_000)
      let plain = try await shifts(wrapper, native, rates: rates)
      print("Clock moved per change (ms): " + plain.map { String(format: "%.1f", $0) }.joined(separator: " "))
      // A plain rate change lost 21 to 26 ms each time; the pinned one moves
      // 3.4 ms on a change away from 1 and none back to it.
      try require(plain.allSatisfy { abs($0) <= 8 }, "A rate change must not move the clock: \(plain)")
      print("PASS: rate changes keep the item's clock continuous")

      wrapper.pause()
      wrapper.setPlaybackRate(playbackRate: 1.02)
      try await Task.sleep(nanoseconds: 200_000_000)
      try require(!wrapper.isPlaying && native.rate == 0, "A paused player must stay paused")
      wrapper.setPlaybackRate(playbackRate: 1)
      print("PASS: a rate change while paused stays paused")

      // With the tap the clock moves by tens of milliseconds either way, so
      // only the rates are checked; the shifts are printed for reference.
      try await wrapper.setEqualizer([
        "enabled": true, "gains": [Double](repeating: 0, count: 10),
        "frequencies": [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000], "limiter": false,
      ])
      wrapper.resume()
      try await Task.sleep(nanoseconds: 1_000_000_000)
      let tapped = try await shifts(wrapper, native, rates: rates)
      print("With the tap, clock moved per change (ms): " + tapped.map { String(format: "%.1f", $0) }.joined(separator: " "))
      print("PASS: an item with the tap takes every rate")
      await wrapper.dispose()
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
