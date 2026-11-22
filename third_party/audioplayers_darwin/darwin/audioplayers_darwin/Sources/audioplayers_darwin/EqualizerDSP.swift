import Foundation

/// Decoded-PCM processor. The render callback never waits for the editor lock.
/// Biquad design: https://www.w3.org/TR/audio-eq-cookbook/
final class EqualizerDSP {
  struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0
    var targetB0 = 1.0, targetB1 = 0.0, targetB2 = 0.0, targetA1 = 0.0, targetA2 = 0.0
    var ramp = 0

    mutating func retarget(_ next: Biquad, frames: Int) {
      targetB0 = next.b0; targetB1 = next.b1; targetB2 = next.b2
      targetA1 = next.a1; targetA2 = next.a2
      ramp = max(1, frames)
    }

    static func peak(frequency: Double, gain: Double, q: Double, rate: Double) -> Biquad {
      let w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
      let a = pow(10, gain / 40)
      let alpha = sin(w) / (2 * q)
      let divisor = 1 + alpha / a
      return Biquad(b0: (1 + alpha * a) / divisor, b1: -2 * cos(w) / divisor,
        b2: (1 - alpha * a) / divisor, a1: -2 * cos(w) / divisor,
        a2: (1 - alpha / a) / divisor)
    }

    /// A shelf of the cookbook; `high` turns it around the frequency.
    static func shelf(high: Bool, frequency: Double, gain: Double, q: Double, rate: Double) -> Biquad {
      let w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
      let a = pow(10, gain / 40)
      let cosine = high ? -cos(w) : cos(w)
      let slope = 2 * sqrt(a) * sin(w) / (2 * q)
      let divisor = (a + 1) + (a - 1) * cosine + slope
      let sign = high ? -1.0 : 1.0
      return Biquad(b0: a * ((a + 1) - (a - 1) * cosine + slope) / divisor,
        b1: sign * 2 * a * ((a - 1) - (a + 1) * cosine) / divisor,
        b2: a * ((a + 1) - (a - 1) * cosine - slope) / divisor,
        a1: sign * -2 * ((a - 1) + (a + 1) * cosine) / divisor,
        a2: ((a + 1) + (a - 1) * cosine - slope) / divisor)
    }

