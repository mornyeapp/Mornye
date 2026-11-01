import AVFoundation
import Foundation

// Only Flutter's channel boundary is stubbed. The production wrapper, asset
// creation, decoder and seek calls all run against AVFoundation.
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

@main struct AccurateSeekTests {
  enum Failure: Error {
    case message(String)
  }

  static func samples(_ asset: AVAsset, at seconds: Double) async throws -> Data {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw Failure.message("Missing audio track")
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
      duration: CMTime(seconds: 0.1, preferredTimescale: 1_000_000))
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? Failure.message("Cannot decode audio")
    }
    defer { reader.cancelReading() }
    var result = Data()
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else {
        throw Failure.message("Missing PCM data")
      }
      var length = 0
      var pointer: UnsafeMutablePointer<Int8>?
      let status = CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil,
        totalLengthOut: &length, dataPointerOut: &pointer)
      guard status == noErr, let pointer else {
        throw Failure.message("Cannot read PCM data")
      }
      result.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length)
    }
    guard !result.isEmpty, reader.status != .failed else {
      throw reader.error ?? Failure.message("No decoded samples")
    }
    return result
  }

  @MainActor static func main() async {
    do {
      guard CommandLine.arguments.count == 2 else {
        throw Failure.message("Usage: accurate_seek_tests /path/to/variable-bitrate.flac")
      }
      let url = URL(fileURLWithPath: CommandLine.arguments[1])
      let reference = AVURLAsset(
        url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      let duration = try await reference.load(.duration).seconds
      guard duration > 10 else { throw Failure.message("Use a FLAC longer than 10 seconds") }

      // Exercise both local-file asset branches, including the MIME override.
      for mime in [nil, "audio/flac"] as [String?] {
        let native = AVPlayer()
        native.isMuted = true
        let wrapper = WrappedMediaPlayer(
          reference: AudioplayersDarwinPlugin(),
          eventHandler: AudioPlayersStreamHandler(), player: native)
        try await wrapper.setSourceUrl(url: url.path, isLocal: true, mimeType: mime)
        guard let actualDuration = wrapper.getDuration(),
          abs(Double(actualDuration) / 1000 - duration) < 0.001
        else {
          throw Failure.message("Prepared player duration does not match the precise asset")
        }
        guard let asset = native.currentItem?.asset else {
          throw Failure.message("Player did not prepare the asset")
        }
        for fraction in [0.04, 0.405, 0.777, 0.116] {
          let target = duration * fraction
          await wrapper.seek(time: CMTime(seconds: target, preferredTimescale: 1_000_000))
          let expected = try await samples(reference, at: target)
          let actual = try await samples(asset, at: target)
          guard actual == expected else {
            throw Failure.message(
              "Decoded audio differs after seek to \(target), MIME \(mime ?? "none")")
          }
        }
        await wrapper.dispose()
      }
      print("PASS: forward/backward FLAC seeks match precise PCM with and without a MIME override")
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
