# Local audioplayers_darwin patch

Based on `audioplayers_darwin` 6.5.0 from bluefireteam/audioplayers (MIT;
license retained in LICENSE). `README.md` describes the user-facing
behavior; this file lists every difference from upstream.

The root `pubspec.yaml` overrides the federated package with this copy
(`dependency_overrides: audioplayers_darwin: path:
third_party/audioplayers_darwin`), next to `audioplayers: ^6.8.1`. The
version is the one in this folder's `pubspec.yaml` (6.5.0, unchanged).
`CHANGELOG.md`, `analysis_options.yaml` and
`darwin/audioplayers_darwin/.swiftpm` from the upstream package are not
vendored.

## Patches

### Source failure diagnostics

Failed preparation preserves the native NSError domains and codes, including
the underlying chain (five causes at most), instead of replacing every failure
with the same message. It logs the same bounded cause chain. URLs, headers and
other userInfo values are omitted so playback errors cannot expose NAS credentials.

### Per-player equalizer

- AudioplayersDarwinPlugin.swift handles a `setEqualizer` method with a
  `configuration` map. A missing map or a failed attach returns a
  `DarwinAudioError`.
- WrappedMediaPlayer.swift keeps the configuration per player and attaches
  the tap to the current `AVPlayerItem` when the equalizer is enabled (the
  pitch shift below shares the same tap). Each new source gets a fresh tap
  so filter state is never shared between items.
- EqualizerAudioTap.swift (new) installs an `MTAudioProcessingTap` through
  an `AVMutableAudioMix` on the item. Protected assets and `.m3u8` URLs fail
  with "Equalizer is unavailable for protected audio or HLS streams".
- EqualizerDSP.swift (new) processes decoded PCM with cascaded RBJ peaking
  biquads, plus input gain, balance, a compressor and a limiter. It accepts 5, 10,
  15 or 31 bands with gains from -24 to 24 dB, the same limits as the
  Android fork. With a `filters` list in the configuration (the parametric
  equalizer: up to 20 entries of `type` `peak`, `lowshelf` or `highshelf`
  with `frequency`, `gain` and `q`) it plays those cookbook sections in
  place of the bands; an entry it cannot read turns the equalizer off.

### External playback

`WrappedMediaPlayer` sets `player.allowsExternalPlayback = false`. Audio then
follows the system route (AirPlay audio) through the tap, instead of handing
the item to the receiver as an external video session that bypasses the
equalizer.

### Accurate audio seeking

`WrappedMediaPlayer` creates every asset with
`AVURLAssetPreferPreciseDurationAndTimingKey: true`, preserving any MIME
override, and seeks with zero tolerances. Without the precise asset index,
AVFoundation can report the requested FLAC position while decoding audio
from tens of seconds earlier or later. This affects both macOS and iOS,
including lyric taps and timeline scrubbing. Preparing a variable-bitrate
network asset can take longer because its timing must be indexed.

A URL with the fragment `#mornye-arriving` is the exception: the app marks
a song a paired phone is still sending (Mornye Link), served over loopback
HTTP while it is written. Indexing reads to the end of the file, which
stalls until the upload ends, and AVPlayer fails with a request timeout
when the upload is slower than about 2 MB/s. Such an asset is created
without the precise key, from the URL without the fragment, so it starts
at once; its seeks may be approximate until it plays again from the whole
file.

### Spatial audio

A `setSpatialAudio` method (argument `enabled`) sets
`allowedAudioSpatializationFormats` (iOS 14, macOS 11 and later) on the
player's current item and on every item it creates afterwards:
`.monoStereoAndMultichannel` when true (the default), none when false.
Upstream leaves AVFoundation's audio-only default, multichannel only. A
missing value returns a `DarwinAudioError`. AVFoundation does not document
whether a change on an item already playing takes effect at once.

### Speed and pitch

A `setPitch` method (arguments `semitones`, `followsRate`) keeps both values
per player. A missing value returns a `DarwinAudioError`. A player starts at
0 semitones with `followsRate` false.

- Time pitch algorithm: `followsRate` true selects `.varispeed` (the pitch
  follows `setPlaybackRate` like a record), false selects `.spectral` (pitch
  kept, music quality). Upstream creates items with `.timeDomain`; every item
  now starts with the current choice. On a playing or paused item a change
  rebuilds the audio chain at once (the tap is prepared again, with a short
  stall of about 0.3 s measured on macOS) and never starts playback. Both
  algorithms sound the same at rate 1, so the current item gets a new
  algorithm only at a rate other than 1, and `setPlaybackRate` applies it
  just before the new rate.
