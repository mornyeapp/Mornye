import AVFoundation
import MediaToolbox

/// The item's audio tap: the equalizer, then the pitch shift.
final class EqualizerAudioTap {
  let dsp = EqualizerDSP()
  let pitch = PitchShifter()
  private var format = AudioStreamBasicDescription()
  private var frame = [Double](repeating: 0, count: 8)

  /// `feature` names what needs the tap in its errors.
  @MainActor static func attach(
    to item: AVPlayerItem, processor: EqualizerAudioTap, feature: String = "Equalizer"
  ) async throws {
    let protected: Bool
    let tracks: [AVAssetTrack]
    if #available(iOS 15.0, macOS 12.0, *) {
      protected = try await item.asset.load(.hasProtectedContent)
      tracks = try await item.asset.loadTracks(withMediaType: .audio)
    } else {
      protected = item.asset.hasProtectedContent
      tracks = item.asset.tracks(withMediaType: .audio)
    }
    if protected || (item.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8" {
      throw AudioPlayerError.error("\(feature) is unavailable for protected audio or HLS streams")
    }
    guard let track = tracks.first else {
      throw AudioPlayerError.error("\(feature) cannot access this audio track")
    }
    let retained = Unmanaged.passRetained(processor)
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: retained.toOpaque(),
      init: { _, info, storage in storage.pointee = info },
      finalize: { tap in Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, maxFrames, format in
        let processor = Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        processor.format = format.pointee
        processor.dsp.prepare(sampleRate: format.pointee.mSampleRate)
        processor.pitch.prepare(
          sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame),
          maxFrames: Int(maxFrames))
      },
      unprepare: { tap in
        Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
          .pitch.unprepare()
      },
      process: { tap, count, _, buffers, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, count, buffers, flagsOut, nil, framesOut) == noErr else {
          framesOut.pointee = 0
          return
        }
        let processor = Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        // After a discontinuity the shifted audio must not continue from before it.
        if flagsOut.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0 { processor.pitch.reset() }
        processor.process(buffers, frames: Int(framesOut.pointee))
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr, let tap else {
      retained.release()
      throw AudioPlayerError.error("Could not create \(feature.lowercased()) audio tap: \(status)")
    }
    let input = AVMutableAudioMixInputParameters(track: track)
    input.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [input]
    item.audioMix = mix
  }

  private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    // Adopts a new EQ plan without waiting; while one is being written the
    // active filters keep running instead of passing dry audio.
    let equalize = dsp.beginRenderBlock()
    let shift = pitch.begin()
    let channels = Int(format.mChannelsPerFrame)
    guard equalize || shift, channels > 0, channels <= 8,
      format.mFormatID == kAudioFormatLinearPCM else { return }
    let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let bits = Int(format.mBitsPerChannel)
    guard (floating && (bits == 32 || bits == 64)) || (!floating && (bits == 16 || bits == 32)) else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    for buffer in buffers where buffer.mData == nil { return }
    var start = 0
    while start < frames {
      let count = shift ? min(frames - start, pitch.capacity) : frames - start
      for index in start..<(start + count) {
        load(buffers, index: index, floating: floating, bits: bits)
        if equalize { dsp.processFrame(&frame, channels: channels) }
        if shift {
          for channel in 0..<channels { pitch.block[channel][index - start] = Float(frame[channel]) }
        } else {
          store(buffers, index: index, floating: floating, bits: bits)
        }
      }
      if shift {
        pitch.process(frames: count)
        for index in start..<(start + count) {
          for channel in 0..<channels { frame[channel] = Double(pitch.block[channel][index - start]) }
          store(buffers, index: index, floating: floating, bits: bits)
        }
      }
      start += count
    }
  }

  private func load(_ buffers: UnsafeMutableAudioBufferListPointer, index: Int, floating: Bool, bits: Int) {
    var channel = 0
    for buffer in buffers {
      let data = buffer.mData!
      for offset in 0..<Int(buffer.mNumberChannels) {
        let sample = index * Int(buffer.mNumberChannels) + offset
        if floating && bits == 32 { frame[channel] = Double(data.assumingMemoryBound(to: Float.self)[sample]) }
        else if floating { frame[channel] = data.assumingMemoryBound(to: Double.self)[sample] }
        else if bits == 16 { frame[channel] = Double(data.assumingMemoryBound(to: Int16.self)[sample]) / 32768 }
        else { frame[channel] = Double(data.assumingMemoryBound(to: Int32.self)[sample]) / 2147483648 }
        channel += 1
      }
    }
  }

  private func store(_ buffers: UnsafeMutableAudioBufferListPointer, index: Int, floating: Bool, bits: Int) {
    var channel = 0
    for buffer in buffers {
      let data = buffer.mData!
      for offset in 0..<Int(buffer.mNumberChannels) {
        let sample = index * Int(buffer.mNumberChannels) + offset
        let value = frame[channel]
        if floating && bits == 32 { data.assumingMemoryBound(to: Float.self)[sample] = Float(value) }
        else if floating { data.assumingMemoryBound(to: Double.self)[sample] = value }
        else if bits == 16 { data.assumingMemoryBound(to: Int16.self)[sample] = Int16(max(-32768, min(32767, value * 32768))) }
        else { data.assumingMemoryBound(to: Int32.self)[sample] = Int32(max(-2147483648, min(2147483647, value * 2147483648))) }
        channel += 1
      }
    }
  }
}
