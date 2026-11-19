# Direct USB audio

Android USB host transport for local FLAC/WAV PCM, uncompressed DSF/DSDIFF and
lossless WavPack DSD.
The existing Android 14 preferred-mixer path remains available. Direct USB is
opt-in under Settings > Playback > Hi-res and bit-perfect audio.

## Ownership and playback

- Android asks for USB permission; the engine, not the Activity, owns the
  connection. Permission denial and absent hardware leave PCM on normal output.
- One Rust worker owns libusb, its claimed interfaces, four isochronous output
  transfers, and a separate explicit-feedback transfer. The bounded queue holds
  approximately 200 ms of audio (minimum 256 KiB). There is no resampling or gain.
- UAC1 fixed rates are verified from descriptors; variable UAC1/UAC2 rates are
  read back from the endpoint/clock. Implicit feedback, ambiguous clocks, and
  multiple configurations fail closed. Endpoint capacities bound packet sizes.
- Fractional rates and 10.14/16.16 feedback determine packet lengths. Completed
  data frames advance position; silence inserted during an underrun does not.
- Every native transfer is cancelled and acknowledged before its memory is
  freed. The worker joins before Android closes the original USB descriptor.
  Interfaces are released and the kernel driver reattached automatically.
- Pause/seek discard queued audio and reopen the decoder position at the last
  completed frame. Disconnect pauses playback; it never redirects active USB
  playback to the speaker. Pending permission requests can be cancelled by Next.
- ReplayGain, AutoMix, software volume and playback-rate processing are bypassed
  while USB mode is selected. Volume is controlled at the DAC's USB Feature Unit.

## Hardware volume

- Follow the selected playback terminal to a UAC1/UAC2 Feature Unit. Do not
  modify capture controls, guess a mixer/selector route, or advertise volume
  when only some channels are writable.
- Read GET_MIN/MAX/RES (UAC1) or RANGE (UAC2), then SET_CUR and read back CUR.
  Master volume is preferred; otherwise all playback channels must be writable.
  Values are signed 1/256 dB. Gaps/steps round down; positive gain is not offered.
- Before the first audio transfer, lower each channel to at most -40 dB, keeping
  quieter or already silent channels. Reuse a user-selected volume between songs
  on the same attached device, respecting a hardware knob lowered externally.
  Remove remembered levels on detach. This is attenuation, not a guarantee of
  safe acoustic output for every amplifier/headphone combination.
- The Mornye player slider and Playback settings control verified DAC
  volume. They never modify DSD/DoP samples or apply software gain. Phone volume
  buttons may not affect direct USB output.
- Warn before enabling the mode. A DAC without verified hardware volume stays
  paused unless the user explicitly enables fixed-volume output after a second
  warning. A failure after direct-USB preparation never redirects to the speaker.

## DSD

`DsdFile.kt` normalizes DSF channel blocks/LSB ordering and DFF byte-interleaved
MSB data without loading the file into memory. Native U32 uses the device's
byte ordering. DoP uses 24-bit words, left-aligned when carried in 32-bit slots.
WavPack 5.9.0 decodes compressed DSD to the same MSB-first bitstream through a
small JNI bridge (`OPEN_DSD_NATIVE`, checksums enabled). It retains its own file
descriptor across SAF lease closure and never converts DSD into PCM. Reads and
seeks are bounded; only mono/stereo DSD64 through DSD512 are accepted.
The transport assigns alternating 05/FA markers across all frames, including
inserted DSD silence. Seeking retains channel/frame alignment.

Native DSD initially recognizes these exact USB identities and alternate
settings; no product-name match or assumption that PCM support implies DSD:

| VID:PID | Alternate | Firmware | Encoding |
| --- | --- | --- | --- |
| 16d0:071a (Amanero Combo384) | 2 | 0199 | U32 LE |
| 16d0:071a (Amanero Combo384) | 2 | 019b, 0203 | U32 BE |
| 2772:0230 (Pro-Ject Pre Box S2 Digital) | 2 | any | U32 BE |
| 20b1:3089 (Mola-Mola) | 2 | any | U32 BE |