- Semitones: PitchShifter.swift (new) runs Apple's AUNewTimePitch at rate 1
  with the pitch in cents, inside the item's tap after the equalizer, so the
  duration is kept. The unit pulls from a FIFO of the tap's input, so each
  callback returns exactly the frames it received; output lags by the unit's
  latency (4096 frames, about 85 to 93 ms at 48 or 44.1 kHz). The unit is
  created and its buffers allocated when the tap is prepared; the process
  callback neither allocates nor waits for a lock (it picks up a new shift
  with `NSLock.try`). A shift started mid-stream fades the unshifted audio
  out and the unit's input in, with silence for the latency between. When
  the shift returns to 0 the unit stays in the path (bit-exact, only
  delayed) until the next discontinuity, so audio is never skipped; after
  that 0 bypasses it. The tap receives audio after the rate change, so with
  varispeed the result is `2^(semitones/12) * rate`.
- The tap is attached when the equalizer is on or the shift is not 0, also
  for every later source of the player (before `onPrepared`; a failure is
  logged). It stays attached and passes audio through when neither needs it
  any more; the next source gets none. Changing the shift updates the
  running unit without a new tap. A shift on protected audio or `.m3u8`
  fails with "Pitch shift is unavailable for this source" and the details
  "Pitch shift is unavailable for protected audio or HLS streams".
- The tap resets the shifter on `kMTAudioProcessingTapFlag_StartOfStream`.
  AVFoundation did not set that flag after a seek on macOS, so after a seek
  the old position plays for the latency before the new one.

### Rate changes keep the clock

Upstream sets `player.rate`. On macOS that holds the item's clock while
the audio restarts at the new rate: every change, with every time pitch
algorithm and also between two rates other than 1, left the song 21 to 26 ms
further behind its clock, so small repeated changes (Mornye Link Play
together nudges 1.02 and back) never closed a gap. `setPlaybackRate` on a
playing item now pins the item time at the current host instant with
`setRate(_:time:atHostTime:)`, read from the item's own timebase, turning
`automaticallyWaitsToMinimizeStalling` off for that call only. Measured
change: 3.4 ms on a change away from 1, none back to 1. A player that waits
for data, is not moving, or whose item has the tap (equalizer or pitch shift)
still sets `rate`: with the tap both ways moved the clock by tens of
milliseconds per change, the pinned one up to 200 ms when leaving a rate.

### Packaging

- `darwin/audioplayers_darwin.podspec` adds
  `s.frameworks = 'AVFoundation', 'AudioToolbox', 'MediaToolbox'` for the
  tap and the pitch shifter.
- `pubspec.yaml` drops `resolution: workspace`; this copy is not a member of
  the upstream pub workspace.
- `pubspec.lock` in this folder is tracked but not part of upstream.

### Source lifecycle

`WrappedMediaPlayer` owns the pending preparation continuation and completes it
when a source is replaced or disposed. KVO callbacks return to the main actor
and verify the item still belongs to the player. Queued completion notifications
from an outgoing item cannot reset or release its replacement. The plugin treats
cancelled preparation as a completed method call without a playback error.
The `getDuration` branch returns after delivering its duration so the same
method call cannot receive the default result a second time.

### Next player

A `setNextPlayer` method with an optional `nextPlayerId` sets
`WrappedMediaPlayer.next` (weak) for gapless playback. Linking prerolls the
next player's loaded item. When the current item ends, the completion
handler resumes the next player before anything else, then reports
completion. Replacing or releasing the current item clears the link; no
`nextPlayerId` unlinks it.

## Tests

`tests/EqualizerDSPTests.swift` is a standalone `@main` program for the DSP.
No script or CI job runs it. On macOS:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/EqualizerDSP.swift \
  tests/EqualizerDSPTests.swift -o /tmp/eq_dsp_tests && /tmp/eq_dsp_tests
```

Build without `-O` so its `assert` checks stay active. It prints a `PASS`
line on success.

`tests/PitchShifterTests.swift` checks the pitch shifter the same way: a
440 Hz sine comes out near 880 Hz at +12 and 220 Hz at -12 semitones (44.1,
48 and 96 kHz, mono, stereo and 5.1), with steady energy and no dropouts
after the latency, through irregular block sizes; 0 semitones is bit-exact;
a shift started mid-stream does not click; returning to 0 only delays until
a reset; unsupported formats are left unchanged:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/PitchShifter.swift \
  tests/PitchShifterTests.swift -o /tmp/pitch_shifter_tests && /tmp/pitch_shifter_tests
```

