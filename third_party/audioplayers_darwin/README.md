# Local audioplayers_darwin patch

Upstream: bluefireteam/audioplayers, `audioplayers_darwin` 6.5.0 (MIT).

The local fork adds the player-specific `setEqualizer` method and an
MTAudioProcessingTap on the existing AVPlayerItem. Audio session ownership,
transport, loading, notifications and the upstream player API are preserved.
The tap processes decoded PCM only, never video artwork or other apps' audio.
EQ is bypassed when disabled. Android's native bit-perfect paths bypass EQ.
AVPlayer external playback is disabled, so AirPlay receives the processed
audio route instead of a full-screen AirPlay video session.
A `setSpatialAudio` method lets the system spatialize mono, stereo and
multichannel audio (the default) or nothing, on the current and later items.
A `setPitch` method shifts the pitch by semitones in the same tap (after the
EQ, duration kept, with about 90 ms of latency while shifted) and chooses
whether the pitch follows the playback rate (varispeed) or stays (spectral,
the default), on the current and later items.

The graphic EQ curve is approximate across output engines: Android uses
DynamicsProcessing; Darwin uses cascaded RBJ peaking biquads. Preset gains and
dynamics controls are portable, but their exact frequency response differs.
HLS/DRM sources that do not allow AVAudioMix are unsupported and report an
error, for the EQ and for a pitch shift.