    mutating func process(_ input: Double) -> Double {
      if ramp > 0 {
        let step = 1 / Double(ramp)
        b0 += (targetB0 - b0) * step; b1 += (targetB1 - b1) * step
        b2 += (targetB2 - b2) * step; a1 += (targetA1 - a1) * step
        a2 += (targetA2 - a2) * step
        ramp -= 1
      }
      let value = b0 * input + z1
      z1 = b1 * input - a1 * value + z2
      z2 = b2 * input - a2 * value
      if !value.isFinite { z1 = 0; z2 = 0; return 0 }
      return value
    }
  }

  let lock = NSLock()
  private(set) var enabled = false
  private var configuration: [String: Any] = [:]
  private var rate = 48000.0
  private var filters = Array(repeating: [Biquad](), count: 8)
  private var inputGain = 1.0
  private var currentInputGain = 1.0
  private var balance = 0.0
  private var compressor = false
  private var limiter = true
  private var threshold = -18.0
  private var ratio = 3.0
  private var attack = 0.0
  private var release = 0.0
  private var reduction = 1.0
  private var limiterGain = 1.0

  func configure(_ data: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    configuration = data
    update()
  }

  func prepare(sampleRate: Double) {
    lock.lock()
    defer { lock.unlock() }
    rate = sampleRate
    filters = Array(repeating: [], count: 8)
    reduction = 1; limiterGain = 1
    update()
    currentInputGain = inputGain
  }

  private func number(_ key: String, _ fallback: Double, _ min: Double, _ max: Double) -> Double {
    guard let value = configuration[key] as? NSNumber, value.doubleValue.isFinite else { return fallback }
    return Swift.min(max, Swift.max(min, value.doubleValue))
  }

  private func update() {
    enabled = configuration["enabled"] as? Bool == true
    guard let gains = configuration["gains"] as? [Double],
      let frequencies = configuration["frequencies"] as? [Double],
      [5, 10, 15, 31].contains(gains.count), frequencies.count == gains.count,
      gains.allSatisfy({ $0.isFinite && abs($0) <= 24 }),
      frequencies.allSatisfy({ $0.isFinite && $0 > 0 }), rate.isFinite && rate > 0
    else { enabled = false; return }
    guard zip(frequencies, frequencies.dropFirst()).allSatisfy({ $0 < $1 }) else {
      enabled = false; return
    }
    let step = pow(frequencies.last! / frequencies.first!, 1 / Double(gains.count - 1))
    let q = sqrt(step) / (step - 1)
    var sections = zip(frequencies, gains).map {
      Biquad.peak(frequency: $0.0, gain: $0.1, q: q, rate: rate)
    }
    // Parametric: the listener's own filters play in place of the bands.
    if let parametric = configuration["filters"] as? [[String: Any]] {
      guard parametric.count <= 20 else { enabled = false; return }
      sections = []
      for filter in parametric {
        guard let type = filter["type"] as? String,
          let frequency = (filter["frequency"] as? NSNumber)?.doubleValue,
          let gain = (filter["gain"] as? NSNumber)?.doubleValue,
          let width = (filter["q"] as? NSNumber)?.doubleValue,
          ["peak", "lowshelf", "highshelf"].contains(type),
          frequency.isFinite, frequency >= 10, frequency <= 24000,
          gain.isFinite, abs(gain) <= 24, width.isFinite, width >= 0.05, width <= 40
        else { enabled = false; return }
        sections.append(type == "peak"
          ? Biquad.peak(frequency: frequency, gain: gain, q: width, rate: rate)
          : Biquad.shelf(high: type == "highshelf", frequency: frequency, gain: gain, q: width, rate: rate))
      }
    }
    for channel in filters.indices {
      let old = filters[channel]
      filters[channel] = sections.enumerated().map { index, next in
        guard old.count == sections.count else { return next }
        var filter = old[index]
        filter.retarget(next, frames: Int(rate * 0.005))
        return filter
      }
    }
    inputGain = pow(10, number("inputGain", 0, -48, 12) / 20)
    balance = number("balance", 0, -1, 1)
    compressor = configuration["compressor"] as? Bool == true
    limiter = configuration["limiter"] as? Bool != false
    threshold = number("threshold", -18, -60, 0)
    ratio = number("ratio", 3, 1, 20)
    attack = exp(-1 / (rate * number("attack", 10, 1, 100) / 1000))
    release = exp(-1 / (rate * number("release", 150, 20, 1000) / 1000))
  }

  /// Caller holds the lock for one block and supplies an existing frame buffer.
  func processFrame(_ frame: inout [Double], channels: Int) {
    guard enabled, channels > 0, channels <= filters.count, frame.count >= channels else { return }
    currentInputGain += (inputGain - currentInputGain) * min(1, 1 / (rate * 0.005))
    var peak = 0.0
    for channel in 0..<channels {
      var value = frame[channel].isFinite ? frame[channel] * currentInputGain : 0
      for index in filters[channel].indices { value = filters[channel][index].process(value) }
      if channels >= 2 && channel == 0 && balance > 0 { value *= 1 - balance }
      if channels >= 2 && channel == 1 && balance < 0 { value *= 1 + balance }
      frame[channel] = value
      peak = max(peak, abs(value))
    }
    let level = 20 * log10(max(peak, 1e-12))
    let desired = compressor && level > threshold ? pow(10, (threshold - level) * (1 - 1 / ratio) / 20) : 1
    let speed = desired < reduction ? attack : release
    reduction = speed * reduction + (1 - speed) * desired
    let ceiling = pow(10, -0.5 / 20)
    let wanted = limiter ? min(1, ceiling / max(peak * reduction, 1e-12)) : 1
    if wanted < limiterGain { limiterGain = wanted }
    else { limiterGain += (wanted - limiterGain) * min(1, 1 / (rate * 0.06)) }
    for channel in 0..<channels { frame[channel] *= reduction * limiterGain }
  }
}
