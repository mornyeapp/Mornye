<p align="center">
  <a href="https://pub.dev/packages/audioplayers">
    <img alt="AudioPlayers" height="150px" src="https://raw.githubusercontent.com/bluefireteam/audioplayers/main/images/logo_ap_compact.svg">
  </a>
</p>

---

# audioplayers_android
<p>
  <a title="Pub" href="https://pub.dev/packages/audioplayers_android"><img src="https://img.shields.io/pub/v/audioplayers_android.svg?style=popout&include_prereleases"/></a>
  <a title="Build Status" href="https://github.com/bluefireteam/audioplayers/actions?query=workflow%3Abuild+branch%3Amain"><img src="https://github.com/bluefireteam/audioplayers/actions/workflows/build.yml/badge.svg?branch=main"/></a>
  <a title="Discord" href="https://discord.gg/pxrBmy4"><img src="https://img.shields.io/discord/509714518008528896.svg"/></a>
  <a title="Melos" href="https://github.com/invertase/melos"><img src="https://img.shields.io/badge/maintained%20with-melos-f700ff.svg"/></a>
</p>

The Android implementation of [`audioplayers`](https://pub.dev/packages/audioplayers).

## Mornye local changes

Player commands and native callbacks run on one owned playback Looper, so a slow
MediaPlayer reset/release cannot hold Android's input thread. Flutter channel
registration and events still run on the main thread. Engine detach queues
cleanup without waiting for the media service.

In addition to preserving granted proxy file descriptors, this fork exposes a
player-specific `setEqualizer` method. On Android 9+, `DynamicsProcessing` attaches
to that player's nonzero audio session and provides graphic EQ, preamp, balance,
compression and limiting. Effects are released with the underlying player and
restored by the playback deck after source preparation. Unsupported effects are
reported to the editor without stopping playback. Direct USB and exclusive
bit-perfect paths bypass these effects.

API reference: https://developer.android.com/reference/android/media/audiofx/DynamicsProcessing

A `setNextPlayer` method links a prepared player to start the moment another
completes, through `MediaPlayer.setNextMediaPlayer`, for gapless playback.

While a player plays on Android 9+, an effect with no processing in use stays
enabled on its session, so the platform mixes its audio instead of sending it
to a compressed offload output. System features that read the mixed output,
such as music-synced phone lights, then receive the music.

## Usage

This package is [endorsed](https://flutter.dev/docs/development/packages-and-plugins/developing-packages#endorsed-federated-plugin),
which means you can simply use `audioplayers` normally.
This package will be automatically included in your app when you do, so you do not need to add it to your `pubspec.yaml`.
