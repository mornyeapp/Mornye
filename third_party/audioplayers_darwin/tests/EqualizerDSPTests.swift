import Foundation

@main struct EqualizerDSPTests {
  static let frequencies = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

  static func engine(_ extra: [String: Any] = [:]) -> EqualizerDSP {
    let engine = EqualizerDSP()
    var data: [String: Any] = ["enabled": true, "gains": [Double](repeating: 0, count: 10),
      "frequencies": frequencies, "limiter": false, "inputGain": 0.0]
    data.merge(extra) { _, value in value }
    engine.configure(data)
    engine.prepare(sampleRate: 48000)
    return engine
  }

  static func rms(_ engine: EqualizerDSP, amplitude: Double, frequency: Double = 1000, seconds: Int = 1) -> Double {
    var frame = [Double](repeating: 0, count: 2)
    var sum = 0.0
    for index in 0..<(48000 * seconds) {
      let value = amplitude * sin(Double(index) * 2 * .pi * frequency / 48000)
      frame[0] = value; frame[1] = value
      engine.processFrame(&frame, channels: 2)
      if index >= 24000 { sum += frame[0] * frame[0] }
      assert(frame.allSatisfy { $0.isFinite })
    }
    return sqrt(sum / Double(48000 * seconds - 24000))
  }

  static func main() {
    let flat = rms(engine(), amplitude: 0.1)
    assert(abs(flat - 0.1 / sqrt(2)) < 1e-8, "Flat EQ must preserve samples")
    var gains = [Double](repeating: 0, count: 10)
    gains[5] = 6
    let boosted = rms(engine(["gains": gains]), amplitude: 0.1)
    assert(abs(20 * log10(boosted / flat) - 6) < 0.02, "1kHz band must produce 6dB")
    let preamp = rms(engine(["inputGain": -6.0]), amplitude: 0.1)
    assert(abs(20 * log10(preamp / flat) + 6) < 0.02)
    let compressed = rms(engine(["compressor": true, "threshold": -30.0, "ratio": 10.0]), amplitude: 0.8, seconds: 2)
    assert(compressed < 0.15, "Compressor must attenuate sustained loud audio")
    let limiter = engine(["inputGain": 12.0, "limiter": true])
    var frame = [Double](repeating: 1, count: 2)
    limiter.processFrame(&frame, channels: 2)
    assert(frame.allSatisfy { abs($0) <= pow(10, -0.5 / 20) + 1e-12 })
    let pan = engine(["balance": 1.0])
    frame = [0.25, 0.25]
    pan.processFrame(&frame, channels: 2)
    assert(frame[0] == 0 && abs(frame[1] - 0.25) < 1e-12)
    var mono = [0.25]
    pan.processFrame(&mono, channels: 1)
    assert(abs(mono[0] - 0.25) < 1e-12, "Pan must not silence a mono source")
    let bypass = engine(["enabled": false, "inputGain": 12.0])
    frame = [0.123, -0.456]
    bypass.processFrame(&frame, channels: 2)
    assert(frame == [0.123, -0.456], "Disabled processing must be transparent")
    for rate in [44100.0, 96000.0, 192000.0] {
      let stress = engine()
      let centers = (0..<31).map { 20 * pow(1000, Double($0) / 30) }
      stress.configure(["enabled": true, "frequencies": centers,
        "gains": [Double](repeating: 15, count: 31), "limiter": true])
      stress.prepare(sampleRate: rate)
      for sample in 0..<20000 {
        frame = [sin(Double(sample) * 0.1), cos(Double(sample) * 0.23)]
        stress.processFrame(&frame, channels: 2)
        assert(frame.allSatisfy { $0.isFinite && abs($0) <= pow(10, -0.5 / 20) + 1e-9 })
      }
    }
    // Parametric filters play in place of the bands, which are sent flat.
    func level(_ filters: [[String: Any]], at frequency: Double) -> Double {
      20 * log10(rms(engine(["filters": filters]), amplitude: 0.1, frequency: frequency) / flat)
    }
    let peak: [String: Any] = ["type": "peak", "frequency": 1000.0, "gain": 6.0, "q": 1.4]
    assert(abs(level([peak], at: 1000) - 6) < 0.02 && abs(level([peak], at: 60)) < 0.05)
    let low: [String: Any] = ["type": "lowshelf", "frequency": 200.0, "gain": -5.0, "q": 0.707]
    assert(abs(level([low], at: 30) + 5) < 0.05 && abs(level([low], at: 200) + 2.5) < 0.05)
    assert(abs(level([low], at: 5000)) < 0.02)
    let high: [String: Any] = ["type": "highshelf", "frequency": 4000.0, "gain": 4.0, "q": 0.707]
    assert(abs(level([high], at: 100)) < 0.02 && abs(level([high], at: 4000) - 2) < 0.05)
    assert(abs(level([high], at: 18000) - 4) < 0.1)
    assert(abs(level([], at: 1000)) < 1e-6, "No filters must play flat, not the bands")
    let invalid = engine(["filters": [["type": "notch", "frequency": 1000.0, "gain": 3.0, "q": 1.0]]])
    assert(!invalid.enabled, "An unknown filter must turn the equalizer off")
    print("PASS: flat, gain, preamp, compressor, limiter, pan, mono, bypass, 31-band multi-rate stability and parametric filters")
  }
}
