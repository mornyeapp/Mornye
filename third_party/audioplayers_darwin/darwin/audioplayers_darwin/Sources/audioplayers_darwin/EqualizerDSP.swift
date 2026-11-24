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

  private struct Plan {
    let enabled: Bool
    let sections: [Biquad]
    let inputGain: Double
    let balance: Double
    let compressor: Bool
    let limiter: Bool
    let threshold: Double
    let compressorSlope: Double
    let attack: Double
    let release: Double
  }

  private static let maxChannels = 8
  private static let maxSections = 31
  private static let limiterCeiling = pow(10.0, -0.5 / 20.0)

  private let lock = NSLock()
  // Serializes configure() and prepare(); the render thread never takes it.
  private let controlLock = NSLock()
  private var configuration: [String: Any] = [:]
  private var configuredRate = 48000.0
  private var pendingPlan: Plan?
  // The plan the render thread last adopted, released on the control side.
  private var retiredPlan: Plan?

  // Audio-thread-owned state: never mutated by configure() directly.
  private(set) var enabled = false
  private var inputGainAlpha = min(1.0, 1.0 / (48000.0 * 0.005))
  private var limiterReleaseAlpha = min(1.0, 1.0 / (48000.0 * 0.06))
  private var rampFrames = Int(48000.0 * 0.005)
  private var sectionCount = 0
  private var filters = Array(repeating: Biquad(), count: maxChannels * maxSections)
  private var inputGain = 1.0
  private var currentInputGain = 1.0
  private var balance = 0.0
  private var compressor = false
  private var limiter = true
  private var threshold = -18.0
  private var compressorSlope = (1.0 - 1.0 / 3.0) / 20.0
  private var attack = 0.0
  private var release = 0.0
  private var reduction = 1.0
  private var limiterGain = 1.0

  func configure(_ data: [String: Any]) {
    controlLock.lock()
    defer { controlLock.unlock() }
    lock.lock()
    configuration = data
    let currentRate = configuredRate
    lock.unlock()

    // Built outside the render lock, so the render thread never waits on it.
    let next = Self.buildPlan(from: data, rate: currentRate)
    lock.lock()
    retiredPlan = nil
    pendingPlan = next
    lock.unlock()
  }

  func prepare(sampleRate: Double) {
    controlLock.lock()
    defer { controlLock.unlock() }
    lock.lock()
    configuredRate = sampleRate
    let data = configuration
    lock.unlock()

    let next = Self.buildPlan(from: data, rate: sampleRate)
    lock.lock()
    pendingPlan = nil
    retiredPlan = nil
    lock.unlock()

    inputGainAlpha = sampleRate.isFinite && sampleRate > 0 ? min(1.0, 1.0 / (sampleRate * 0.005)) : 1.0
    limiterReleaseAlpha = sampleRate.isFinite && sampleRate > 0 ? min(1.0, 1.0 / (sampleRate * 0.06)) : 1.0
    rampFrames = sampleRate.isFinite && sampleRate > 0 ? max(1, Int(sampleRate * 0.005)) : 1
    sectionCount = 0
    reduction = 1
    limiterGain = 1
    applyPlan(next, snap: true)
  }

  /// Called once per render block on the audio thread. Never waits: while the
  /// control side holds the lock, the active filters run and the plan waits.
  func beginRenderBlock() -> Bool {
    guard lock.try() else { return enabled }
    if let next = pendingPlan {
      pendingPlan = nil
      // Every publish clears this slot first, so nothing is freed here.
      retiredPlan = next
      applyPlan(next, snap: false)
    }
    lock.unlock()
    return enabled
  }

  private func applyPlan(_ plan: Plan, snap: Bool) {
    enabled = plan.enabled
    guard plan.enabled else { return }
    let nextCount = min(plan.sections.count, Self.maxSections)
    let smooth = !snap && nextCount == sectionCount
    let frames = rampFrames
    filters.withUnsafeMutableBufferPointer { buffer in
      for channel in 0..<Self.maxChannels {
        let base = channel * Self.maxSections
        for index in 0..<nextCount {
          let target = plan.sections[index]
          if smooth {
            buffer[base + index].retarget(target, frames: frames)
          } else {
            buffer[base + index] = target
          }
        }
      }
    }
    sectionCount = nextCount
    inputGain = plan.inputGain
    if snap { currentInputGain = plan.inputGain }
    balance = plan.balance
    compressor = plan.compressor
    limiter = plan.limiter
    threshold = plan.threshold
    compressorSlope = plan.compressorSlope
    attack = plan.attack
    release = plan.release
  }

  private static func number(
    _ configuration: [String: Any], _ key: String, _ fallback: Double, _ min: Double, _ max: Double
  ) -> Double {
    guard let value = configuration[key] as? NSNumber, value.doubleValue.isFinite else { return fallback }
    return Swift.min(max, Swift.max(min, value.doubleValue))
  }

  private static func buildPlan(from configuration: [String: Any], rate: Double) -> Plan {
    let disabled = Plan(
      enabled: false, sections: [], inputGain: 1.0, balance: 0.0,
      compressor: false, limiter: true, threshold: -18.0,
      compressorSlope: (1.0 - 1.0 / 3.0) / 20.0, attack: 0.0, release: 0.0)
    guard configuration["enabled"] as? Bool == true else { return disabled }
    guard let gains = configuration["gains"] as? [Double],
      let frequencies = configuration["frequencies"] as? [Double],
      (gains.count == 5 || gains.count == 10 || gains.count == 15 || gains.count == 31),
      frequencies.count == gains.count,
      gains.allSatisfy({ $0.isFinite && abs($0) <= 24 }),
      frequencies.allSatisfy({ $0.isFinite && $0 > 0 }), rate.isFinite && rate > 0
    else { return disabled }
    guard zip(frequencies, frequencies.dropFirst()).allSatisfy({ $0 < $1 }) else {
      return disabled
    }
    let step = pow(frequencies.last! / frequencies.first!, 1 / Double(gains.count - 1))
    let q = sqrt(step) / (step - 1)
    var sections = zip(frequencies, gains).map {
      Biquad.peak(frequency: $0.0, gain: $0.1, q: q, rate: rate)
    }
    // Parametric: the listener's own filters play in place of the bands.
    if let parametric = configuration["filters"] as? [[String: Any]] {
      guard parametric.count <= 20 else { return disabled }
      sections = []
      sections.reserveCapacity(parametric.count)
      for filter in parametric {
        guard let type = filter["type"] as? String,
          let frequency = (filter["frequency"] as? NSNumber)?.doubleValue,
          let gain = (filter["gain"] as? NSNumber)?.doubleValue,
          let width = (filter["q"] as? NSNumber)?.doubleValue,
          (type == "peak" || type == "lowshelf" || type == "highshelf"),
          frequency.isFinite, frequency >= 10, frequency <= 24000,
          gain.isFinite, abs(gain) <= 24, width.isFinite, width >= 0.05, width <= 40
        else { return disabled }
        sections.append(type == "peak"
          ? Biquad.peak(frequency: frequency, gain: gain, q: width, rate: rate)
          : Biquad.shelf(high: type == "highshelf", frequency: frequency, gain: gain, q: width, rate: rate))
      }
    }
    let ratio = number(configuration, "ratio", 3, 1, 20)
    return Plan(
      enabled: true,
      sections: sections,
      inputGain: pow(10, number(configuration, "inputGain", 0, -48, 12) / 20),
      balance: number(configuration, "balance", 0, -1, 1),
      compressor: configuration["compressor"] as? Bool == true,
      limiter: configuration["limiter"] as? Bool != false,
      threshold: number(configuration, "threshold", -18, -60, 0),
      compressorSlope: (1.0 - 1.0 / ratio) / 20.0,
      attack: exp(-1 / (rate * number(configuration, "attack", 10, 1, 100) / 1000)),
      release: exp(-1 / (rate * number(configuration, "release", 150, 20, 1000) / 1000)))
  }

  /// Runs on the audio thread after `beginRenderBlock()` returned true.
  func processFrame(_ frame: inout [Double], channels: Int) {
    guard enabled, channels > 0, channels <= Self.maxChannels, frame.count >= channels else { return }
    currentInputGain += (inputGain - currentInputGain) * inputGainAlpha
    let count = sectionCount
    let gainNow = currentInputGain
    let bal = balance
    var peak = 0.0
    filters.withUnsafeMutableBufferPointer { buffer in
      for channel in 0..<channels {
        var value = frame[channel].isFinite ? frame[channel] * gainNow : 0
        let base = channel * Self.maxSections
        for index in 0..<count {
          value = buffer[base + index].process(value)
        }
        if channels >= 2 {
          if channel == 0 && bal > 0 { value *= 1 - bal }
          else if channel == 1 && bal < 0 { value *= 1 + bal }
        }
        frame[channel] = value
        let mag = abs(value)
        if mag > peak { peak = mag }
      }
    }
    let needsCompressor = compressor || reduction < 0.9999999
    if needsCompressor {
      var desired = 1.0
      if compressor && peak > 1e-12 {
        let level = 20.0 * log10(peak)
        if level > threshold {
          desired = pow(10.0, (threshold - level) * compressorSlope)
        }
      }
      let speed = desired < reduction ? attack : release
      reduction = speed * reduction + (1.0 - speed) * desired
      if !compressor && reduction > 0.9999999 { reduction = 1.0 }
    }
    let needsLimiter = limiter || limiterGain < 0.9999999
    if needsLimiter {
      let scaledPeak = peak * reduction
      let wanted = (limiter && scaledPeak > Self.limiterCeiling)
        ? (Self.limiterCeiling / scaledPeak)
        : 1.0
      if wanted < limiterGain {
        limiterGain = wanted
      } else {
        limiterGain += (wanted - limiterGain) * limiterReleaseAlpha
        if !limiter && limiterGain > 0.9999999 { limiterGain = 1.0 }
      }
    }
    let postGain = reduction * limiterGain
    if postGain != 1.0 {
      for channel in 0..<channels { frame[channel] *= postGain }
    }
  }
}
