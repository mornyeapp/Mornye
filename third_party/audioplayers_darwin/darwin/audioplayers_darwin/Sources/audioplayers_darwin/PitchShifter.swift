import AVFoundation
import AudioToolbox

/// Shifts the pitch of decoded PCM by semitones while keeping its duration,
/// with Apple's AUNewTimePitch at rate 1. The unit pulls its input from a
/// FIFO that `process` fills, so every call returns exactly the frames it was
/// given, delayed by the unit's latency (silence fills that time once, after
/// the shift starts or a reset).
///
/// `prepare` allocates; `process` and `reset` run on the render thread and
/// neither allocate nor wait for a lock. `setSemitones` may run on any thread.
final class PitchShifter {
  static let maxChannels = 8

  private let control = NSLock()
  /// Guarded by `control`.
  private var requestedCents: Float = 0

  private var unit: AudioUnit?
  private var channels = 0
  /// Frames one `process` call handles at most.
  private(set) var capacity = 0
  /// The frames `process` shifts in place, one buffer per channel.
  private(set) var block: [UnsafeMutablePointer<Float>] = []
  private var rendered: [UnsafeMutablePointer<Float>] = []
  private var fifo: [UnsafeMutablePointer<Float>] = []
  private var fifoCapacity = 0
  private var fifoRead = 0
  private var fifoCount = 0
  private var output: UnsafeMutableAudioBufferListPointer?
  private var sampleTime = 0.0
  private var cents: Float = 0
  private var appliedCents: Float = 0
  /// Whether the unit is in the signal path. It stays there after the shift
  /// returns to 0 until the next reset, so audio is never skipped mid-stream.
  private var running = false
  private var failed = false
  /// No frame has left since the last reset, so a start needs no fade out.
  private var fresh = true
  /// Input frames still to fade in after the shift starts.
  private var fadeIn = 0
  /// The shift started mid-stream: fade the unshifted audio out while the
  /// unit fills its latency, instead of cutting it off.
  private var fadeOutDry = false
  private var ramp = 240

  /// Processing latency of the unit, in seconds (0 before `prepare`).
  private(set) var latency = 0.0

  deinit {
    unprepare()
  }

  func setSemitones(_ value: Double) {
    let clamped = value.isFinite ? Float(max(-24, min(24, value))) * 100 : 0
    control.lock()
    requestedCents = clamped
    control.unlock()
  }

