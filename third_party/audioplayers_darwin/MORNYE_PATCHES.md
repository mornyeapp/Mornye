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

### Per-player equalizer

- AudioplayersDarwinPlugin.swift handles a `setEqualizer` method with a
  `configuration` map. A missing map or a failed attach returns a
  `DarwinAudioError`.
- WrappedMediaPlayer.swift keeps the configuration per player and attaches
  the tap to the current `AVPlayerItem` when the equalizer is enabled. Each
  new source gets a fresh tap so filter state is never shared between items.
- EqualizerAudioTap.swift (new) installs an `MTAudioProcessingTap` through
  an `AVMutableAudioMix` on the item. Protected assets and `.m3u8` URLs fail
  with "Equalizer is unavailable for protected audio or HLS streams".
- EqualizerDSP.swift (new) processes decoded PCM with cascaded RBJ peaking
  biquads, plus input gain, balance, a compressor and a limiter. It accepts 5, 10,
  15 or 31 bands with gains from -24 to 24 dB, the same limits as the
  Android fork.

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

### Packaging

- `darwin/audioplayers_darwin.podspec` adds
  `s.frameworks = 'AVFoundation', 'MediaToolbox'` for the tap.
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

`tests/AccurateSeekTests.swift` exercises the production wrapper against the
real AVFoundation decoder, with only Flutter channel delivery stubbed. Pass
a variable-bitrate FLAC longer than 10 seconds. No music fixture is bundled.
The test compares decoded PCM after forward and backward seeks against a
precisely indexed reference, with and without a MIME override:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/{WrappedMediaPlayer,Utils,AudioPlayerError,EqualizerAudioTap,EqualizerDSP}.swift \
  tests/AccurateSeekTests.swift -o /tmp/accurate_seek_tests
/tmp/accurate_seek_tests /path/to/variable-bitrate.flac
```

The same sources can be compiled with the iOS simulator SDK and run with
`simctl spawn` to check the shared iOS implementation.

`tests/SourceLifecycleTests.swift` uses a deferred AVPlayer for cancellation and
real generated WAV files for successful preparation, failed preparation and
stale completion delivery. It does not need an external music fixture:

```bash
cd third_party/audioplayers_darwin
swiftc darwin/audioplayers_darwin/Sources/audioplayers_darwin/{WrappedMediaPlayer,Utils,AudioPlayerError,EqualizerAudioTap,EqualizerDSP}.swift \
  tests/SourceLifecycleTests.swift -o /tmp/source_lifecycle_tests
/tmp/source_lifecycle_tests
```

## Changed Files

Compared against the pub.dev 6.5.0 package in the local pub cache:

- `darwin/audioplayers_darwin.podspec`
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/AudioplayersDarwinPlugin.swift`
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/WrappedMediaPlayer.swift`
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/EqualizerAudioTap.swift` (new)
- `darwin/audioplayers_darwin/Sources/audioplayers_darwin/EqualizerDSP.swift` (new)
- `tests/EqualizerDSPTests.swift` (new)
- `tests/AccurateSeekTests.swift` (new)
- `tests/SourceLifecycleTests.swift` (new)
- `pubspec.yaml`, `README.md`, `pubspec.lock` (new)

## Upgrading

1. Fetch both versions: `dart pub cache add audioplayers_darwin --version 6.5.0`
   and the same for the new version.
2. Record the local patch:
   `diff -ru ~/.pub-cache/hosted/pub.dev/audioplayers_darwin-6.5.0 third_party/audioplayers_darwin`.
3. Replace the sources with the new upstream files and re-apply each patch
   above. Keep the `setEqualizer` arguments in step with the Android fork and
   with `lib/services/music_playback_deck.dart` in the app.
4. Run the DSP test above, then test the equalizer, source changes and
   AirPlay audio on a device.
5. Run `flutter pub get` and `(cd ios && pod install)`, then update this file.
