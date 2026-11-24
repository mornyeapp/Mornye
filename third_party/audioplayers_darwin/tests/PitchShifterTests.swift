import Foundation

@main struct PitchShifterTests {
  /// Irregular sizes like the tap's, up to the prepared capacity.
  static let blocks = [4096, 512, 1024, 300, 4096, 77, 2000, 470, 3333]

  static func sine(_ frequency: Double, rate: Double, amplitude: Double = 0.5) -> (Int) -> Float {
    { Float(amplitude * sin(Double($0) * 2 * .pi * frequency / rate)) }
  }

  /// Feeds `seconds` of `signal` through `shifter` in irregular blocks.
  /// `change` may adjust the shifter before the block starting at a frame.
  static func run(
    _ shifter: PitchShifter, rate: Double, channels: Int, seconds: Double,
    signal: (Int) -> Float, change: (Int) -> Void = { _ in }
  ) -> (input: [Float], output: [[Float]]) {
    let total = Int(rate * seconds)
    var input: [Float] = []
    var output = [[Float]](repeating: [], count: channels)
    var position = 0
    var index = 0
    while position < total {
      change(position)
      let count = min(blocks[index % blocks.count], total - position, shifter.capacity)
      index += 1
      let active = shifter.begin()
      for frame in 0..<count {
        let value = signal(position + frame)
        input.append(value)
        for channel in 0..<channels { shifter.block[channel][frame] = value }
      }
      if active { shifter.process(frames: count) }
      for channel in 0..<channels {
        output[channel].append(contentsOf: UnsafeBufferPointer(start: shifter.block[channel], count: count))
      }
      position += count
    }
    assert(input.count == total, "Every block must be accounted for")
    assert(output.allSatisfy { $0.count == total }, "Output frame count must equal the input count")
    return (input, output)
  }

  static func frequency(_ samples: ArraySlice<Float>, rate: Double) -> Double {
    var crossings = 0
    var previous = samples.first ?? 0
    for sample in samples.dropFirst() {
      if (previous < 0) != (sample < 0) { crossings += 1 }
      previous = sample
    }
    return Double(crossings) / 2 / (Double(samples.count) / rate)
  }

  static func rms(_ samples: ArraySlice<Float>) -> Double {
    sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
  }

  static func checkShift(semitones: Double, rate: Double, channels: Int) {
    let shifter = PitchShifter()
    assert(shifter.prepare(sampleRate: rate, channels: channels, maxFrames: 4096))
    shifter.setSemitones(semitones)
    let (input, output) = run(shifter, rate: rate, channels: channels, seconds: 3, signal: sine(440, rate: rate))
    let expected = 440 * pow(2, semitones / 12)
    let steady = Int(rate)..<Int(rate * 2.5)
    for channel in output {
      assert(channel.allSatisfy { $0.isFinite && abs($0) < 1 }, "Output must stay finite and in range")
      let measured = frequency(channel[steady], rate: rate)
      assert(abs(measured - expected) < expected * 0.01, "\(semitones) semitones: \(measured) Hz, expected \(expected)")
      let ratio = rms(channel[steady]) / rms(input[steady])
      assert(ratio > 0.75 && ratio < 1.25, "Energy must stay close to the input: \(ratio)")
      // After the latency, no window may drop out.
      var start = Int(shifter.latency * rate) + 2048
      while start + 512 < channel.count {
        assert(rms(channel[start..<start + 512]) > 0.2, "Shifted output dropped out at frame \(start)")
        start += 512
      }
    }
  }

  static func main() {
    for rate in [44100.0, 48000.0, 96000.0] {
      checkShift(semitones: 12, rate: rate, channels: 2)
      checkShift(semitones: -12, rate: rate, channels: 2)
    }
    checkShift(semitones: 7, rate: 48000, channels: 1)
    checkShift(semitones: -3.5, rate: 44100, channels: 6)

    // 0 semitones bypasses the unit: bit-exact and without delay.
    let rate = 48000.0
    let shifter = PitchShifter()
    assert(shifter.prepare(sampleRate: rate, channels: 2, maxFrames: 4096))
    assert(shifter.latency > 0 && shifter.latency < 0.25, "Latency must be reported: \(shifter.latency)")
    let music: (Int) -> Float = {
      let time = Double($0) / rate
      return Float(0.3 * sin(time * 2 * .pi * 440) + 0.2 * sin(time * 2 * .pi * 1234.5)
        + 0.1 * sin(time * 2 * .pi * 97))
    }
    var (input, output) = run(shifter, rate: rate, channels: 2, seconds: 1, signal: music)
    assert(output.allSatisfy { $0 == input }, "0 semitones must pass audio through unchanged")

    // A shift started mid-stream fades the dry audio out, fills the latency
    // with silence, then returns to 0 without skipping: the unit stays in
    // the path, exactly delayed by its latency, until the next reset.
    let startAt = Int(rate * 0.5)
    let backAt = Int(rate * 1.5)
    (input, output) = run(shifter, rate: rate, channels: 2, seconds: 3, signal: music) { position in
      if position >= startAt { shifter.setSemitones(position >= backAt ? 0 : 5) }
    }
    let latency = Int((shifter.latency * rate).rounded())
    let tail = Int(rate * 2)..<Int(rate * 3)
    for channel in output {
      for index in tail { assert(channel[index] == input[index - latency], "Unit at 0 must only delay") }
      var largest: Float = 0
      for index in 1..<channel.count { largest = max(largest, abs(channel[index] - channel[index - 1])) }
      assert(largest < 0.2, "Starting the shift must not click: step \(largest)")
    }
    assert(shifter.begin(), "The unit stays in the path at 0 until a reset")
    shifter.reset()
    assert(!shifter.begin(), "A reset at 0 bypasses the unit again")
    (input, output) = run(shifter, rate: rate, channels: 2, seconds: 0.5, signal: music)
    assert(output.allSatisfy { $0 == input }, "Bypass after a reset must be unchanged")

    // Formats the unit cannot take leave the audio unchanged.
    let wide = PitchShifter()
    assert(!wide.prepare(sampleRate: rate, channels: 9, maxFrames: 4096))
    wide.setSemitones(12)
    assert(!wide.begin(), "An unprepared shifter must not process")
    print("PASS: +12/-12 at 44.1/48/96 kHz, mono and 5.1, energy, no dropouts, bypass, mid-stream start, return to 0, reset, unsupported formats (latency \(latency) frames at 48 kHz)")
  }
}