  /// Creates the unit for this stream format. Returns false when the format
  /// cannot be shifted; `process` then leaves the audio unchanged.
  @discardableResult
  func prepare(sampleRate: Double, channels: Int, maxFrames: Int) -> Bool {
    unprepare()
    guard sampleRate.isFinite, sampleRate > 0, channels > 0, channels <= Self.maxChannels else {
      return false
    }
    let frames = max(maxFrames, 512)
    self.channels = channels
    ramp = max(1, Int(sampleRate * 0.005))
    capacity = frames
    fifoCapacity = max(frames * 4, 32768)
    block = (0..<channels).map { _ in Self.allocate(frames) }
    rendered = (0..<channels).map { _ in Self.allocate(frames) }
    fifo = (0..<channels).map { _ in Self.allocate(fifoCapacity) }
    output = AudioBufferList.allocate(maximumBuffers: channels)
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_FormatConverter,
      componentSubType: kAudioUnitSubType_NewTimePitch,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { return false }
    var created: AudioUnit?
    guard AudioComponentInstanceNew(component, &created) == noErr, let created else { return false }
    var format = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var maximum = UInt32(frames)
    var callback = AURenderCallbackStruct(
      inputProc: { refCon, _, _, _, frames, data in
        guard let data else { return kAudio_ParamError }
        let shifter = Unmanaged<PitchShifter>.fromOpaque(refCon).takeUnretainedValue()
        shifter.pull(UnsafeMutableAudioBufferListPointer(data), frames: Int(frames))
        return noErr
      },
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    let ready =
      AudioUnitSetProperty(
        created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize)
      == noErr
      && AudioUnitSetProperty(
        created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize)
        == noErr
      && AudioUnitSetProperty(
        created, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum,
        UInt32(MemoryLayout<UInt32>.size)) == noErr
      && AudioUnitSetProperty(
        created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
      && AudioUnitInitialize(created) == noErr
      && AudioUnitSetParameter(created, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, 1, 0)
        == noErr
    guard ready else {
      AudioComponentInstanceDispose(created)
      return false
    }
    var seconds = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    if AudioUnitGetProperty(created, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
      == noErr, seconds.isFinite
    {
      latency = max(0, seconds)
    }
    unit = created
    appliedCents = 0
    reset()
    return true
  }

  func unprepare() {
    if let unit {
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
    }
    unit = nil
    for buffer in block + rendered { buffer.deallocate() }
    for buffer in fifo { buffer.deallocate() }
    block = []
    rendered = []
    fifo = []
    output?.unsafeMutablePointer.deallocate()
    output = nil
    capacity = 0
    channels = 0
    running = false
    failed = false
    latency = 0
  }

  /// Drops buffered audio after a discontinuity such as a seek. Render thread.
  func reset() {
    if let unit { AudioUnitReset(unit, kAudioUnitScope_Global, 0) }
    fifoRead = 0
    fifoCount = 0
    sampleTime = 0
    running = false
    fresh = true
    fadeIn = 0
    fadeOutDry = false
  }

  /// Picks up the requested shift for the next block and returns whether the
  /// block must go through `process`. Render thread.
  func begin() -> Bool {
    if control.try() {
      cents = requestedCents
      control.unlock()
    }
    guard unit != nil, !failed else {
      fresh = false
      return false
    }
    if cents != 0 && !running {
      running = true
      fadeIn = ramp
      fadeOutDry = !fresh
    }
    if !running { fresh = false }
    return running
  }

  /// Shifts `frames` frames of `block` in place. `frames` is at most
  /// `capacity`. Render thread.
  func process(frames: Int) {
    guard let unit, let output, frames > 0, frames <= capacity else { return }
    if cents != appliedCents {
      AudioUnitSetParameter(unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, cents, 0)
      appliedCents = cents
    }
    push(frames)
    for channel in 0..<channels {
      output[channel].mNumberChannels = 1
      output[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
      output[channel].mData = UnsafeMutableRawPointer(rendered[channel])
    }
    var flags = AudioUnitRenderActionFlags()
    var time = AudioTimeStamp()
    time.mSampleTime = sampleTime
    time.mFlags = .sampleTimeValid
    sampleTime += Double(frames)
    fresh = false
    guard AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), output.unsafeMutablePointer) == noErr
    else {
      // The block is still the unshifted input. Stop shifting instead of
      // repeating the failure every block.
      failed = true
      running = false
      fadeOutDry = false
      return
    }
    let fading = fadeOutDry ? min(ramp, frames) : 0
    fadeOutDry = false
    for channel in 0..<channels {
      guard let raw = output[channel].mData else {
        block[channel].update(repeating: 0, count: frames)
        continue
      }
      let data = raw.assumingMemoryBound(to: Float.self)
      for index in 0..<fading {
        block[channel][index] = data[index] + block[channel][index] * (1 - Float(index) / Float(ramp))
      }
      (block[channel] + fading).update(from: data + fading, count: frames - fading)
    }
  }

  private static func allocate(_ count: Int) -> UnsafeMutablePointer<Float> {
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
    buffer.initialize(repeating: 0, count: count)
    return buffer
  }

  /// Appends `block` to the FIFO, dropping the oldest frames on overflow.
  private func push(_ frames: Int) {
    if fifoCount + frames > fifoCapacity {
      let dropped = fifoCount + frames - fifoCapacity
      fifoRead = (fifoRead + dropped) % fifoCapacity
      fifoCount -= dropped
    }
    let start = (fifoRead + fifoCount) % fifoCapacity
    var write = start
    var copied = 0
    while copied < frames {
      let count = min(frames - copied, fifoCapacity - write)
      for channel in 0..<channels {
        (fifo[channel] + write).update(from: block[channel] + copied, count: count)
      }
      copied += count
      write = (write + count) % fifoCapacity
    }
    fifoCount += frames
    // The unit hears the audio start from silence, not mid-waveform.
    let fading = min(fadeIn, frames)
    for index in 0..<fading {
      let gain = Float(ramp - fadeIn + index) / Float(ramp)
      let position = (start + index) % fifoCapacity
      for channel in 0..<channels { fifo[channel][position] *= gain }
    }
    fadeIn -= fading
  }

  /// The unit's input callback. Frames the FIFO does not hold yet are
  /// silence; that happens only while the unit fills its latency.
  private func pull(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
    let available = min(frames, fifoCount)
    for (channel, buffer) in list.enumerated() {
      guard let raw = buffer.mData, Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size
      else { continue }
      let data = raw.assumingMemoryBound(to: Float.self)
      guard channel < channels else {
        data.update(repeating: 0, count: frames)
        continue
      }
      var read = fifoRead
      var copied = 0
      while copied < available {
        let count = min(available - copied, fifoCapacity - read)
        (data + copied).update(from: fifo[channel] + read, count: count)
        copied += count
        read = (read + count) % fifoCapacity
      }
      if available < frames { (data + available).update(repeating: 0, count: frames - available) }
    }
    fifoRead = (fifoRead + available) % fifoCapacity
    fifoCount -= available
  }
}