`tests/PitchPlaybackTests.swift` plays generated sine files (muted) through
the production wrapper and a real AVPlayer, and measures the shifter's
output: `setPitch` while paused attaches the tap without playing, a change
while playing keeps the running tap, spectral keeps the pitch at 1.5x,
varispeed set while playing follows the rate at once, paused changes stay
paused, the algorithm waits for a rate other than 1, later sources keep both
values, and the equalizer and the shift share the tap. It takes under half
a minute:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/{WrappedMediaPlayer,Utils,AudioPlayerError,EqualizerAudioTap,EqualizerDSP,PitchShifter}.swift \
  tests/PitchPlaybackTests.swift -o /tmp/pitch_playback_tests
/tmp/pitch_playback_tests
```

`tests/AccurateSeekTests.swift` exercises the production wrapper against the
real AVFoundation decoder, with only Flutter channel delivery stubbed. Pass
a variable-bitrate FLAC longer than 10 seconds. No music fixture is bundled.
The test compares decoded PCM after forward and backward seeks against a
precisely indexed reference, with and without a MIME override:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/{WrappedMediaPlayer,Utils,AudioPlayerError,EqualizerAudioTap,EqualizerDSP,PitchShifter}.swift \
  tests/AccurateSeekTests.swift -o /tmp/accurate_seek_tests
/tmp/accurate_seek_tests /path/to/variable-bitrate.flac
```

The same sources can be compiled with the iOS simulator SDK and run with
`simctl spawn` to check the shared iOS implementation.

`tests/RateChangeTests.swift` plays a generated sine file (muted) through the
production wrapper and a real AVPlayer, moves its rate between 1, 1.02 and
0.98, and requires each change to move the item's clock by 8 ms at most
against the rates asked for (the plain `rate` change lost 21 to 26 ms each
time). It also checks that a change while paused stays paused, and prints
the clock movement with the tap attached without asserting it. It takes
about 20 seconds:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/{WrappedMediaPlayer,Utils,AudioPlayerError,EqualizerAudioTap,EqualizerDSP,PitchShifter}.swift \
  tests/RateChangeTests.swift -o /tmp/rate_change_tests
/tmp/rate_change_tests
```

`tests/SourceLifecycleTests.swift` uses a deferred AVPlayer for cancellation and
real generated WAV files for successful preparation, failed preparation,
stale completion delivery and a linked next player starting on completion.
It does not need an external music fixture:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/{WrappedMediaPlayer,Utils,AudioPlayerError,EqualizerAudioTap,EqualizerDSP,PitchShifter}.swift \
  tests/SourceLifecycleTests.swift -o /tmp/source_lifecycle_tests
/tmp/source_lifecycle_tests
```

Optional URL arguments also exercise real AVPlayer HTTP preparation. From the
application root, set `MORNYE_DARWIN_SOURCE_TEST` to that compiled binary and run
`flutter test test/network_storage_darwin_test.dart` to check the complete NAS
proxy route. The fixture serves generated WAV audio as generic bytes and checks
that the native player can prepare it through the proxy with byte-range reads.
This host check does not replace testing on a physical iPhone.

## Changed Files

Compared against the pub.dev 6.5.0 package in the local pub cache:

- `darwin/audioplayers_darwin.podspec`
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/AudioplayersDarwinPlugin.swift`
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/WrappedMediaPlayer.swift`
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/EqualizerAudioTap.swift` (new)
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/EqualizerDSP.swift` (new)
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/PitchShifter.swift` (new)
- `tests/EqualizerDSPTests.swift` (new)
- `tests/PitchShifterTests.swift` (new)
- `tests/PitchPlaybackTests.swift` (new)
- `tests/AccurateSeekTests.swift` (new)
- `tests/SourceLifecycleTests.swift` (new)
- `tests/RateChangeTests.swift` (new)
- `pubspec.yaml`, `README.md`, `pubspec.lock` (new)

## Upgrading

1. Fetch both versions: `dart pub cache add audioplayers_darwin --version 6.5.0`
   and the same for the new version.
2. Record the local patch:
   `diff -ru ~/.pub-cache/hosted/pub.dev/audioplayers_darwin-6.5.0 third_party/audioplayers_darwin`.
3. Replace the sources with the new upstream files and re-apply each patch
   above. Keep the `setEqualizer` and `setPitch` arguments in step with the
   Android fork and with `lib/services/music_playback_deck.dart` in the app.
4. Run the DSP, pitch shifter and pitch playback tests above, then test the
   equalizer, speed and pitch, source changes and AirPlay audio on a device.
5. Run `flutter pub get` and `(cd ios && pod install)`, then update this file.