DoP is a separate opt-in for a DAC explicitly known to support it; USB audio
descriptors do not announce DoP support. Keep it disabled for ordinary USB
headsets. Unsupported DSD is stopped rather than interpreted as PCM audio.
DSD DST compression, DSD-to-PCM conversion and vendor-specific internal DAP DSD
commands are not implemented. SAF scanning reads basic DSD format/duration and
uses the filename for metadata; embedded DSD artwork/tags are not yet imported.

## Verification

- Rust descriptor/clock tests: UAC1 and UAC2 fixtures, malformed data, exact
  native-DSD identity matching, precision rejection, fractional rates/feedback.
- JVM tests: DSF padding/bit order, DFF channel order, native LE/BE, DoP layout,
  seeking, truncated containers and compressed-DST rejection.
- Android instrumentation: absent USB fallback, real native FFI error cleanup,
  integer WAV decode/seek after the original SAF descriptor is closed, synthetic
  WavPack DSD byte equality through native/DoP packing, seek and EOF behavior.
- Hardware volume host tests: UAC1/UAC2 ranges and read-back, failed verification,
  silence preservation, independent channel attenuation and playback topology.
- Flutter tests: opt-in settings, transport options, cancellation, stale replies,
  DSD failure without PCM fallback, existing playback/queue/DSP behavior.

The user reported working physical USB DSP playback with the previous direct
USB build (device model unspecified). New hardware volume, native DSD/DoP and
long playback stability still require device testing. Host tests, emulator
tests and successful ARM32/ARM64 builds do not establish DAC compatibility.

## DAP PCM hi-res

The separate **DAP hi-res (AAudio exclusive)** option uses Oboe 1.11.0 on Android
8.1+. It opens at the source rate/channels and sufficient precision, with Oboe
conversion disabled. Integer PCM is padded losslessly when necessary; float
output is allowed only for <=24-bit sources with exact representation. A bounded
single-producer/single-consumer queue feeds the audio callback without allocation,
locking or file I/O. Hardware timestamps exclude inserted silence from position.

Android may grant Shared when Exclusive was requested. Verify the actual API,
sharing mode, rate, channels and format before reporting active output. If no
matching exclusive stream is available, close it and use ordinary playback.
DSD is rejected before reaching this PCM engine. Disconnect after starting
pauses playback. This does not claim to bypass undocumented vendor DSP.

The current emulator only grants Shared; instrumentation verifies rejection.
Actual exclusive DAP playback and route-specific hardware behavior need a DAP.

## Reference and dependencies

All three Android PCM paths share `UsbPcmSource`. Native FLAC is decoded with
libFLAC directly from the original file, rather than Android `MediaExtractor`:
some vendor extractors expose 24-bit FLAC as already-decoded 16-bit `audio/raw`.
The decoder keeps one bounded block, writes integer PCM into a reused direct
buffer, and supports sample-accurate seeking and retained SAF descriptors.
16/24/32-bit sources may be padded to a wider DAC format but never truncated.
The reported bit depth is the negotiated output format.

Decoder sample/seek tests can run without building an APK:

```sh
cmake -S android/app/src/main/cpp -B /tmp/mornye-flac-tests \
  -DMORNYE_AUDIO_HOST_TESTS=ON
cmake --build /tmp/mornye-flac-tests
ctest --test-dir /tmp/mornye-flac-tests --output-on-failure
```

USB identity/format facts were checked against
[Linux USB audio quirks](https://github.com/torvalds/linux/blob/master/sound/usb/quirks.c).
The Android-only `libusb1-sys` dependency builds its unmodified bundled libusb;
license texts and rebuild information are in `assets/licenses/usb.txt` and in
the app's license registry. Oboe (Apache-2.0), WavPack and libFLAC (BSD-3-Clause) are built
statically into `libmornye_audio.so` for ARM32/ARM64. Their pinned release URLs
and SHA-256 checksums are in `android/app/src/main/cpp/CMakeLists.txt`; licenses
are included in `assets/licenses/oboe.txt`, `assets/licenses/wavpack.txt` and
`assets/licenses/flac.txt`.
