# Synthetic DSD fixture

`dsd-pattern.wv` is original test data, not a music recording. WavPack 5.9.0
encoded a stereo DSD64 DSF with 16,384 bytes per channel and 4,096-byte channel
blocks. Normalized MSB-first byte `i` of channel `c` is `(i * 17 + c * 29) & 255`.
The DSF input stores those bytes with reversed bits (LSB-first).

This tests lossless WavPack DSD decoding, channel order, seek alignment, native
LE/BE packing and DoP packing against known bytes. It is packaged only in the
instrumentation test APK.

## Synthetic 24-bit PCM fixture

`pcm24-pattern.flac` contains 0.1 seconds of stereo 24-bit/96-kHz audio with
constant integer samples `1193047` and `-1193047` in its left/right channels.
The nonzero low bits detect truncation to 16-bit PCM. It tests native FLAC
decoding, lossless padding to 32-bit output, seeking and SAF descriptor lifetime.
Generate with FFmpeg:

```sh
ffmpeg -f lavfi -i 'aevalsrc=1193047/8388608|-1193047/8388608:s=96000:d=0.1' \
  -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 pcm24-pattern.flac
```

## Synthetic gapless fixtures

`gapless-a.flac` and `gapless-b.flac` are two seconds of mono 16-bit
44.1-kHz sine tones (440 and 660 Hz) at -20 dB. `Media3GaplessTest` plays
one into the other to check that a queued handoff keeps its audio track.
Generate with `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100:duration=2
-af volume=0.1 -ac 1 -c:a flac -sample_fmt s16 gapless-a.flac` (660 for
`gapless-b.flac`).

## Synthetic motion artwork fixtures

`motion-probe-h264.mp4` and `motion-probe-hevc.mp4` contain one second of the
FFmpeg `testsrc2` pattern at 32x32 pixels and two frames per second. They are
original generated test data and are packaged only in the instrumentation APK.
The capability test validates decoding and MP4 stream-copy after reducing the
shipped FFmpeg dependency. Generate with `-f lavfi -i testsrc2=size=32x32:rate=2
-t 1 -an -pix_fmt yuv420p -movflags +faststart`, using `-c:v libx264` or
`-c:v libx265 -x265-params log-level=error:pools=1 -tag:v hvc1` respectively.

For a live encrypted HLS gate through `MotionArtworkProxy`, forward its local
port with `adb reverse tcp:PORT tcp:PORT` and pass
`-e motionProxyUrl http://127.0.0.1:PORT/TOKEN/0.m3u8` to the instrumentation
runner for `com.zarz.mornye.FFmpegCapabilitiesTest`. The optional gate decodes
the input, remuxes it, then decodes the resulting MP4 using the shipped native
library. Normal fixture tests run without a server or this argument.
